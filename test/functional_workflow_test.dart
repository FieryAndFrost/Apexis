import 'package:apexis/data/controller.dart';
import 'package:apexis/data/parameters.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/firmware_demo.dart';

// Simulation coverage only: this cannot establish DSP capacity or audio quality.
void main() {
  Future<(ApexisController, FirmwareDemo)> open() async {
    final c = ApexisController(), d = FirmwareDemo(124);
    await c.connect(d, const DevicePort('demo', 'GT1', '演示'));
    expect(c.error, isNull);
    addTearDown(() async {
      await c.disconnect();
      c.dispose();
    });
    return (c, d);
  }

  test(
    'effect chain reaches 10, edits/reorders/deletes and survives rejected 11th',
    () async {
      final (c, _) = await open();
      while (c.patch!.count < 10) {
        final next = c.patch!.count;
        await c.action(1, 0, 1, [next, ...Gt1.u14(c.types.first.id)]);
        expect(c.error, isNull);
        expect(c.patch!.count, next + 1);
      }
      await c.selectUnit(9);
      await c.patchField(9 * 32 + 6, raw16(42));
      expect(c.patch!.unit(9).parameter(0), 42);
      await c.patchField(9 * 32 + 2, [0]);
      expect(c.patch!.bytes[9 * 32 + 2], 0);
      final reversed = c.patch!.chain.reversed.toList();
      await c.patchField(320, reversed);
      expect(c.patch!.chain, reversed);
      await c.action(1, 0, 1, [10, ...Gt1.u14(c.types.first.id)]);
      expect(c.error, isNotNull);
      expect(c.ready, isTrue);
      expect(c.patch!.count, 10);
      await c.action(1, 0x0b, 0, [9]);
      expect(c.error, isNull);
      expect(c.patch!.count, 9);
      expect(c.patch!.chain.toSet().length, 9);
      expect(c.patch!.chain.every((id) => id < 9), isTrue);
    },
  );

  test(
    'user preset copy/swap/rename/save preserves selected target and data',
    () async {
      final (c, _) = await open();
      await c.action(0, 0, 0, [64]);
      await c.rename('Audit A');
      await c.action(0, 0x0a, 0, [64, 65]);
      expect(c.selected, 64);
      await c.action(0, 0, 0, [65]);
      expect(c.patch!.name, 'Audit A');
      await c.rename('Audit B');
      await c.action(0, 0x0c, 0, [64, 65]);
      expect(c.selected, 64);
      expect(c.patch!.name, 'Audit B');
      await c.save();
      expect(c.error, isNull);
      await c.loadPresetPage(64);
      expect(c.presetNames[64], 'Audit B');
      expect(c.presetNames[65], 'Audit A');
    },
  );

  test(
    'preset swap follows either selected endpoint and ignores same address',
    () async {
      final (c, _) = await open();
      await c.action(0, 0, 0, [64]);
      final original = c.patch!.bytes.toList();
      await c.action(0, 0x0c, 0, [64, 65]);
      expect(c.selected, 65);
      expect(c.patch!.bytes, original);
      final revision = c.revision;
      await c.action(0, 0x0c, 0, [65, 65]);
      expect(c.selected, 65);
      expect(c.revision, revision);
      await c.action(0, 0, 0, [66]);
      final unrelated = c.patch!.bytes.toList();
      await c.action(0, 0x0c, 0, [64, 65]);
      expect(c.selected, 66);
      expect(c.patch!.bytes, unrelated);
    },
  );

  test('drum, looper, tuner and link status complete page workflows', () async {
    final (c, _) = await open();
    c.setActivePage(4);
    await c.loadPatterns();
    expect(c.patterns, isNotEmpty);
    await c.action(3, 3, 0, [], false);
    expect(c.drumState, 1);
    await c.action(3, 4, 0, [], false);
    expect(c.drumState, 0);
    c.setActivePage(3);
    await c.action(4, 0x14, 0, [], false);
    expect(c.loopState, 2);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await c.action(4, 0x13, 0, [], false);
    expect(c.loopTotal, greaterThan(0));
    await c.action(4, 0x12, 0, [], false);
    expect(c.loopState, 1);
    await c.action(4, 0x13, 0, [], false);
    await c.action(4, 0x15, 0, [], false);
    expect(c.loopTotal, 0);
    c.setActivePage(5);
    await c.setTuner(true);
    expect(c.tunerActive, isTrue);
    await c.pollNow();
    expect(c.tunerNote, 255);
    await c.setTuner(false);
    expect(c.tunerActive, isFalse);
    await c.readLinks();
    expect(c.error, isNull);
    expect(c.ready, isTrue);
  });
}
