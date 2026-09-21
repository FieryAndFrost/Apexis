import 'dart:async';
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
import 'hardware_backup_test.dart' show BackupTransport;
import 'hardware_readonly_test.dart' show readRange;

/// Explicit destructive test. No firmware/power commands and no reset retries.
class FactoryAuditTransport extends BackupTransport {
  FactoryAuditTransport(super.inner, super.trace);
  int? preset;
  bool patchSaved = false, bankVerified = false;
  String phase = 'backup';
  int resetBegins = 0, resetCommits = 0;

  @override
  Future<void> send(Uint8List frame) {
    final m = Message.parse(frame, response: false);
    var allowed = false;
    if (patchSaved &&
        phase == 'backup' &&
        m.component == 9 &&
        m.command == 0 &&
        m.selector == 0x41 &&
        m.data.length >= 13) {
      allowed =
          Gt1.integer(m.data, 7, 3) == Gt1.patchOffset(preset!, 352) &&
          Gt1.integer(m.data, 10, 2) == 20;
    }
    if (bankVerified && phase == 'reset' && m.component == 0) {
      if (m.command == 7 &&
          m.selector == 0x34 &&
          m.data.length == 1 &&
          m.data[0] == 1 &&
          resetBegins == 0) {
        resetBegins++;
        allowed = true;
      } else if (m.command == 8 &&
          m.selector == 0x36 &&
          m.data.length == 2 &&
          resetBegins == 1 &&
          resetCommits == 0) {
        resetCommits++;
        allowed = true;
      }
    }
    if (phase == 'restore' && m.component == 0 && patchSaved) {
      allowed =
          (m.command == 0 &&
              m.selector == 0x30 &&
              m.data.length == 1 &&
              m.data[0] == preset) ||
          (m.command == 0 && m.selector == 0x31) ||
          (m.command == 8 && m.selector == 0x32) ||
          (bankVerified &&
              m.command == 0 &&
              [0x34, 0x35].contains(m.selector)) ||
          (bankVerified && m.command == 8 && m.selector == 0x36);
    }
    if (!allowed) return super.send(frame);
    trace.add({'time': DateTime.now().toIso8601String(), 'tx': frame.toList()});
    return inner.send(frame);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'one factory reset with verified backup and restoration',
    (tester) async {
      const target = String.fromEnvironment('MIDI_DEVICE');
      const destination = String.fromEnvironment('AUDIT_DIRECTORY');
      if (!const bool.fromEnvironment('HARDWARE_FACTORY_RESET') ||
          target.isEmpty ||
          destination.isEmpty) {
        fail(
          'Explicit factory-reset opt-in, exact target and new directory required',
        );
      }
      final dir = Directory(destination);
      if (await dir.exists()) fail('Never overwrite evidence');
      await dir.create(recursive: true);
      final trace = <Map<String, Object?>>[], steps = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'started': DateTime.now().toIso8601String(),
        'trace': trace,
        'steps': steps,
        'resetAttempted': false,
        'restored': false,
        'backupVerified': false,
      };
      binding.reportData = report;
      Future<void> persist() => File(
        '$destination/report.json',
      ).writeAsString(jsonEncode(report), flush: true);
      void mark(String name, [Object? data]) {
        steps.add({
          'time': DateTime.now().toIso8601String(),
          'name': name,
          'data': data,
        });
        debugPrint('FACTORY STEP $name: $data');
      }

      final c = ApexisController(), native = NativeTransport();
      final transport = FactoryAuditTransport(native, trace);
      Uint8List? originalPreset, quietBank, recoveryPreset, recoveryBank;
      const recoveryDirectory = String.fromEnvironment(
        'FINAL_RESTORE_DIRECTORY',
      );
      int? recoverySelected;
      var ownsTransport = false, mappingAttempted = false;
      var heartbeat = 0, maxHeartbeatGapMs = 0;
      final clock = Stopwatch()..start();
      var lastBeat = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final now = clock.elapsedMilliseconds;
        final gap = now - lastBeat;
        if (gap > maxHeartbeatGapMs) maxHeartbeatGapMs = gap;
        lastBeat = now;
        heartbeat++;
      });
      FileTransfer transfer() =>
          FileTransfer(c.session!, onProgress: (_) {}, cancelled: () => false);
      try {
        if (recoveryDirectory.isNotEmpty) {
          final prior = jsonDecode(
            await File('$recoveryDirectory/report.json').readAsString(),
          );
          expect(prior['backupVerified'], isTrue);
          recoverySelected = prior['selected'] as int;
          recoveryPreset = await File(
            '$recoveryDirectory/original.gt1s',
          ).readAsBytes();
          recoveryBank = await File(
            '$recoveryDirectory/quiet-before.gt1b',
          ).readAsBytes();
          PresetFile.validate(recoveryPreset, bank: false);
          PresetFile.validate(recoveryBank, bank: true);
          expect(recoveryPreset.length, 386);
          expect(recoveryBank[16], recoverySelected);
          final mappingStart = 16 + Gt1.patchOffset(recoverySelected, 352);
          expect(recoveryBank[mappingStart + 9], 0);
          expect(recoveryBank[mappingStart + 19], 0);
          report['finalRecoveryDirectory'] = recoveryDirectory;
        }
        final ports = (await native.scan())
            .where((p) => p.name == target)
            .toList();
        expect(ports, hasLength(1));
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Center(child: Text('GT1 恢复出厂实机诊断 · 请勿操作或断电'))),
          ),
        );
        ownsTransport = true;
        await c.connect(transport, ports.single);
        expect(c.error, isNull);
        expect(c.ready, isTrue);
        c.setActivePage(null);
        transport.preset = c.selected;
        if (recoverySelected != null) expect(c.selected, recoverySelected);
        report['selected'] = c.selected;
        expect((await c.session!.command(9, 1, 0)).data[0], 0);
        expect((await c.session!.command(3, 1, 0)).data[0], 0);
        expect((await c.session!.command(4, 1, 0x21)).data[1], 0);
        originalPreset = await transfer().transfer(
          bank: false,
          preset: c.selected,
        );
        PresetFile.validate(originalPreset, bank: false);
        expect(originalPreset.length, 386);
        await File(
          '$destination/original.gt1s',
        ).writeAsBytes(originalPreset, flush: true);
        transport.patchSaved = true;
        mark('original_preset_saved');
        final mapping = originalPreset.sublist(8 + 352, 8 + 372);
        mapping[9] = mapping[19] = 0;
        mappingAttempted = true;
        await c.patchField(352, mapping);
        expect(c.error, isNull);
        expect(c.patch!.bytes.sublist(352, 372), mapping);
        mark('physical_mappings_temporarily_disabled');
        final revision = c.revision;
        quietBank = await transfer().transfer(bank: true, preset: c.selected);
        PresetFile.validate(quietBank, bank: true);
        await File(
          '$destination/quiet-before.gt1b',
        ).writeAsBytes(quietBank, flush: true);
        expect(
          await readRange(c.session!, revision, 0, Gt1.bankSize),
          quietBank.sublist(16, quietBank.length - 4),
        );
        expect(c.revision, revision);
        transport.bankVerified = true;
        report['backupVerified'] = true;
        // Complete restoration image: independently verified quiet bank, with
        // the saved original current preset reinserted. Clearly mark provenance.
        final restoration = Uint8List.fromList(quietBank);
        final offset = 16 + Gt1.patchOffset(transport.preset!);
        restoration.setRange(
          offset,
          offset + 374,
          originalPreset.sublist(8, 382),
        );
        ByteData.sublistView(restoration).setUint32(
          restoration.length - 4,
          PresetFile.crc32(restoration.sublist(0, restoration.length - 4)),
          Endian.little,
        );
        PresetFile.validate(restoration, bank: true);
        await File(
          '$destination/restoration.gt1b',
        ).writeAsBytes(restoration, flush: true);
        report['restorationImageProvenance'] =
            'verified quiet bank + pre-isolation GT1S';
        mark('full_bank_verified');
        await persist();
        transport.phase = 'reset';
        report['resetAttempted'] = true;
        mark('reset_single_attempt');
        await persist();
        final watch = Stopwatch()..start();
        await transfer().restoreDefaults();
        report['resetAckMilliseconds'] = watch.elapsedMilliseconds;
        mark('reset_ack', watch.elapsedMilliseconds);
        await c.resync();
        await c.waitReady();
        expect(c.selected, 0);
        expect(c.patch!.count, 0);
        expect(c.patch!.name, 'F01A');
        report['resetReadback'] = {
          'globals': c.globals.toList(),
          'patch': c.patch!.bytes.toList(),
        };
        for (var i = 0; i < 10; i++) {
          expect((await c.session!.command(9, 1, 0)).data, hasLength(4));
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        report['resetVerified'] = true;
        mark('post_reset_queries_ok');
      } catch (e, st) {
        report['error'] = '$e';
        report['stack'] = '$st';
        mark('failed', '$e');
      } finally {
        if (mappingAttempted &&
            originalPreset != null &&
            c.session?.isValid == true) {
          transport.phase = 'restore';
          try {
            final restoreBank = recoveryBank ?? quietBank;
            final restorePreset = report['resetAttempted'] == true
                ? (recoveryPreset ?? originalPreset)
                : originalPreset;
            if (transport.bankVerified && report['resetAttempted'] == true) {
              mark('restore_quiet_bank');
              await persist();
              await transfer().transfer(
                bank: true,
                preset: transport.preset!,
                input: restoreBank,
              );
              await c.resync();
              await c.waitReady();
              expect(
                await readRange(c.session!, c.revision, 0, Gt1.bankSize),
                restoreBank!.sublist(16, restoreBank.length - 4),
              );
              report['quietBankRestoredVerified'] = true;
            }
            await transfer().transfer(
              bank: false,
              preset: transport.preset!,
              input: restorePreset,
            );
            await c.resync();
            await c.waitReady();
            expect(c.patch!.bytes, restorePreset.sublist(8, 382));
            report['restored'] = true;
            mark('original_preset_and_mappings_restored');
          } catch (e, st) {
            report['restorationError'] = '$e';
            report['restorationStack'] = '$st';
            mark('restoration_failed', '$e');
          }
        }
        timer.cancel();
        report['heartbeatCount'] = heartbeat;
        report['maxHeartbeatGapMs'] = maxHeartbeatGapMs;
        report['logs'] = List.of(c.logs);
        report['finished'] = DateTime.now().toIso8601String();
        await persist();
        await c.disconnect();
        if (!ownsTransport) await transport.dispose();
        c.dispose();
      }
      expect(report['error'], isNull);
      expect(report['resetVerified'], isTrue);
      expect(report['restored'], isTrue);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
