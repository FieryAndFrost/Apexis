import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:apexis/data/controller.dart';
import 'package:apexis/data/parameters.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/transport/windows_cdc_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'hardware_readonly_test.dart' show readRange;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'CDC actual controller latency, bounded output change and restore',
    (tester) async {
      const output = String.fromEnvironment('CDC_PERF_REPORT');
      const backupPath = String.fromEnvironment('CDC_PERF_BACKUP');
      if (!const bool.fromEnvironment('HARDWARE_CDC_PERF') ||
          output.isEmpty ||
          backupPath.isEmpty) {
        fail('Explicit opt-in, verified backup, and new report path required');
      }
      if (File(output).existsSync()) fail('Do not overwrite evidence');
      final bank = await File(backupPath).readAsBytes();
      PresetFile.validate(bank, bank: true);
      final backupReport = jsonDecode(
        await File(
          '${File(backupPath).parent.path}/report.json',
        ).readAsString(),
      );
      expect(backupReport['verified'], true);
      final report = <String, Object?>{
        'started': DateTime.now().toIso8601String(),
        'passed': false,
        'restored': false,
        'backup': backupPath,
      };
      Future<void> save() => File(output).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
      await save();
      final c = ApexisController();
      final native = WindowsCdcTransport();
      int? original, preset;
      var changed = false;
      try {
        final ports = await native.scan();
        expect(ports, hasLength(1));
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('CDC 延迟验证 · 单参数测试后恢复'))),
        );
        final watch = Stopwatch()..start();
        await c.connect(native, ports.single);
        report['connectUs'] = watch.elapsedMicroseconds;
        expect(c.error, isNull);
        expect(c.ready, true);
        c.setActivePage(null);
        preset = c.selected;
        original = c.patch!.output;
        expect(c.globals, bank.sublist(16, 80));
        expect(
          c.patch!.bytes,
          bank.sublist(80 + preset * 374, 80 + (preset + 1) * 374),
        );
        report.addAll({
          'preset': preset,
          'originalOutput': original,
          'port': ports.single.id,
        });
        final syncs = <int>[], writes = <int>[];
        report['syncUs'] = syncs;
        report['writeAndNotifyUs'] = writes;
        for (var i = 0; i < 10; i++) {
          watch.reset();
          await c.resync();
          await c.waitReady();
          syncs.add(watch.elapsedMicroseconds);
        }
        for (var i = 0; i < 30; i++) {
          final value = i.isEven ? (original > 0 ? original - 1 : 1) : original;
          changed = true;
          await save();
          watch.reset();
          await c.patchField(351, [value]);
          writes.add(watch.elapsedMicroseconds);
          expect(c.error, isNull);
          expect(c.ready, true);
          expect(c.selected, preset);
          expect(c.patch!.output, value);
          expect(
            await readRange(
              c.session!,
              c.revision,
              Gt1.patchOffset(preset, 351),
              1,
            ),
            [value],
          );
        }
        report['passed'] = true;
      } catch (e) {
        report['error'] = e.toString();
        rethrow;
      } finally {
        try {
          if (changed && c.session?.isValid == true && c.selected == preset) {
            await c.patchField(351, [original!]);
            expect(c.error, isNull);
            expect(c.patch!.output, original);
            final restored = await readRange(
              c.session!,
              c.revision,
              0,
              Gt1.bankSize,
            );
            expect(restored, Uint8List.sublistView(bank, 16, 47952));
            report['restored'] = true;
          }
        } finally {
          report['finished'] = DateTime.now().toIso8601String();
          report['logs'] = List.of(c.logs);
          await save();
          await c.disconnect();
          await native.dispose();
          c.dispose();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
