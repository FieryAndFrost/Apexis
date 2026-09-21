import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/data/controller.dart';
import 'package:apexis/data/parameters.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/transport/demo_transport.dart';
import 'package:apexis/transport/transport.dart';

const port = DevicePort('demo', 'GT1', '演示');
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

class AckGateDemo extends DemoTransport {
  final gate = Completer<void>();
  bool waiting = false;
  @override
  Future<void> send(frame) async {
    final m = Message.parse(frame, response: false);
    if (m.component == 9 &&
        m.selector == 0x42 &&
        m.data.first == 2 &&
        !gate.isCompleted) {
      waiting = true;
      await gate.future;
    }
    await super.send(frame);
  }
}

class RetryDemo extends DemoTransport {
  bool rejectAckOnce = false;
  bool injectOldView = false;
  int busyWrites = 0;
  final rejectedFrames = <List<int>>[];
  @override
  Future<void> send(frame) async {
    final m = Message.parse(frame, response: false);
    if (m.component == 9 &&
        m.selector == 0x42 &&
        m.data.first == 3 &&
        injectOldView) {
      injectOldView = false;
      subscribed = true;
      bank[0] = 0;
      currentView(); // 模拟 USB 程序重开之前的旧快照队列。
      bank[0] = 18;
    }
    if (m.component == 9 &&
        m.selector == 0x42 &&
        m.data.first == 2 &&
        rejectAckOnce) {
      rejectAckOnce = false;
      emitFrame(Gt1.frame(9, 0, 0x42, [2, 2, ...Gt1.u32(revision)], 0));
      return;
    }
    if (m.component == 9 && m.selector == 0x41 && busyWrites > 0) {
      busyWrites--;
      rejectedFrames.add(List<int>.from(frame));
      emitFrame(Gt1.frame(9, 0, 0x41, [], 7));
      return;
    }
    await super.send(frame);
  }
}

class SnapshotOnWriteDemo extends DemoTransport {
  bool fullViewOnNextNotify = false;
  @override
  void notifyRange(int start, int length) {
    if (fullViewOnNextNotify) {
      fullViewOnNextNotify = false;
      super.notifyRange(0, 64);
      super.notifyRange(Gt1.patchOffset(bank[0]), 374);
      return;
    }
    super.notifyRange(start, length);
  }
}

