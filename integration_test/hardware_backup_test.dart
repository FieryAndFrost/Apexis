import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:apexis/data/controller.dart';
import 'package:apexis/data/file_transfer.dart';
import 'package:apexis/data/parameters.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/transport/native_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'hardware_readonly_test.dart' show ReadOnlyTransport, readRange;

/// Parameter read/export only. No parameter writes, audio actions or boot entry.
class BackupTransport extends ReadOnlyTransport {
  BackupTransport(super.inner, super.trace);
  @override
  Future<void> send(Uint8List frame) {
    final m = Message.parse(frame, response: false);
    final fileExport =
        m.component == 0 &&
        ((m.command == 1 && [0x30, 0x31, 0x34, 0x35].contains(m.selector)) ||
            (m.command == 7 && [0x33, 0x37].contains(m.selector)));
    if (!fileExport) return super.send(frame);
    trace.add({'tx': frame.toList()});
    return inner.send(frame);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'verified parameter backup before firmware replacement',
    (tester) async {
      const name = String.fromEnvironment('MIDI_DEVICE');
      const destination = String.fromEnvironment('AUDIT_DIRECTORY');
      if (!const bool.fromEnvironment('HARDWARE_BACKUP') ||
          name.isEmpty ||
          destination.isEmpty) {
        fail('Explicit hardware backup opt-in and new destination required');
      }
      final directory = Directory(destination);
      if (await directory.exists()) fail('Never overwrite an existing backup');
      await directory.create(recursive: true);
      final trace = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'started': DateTime.now().toIso8601String(),
        'device': name,
        'verified': false,
        'mutationsStarted': false,
        'trace': trace,
      };
      binding.reportData = report;
      final c = ApexisController();
      final native = NativeTransport();
      final transport = BackupTransport(native, trace);
      var controllerOwnsTransport = false;
      try {
        final ports = (await native.scan())
            .where((p) => p.name == name)
            .toList();
        expect(
          ports,
          hasLength(1),
          reason: 'Exactly one target must be present',
        );
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Center(child: Text('GT1 升级前只读备份 · 请勿断电'))),
          ),
        );
        controllerOwnsTransport = true;
        await c.connect(transport, ports.single);
        expect(c.error, isNull);
        expect(c.ready, isTrue);
        c.setActivePage(null);
        final revision = c.revision;
        final selected = c.selected;
        final patch = c.patch!.bytes.toList();
        final globals = c.globals.toList();
        report['baseline'] = {
          'version': c.identity!.version,
          'revision': revision,
          'selected': selected,
          'globals': globals,
          'patch': patch,
        };
        final transfer = FileTransfer(
          c.session!,
          onProgress: (_) {},
          cancelled: () => false,
        );
        final preset = await transfer.transfer(bank: false, preset: selected);
        PresetFile.validate(preset, bank: false);
        await File(
          '$destination/before.gt1s',
        ).writeAsBytes(preset, flush: true);
        final bank = await transfer.transfer(bank: true, preset: selected);
        PresetFile.validate(bank, bank: true);
        await File('$destination/before.gt1b').writeAsBytes(bank, flush: true);
        expect(preset.sublist(8, 382), patch);
        expect(bank.sublist(16, 80), globals);
        expect(
          bank.sublist(80 + selected * 374, 80 + (selected + 1) * 374),
          patch,
        );
        // An independent, revision-locked READ proves export coherence.
        expect(
          await readRange(c.session!, revision, 0, 47936),
          bank.sublist(16, 47952),
        );
        expect(c.revision, revision);
        report['verified'] = true;
        report['bankBytes'] = bank.length;
        report['presetBytes'] = preset.length;
      } catch (e) {
        report['error'] = '$e';
        rethrow;
      } finally {
        report['finished'] = DateTime.now().toIso8601String();
        await File(
          '$destination/report.json',
        ).writeAsString(jsonEncode(report), flush: true);
        await c.disconnect();
        // disconnect already disposes the transport handed to the controller.
        if (!controllerOwnsTransport) await transport.dispose();
        c.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
