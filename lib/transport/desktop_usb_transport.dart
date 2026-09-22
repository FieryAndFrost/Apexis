import 'dart:io';
import 'macos_usb_transport.dart';
import 'transport.dart';
import 'windows_usb_transport.dart';

DeviceTransport createDesktopUsbTransport() {
  if (Platform.isWindows) return WindowsUsbTransport();
  if (Platform.isMacOS) return MacosUsbTransport();
  throw UnsupportedError('私有 USB 目前支持 Windows 和 macOS');
}
