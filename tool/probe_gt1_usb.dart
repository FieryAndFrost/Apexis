import 'dart:convert';
import 'dart:io';
import 'package:apexis/data/parameters.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/protocol/session.dart';
import 'package:apexis/transport/windows_usb_transport.dart';

/// Read-only, real Windows transport: reconnect three times and repeat GETs.
Future<void> main(List<String> args) async {
  final queries = int.parse(
    Platform.environment['GT1_USB_PROBE_QUERIES'] ?? '20',
  );
  if (queries < 1 || queries > 10000) {
    throw ArgumentError('Queries must be 1..10000');
  }
  if ((args.length != 1 && args.length != 2) ||
      await File(args.first).exists()) {
    throw ArgumentError(
      'Provide a new JSON evidence path and optional GT1B backup',
    );
  }
  final report = <String, Object?>{
    'started': DateTime.now().toIso8601String(),
    'readOnly': true,
    'queriesPerConnection': queries,
    'passed': false,
    'cycles': <Map<String, Object?>>[],
  };
  final output = File(args.first);
  Future<void> save() => output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  await save();
  try {
    for (var cycle = 0; cycle < 3; cycle++) {
      final transport = WindowsUsbTransport();
      ProtocolSession? session;
      final results = <Map<String, Object?>>[];
      final item = <String, Object?>{'cycle': cycle + 1, 'gets': results};
      (report['cycles'] as List).add(item);
      try {
        final ports = await transport.scan();
        if (ports.length != 1) {
          throw StateError('Expected exactly one GT1 WinUSB: ${ports.length}');
        }
        item['port'] = ports.single.id;
        await transport.connect(ports.single);
        session = ProtocolSession(transport);
        final identity = DeviceIdentity(
          (await session.command(9, 1, 0x22)).data,
        );
        if (identity.name != 'GT1' || identity.platform != 'AC703N') {
          throw StateError('Unexpected target identity');
        }
        item['identity'] =
            '${identity.name} ${identity.version} ${identity.platform}';
        if (cycle == 0 && args.length == 2) {
          final backup = await File(args[1]).readAsBytes();
          PresetFile.validate(backup, bank: true);
          final capability = RangeReply(
            await session.command(9, 1, 0x40),
            capability: true,
          );
          final raw = <int>[];
          while (raw.length < Gt1.bankSize) {
            final size = (Gt1.bankSize - raw.length).clamp(1, capability.count);
            final part = RangeReply(
              await session.request(
                Gt1.read(capability.revision, raw.length, size),
              ),
            );
            if (part.revision != capability.revision ||
                part.offset != raw.length ||
                part.count < 1 ||
                part.count > size) {
              throw StateError('Inconsistent bank read');
            }
            raw.addAll(part.raw);
          }
          final differences = <int>[];
          for (var at = 0; at < raw.length; at++) {
            if (raw[at] != backup[16 + at]) differences.add(at);
          }
          report['bankVerification'] = {
            'backup': args[1],
            'bytes': raw.length,
            'revision': capability.revision,
            'differentOffsets': differences,
            'matched': differences.isEmpty,
          };
          if (differences.isNotEmpty) {
            throw StateError(
              'Bank differs at ${differences.length} bytes; no restore performed',
            );
          }
        }
        for (var index = 0; index < queries; index++) {
          final selector = index.isEven ? 0x22 : 0x40;
          final timer = Stopwatch()..start();
          final reply = await session.command(9, 1, selector);
          if (selector == 0x22) {
            DeviceIdentity(reply.data);
          } else {
            RangeReply(reply, capability: true);
          }
          results.add({
            'selector': selector,
            'elapsedUs': timer.elapsedMicroseconds,
            'data': reply.data.toList(),
          });
        }
        item['passed'] = true;
      } finally {
        await session?.dispose();
        await transport.dispose();
        await save();
      }
    }
    report['passed'] = true;
  } catch (error) {
    report['error'] = error.toString();
    exitCode = 1;
  } finally {
    report['finished'] = DateTime.now().toIso8601String();
    await save();
    stdout.writeln(jsonEncode(report));
  }
}
