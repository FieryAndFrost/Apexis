import 'dart:convert';
import 'dart:io';
import 'package:apexis/transport/cdc_worker.dart';
import 'package:apexis/transport/windows_cdc_worker.dart';

/// Read-only native enumeration. Does not open any serial or MIDI device.
Future<void> main() async {
  final worker = CdcWorker(windowsCdcWorker);
  try {
    stdout.writeln(jsonEncode({'gt1CdcPorts': await worker.request('scan')}));
  } finally {
    await worker.dispose();
  }
}
