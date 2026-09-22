import 'dart:convert';
import 'dart:io';
import 'package:apexis/transport/desktop_usb_transport.dart';

/// Read-only native enumeration. Does not open any serial or MIDI device.
Future<void> main() async {
  final transport = createDesktopUsbTransport();
  try {
    final ports = await transport.scan();
    stdout.writeln(
      jsonEncode({
        'gt1UsbInterfaces': [
          for (final port in ports) [port.id, port.name],
        ],
      }),
    );
  } finally {
    await transport.dispose();
  }
}
