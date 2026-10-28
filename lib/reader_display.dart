import 'package:flutter/services.dart';

/// Controls the reader's native window without changing playback or appearance.
abstract final class ReaderDisplay {
  static const MethodChannel _channel = MethodChannel(
    'audiosubs_reader/display',
  );

  /// Completes once the platform has applied the requested presentation.
  /// Native failures are reported as [PlatformException]s.
  static Future<void> setFullscreen(bool enabled) =>
      _channel.invokeMethod<void>('setFullscreen', enabled);
}
