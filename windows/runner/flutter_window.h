#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "win32_window.h"

// Hosts the Flutter view and the reader's native fullscreen presentation.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  struct WindowState {
    LONG_PTR style = 0;
    LONG_PTR extended_style = 0;
    WINDOWPLACEMENT placement{};
    RECT bounds{};
  };

  bool SetFullscreen(bool enabled, std::string* error);
  bool CaptureWindowState(WindowState* state, std::string* error);
  bool RestoreWindowState(const WindowState& state, std::string* error);
  bool FitFullscreenToMonitor(HMONITOR monitor, DWORD* error) noexcept;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Must be unregistered before its engine/messenger is destroyed.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      display_channel_;
  WindowState windowed_state_;
  bool fullscreen_ = false;
  bool fullscreen_transition_ = false;
  bool restore_pending_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
