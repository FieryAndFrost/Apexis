import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/data/controller.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/transport/demo_transport.dart';
import 'package:apexis/transport/transport.dart';

const port = DevicePort('demo', 'GT1', '演示');

class DelayedPollDemo extends DemoTransport {
  bool fail = false;
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> send(frame) async {
    final message = Message.parse(frame, response: false);
    if (message.component == 3 && message.command == 1) {
      started.complete();
      await release.future;
      if (fail) {
        emitFrame(Gt1.frame(3, 1, 0, [], 1));
        return;
      }
      emitFrame(Gt1.frame(3, 1, 0, [1, 0, 0, 0, 0, 0, 0], 0));
      return;
    }
    await super.send(frame);
  }
}

void main() {
  test('快照不可变、按值去重、分区通知且发布是原子的', () async {
    final c = ApexisController();
    await c.connect(DemoTransport(), port, demonstration: true);
    final before = c.view.snapshot;
    final calls = <DeviceAspect, int>{};
    var legacy = 0;
    c.addListener(() => legacy++);
    for (final aspect in DeviceAspect.values) {
      c.view.channel(aspect).addListener(() {
        calls.update(aspect, (v) => v + 1, ifAbsent: () => 1);
        expect(c.view.snapshot.globals[4], c.globals[4]);
        expect(c.view.snapshot.patch?[350], c.patch?.input);
      });
    }
    c.emit();
    c.emit();
    expect(calls, isEmpty);
    expect(legacy, 0);
    expect(() => before.globals[4] = 0, throwsUnsupportedError);
    expect(() => before.patch![350] = 0, throwsUnsupportedError);
    expect(() => before.parameters.clear(), throwsUnsupportedError);
    c.globals[4]++;
    c.patch!.bytes[350]++;
    c.emit();
    expect(calls, {DeviceAspect.globals: 1, DeviceAspect.patch: 1});
    expect(before.globals[4], 64);
    expect(before.patch![350], 15);
    expect(legacy, 1);
    calls.clear();
    c.tunerPointer++;
    c.emit();
    expect(calls, {DeviceAspect.tuner: 1});
    await c.disconnect();
    c.dispose();
  });

  test('关闭的调音器不查询不通知，相同鼓机轮询结果不通知', () async {
    final c = ApexisController(), device = DemoTransport();
    await c.connect(device, port, demonstration: true);
    var calls = 0;
    c.addListener(() => calls++);
    final requests = device.requests.length;
    c.setActivePage(5);
    for (var i = 0; i < 3; i++) {
      await c.pollNow();
    }
    expect(device.requests.length, requests);
    expect(calls, 0);
    c.setActivePage(4);
    for (var i = 0; i < 3; i++) {
      await c.pollNow();
    }
    expect(device.requests.length, requests + 3);
    expect(calls, 0);
    await c.disconnect();
    c.dispose();
  });

  test('离开页面后丢弃在途轮询回包', () async {
    final c = ApexisController(), device = DelayedPollDemo();
    await c.connect(device, port, demonstration: true);
    c.setActivePage(4);
    final polling = c.pollNow();
    await device.started.future;
    c.setActivePage(null);
    device.release.complete();
    await polling;
    expect(c.drumState, 0);
    expect(c.view.snapshot.drum, 0);
    await c.disconnect();
    c.dispose();
  });

  test('离开页面后在途轮询错误不会污染新页面', () async {
    final c = ApexisController(), device = DelayedPollDemo()..fail = true;
    await c.connect(device, port, demonstration: true);
    c.setActivePage(4);
    final polling = c.pollNow();
    await device.started.future;
    c.setActivePage(null);
    device.release.complete();
    await polling;
    expect(c.error, isNull);
    await c.disconnect();
    c.dispose();
  });
}
