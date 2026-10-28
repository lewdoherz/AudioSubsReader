#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::string WindowsError(const char* operation, DWORD code) {
  return std::string(operation) + " failed (Windows error " +
         std::to_string(code) + ").";
}

bool ReadWindowStyle(HWND window, int index, LONG_PTR* value) {
  SetLastError(ERROR_SUCCESS);
  *value = GetWindowLongPtr(window, index);
  return *value != 0 || GetLastError() == ERROR_SUCCESS;
}

bool WriteWindowStyle(HWND window, int index, LONG_PTR value) {
  SetLastError(ERROR_SUCCESS);
  return SetWindowLongPtr(window, index, value) != 0 ||
         GetLastError() == ERROR_SUCCESS;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  OnDestroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  display_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "audiosubs_reader/display",
          &flutter::StandardMethodCodec::GetInstance());
  display_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() != "setFullscreen") {
          result->NotImplemented();
          return;
        }
        const auto* enabled = call.arguments()
                                  ? std::get_if<bool>(call.arguments())
                                  : nullptr;
        if (!enabled) {
          result->Error("invalid_argument",
                        "setFullscreen requires a boolean argument.");
          return;
        }
        std::string error;
        if (!SetFullscreen(*enabled, &error)) {
          result->Error("fullscreen_failed", error);
          return;
        }
        result->Success();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (display_channel_) {
    display_channel_->SetMethodCallHandler(nullptr);
    display_channel_.reset();
  }
  flutter_controller_.reset();
  Win32Window::OnDestroy();
}

bool FlutterWindow::CaptureWindowState(WindowState* state, std::string* error) {
  const HWND window = GetHandle();
  state->placement.length = sizeof(WINDOWPLACEMENT);
  if (!ReadWindowStyle(window, GWL_STYLE, &state->style) ||
      !ReadWindowStyle(window, GWL_EXSTYLE, &state->extended_style) ||
      !GetWindowPlacement(window, &state->placement) ||
      !GetWindowRect(window, &state->bounds)) {
    *error = WindowsError("Saving the window presentation", GetLastError());
    return false;
  }
  return true;
}

bool FlutterWindow::RestoreWindowState(const WindowState& state,
                                       std::string* error) {
  const HWND window = GetHandle();
  bool restored = true;
  // Attempt every restoration step even if an earlier one fails. Keep the
  // snapshot until all steps succeed, so a later exit request can retry.
  const auto record_failure = [&](const char* operation) {
    if (restored) {
      *error = WindowsError(operation, GetLastError());
    }
    restored = false;
  };
  if (!WriteWindowStyle(window, GWL_STYLE, state.style)) {
    record_failure("Restoring the window style");
  }
  if (!WriteWindowStyle(window, GWL_EXSTYLE, state.extended_style)) {
    record_failure("Restoring the extended window style");
  }
  if (!SetWindowPlacement(window, &state.placement)) {
    record_failure("Restoring the window placement");
  }
  UINT flags = SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED;
  // WINDOWPLACEMENT retains the restore rectangle for maximized/minimized
  // windows. For a normal window also restore its exact screen rectangle;
  // rcNormalPosition alone is expressed in workspace coordinates.
  if ((state.style & (WS_MAXIMIZE | WS_MINIMIZE)) != 0) {
    flags |= SWP_NOMOVE | SWP_NOSIZE;
  }
  if (!SetWindowPos(window, nullptr, state.bounds.left, state.bounds.top,
                    state.bounds.right - state.bounds.left,
                    state.bounds.bottom - state.bounds.top, flags)) {
    record_failure("Restoring the window bounds");
  }
  return restored;
}

bool FlutterWindow::FitFullscreenToMonitor(HMONITOR monitor,
                                           DWORD* error) noexcept {
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!monitor || !GetMonitorInfo(monitor, &monitor_info)) {
    *error = GetLastError();
    return false;
  }
  const RECT& bounds = monitor_info.rcMonitor;
  if (!SetWindowPos(GetHandle(), nullptr, bounds.left, bounds.top,
                    bounds.right - bounds.left, bounds.bottom - bounds.top,
                    SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
    *error = GetLastError();
    return false;
  }
  return true;
}

