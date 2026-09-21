import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/data/controller.dart';
import 'package:apexis/data/parameters.dart';
import 'package:apexis/transport/transport.dart';
import 'support/firmware_demo.dart';

const port = DevicePort('demo', 'GT1', '演示');

void main() {
  test('编号区分旧固件与 F/U 地址，不从名称判断', () async {
    expect(presetLabel(64), '17A');
    for (final version in [117, 121, 122, 124]) {
      final c = ApexisController(), d = FirmwareDemo(version);
      await c.connect(d, port);
      expect(c.error, isNull);
      expect(c.factoryUserPresets, version >= 122);
      expect(c.labelForPreset(0), version >= 122 ? 'F01A' : '01A');
      expect(c.labelForPreset(63), version >= 122 ? 'F16D' : '16D');
      expect(c.labelForPreset(64), version >= 122 ? 'U01A' : '17A');
      expect(c.labelForPreset(127), version >= 122 ? 'U16D' : '32D');
      await c.disconnect();
      c.dispose();
    }
  });
  test('新版厂商保存/复制目标/交换在客户端拒绝，合法另存不自动切换', () async {
    final c = ApexisController(), d = FirmwareDemo(124);
    await c.connect(d, port);
    d.requests.clear();
    await c.save();
    expect(c.error, contains('另存'));
    await c.action(0, 0x0a, 0, [0, 63]);
    expect(c.error, contains('U 用户区'));
    await c.action(0, 0x0c, 0, [0, 64]);
    expect(c.error, contains('交换'));
    expect(d.requests, isEmpty);
    await c.action(0, 0x0a, 0, [0, 64]);
    expect(c.error, isNull);
    expect(c.selected, 0);
    await c.action(0, 0, 0, [64]);
    await c.save();
    expect(c.error, isNull);
    expect(c.notice, contains('软关机'));
    await c.disconnect();
    c.dispose();
  });
  test('旧固件保留原来的 RAM 保存路径', () async {
    final c = ApexisController(), d = FirmwareDemo(117);
    await c.connect(d, port);
    await c.save();
    expect(c.error, isNull);
    expect(d.requests.any((m) => m.component == 0 && m.command == 8), isTrue);
    await c.disconnect();
    c.dispose();
  });
  test('目录未持久化标志按设备返回保存，断连清空', () async {
    final c = ApexisController(), d = FirmwareDemo(124);
    await c.connect(d, port);
    await c.loadPresetPage(60);
    expect(c.presetFlags[63], 1);
    expect(c.presetFlags[64], 1);
    expect(c.view.snapshot.presetFlags[64], 1);
    await c.disconnect();
    expect(c.presetFlags, isEmpty);
    c.dispose();
  });
  test('鼓机拒绝后暂停自动轮询，可手动刷新恢复，不把拒绝当成空目录', () async {
    final c = ApexisController(), d = FirmwareDemo(117)..rejectDrum = true;
    await c.connect(d, port);
    c.setActivePage(4);
    await expectLater(c.pollNow(), throwsA(anything));
    expect(c.drumIssue, contains('不可用'));
    final count = d.drumQueries;
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(d.drumQueries, count);
    d.rejectDrum = false;
    await c.loadPatterns();
    expect(c.drumIssue, isNull);
    expect(c.error, isNull);
    expect(c.patterns.length, 3);
    await c.disconnect();
    c.dispose();
  });
  test('Looper pending/运行代次/预备拍来自独立 GET，断连清空', () async {
    final c = ApexisController(), d = FirmwareDemo(124)..cue = true;
    await c.connect(d, port);
    c.setActivePage(3);
    await c.pollNow();
    expect(c.loopPending, 2);
    expect(c.loopGeneration, 17);
    expect(c.loopCountinRemaining, 1200000);
    expect(c.view.snapshot.looper.countinRemaining, 1200000);
    await c.disconnect();
    expect(c.loopGeneration, 0);
    c.dispose();
  });
}
