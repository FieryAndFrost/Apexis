import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:apexis/data/controller.dart';
import 'package:apexis/data/file_transfer.dart';
import 'package:apexis/data/parameters.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/transport/native_transport.dart';
import 'package:apexis/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'hardware_readonly_test.dart' show ReadOnlyTransport, readRange;
import '../test/support/drag_effect.dart';

class WriteAuditTransport extends ReadOnlyTransport {
  WriteAuditTransport(super.inner, super.trace);
  int? preset;
  bool backupSaved = false, presetSaved = false, restoringPreset = false;
  @override
  Future<void> send(Uint8List frame) {
    final m = Message.parse(frame, response: false);
    final sync = m.component == 9 && m.selector == 0x42;
    final exportEnd =
        m.component == 0 && m.command == 7 && [0x33, 0x37].contains(m.selector);
    final isolateMappings =
        presetSaved &&
        m.component == 9 &&
        m.command == 0 &&
        m.selector == 0x41 &&
        m.data.length >= 13 &&
        Gt1.integer(m.data, 7, 3) == Gt1.patchOffset(preset!, 352) &&
        Gt1.integer(m.data, 10, 2) == 20;
    final restoreSavedPreset =
        presetSaved &&
        restoringPreset &&
        m.component == 0 &&
        ((m.command == 0 && [0x30, 0x31].contains(m.selector)) ||
            (m.command == 8 && m.selector == 0x32));
    if (!backupSaved &&
        !isolateMappings &&
        !restoreSavedPreset &&
        m.command != 1 &&
        !sync &&
        !exportEnd) {
      throw StateError(
        'Cannot mutate hardware before verified backups are saved',
      );
    }
    // Never reset defaults, write another preset, copy/swap, or import a bank.
    if (m.component == 0 &&
        ((m.command == 7 && [0, 0x34].contains(m.selector)) ||
            [0x0a, 0x0c].contains(m.command) ||
            (m.command == 0 && [0, 0x20, 0x34, 0x35].contains(m.selector)) ||
            (m.command == 8 && m.selector == 0x36))) {
      throw StateError('Operation excluded from bounded hardware write audit');
    }
    if (m.component == 0 &&
        m.command == 0 &&
        m.selector == 0x30 &&
        (m.data.length != 1 || m.data[0] != preset)) {
      throw StateError('Import may only target the backed-up preset');
    }
    if (m.component == 9 && m.selector == 0x41 && m.command == 0) {
      final at = Gt1.integer(m.data, 7, 3), size = Gt1.integer(m.data, 10, 2);
      final start = Gt1.patchOffset(preset!);
      if (!(at < 64 && at + size <= 64) &&
          !(at >= start && at + size <= start + 374)) {
        throw StateError('Write outside backed-up globals/current preset');
      }
    }
    trace.add({'tx': frame.toList()});
    return inner.send(frame);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'explicitly authorized bounded hardware writes with backup/restore',
    (tester) async {
      const enabled = bool.fromEnvironment('HARDWARE_WRITE_TEST');
      const name = String.fromEnvironment('MIDI_DEVICE');
      const destination = String.fromEnvironment('AUDIT_DIRECTORY');
      if (!enabled || name.isEmpty || destination.isEmpty) {
        fail('Explicit hardware write opt-in and backup directory required');
      }
      final directory = Directory(destination);
      if (await directory.exists()) {
        fail('Use a new backup directory for every run');
      }
      await directory.create(recursive: true);
      final trace = <Map<String, Object?>>[], checks = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'device': name,
        'started': DateTime.now().toIso8601String(),
        'checks': checks,
        'trace': trace,
        'restored': false,
        'mutationsStarted': false,
      };
      binding.reportData = report;
      Future<void> persist() => File(
        '${directory.path}/report.json',
      ).writeAsString(jsonEncode(report), flush: true);
      final c = ApexisController();
      final native = NativeTransport();
      final transport = WriteAuditTransport(native, trace);
      final available = await native.scan();
      report['availablePorts'] = [
        for (final p in available) {'name': p.name, 'id': p.id, 'kind': p.kind},
      ];
      final ports = available.where((p) => p.name == name).toList();
      if (ports.length != 1) {
        report['preflightError'] =
            'Expected one $name endpoint, found ${ports.length}';
        report['mutationsStarted'] = false;
        await persist();
        await transport.dispose();
        c.dispose();
        fail(report['preflightError']! as String);
      }
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('GT1 实机测试 · 已备份后写入 · 请勿断电'))),
        ),
      );
      Uint8List? originalPatch, originalGlobals, presetFile, bankFile;
      final changedGlobals = <(int, int)>{};
      var mutationsStarted = false,
          transportFailed = false,
          loopWasEmpty = false,
          loopTouched = false,
          tunerWasActive = false;
      Future<void> checked(Future<void> command) async {
        await command;
        if (c.error != null) throw StateError(c.error!);
        if (!c.ready) throw StateError('Controller not ready');
      }

      Future<void> resync() async {
        await c.resync();
        await c.waitReady();
      }

      Future<bool> step(String label, Future<void> Function() body) async {
        if (transportFailed) {
          checks.add({
            'name': label,
            'status': 'skipped',
            'reason': 'Transport failed; no automatic reconnect or replay',
          });
          await persist();
          return false;
        }
        debugPrint('HARDWARE STEP $label');
        report['activeStep'] = label;
        await persist();
        final watch = Stopwatch()..start();
        try {
          await body();
          checks.add({
            'name': label,
            'status': 'ok',
            'milliseconds': watch.elapsedMilliseconds,
            'revision': c.revision,
          });
          await persist();
          return true;
        } catch (e, st) {
          if (c.session?.isValid != true) transportFailed = true;
          checks.add({
            'name': label,
            'status': 'failed',
            'error': '$e',
            'stack': '$st',
            'revision': c.revision,
          });
          debugPrint('HARDWARE FAILED $label: $e');
          await persist();
          return false;
        }
      }

      FileTransfer transfer({bool Function()? cancelled}) => FileTransfer(
        c.session!,
        onProgress: (v) {},
        cancelled: cancelled ?? () => false,
      );
      Future<void> verifyPatch(int offset, List<int> expected) async {
        expect(
          c.patch!.bytes.sublist(offset, offset + expected.length),
          expected,
        );
        expect(
          await readRange(
            c.session!,
            c.revision,
            Gt1.patchOffset(c.selected, offset),
            expected.length,
          ),
          expected,
        );
      }

      Future<void> global(int offset, List<int> value) async {
        changedGlobals.add((offset, value.length));
        await checked(c.writeField(offset, value));
        expect(
          await readRange(c.session!, c.revision, offset, value.length),
          value,
        );
      }

      Future<void> verifyUiMovement() async {
        final original = c.patch!.chain.toList();
        expect(original.length, greaterThanOrEqualTo(2));
        final selected = original.first;
        final moved = List<int>.from(original);
        moved[0] = original[1];
        moved[1] = selected;
        await checked(c.selectUnit(selected));
        await tester.pumpWidget(ApexisApp(controller: c));
        await tester.pumpAndSettle();
        final units = c.patch!.bytes.sublist(0, 320);
        Finder button(String name) =>
            find.byWidgetPredicate((w) => w is IconButton && w.tooltip == name);
        expect(button('向前移动'), findsNothing);
        expect(button('向后移动'), findsNothing);
        for (final move in [('向后移动', moved), ('向前移动', original)]) {
          await dragEffectCard(tester, selected, original[1]);
          final deadline = Stopwatch()..start();
          do {
            await tester.pump(const Duration(milliseconds: 50));
            await Future<void>.delayed(const Duration(milliseconds: 20));
            if (deadline.elapsed > const Duration(seconds: 5)) {
              throw StateError(
                'UI movement incomplete: ${move.$1}; ${c.error}',
              );
            }
          } while (c.busy || c.patch!.chain[0] != move.$2[0]);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(c.error, isNull);
          expect(c.selectedUnit, selected);
          expect(c.patch!.bytes.sublist(0, 320), units);
          await verifyPatch(320, [
            ...move.$2,
            ...List.filled(10 - original.length, 0),
          ]);
        }
        report['actualUiMovementVerified'] = true;
        report['actualUiDragVerified'] = true;
        await persist();
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        c.setActivePage(null);
      }

      Future<List<int>> loopStatus() async {
        final d = await c.readLooperProgress();
        expect(d, hasLength(24));
        return d;
      }

      Future<List<int>> waitLoop(bool Function(List<int>) predicate) async {
        final watch = Stopwatch()..start();
        while (watch.elapsed < const Duration(seconds: 4)) {
          final d = await loopStatus();
          if (predicate(d)) return d;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        throw StateError('Looper did not reach expected runtime state');
      }

      try {
        await c.connect(transport, ports.single);
        expect(c.error, isNull);
        expect(c.ready, isTrue);
        transport.preset = c.selected;
        c.setActivePage(null);
        originalPatch = Uint8List.fromList(c.patch!.bytes);
        originalGlobals = Uint8List.fromList(c.globals);
        tunerWasActive = (await c.session!.command(9, 1, 0)).data[0] == 4;
        final initialLoop = await loopStatus();
        loopWasEmpty =
            initialLoop[1] == 0 &&
            initialLoop[2] & 1 == 0 &&
            initialLoop[3] == 0;
        report['baseline'] = {
          'revision': c.revision,
          'selected': c.selected,
          'version': c.identity!.version,
          'globals': originalGlobals.toList(),
          'patch': originalPatch.toList(),
          'looper': initialLoop,
          'tunerActive': tunerWasActive,
          'types': [
            for (final t in c.types)
              {'id': t.id, 'name': t.name, 'flags': t.flags, 'count': t.count},
          ],
        };
        final backedUp = await step('backup_GT1S_GT1B', () async {
          final drumState = (await c.session!.command(3, 1, 0)).data;
          expect(drumState, hasLength(7));
          report['baselineDrumState'] = drumState.toList();
          expect(
            drumState[0],
            0,
            reason: 'Do not interrupt an already playing drum session',
          );
          presetFile = await transfer().transfer(
            bank: false,
            preset: c.selected,
          );
          await File(
            '${directory.path}/before.gt1s',
          ).writeAsBytes(presetFile!, flush: true);
          PresetFile.validate(presetFile!, bank: false);
          originalPatch = Uint8List.fromList(presetFile!.sublist(8, 382));
          transport.presetSaved = true;
          mutationsStarted = true;
          report['mutationsStarted'] = true;
          report['mappingIsolationStarted'] = true;
          await persist();
          final maps = originalPatch!.sublist(352, 372);
          maps[9] = maps[19] = 0;
          await checked(c.patchField(352, maps));
          final quietPatch = Uint8List.fromList(originalPatch!);
          quietPatch.setRange(352, 372, maps);
          expect(c.patch!.bytes, quietPatch);
          final backupRevision = c.revision;
          originalGlobals = Uint8List.fromList(c.globals);
          bankFile = await transfer().transfer(bank: true, preset: c.selected);
          await File(
            '${directory.path}/quiet-before.gt1b',
          ).writeAsBytes(bankFile!, flush: true);
          expect(presetFile!.sublist(8, 382), originalPatch);
          expect(bankFile!.sublist(16, 80), originalGlobals);
          expect(
            bankFile!.sublist(
              80 + c.selected * 374,
              80 + (c.selected + 1) * 374,
            ),
            quietPatch,
          );
          // Match the dedicated backup audit: CRC alone cannot prove that a
          // valid export belongs to the same device view used for restoration.
          expect(
            await readRange(c.session!, backupRevision, 0, Gt1.bankSize),
            bankFile!.sublist(16, bankFile!.length - 4),
          );
          expect(c.revision, backupRevision);
          report['backupVerified'] = true;
          report['backupFormat'] = 'quiet_bank_original_preset';
          report['backupCrc32'] = {
            'preset': PresetFile.crc32(
              presetFile!.sublist(0, presetFile!.length - 4),
            ),
            'bank': PresetFile.crc32(
              bankFile!.sublist(0, bankFile!.length - 4),
            ),
          };
        });
        if (!backedUp) {
          fail(
            'Bank backup failed; only backed-up mapping isolation was allowed',
          );
        }
        transport.backupSaved = true;
        mutationsStarted = true;
        report['mutationsStarted'] = true;
        if (!await step('mute_output', () async {
          await checked(c.patchField(351, [0]));
          await verifyPatch(351, [0]);
        })) {
          fail('Could not verify output mute; remaining writes aborted');
        }
        await step('same_value_no_revision', () async {
          final revision = c.revision;
          await checked(c.patchField(351, [0]));
          expect(c.revision, revision);
        });
        await step('input_pan_tempo_name', () async {
          await checked(
            c.patchField(350, [
              originalPatch![350] == 0 ? 1 : originalPatch![350] - 1,
            ]),
          );
          await verifyPatch(350, [
            originalPatch![350] == 0 ? 1 : originalPatch![350] - 1,
          ]);
          await checked(c.patchField(372, raw16(-23)));
          await verifyPatch(372, raw16(-23));
          await checked(c.patchField(330, raw16(97)));
          await verifyPatch(330, raw16(97));
          await checked(c.rename('AUDIT_TEMP'));
          expect(c.patch!.name, 'AUDIT_TEMP');
        });
        await step('globals_usb_eq_tuner_reference', () async {
          await global(4, [
            originalGlobals![4] == 0 ? 1 : originalGlobals![4] - 1,
          ]);
          await global(61, [99]);
          await global(38, [1]);
          await global(60, [1]);
        });
        await step('full_PATCH_atomic_write_and_knob_disable', () async {
          final candidate = Uint8List.fromList(c.patch!.bytes);
          candidate.setRange(372, 374, raw16(17));
          await checked(c.writeField(Gt1.patchOffset(c.selected), candidate));
          await verifyPatch(0, candidate);
          final knob = candidate.sublist(352, 372);
          knob[9] = knob[19] = 0;
          await checked(c.patchField(352, knob));
          await verifyPatch(352, knob);
          final mapping = (await c.session!.command(8, 1, 0x20, [0])).data;
          expect(mapping, hasLength(11));
          expect(mapping[10], 0);
        });
        if (originalPatch![349] == 0) {
          await step(
            'effect_add_parameter_bypass_duplicate_reorder_delete',
            () async {
              final candidates = c.types
                  .where((t) => t.flags & 3 == 0 && t.count > 0)
                  .toList();
              final type =
                  candidates
                      .where((t) => t.name.toLowerCase().contains('gate'))
                      .firstOrNull ??
                  candidates.first;
              report['testedType'] = {'id': type.id, 'name': type.name};
              await persist();
              await checked(c.action(1, 0, 1, [0, ...Gt1.u14(type.id)]));
              expect(c.patch!.count, 1);
              await checked(c.selectUnit(0));
              expect(c.parameters, isNotEmpty);
              final p = c.parameters.indexWhere((p) => p.max > p.min);
              if (p < 0) {
                throw StateError(
                  'Selected type has no adjustable visible parameters',
                );
              }
              final info = c.parameters[p],
                  current = c.patch!.unit(0).parameter(p);
              final next = current < info.max ? current + 1 : current - 1;
              await checked(c.patchField(6 + p * 2, raw16(next)));
              await verifyPatch(6 + p * 2, raw16(next));
              if (type.flags & 4 != 0) {
                await checked(c.patchField(4, [1]));
                await verifyPatch(4, [1]);
                report['clearOnBypassTested'] = true;
              }
              await checked(c.action(1, 4, 0, [0]));
              expect(c.patch!.unit(0).enabled, isFalse);
              await checked(c.action(1, 3, 0, [0]));
              expect(c.patch!.unit(0).enabled, isTrue);
              await checked(c.action(1, 0, 1, [1, ...Gt1.u14(type.id)]));
              expect(c.patch!.count, 2);
              if (const bool.fromEnvironment('HARDWARE_UI_MOVEMENT')) {
                await verifyUiMovement();
              }
              await checked(c.action(1, 0, 2, [0, 1]));
              expect(c.patch!.chain, [1, 0]);
              await checked(c.action(1, 0x0b, 0, [1]));
              expect(c.patch!.count, 1);
              await checked(c.action(1, 0x0b, 0, [0]));
              expect(c.patch!.count, 0);
            },
          );
        } else {
          if (const bool.fromEnvironment('HARDWARE_UI_MOVEMENT')) {
            await step(
              'actual_UI_forward_backward_existing_chain',
              verifyUiMovement,
            );
          }
          checks.add({
            'name': 'effect_structure',
            'status': 'skipped',
            'reason': 'Existing effect chain preserved',
          });
        }
        await step('GT1S_partial_import_cancel_preserves_patch', () async {
          final before = Uint8List.fromList(c.patch!.bytes);
          var cancel = false;
          final t = FileTransfer(
            c.session!,
            onProgress: (v) => cancel = true,
            cancelled: () => cancel,
          );
          await expectLater(
            t.transfer(bank: false, preset: c.selected, input: presetFile),
            throwsStateError,
          );
          expect(cancel, isTrue);
          expect((await c.session!.command(0, 1, 0x32)).data[1], 0);
          expect(
            await readRange(
              c.session!,
              c.revision,
              Gt1.patchOffset(c.selected),
              374,
            ),
            before,
          );
        });
        await step('tuner_enter_query_exit', () async {
          await checked(c.setTuner(true));
          expect(c.tunerActive, isTrue);
          expect((await c.session!.command(5, 1, 0)).data, hasLength(6));
          await checked(c.setTuner(false));
          expect(c.tunerActive, isFalse);
        });
        await step('drum_start_stop', () async {
          // Do not infer availability from an empty/default pattern field.
          await c.session!.command(3, 1, 0x20);
          await c.session!.command(3, 3, 0);
          try {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            expect((await c.session!.command(3, 1, 0)).data[0], isNot(0));
          } finally {
            await c.session!.command(3, 4, 0);
          }
        });
        if (loopWasEmpty) {
          await step('looper_record_play_overdub_undo_redo_clear', () async {
            await global(55, [0]);
            await global(57, [0]);
            await global(59, [0]);
            loopTouched = true;
            await c.session!.command(4, 0x14, 0);
            await waitLoop((d) => d[1] == 2);
            await Future<void>.delayed(const Duration(milliseconds: 700));
            await c.session!.command(4, 0x13, 0);
            final stopped = await waitLoop((d) => d[1] == 0 && d[2] & 8 == 0);
            expect(Gt1.integer(stopped, 14, 5), greaterThan(0));
            await c.session!.command(4, 0x12, 0);
            await waitLoop((d) => d[1] == 1);
            await Future<void>.delayed(const Duration(milliseconds: 200));
            final playing = await loopStatus();
            report['looperPlayback'] = playing;
            final duration = Gt1.integer(playing, 14, 5);
            await c.session!.command(4, 0x14, 0);
            await waitLoop((d) => d[1] == 2 && d[2] & 4 != 0);
            await Future<void>.delayed(const Duration(milliseconds: 200));
            await c.session!.command(4, 0x13, 0);
            var stable = await waitLoop(
              (d) => d[1] == 0 && d[2] & 8 == 0 && d[2] & 2 != 0,
            );
            for (var i = 0; i < 2; i++) {
              final generation = Gt1.integer(stable, 4, 5);
              await c.session!.command(4, 0x16, 0);
              stable = await waitLoop(
                (d) => d[3] == 0 && Gt1.integer(d, 4, 5) != generation,
              );
              expect(Gt1.integer(stable, 14, 5), duration);
            }
            await c.session!.command(4, 0x15, 0);
            await waitLoop((d) => d[1] == 0 && d[2] & 1 == 0);
          });
        }
        if (!c.currentFactoryPreset) {
          await step('RAM_save_ack', () => checked(c.save()));
        } else {
          checks.add({
            'name': 'RAM_save_ack',
            'status': 'skipped',
            'reason':
                'Factory preset requires Save As; other presets are excluded from this audit',
          });
        }
      } finally {
        if (mutationsStarted &&
            originalPatch != null &&
            originalGlobals != null &&
            !transportFailed &&
            c.session?.isValid == true) {
          if (transport.backupSaved) {
            await step('restore_runtime_and_all_changed_globals', () async {
              if (!c.ready) {
                await resync();
              }
              c.setActivePage(null);
              if (loopTouched) {
                await c.session!.command(4, 0x13, 0);
                await waitLoop((d) => d[1] == 0);
                await c.session!.command(4, 0x15, 0);
                await waitLoop((d) => d[1] == 0 && d[2] & 1 == 0);
              }
              await checked(c.setTuner(tunerWasActive));
            });
            for (final field in changedGlobals) {
              await step('restore_global_${field.$1}', () async {
                await checked(
                  c.writeField(
                    field.$1,
                    originalGlobals!.sublist(field.$1, field.$1 + field.$2),
                  ),
                );
              });
            }
          }
          await step('GT1S_import_restore_and_full_bank_verify', () async {
            transport.restoringPreset = true;
            if (transport.backupSaved) {
              final quietPreset = Uint8List.fromList(presetFile!);
              quietPreset[8 + 361] = quietPreset[8 + 371] = 0;
              ByteData.sublistView(quietPreset).setUint32(
                quietPreset.length - 4,
                PresetFile.crc32(
                  quietPreset.sublist(0, quietPreset.length - 4),
                ),
                Endian.little,
              );
              await transfer().transfer(
                bank: false,
                preset: transport.preset!,
                input: quietPreset,
              );
              await resync();
              expect(c.globals, originalGlobals);
              expect(
                await readRange(c.session!, c.revision, 0, Gt1.bankSize),
                bankFile!.sublist(16, bankFile!.length - 4),
              );
              report['quietBankRestoredVerified'] = true;
            }
            await transfer().transfer(
              bank: false,
              preset: transport.preset!,
              input: presetFile,
            );
            await resync();
            expect(c.patch!.bytes, originalPatch);
            expect(c.globals, originalGlobals);
            report['restored'] = true;
            report['finalRevision'] = c.revision;
          });
        }
        report['logs'] = List.of(c.logs);
        report['transportFailed'] = transportFailed;
        if (mutationsStarted && report['restored'] != true) {
          report['restorationIncomplete'] = true;
        }
        report['allChecksPassed'] = checks.every(
          (v) => v['status'] != 'failed',
        );
        report['finished'] = DateTime.now().toIso8601String();
        await persist();
        await c.disconnect();
        c.dispose();
      }
      expect(
        checks.where((v) => v['status'] == 'failed').map((v) => v['name']),
        isEmpty,
        reason: 'See report.json for failed hardware features and restoration',
      );
      expect(report['restored'], isTrue);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
