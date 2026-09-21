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
import 'hardware_factory_test.dart' show FactoryAuditTransport;
import 'hardware_readonly_test.dart' show readRange;

/// Recovery only: no reset, power control, firmware update, or automatic retry.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'restore independently verified pre-test backup',
    (tester) async {
      const source = String.fromEnvironment('FINAL_RESTORE_DIRECTORY');
      const destination = String.fromEnvironment('AUDIT_DIRECTORY');
      const target = String.fromEnvironment('MIDI_DEVICE');
      const rounds = int.fromEnvironment('RESTORE_ROUNDS', defaultValue: 1);
      if (!const bool.fromEnvironment('HARDWARE_RESTORE') ||
          source.isEmpty ||
          destination.isEmpty ||
          target.isEmpty) {
        fail(
          'Explicit recovery opt-in, backup, target and new evidence required',
        );
      }
      expect(rounds, inInclusiveRange(1, 5));
      final dir = Directory(destination);
      if (await dir.exists()) fail('Never overwrite evidence');
      final prior = jsonDecode(
        await File('$source/report.json').readAsString(),
      );
      expect(prior['backupVerified'], isTrue);
      const writeAudit = bool.fromEnvironment('RESTORE_WRITE_AUDIT');
      final isolatedWriteAudit =
          writeAudit && prior['backupFormat'] == 'quiet_bank_original_preset';
      final selected =
          (writeAudit ? prior['baseline']['selected'] : prior['selected'])
              as int;
      final bank = await File(
        '$source/${writeAudit && !isolatedWriteAudit ? 'before.gt1b' : 'quiet-before.gt1b'}',
      ).readAsBytes();
      final preset = await File(
        '$source/${writeAudit ? 'before.gt1s' : 'original.gt1s'}',
      ).readAsBytes();
      PresetFile.validate(bank, bank: true);
      PresetFile.validate(preset, bank: false);
      expect(preset.length, 386);
      expect(bank[16], selected);
      final mapping = 16 + Gt1.patchOffset(selected, 352);
      if (writeAudit) {
        final expectedPatch = preset.sublist(8, 382);
        if (isolatedWriteAudit) {
          expectedPatch[361] = expectedPatch[371] = 0;
        }
        expect(
          bank.sublist(
            16 + Gt1.patchOffset(selected),
            16 + Gt1.patchOffset(selected) + Gt1.patchSize,
          ),
          expectedPatch,
        );
        // Only the verification intermediate disables physical mappings.
        // The original preset (including both mappings) is restored last.
        bank[mapping + 9] = bank[mapping + 19] = 0;
        ByteData.sublistView(bank).setUint32(
          bank.length - 4,
          PresetFile.crc32(bank.sublist(0, bank.length - 4)),
          Endian.little,
        );
        PresetFile.validate(bank, bank: true);
      }
      expect(bank[mapping + 9], 0);
      expect(bank[mapping + 19], 0);
      await dir.create(recursive: true);
      if (writeAudit) {
        await File(
          '$destination/derived-quiet-bank.gt1b',
        ).writeAsBytes(bank, flush: true);
      }
      final trace = <Map<String, Object?>>[], steps = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'started': DateTime.now().toIso8601String(),
        'source': source,
        'sourceFormat': writeAudit ? 'write_audit' : 'quiet_factory_audit',
        'selected': selected,
        'trace': trace,
        'steps': steps,
        'resetAttempted': false,
        'restored': false,
        'requestedRounds': rounds,
        'completedRounds': 0,
      };
      binding.reportData = report;
      Future<void> mark(String name) async {
        steps.add({'time': DateTime.now().toIso8601String(), 'name': name});
        debugPrint('RESTORE STEP $name');
        await File(
          '$destination/report.json',
        ).writeAsString(jsonEncode(report), flush: true);
      }

      var c = ApexisController(), native = NativeTransport();
      var transport = FactoryAuditTransport(native, trace)..preset = selected;
      var ownsTransport = false;
      try {
        final ports = (await native.scan())
            .where((p) => p.name == target)
            .toList();
        expect(ports, hasLength(1));
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Center(child: Text('GT1 恢复测试前备份 · 请勿操作或断电'))),
          ),
        );
        ownsTransport = true;
        await c.connect(transport, ports.single);
        expect(c.error, isNull);
        expect(c.ready, isTrue);
        c.setActivePage(null);
        expect(c.selected, selected);
        expect((await c.session!.command(9, 1, 0)).data[0], 0);
        expect((await c.session!.command(3, 1, 0)).data[0], 0);
        expect((await c.session!.command(4, 1, 0x21)).data[1], 0);
        var operation = 'backup_current', lastProgress = -1;
        FileTransfer transfer() => FileTransfer(
          c.session!,
          onProgress: (value) {
            report['operation'] = operation;
            report['progress'] = value;
            final percent = (value * 10).floor();
            if (percent != lastProgress) {
              lastProgress = percent;
              debugPrint('RESTORE $operation: ${(value * 100).floor()}%');
            }
          },
          onPhase: (phase) {
            final event = {
              'time': DateTime.now().toIso8601String(),
              'round': report['round'],
              'operation': operation,
              'phase': phase.name,
            };
            steps.add(event);
            File('$destination/phases.jsonl').writeAsStringSync(
              '${jsonEncode(event)}\n',
              mode: FileMode.append,
              flush: true,
            );
          },
          cancelled: () => false,
        );
        report['identityVersion'] = c.identity!.version;
        await mark('backup_current_before_any_write');
        final beforePreset = await transfer().transfer(
          bank: false,
          preset: selected,
        );
        PresetFile.validate(beforePreset, bank: false);
        await File(
          '$destination/before.gt1s',
        ).writeAsBytes(beforePreset, flush: true);
        if (writeAudit) {
          transport.patchSaved = true;
          final quietMapping = beforePreset.sublist(8 + 352, 8 + 372);
          quietMapping[9] = quietMapping[19] = 0;
          await mark('disable_mappings_after_current_preset_backup');
          await c.patchField(352, quietMapping);
          expect(c.error, isNull);
          expect(c.patch!.bytes.sublist(352, 372), quietMapping);
        }
        final beforeBank = await transfer().transfer(
          bank: true,
          preset: selected,
        );
        PresetFile.validate(beforeBank, bank: true);
        await File(
          '$destination/before.gt1b',
        ).writeAsBytes(beforeBank, flush: true);
        report['currentBackupCrcValidated'] = true;
        final timings = <int>[];
        report['systemQueryMilliseconds'] = timings;
        for (var round = 1; round <= rounds; round++) {
          report['round'] = round;
          report['restored'] = false;
          report['quietBankRestoredVerified'] = false;
          if (round > 1) {
            await c.disconnect();
            c.dispose();
            c = ApexisController();
            native = NativeTransport();
            transport = FactoryAuditTransport(native, trace)..preset = selected;
            ownsTransport = false;
            final ports = (await native.scan())
                .where((p) => p.name == target)
                .toList();
            expect(ports, hasLength(1));
            ownsTransport = true;
            await c.connect(transport, ports.single);
            expect(c.error, isNull);
            expect(c.ready, isTrue);
            expect(c.selected, selected);
            c.setActivePage(null);
          }
          await mark('round_${round}_connected');
          for (var sync = 0; sync < 3; sync++) {
            await c.resync();
            await c.waitReady();
            expect(c.error, isNull);
            expect(c.ready, isTrue);
          }
          for (var query = 0; query < 50; query++) {
            final watch = Stopwatch()..start();
            expect((await c.session!.command(9, 1, 0)).data, hasLength(4));
            timings.add(watch.elapsedMilliseconds);
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          transport.patchSaved = true;
          transport.bankVerified = true;
          transport.phase = 'restore';
          operation = 'restore_bank';
          lastProgress = -1;
          await mark('restore_verified_quiet_bank');
          await transfer().transfer(bank: true, preset: selected, input: bank);
          await c.resync();
          await c.waitReady();
          expect(
            await readRange(c.session!, c.revision, 0, Gt1.bankSize),
            bank.sublist(16, bank.length - 4),
          );
          report['quietBankRestoredVerified'] = true;
          operation = 'restore_preset';
          lastProgress = -1;
          await mark('restore_original_preset_and_mappings');
          await transfer().transfer(
            bank: false,
            preset: selected,
            input: preset,
          );
          await c.resync();
          await c.waitReady();
          expect(c.patch!.bytes, preset.sublist(8, 382));
          report['restored'] = true;
          report['completedRounds'] = round;
          await mark('round_${round}_restoration_verified');
        }
        for (var i = 0; i < 30; i++) {
          expect((await c.session!.command(9, 1, 0)).data, hasLength(4));
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        report['postRestoreQueriesPassed'] = 30;
        await mark('post_restore_30_seconds_ok');
      } catch (e, st) {
        report['error'] = '$e';
        report['stack'] = '$st';
      } finally {
        report['finished'] = DateTime.now().toIso8601String();
        report['logs'] = List.of(c.logs);
        await mark('finished');
        await c.disconnect();
        if (!ownsTransport) await transport.dispose();
        c.dispose();
      }
      expect(report['error'], isNull);
      expect(report['restored'], isTrue);
      expect(report['completedRounds'], rounds);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