void main() {
  test('写入后设备主动重发完整视图，不提前 ACK GLOB', () async {
    final c = ApexisController(), d = SnapshotOnWriteDemo();
    await c.connect(d, port, demonstration: true);
    d.requests.clear();
    d.fullViewOnNextNotify = true;
    await c.patchField(330, raw16(97));
    expect(c.error, isNull);
    expect(c.ready, isTrue);
    expect(c.patch!.bytes.sublist(330, 332), raw16(97));
    expect(c.revision, d.revision);
    expect(d.requests.where((m) => m.selector == 0x42).map((m) => m.data[0]), [
      3,
      2,
    ]);
    expect(d.requests.where((m) => m.selector == 0x41).length, 1);
    await c.disconnect();
    c.dispose();
  });
  test('恰好 64 字节的全局增量也可重新建立完整视图而不等待缺失 PATCH', () async {
    final c = ApexisController(), d = DemoTransport();
    await c.connect(d, port, demonstration: true);
    final globals = List<int>.from(c.globals)..[4] = 99;
    d.requests.clear();
    d.externalEdit(0, globals);
    await settle();
    await c.waitReady(atLeastRevision: d.revision);
    expect(c.error, isNull);
    expect(c.globals, globals);
    expect(d.requests.where((m) => m.selector == 0x42).map((m) => m.data[0]), [
      3,
      2,
    ]);
    await c.disconnect();
    c.dispose();
  });
  test('丢弃 action03 回执前旧快照，ACK state2 不能开放编辑', () async {
    final c = ApexisController(),
        d = RetryDemo()
          ..injectOldView = true
          ..rejectAckOnce = true;
    final published = <int>[];
    c.addListener(() {
      if (c.ready) published.add(c.selected);
    });
    await c.connect(d, port, demonstration: true);
    expect(c.ready, isTrue);
    expect(c.selected, 18);
    expect(published, everyElement(18));
    expect(c.error, isNull, reason: '同步成功后清除旧的 ACK 错误提示');
    expect(
      d.requests.where((m) => m.selector == 0x42 && m.data.first == 3).length,
      2,
    );
    await c.disconnect();
    c.dispose();
  });
  test('BUSY 保留原帧退避与最终重试意图', () async {
    final c = ApexisController(), d = RetryDemo();
    await c.connect(d, port, demonstration: true);
    d.busyWrites = 3;
    await c.patchField(351, [84]);
    expect(c.patch!.output, 65);
    expect(c.retryEdit, isNotNull);
    expect(d.rejectedFrames[0], d.rejectedFrames[1]);
    expect(d.rejectedFrames[1], d.rejectedFrames[2]);
    await c.retryEdit!();
    expect(c.patch!.output, 84);
    expect(c.retryEdit, isNull);
    await c.disconnect();
    c.dispose();
  });
  test('READY 收到孤立完整 PATCH 时重新同步，不 ACK 缺失 GLOB 的视图', () async {
    final c = ApexisController(), d = DemoTransport();
    await c.connect(d, port, demonstration: true);
    d.requests.clear();
    d.bank[4] = 88;
    d.bank[Gt1.patchOffset(c.selected, 351)] = 77;
    d.revision++;
    d.notifyRange(Gt1.patchOffset(c.selected), 374);
    await settle();
    await c.waitReady(atLeastRevision: d.revision);
    expect(c.error, isNull);
    expect(c.globals[4], 88);
    expect(c.patch!.output, 77);
    expect(d.requests.where((m) => m.selector == 0x42).map((m) => m.data[0]), [
      3,
      2,
    ]);
    await c.disconnect();
    c.dispose();
  });
  test('非 01A 首次连接：action03，完整视图，ACK state3 后可编辑', () async {
    final c = ApexisController(), device = AckGateDemo();
    device.bank[0] = 18;
    final connecting = c.connect(device, port, demonstration: true);
    await settle();
    expect(device.waiting, isTrue);
    expect(c.editable, isFalse);
    expect(c.patch, isNull);
    device.gate.complete();
    await connecting;
    expect(c.error, isNull);
    expect(c.ready, isTrue);
    expect(c.selected, 18);
    expect(c.patch!.name, 'Midnight Lead');
    expect(device.requests.where((m) => m.selector == 0x42).first.data, [3]);
    await c.disconnect();
    c.dispose();
  });
  for (final payload in [20, 197]) {
    test('载荷 $payload：字段写入、同值不增代次、设备通知不回写', () async {
      final c = ApexisController(), d = DemoTransport(payload: payload);
      await c.connect(d, port, demonstration: true);
      expect(c.error, isNull);
      await c.patchField(351, [80]);
      expect(c.error, isNull);
      expect(c.patch!.output, 80);
      expect(c.revision, 2);
      await c.patchField(351, [80]);
      expect(c.revision, 2);
      final writes = d.requests.where((m) => m.selector == 0x41).length;
      d.externalEdit(Gt1.patchOffset(c.selected, 351), [23]);
      await settle();
      expect(c.patch!.output, 23);
      expect(d.requests.where((m) => m.selector == 0x41).length, writes);
      await c.disconnect();
      c.dispose();
    });
  }
  test('完整 374 B 原子写跨分片，仅最后一片提交', () async {
    final c = ApexisController(), d = DemoTransport(payload: 20);
    await c.connect(d, port, demonstration: true);
    final raw = List<int>.from(c.patch!.bytes)..[351] = 81;
    await c.writeField(Gt1.patchOffset(0), raw);
    expect(c.error, isNull);
    expect(c.patch!.output, 81);
    expect(c.revision, 2);
    final writes = d.requests.where((m) => m.selector == 0x41).toList();
    expect(writes.length, greaterThan(1));
    expect(writes.map((m) => Gt1.integer(m.data, 5, 2)).toSet().length, 1);
    await c.disconnect();
    c.dispose();
  });
  test('STALE 保留设备新值，重同步不重放旧编辑', () async {
    final c = ApexisController(), d = DemoTransport();
    await c.connect(d, port, demonstration: true);
    d.bank[415] = 91;
    d.revision++;
    await c.patchField(351, [30]);
    expect(c.patch!.output, 91);
    expect(c.revision, 2);
    expect(c.error, contains('其他端'));
    expect(d.requests.where((m) => m.selector == 0x41).length, 1);
    await c.disconnect();
    c.dispose();
  });
  test('切换音色与 TYPE，重读参数并丢弃旧 UNIT 地址', () async {
    final c = ApexisController(), d = DemoTransport();
    await c.connect(d, port, demonstration: true);
    await c.action(0, 0, 0, [18]);
    expect(c.selected, 18);
    expect(c.patch!.name, 'Midnight Lead');
    await c.action(1, 0, 1, [0, ...Gt1.u14(0x400)]);
    expect(c.patch!.unit(0).count, 8);
    await c.selectUnit(0);
    expect(c.parameters.length, 8);
    await c.patchField(372, raw16(-50));
    expect(c.patch!.pan, -50);
    await c.disconnect();
    c.dispose();
  });
}
