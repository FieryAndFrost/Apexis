import 'dart:convert';
import 'dart:io';
import 'package:apexis/data/file_transfer.dart';
import 'package:apexis/data/parameters.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/protocol/session.dart';
import 'package:apexis/transport/windows_cdc_transport.dart';

/// Export only, then independently READ the entire revision-locked bank.
/// Never import, restore, write parameters, restart or enter BOOT.
Future<void> main(List<String> args) async {
  if (args.length != 1 || Directory(args.single).existsSync()) {
    throw ArgumentError('A new backup directory is required');
  }
  final directory = await Directory(args.single).create(recursive: true);
  final report = <String, Object?>{
    'started': DateTime.now().toIso8601String(),
    'verified': false,
    'mutationsStarted': false,
  };
  final transport = WindowsCdcTransport();
  ProtocolSession? session;
  final faults = <String>[];
  report['faults'] = faults;
  try {
    final ports = await transport.scan();
    if (ports.length != 1) throw StateError('Exactly one GT1 CDC required');
    report['port'] = ports.single.id;
    await transport.connect(ports.single);
    session = ProtocolSession(transport);
    session.faults.listen((e) => faults.add(e.toString()));
    session.onMatchedReply = (reply) {
      report['lastReply'] =
          '${reply.component}/${reply.command}/${reply.selector}';
    };
    final identity = DeviceIdentity((await session.command(9, 1, 0x22)).data);
    if (identity.name != 'GT1' || identity.platform != 'AC703N') {
      throw StateError('Wrong device identity');
    }
    report['identity'] =
        '${identity.name} ${identity.version} ${identity.platform}';
    final capability = RangeReply(
      await session.command(9, 1, 0x40),
      capability: true,
    );
    final transfer = FileTransfer(
      session,
      onProgress: (_) {},
      cancelled: () => false,
    );
    final bank = await transfer.transfer(bank: true, preset: 0);
    PresetFile.validate(bank, bank: true);
    await File('${directory.path}/before.gt1b').writeAsBytes(bank, flush: true);
    final raw = <int>[];
    while (raw.length < Gt1.bankSize) {
      final size = (Gt1.bankSize - raw.length).clamp(1, capability.count);
      final reply = RangeReply(
        await session.request(Gt1.read(capability.revision, raw.length, size)),
      );
      if (reply.revision != capability.revision ||
          reply.offset != raw.length ||
          reply.count < 1 ||
          reply.count > size) {
        throw StateError('Inconsistent READ');
      }
      raw.addAll(reply.raw);
    }
    for (var i = 0; i < raw.length; i++) {
      if (raw[i] != bank[16 + i]) throw StateError('Export mismatch at $i');
    }
    report.addAll({
      'verified': true,
      'revision': capability.revision,
      'bankBytes': bank.length,
      'comparedBytes': raw.length,
    });
  } catch (error) {
    report['error'] = error.toString();
    exitCode = 1;
  } finally {
    await session?.dispose();
    await transport.dispose();
    report['finished'] = DateTime.now().toIso8601String();
    await File('${directory.path}/report.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    stdout.writeln(jsonEncode(report));
  }
}
