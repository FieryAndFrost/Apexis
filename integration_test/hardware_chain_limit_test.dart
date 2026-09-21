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
import 'hardware_readonly_test.dart' show readRange;
import 'hardware_write_test.dart' show WriteAuditTransport;

class ChainAuditTransport extends WriteAuditTransport {
  ChainAuditTransport(super.inner, super.trace);

  @override
  Future<void> send(Uint8List frame) {
    final m = Message.parse(frame, response: false);
    // Reselect ONLY the backed-up current preset to leave the firmware's
    // build-failure safe BYPASS. No other preset may be selected or written.
    if (backupSaved &&
        m.component == 0 &&
        m.command == 0 &&
        m.selector == 0 &&
        m.data.length == 1 &&
        m.data[0] == preset) {
      trace.add({'tx': frame.toList()});
      return inner.send(frame);
    }
    return super.send(frame);
  }
}

// Diagnostic only: no SAVE, preset switching, firmware/reset or bank import.
// Every attempted addition is flushed before sending it. A timeout stops ALL
// device commands, including restoration; a reboot must be user-controlled.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'recorded effect-chain capacity diagnostic',
    (tester) async {
      const destination = String.fromEnvironment('AUDIT_DIRECTORY');
      const name = String.fromEnvironment('MIDI_DEVICE');
      if (!const bool.fromEnvironment('HARDWARE_CHAIN_TEST') ||
          destination.isEmpty ||
          name != 'SINCO-MIDI') {
        fail('Explicit diagnostic opt-in and unique target required');
      }
      final directory = Directory(destination);
      if (directory.existsSync()) fail('Use a fresh evidence directory');
      directory.createSync(recursive: true);
      final trace = <Map<String, Object?>>[];
      final events = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'started': DateTime.now().toIso8601String(),
        'events': events,
        'trace': trace,
        'mutationsStarted': false,
        'backupVerified': false,
        'restored': false,
        'completed': false,
      };
      binding.reportData = report;
      void persist() => File(
        '$destination/report.json',
      ).writeAsStringSync(jsonEncode(report), flush: true);
      Map<String, Object?> event(String action, Map<String, Object?> data) {
        final e = <String, Object?>{
          'time': DateTime.now().toIso8601String(),
          'action': action,
          ...data,
        };
        events.add(e);
        persist();
        debugPrint('CHAIN ${jsonEncode(e)}');
        return e;
      }

      final c = ApexisController();
      final native = NativeTransport();
      final transport = ChainAuditTransport(native, trace);
      var owned = false, mutated = false, uncertain = false;
      bool uncertainError(Object error) =>
          '$error'.contains('TimeoutException') || '$error'.contains('连接会话已失效');
      Uint8List? preset, bank;
      List<int>? baselinePatch, baselineGlobals;
      int? selected;
      Future<void> check(Future<void> request) async {
        await request;
        if (!c.ready) {
          uncertain = true;
          throw StateError('Device lost: ${c.error}');
        }
        if (c.error != null) {
          // A recovered asynchronous STALE can remain in the controller's
          // display error after READY. Preserve it as evidence; actual state
          // and independent READ comparisons below still must pass.
          if (c.error!.contains('[09/00/42, error=08,')) {
            event('recovered_sync_warning', {'error': c.error});
          } else {
            uncertain = uncertain || uncertainError(c.error!);
            throw StateError(c.error!);
          }
        }
      }

      Future<void> restore(String reason) async {
        if (uncertain || !c.ready) {
          throw StateError('No restore on uncertain link');
        }
        final e = event('restore', {'reason': reason, 'status': 'pending'});
        await FileTransfer(
          c.session!,
          onProgress: (_) {},
          cancelled: () => false,
        ).transfer(bank: false, preset: selected!, input: preset);
        await c.resync();
        await c.waitReady();
        // FileTransfer/resync exceptions already propagate. c.error can still
        // contain the PREVIOUS rejected add; verify restoration from actual
        // state/READ, not that historical display message.
        if (!c.ready) throw StateError('Restore did not reach READY');
        expect(c.patch!.bytes, baselinePatch);
        expect(c.globals, baselineGlobals);
        e['status'] = 'ok';
        persist();
      }

      try {
        persist();
        final ports = (await native.scan())
            .where((p) => p.name == name)
            .toList();
        expect(ports, hasLength(1));
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Center(child: Text('GT1 效果链边界诊断 · 请勿操作设备或拔线')),
            ),
          ),
        );
        owned = true;
        await check(c.connect(transport, ports.single));
        c.setActivePage(null);
        expect(c.identity!.version, '0.2.124-dev');
        expect(c.patch!.count, 0, reason: 'Preserve nonempty user chain');
        selected = c.selected;
        transport.preset = selected;
        baselinePatch = c.patch!.bytes.toList();
        baselineGlobals = c.globals.toList();
        report['baseline'] = {
          'version': c.identity!.version,
          'selected': selected,
          'revision': c.revision,
          'patch': baselinePatch,
          'globals': baselineGlobals,
        };
        report['types'] = [
          for (final t in c.types)
            {'id': t.id, 'name': t.name, 'flags': t.flags},
        ];
        event('backup', {'status': 'started'});
        const prior = String.fromEnvironment('VERIFY_BASELINE_DIRECTORY');
        if (prior.isEmpty) {
          final transfer = FileTransfer(
            c.session!,
            onProgress: (_) {},
            cancelled: () => false,
          );
          preset = await transfer.transfer(bank: false, preset: selected);
          bank = await transfer.transfer(bank: true, preset: selected);
        } else {
          // Reuse bytes only after independently proving the live entire bank
          // still matches them. This is verification, not a fresh file export.
          preset = File('$prior/before.gt1s').readAsBytesSync();
          bank = File('$prior/before.gt1b').readAsBytesSync();
          report['backupSource'] = prior;
        }
        PresetFile.validate(preset, bank: false);
        PresetFile.validate(bank, bank: true);
        File('$destination/before.gt1s').writeAsBytesSync(preset, flush: true);
        File('$destination/before.gt1b').writeAsBytesSync(bank, flush: true);
        expect(preset.sublist(8, 382), baselinePatch);
        expect(
          await readRange(c.session!, c.revision, 0, Gt1.bankSize),
          bank.sublist(16, bank.length - 4),
        );
        if (prior.isNotEmpty) {
          final previous = File('$prior/before.gt1b').readAsBytesSync();
          PresetFile.validate(previous, bank: true);
          expect(
            bank,
            previous,
            reason: 'Verify previous run restoration before any new write',
          );
          report['previousBaselineVerified'] = prior;
        }
        report['backupVerified'] = true;
        transport.backupSaved = true;
        mutated = true;
        report['mutationsStarted'] = true;
        persist();
        final cases = <String, List<int>>{
          'volume_10': List.filled(10, 2560),
          'mixed_10': [512, 264, 808, 1536, 1799, 1809, 2062, 2313, 2560, 0],
          'delay_10': List.filled(10, 2062),
          'room_reverb_10': List.filled(10, 2313),
        };
        for (final entry in cases.entries) {
          const only = String.fromEnvironment('CHAIN_CASES');
          if (only.isNotEmpty && !only.split(',').contains(entry.key)) continue;
          await restore('before_${entry.key}');
          // Each mapping is an indivisible ten-byte protocol field.
          for (final offset in [352, 362]) {
            final mapping = c.patch!.bytes.sublist(offset, offset + 10)
              ..[9] = 0;
            await check(c.patchField(offset, mapping));
          }
          await check(c.patchField(351, [0]));
          event('activate_current_preset', {'preset': selected});
          await check(c.action(0, 0, 0, [selected]));
          expect(c.selected, selected);
          expect(c.patch!.count, 0);
          final types = <int>[];
          for (final id in entry.value) {
            final type = c.types.singleWhere((t) => t.id == id);
            expect(
              type.flags & 3,
              0,
              reason: 'No external model or CPU1-only type',
            );
            final e = event('add', {
              'case': entry.key,
              'slot': types.length,
              'type': id,
              'name': type.name,
              'beforeTypes': List.of(types),
              'revisionBefore': c.revision,
              'status': 'pending',
            });
            final watch = Stopwatch()..start();
            try {
              await check(c.action(1, 0, 1, [types.length, ...Gt1.u14(id)]));
              types.add(id);
              expect(c.patch!.count, types.length);
              expect([
                for (final u in c.patch!.chain) c.patch!.unit(u).type,
              ], types);
              await Future<void>.delayed(
                Duration(
                  milliseconds: const int.fromEnvironment(
                    'CHAIN_HOLD_MS',
                    defaultValue: 300,
                  ),
                ),
              );
              await c.session!.command(9, 1, 0);
              e.addAll({
                'status': 'ok',
                'elapsedMs': watch.elapsedMilliseconds,
                'revisionAfter': c.revision,
                'patch': c.patch!.bytes.toList(),
              });
              persist();
            } catch (error) {
              // A failed operation is never replayed. Let the outer guard decide
              // whether the still-live link permits restoring the saved preset.
              uncertain = uncertain || !c.ready || uncertainError(error);
              e.addAll({
                'status': 'failed',
                'error': '$error',
                'elapsedMs': watch.elapsedMilliseconds,
                'ready': c.ready,
              });
              persist();
              rethrow;
            }
          }
          event('case_complete', {'case': entry.key, 'count': types.length});
        }
        report['completed'] = true;
      } catch (error, stack) {
        uncertain = uncertain || uncertainError(error);
        report['error'] = '$error';
        report['stack'] = '$stack';
        debugPrint('CHAIN STOP $error');
      } finally {
        if (mutated && !uncertain && c.ready) {
          try {
            await restore('final');
            expect(
              await readRange(c.session!, c.revision, 0, Gt1.bankSize),
              bank!.sublist(16, bank.length - 4),
            );
            report['restored'] = true;
          } catch (error) {
            report['restoreError'] = '$error';
          }
        } else if (mutated) {
          report['restoreSkipped'] = 'Unresponsive device: no further commands';
        }
        report['logs'] = List.of(c.logs);
        report['finishedAt'] = DateTime.now().toIso8601String();
        persist();
        await c.disconnect();
        if (!owned) await transport.dispose();
        c.dispose();
      }
      expect(
        report['error'],
        isNull,
        reason: 'Recorded reproduction; inspect evidence',
      );
      expect(report['restored'], isTrue);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
