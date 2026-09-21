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

/// Only backed-up globals and U126/U127 may be edited; no factory reset/BOOT.
class ExtendedAuditTransport extends FactoryAuditTransport {
  ExtendedAuditTransport(super.inner, super.trace);
  @override
  Future<void> send(Uint8List frame) {
    final m = Message.parse(frame, response: false);
    var allowed = false;
    if (bankVerified && phase == 'extended') {
      final targets = [preset, 126, 127];
      if (m.component == 0 && m.selector == 0) {
        allowed =
            (m.command == 0 &&
                m.data.length == 1 &&
                targets.contains(m.data[0])) ||
            (m.command == 0x0a &&
                m.data.length == 2 &&
                targets.contains(m.data[0]) &&
                [126, 127].contains(m.data[1])) ||
            (m.command == 0x0c &&
                m.data.length == 2 &&
                m.data[0] == 126 &&
                m.data[1] == 127) ||
            (m.command == 8 && m.data.isEmpty);
      }
      if (m.component == 9 &&
          m.command == 0 &&
          m.selector == 0x41 &&
          m.data.length >= 13) {
        final at = Gt1.integer(m.data, 7, 3), size = Gt1.integer(m.data, 10, 2);
        allowed = at < 64 && at + size <= 64;
        for (final id in targets.cast<int>()) {
          final start = Gt1.patchOffset(id);
          allowed |= at >= start && at + size <= start + 374;
        }
      }
    }
    if (!allowed) return super.send(frame);
    trace.add({'time': DateTime.now().toIso8601String(), 'tx': frame.toList()});
    return inner.send(frame);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'backed-up user preset and global control acceptance',
    (tester) async {
      const target = String.fromEnvironment('MIDI_DEVICE');
      const destination = String.fromEnvironment('AUDIT_DIRECTORY');
      if (!const bool.fromEnvironment('HARDWARE_EXTENDED') ||
          target.isEmpty ||
          destination.isEmpty) {
        fail(
          'Explicit extended write opt-in, exact target and new directory required',
        );
      }
      final dir = Directory(destination);
      if (await dir.exists()) fail('Never overwrite evidence');
      await dir.create(recursive: true);
      final trace = <Map<String, Object?>>[], checks = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'started': DateTime.now().toIso8601String(),
        'trace': trace,
        'checks': checks,
        'restored': false,
        'bankVerified': false,
      };
      binding.reportData = report;
      Future<void> persist() => File(
        '$destination/report.json',
      ).writeAsString(jsonEncode(report), flush: true);
      final c = ApexisController(), native = NativeTransport();
      final transport = ExtendedAuditTransport(native, trace);
      Uint8List? originalPreset, quietBank;
      var owns = false, mappingTouched = false;
      Future<void> checked(Future<void> action) async {
        await action;
        if (c.error != null) throw StateError(c.error!);
        expect(c.ready, isTrue);
      }

      Future<void> step(String name, Future<void> Function() action) async {
        final entry = <String, Object?>{
          'name': name,
          'started': DateTime.now().toIso8601String(),
          'status': 'running',
        };
        checks.add(entry);
        await persist();
        debugPrint('EXTENDED STEP $name');
        try {
          await action();
          entry['status'] = 'ok';
        } catch (e) {
          entry['status'] = 'failed';
          entry['error'] = '$e';
          rethrow;
        } finally {
          entry['finished'] = DateTime.now().toIso8601String();
          await persist();
        }
      }

      FileTransfer transfer() =>
          FileTransfer(c.session!, onProgress: (_) {}, cancelled: () => false);
      try {
        final ports = (await native.scan())
            .where((p) => p.name == target)
            .toList();
        expect(ports, hasLength(1));
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Center(child: Text('GT1 全局与 U 区验收 · 请勿操作或断电')),
            ),
          ),
        );
        owns = true;
        await c.connect(transport, ports.single);
        expect(c.error, isNull);
        expect(c.ready, isTrue);
        expect(c.factoryUserPresets, isTrue);
        c.setActivePage(null);
        transport.preset = c.selected;
        expect(c.selected, lessThan(64));
        expect(
          c.patch!.count,
          0,
          reason: 'Use an empty source; do not activate unknown DSP chains',
        );
        expect((await c.session!.command(9, 1, 0)).data[0], 0);
        expect((await c.session!.command(3, 1, 0)).data[0], 0);
        final loop = (await c.session!.command(4, 1, 0x21)).data;
        expect(loop[1], 0);
        expect(loop[2] & 1, 0);
        expect(loop[3], 0);
        report['selected'] = c.selected;
        report['version'] = c.identity!.version;
        await step('backup_and_isolate_knob_mappings', () async {
          originalPreset = await transfer().transfer(
            bank: false,
            preset: c.selected,
          );
          PresetFile.validate(originalPreset!, bank: false);
          await File(
            '$destination/original.gt1s',
          ).writeAsBytes(originalPreset!, flush: true);
          transport.patchSaved = true;
          final maps = originalPreset!.sublist(360, 380);
          maps[9] = maps[19] = 0;
          mappingTouched = true;
          await checked(c.patchField(352, maps));
          final revision = c.revision;
          quietBank = await transfer().transfer(bank: true, preset: c.selected);
          PresetFile.validate(quietBank!, bank: true);
          await File(
            '$destination/quiet-before.gt1b',
          ).writeAsBytes(quietBank!, flush: true);
          expect(
            await readRange(c.session!, revision, 0, Gt1.bankSize),
            quietBank!.sublist(16, quietBank!.length - 4),
          );
          expect(c.revision, revision);
          transport.bankVerified = true;
          report['bankVerified'] = true;
          report['backupVerified'] = true;
        });
        transport.phase = 'extended';
        await step('F_to_U_save_as_copy_swap_save_directory', () async {
          await checked(c.patchField(351, [0]));
          final source = c.patch!.bytes.toList();
          await checked(c.action(0, 0x0a, 0, [transport.preset!, 126]));
          expect(c.selected, transport.preset);
          expect(
            await readRange(c.session!, c.revision, Gt1.patchOffset(126), 374),
            source,
          );
          await checked(c.action(0, 0, 0, [126]));
          await checked(c.rename('AUDIT_U_A'));
          await checked(c.action(0, 0x0a, 0, [126, 127]));
          await checked(c.action(0, 0, 0, [127]));
          expect(c.patch!.name, 'AUDIT_U_A');
          await checked(c.rename('AUDIT_U_B'));
          await checked(c.action(0, 0x0c, 0, [126, 127]));
          report['swapSelected'] = c.selected;
          report['swapCurrentName'] = c.patch!.name;
          expect(
            c.selected,
            126,
            reason: 'Selection follows swapped preset content',
          );
          expect(c.patch!.name, 'AUDIT_U_B');
          await checked(c.save());
          await checked(c.loadPresetPage(126));
          expect(c.presetNames[126], 'AUDIT_U_B');
          expect(c.presetNames[127], 'AUDIT_U_A');
          expect(c.presetFlags[126]! & 1, 1);
          await checked(c.action(0, 0, 0, [transport.preset!]));
        });
        await step(
          'global_EQ_looper_preferences_independent_readback',
          () async {
            final fields = <(int, List<int>)>[
              (1, [1]),
              (1, [2]),
              (2, [1]),
              (3, [1]),
              (4, [63]),
              (5, [50]),
              (6, [65]),
              (7, [70]),
              (8, [16]),
              (9, [1]),
              (10, [1]),
              (10, [2]),
              (11, [1]),
              (12, raw16(101)),
              (14, raw16(109)),
              (16, [1]),
              (17, [1]),
              (32, [1]),
              (34, raw16(80)),
              (36, raw16(12000)),
              for (var i = 0; i < 4; i++) ...[
                (38 + i * 4, [-3 & 255]),
                (39 + i * 4, raw16([120, 800, 1800, 4200][i])),
                (41 + i * 4, [9]),
              ],
              (54, [25]),
              (55, [0]),
              (56, [50]),
              (57, [2]),
              (58, [3]),
              (59, [1]),
              (60, [2]),
              (61, [75]),
              (62, [1]),
              for (var mode = 0; mode < 4; mode++) (63, [mode]),
            ];
            for (final field in fields) {
              report['lastGlobalOffset'] = field.$1;
              await checked(c.writeField(field.$1, field.$2));
              expect(
                await readRange(
                  c.session!,
                  c.revision,
                  field.$1,
                  field.$2.length,
                ),
                field.$2,
              );
            }
            report['globalFieldWritesVerified'] = fields.length;
            await checked(c.loadPatterns());
            expect(c.patterns, isNotEmpty);
            final pattern = c.patterns.keys.last;
            for (final offset in [18, 20]) {
              await checked(c.writeField(offset, raw16(pattern)));
              expect(
                await readRange(c.session!, c.revision, offset, 2),
                raw16(pattern),
              );
            }
            await checked(c.loadResources());
            report['installedResources'] = c.resources.length;
            report['audio_and_trigger_validation'] = 'not_performed';
          },
        );
      } catch (e, st) {
        report['error'] = '$e';
        report['stack'] = '$st';
      } finally {
        if (mappingTouched &&
            originalPreset != null &&
            c.session?.isValid == true) {
          transport.phase = 'restore';
          try {
            if (transport.bankVerified) {
              await step(
                'restore_quiet_bank_and_verify_all_addresses',
                () async {
                  await transfer().transfer(
                    bank: true,
                    preset: transport.preset!,
                    input: quietBank,
                  );
                  await c.resync();
                  await c.waitReady();
                  expect(c.selected, transport.preset);
                  expect(
                    await readRange(c.session!, c.revision, 0, Gt1.bankSize),
                    quietBank!.sublist(16, quietBank!.length - 4),
                  );
                },
              );
            }
            await transfer().transfer(
              bank: false,
              preset: transport.preset!,
              input: originalPreset,
            );
            await c.resync();
            await c.waitReady();
            expect(c.patch!.bytes, originalPreset!.sublist(8, 382));
            report['restored'] = true;
          } catch (e, st) {
            report['restorationError'] = '$e';
            report['restorationStack'] = '$st';
          }
        }
        report['finished'] = DateTime.now().toIso8601String();
        report['logs'] = List.of(c.logs);
        await persist();
        await c.disconnect();
        if (!owns) await transport.dispose();
        c.dispose();
      }
      expect(report['error'], isNull);
      expect(report['restorationError'], isNull);
      expect(report['restored'], isTrue);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
