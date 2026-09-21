import 'dart:convert';
import 'dart:io';
import 'package:apexis/data/controller.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/transport/native_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'hardware_readonly_test.dart' show ReadOnlyTransport;

/// Observe device parameter changes. Passing means observation completed,
/// not that the parameters were stable. The wire allowlist prevents writes.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'observe real device notifications without parameter writes',
    (tester) async {
      const target = String.fromEnvironment('MIDI_DEVICE');
      const destination = String.fromEnvironment('AUDIT_DIRECTORY');
      if (!const bool.fromEnvironment('HARDWARE_OBSERVE') ||
          target.isEmpty ||
          destination.isEmpty) {
        fail(
          'Explicit read-only observation opt-in and a new directory required',
        );
      }
      final directory = Directory(destination);
      if (await directory.exists()) {
        fail('Do not overwrite observation evidence');
      }
      await directory.create(recursive: true);
      final trace = <Map<String, Object?>>[];
      final samples = <Map<String, Object?>>[];
      final changes = <Map<String, Object?>>[];
      final checks = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'started': DateTime.now().toIso8601String(),
        'readOnly': true,
        'mutationsStarted': false,
        'trace': trace,
        'samples': samples,
        'notifications': changes,
        'checks': checks,
        'observationCompleted': false,
      };
      binding.reportData = report;
      final native = NativeTransport();
      final transport = ReadOnlyTransport(native, trace);
      final c = ApexisController();
      var controllerOwnsTransport = false;
      try {
        final ports = (await native.scan())
            .where((p) => p.name == target)
            .toList();
        expect(ports, hasLength(1));
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Center(child: Text('GT1 只读观察 · 请勿转动旋钮或操作其他客户端')),
            ),
          ),
        );
        controllerOwnsTransport = true;
        await c.connect(transport, ports.single);
        expect(c.error, isNull);
        expect(c.ready, isTrue);
        c.setActivePage(null);
        report['version'] = c.identity!.version;
        report['baselineRevision'] = c.revision;
        report['selected'] = c.selected;
        final sub = c.session!.notifications.listen((message) {
          final range = RangeReply(message);
          changes.add({
            'time': DateTime.now().toIso8601String(),
            'revision': range.revision,
            'offset': range.offset,
            'count': range.count,
            'raw': range.raw.toList(),
          });
        });
        try {
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            expect(c.state, isNot(LinkState.disconnected));
            samples.add({
              'time': DateTime.now().toIso8601String(),
              'revision': c.revision,
              'ready': c.ready,
              'selected': c.selected,
              'output': c.patch?.output,
            });
          }
          for (final q in <(String, int, int, int)>[
            ('system', 9, 0, 4),
            ('drum', 3, 0, 7),
            ('looper', 4, 0x21, 24),
            ('tuner', 5, 0, 6),
          ]) {
            final reply = await c.session!.command(q.$2, 1, q.$3);
            expect(reply.data, hasLength(q.$4));
            checks.add({
              'name': q.$1,
              'status': 'ok',
              'data': reply.data.toList(),
            });
          }
          report['observationCompleted'] = true;
        } finally {
          await sub.cancel();
        }
        report['finalRevision'] = c.revision;
        report['parameterChangesDetected'] =
            c.revision != report['baselineRevision'];
        report['outputValues'] = samples
            .map((s) => s['output'])
            .toSet()
            .toList();
      } catch (e) {
        report['error'] = '$e';
        rethrow;
      } finally {
        report['logs'] = List.of(c.logs);
        report['finished'] = DateTime.now().toIso8601String();
        await File(
          '$destination/report.json',
        ).writeAsString(jsonEncode(report), flush: true);
        await c.disconnect();
        if (!controllerOwnsTransport) await transport.dispose();
        c.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
