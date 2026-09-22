import 'dart:convert';
import 'dart:io';
import 'package:apexis/transport/usb_worker.dart';
import 'package:apexis/transport/windows_usb_worker.dart';

/// Read-only native enumeration. Does not open any serial or MIDI device.
Future<void> main() async {
  final worker = UsbWorker(windowsUsbWorker);
  try {
    stdout.writeln(jsonEncode({'gt1UsbInterfaces': await worker.request('scan')}));
  } finally {
    await worker.dispose();
  }
}