bool FlutterWindow::SetFullscreen(bool enabled, std::string* error) {
  if (!GetHandle() || !IsWindow(GetHandle())) {
    *error = "The reader window is no longer available.";
    return false;
  }
  if (fullscreen_transition_) {
    *error = "Another window presentation transition is in progress.";
    return false;
  }
  if (restore_pending_) {
    fullscreen_transition_ = true;
    const bool restored = RestoreWindowState(windowed_state_, error);
    fullscreen_transition_ = false;
    if (!restored) {
      return false;
    }
    restore_pending_ = false;
    fullscreen_ = false;
  }
  if (enabled == fullscreen_) {
    return true;
  }
  if (!enabled) {
    WindowState previous_fullscreen;
    if (!CaptureWindowState(&previous_fullscreen, error)) {
      return false;
    }
    fullscreen_transition_ = true;
    const bool restored = RestoreWindowState(windowed_state_, error);
    if (!restored) {
      std::string rollback_error;
      if (!RestoreWindowState(previous_fullscreen, &rollback_error)) {
        restore_pending_ = true;
        *error += " Fullscreen rollback also failed: " + rollback_error;
      }
    }
    fullscreen_transition_ = false;
    if (restored) {
      fullscreen_ = false;
    }
    return restored;
  }

  if (!CaptureWindowState(&windowed_state_, error)) {
    return false;
  }
  // Choose the monitor before restoring a maximized window: its normal restore
  // rectangle can be on a different monitor.
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  const HMONITOR monitor =
      MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST);
  if (!monitor || !GetMonitorInfo(monitor, &monitor_info)) {
    *error = WindowsError("Finding the reader monitor", GetLastError());
    return false;
  }

  fullscreen_transition_ = true;
  bool applied = true;
  WINDOWPLACEMENT normal_placement = windowed_state_.placement;
  normal_placement.showCmd = SW_SHOWNORMAL;
  normal_placement.flags &= ~WPF_RESTORETOMAXIMIZED;
  if (!SetWindowPlacement(GetHandle(), &normal_placement)) {
    *error = WindowsError("Preparing the fullscreen window", GetLastError());
    applied = false;
  }
  if (applied &&
      !WriteWindowStyle(GetHandle(), GWL_STYLE,
                        windowed_state_.style &
                            ~(WS_OVERLAPPEDWINDOW | WS_MAXIMIZE | WS_MINIMIZE))) {
    *error = WindowsError("Removing the window frame", GetLastError());
    applied = false;
  }
  if (applied &&
      !WriteWindowStyle(GetHandle(), GWL_EXSTYLE,
                        windowed_state_.extended_style &
                            ~(WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE |
                              WS_EX_DLGMODALFRAME | WS_EX_STATICEDGE))) {
    *error = WindowsError("Removing the extended window frame", GetLastError());
    applied = false;
  }
  const RECT& bounds = monitor_info.rcMonitor;
  if (applied &&
      !SetWindowPos(GetHandle(), nullptr, bounds.left, bounds.top,
                    bounds.right - bounds.left, bounds.bottom - bounds.top,
                    SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
    *error = WindowsError("Sizing the fullscreen window", GetLastError());
    applied = false;
  }
  if (!applied) {
    std::string rollback_error;
    if (!RestoreWindowState(windowed_state_, &rollback_error)) {
      restore_pending_ = true;
      *error += " Window restoration also failed: " + rollback_error;
    }
  }
  fullscreen_transition_ = false;
  fullscreen_ = applied;
  return applied;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Flutter still receives DPI/size messages. WM_SIZE then reaches the base
  // handler, which resizes the existing child view without recreating it.
  std::optional<LRESULT> flutter_result;
  if (flutter_controller_) {
    flutter_result = flutter_controller_->HandleTopLevelWindowProc(
        hwnd, message, wparam, lparam);
  }

  if ((message == WM_DPICHANGED || message == WM_DISPLAYCHANGE) &&
      (fullscreen_ || fullscreen_transition_)) {
    if (!fullscreen_transition_) {
      fullscreen_transition_ = true;
      DWORD error = ERROR_SUCCESS;
      // During WM_DPICHANGED the native window can still be on its old monitor.
      // Use the suggested rectangle to identify the destination, then fill that
      // monitor rather than adopting the suggested decorated-window size.
      const HMONITOR monitor = message == WM_DPICHANGED
          ? MonitorFromRect(reinterpret_cast<const RECT*>(lparam),
                            MONITOR_DEFAULTTONEAREST)
          : MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      if (!FitFullscreenToMonitor(monitor, &error)) {
        // A display can disappear during a topology update. Retain the saved
        // windowed state and allow the next update/exit to recover normally.
        OutputDebugStringW(L"AudioSubs Reader: fullscreen monitor resize failed.\n");
      }
      fullscreen_transition_ = false;
    }
    // Do not apply the decorated-window suggested rectangle from WM_DPICHANGED.
    return 0;
  }
  if (flutter_result && message != WM_SIZE) {
    return *flutter_result;
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
