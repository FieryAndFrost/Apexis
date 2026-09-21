import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/data/controller.dart';
import 'package:apexis/data/parameters.dart';
import 'package:apexis/protocol/codec.dart';
import 'support/firmware_demo.dart';
import 'controller_test.dart' show port, settle;

class MetadataDevice extends FirmwareDemo {
  MetadataDevice({int version = 124}) : super(version);
  bool unsupported = false, dynamicSchema = false;
  String dependencyName = 'Sync';
  Completer<void>? labelGate;
  bool labelWaiting = false;
  final queries = <Message>[];

  @override
  Future<void> send(frame) async {
    final m = Message.parse(frame, response: false);
    if (m.component == 2 && m.command == 1) {
      queries.add(m);
      final p = m.data.length == 4 ? m.data[3] : -1;
      if (m.selector == 0x21 && labelGate != null) {
        labelWaiting = true;
        await labelGate!.future;
      }
      if (m.selector == 0x21 && unsupported) {
        emitFrame(Gt1.frame(2, 1, 0x21, [], 6));
        return;
      }
      if (dynamicSchema) {
        final mode = bank[Gt1.patchOffset(bank[0], m.data[0] * 32 + 6)];
        List<int>? reply;
        if (m.selector == 0x20) reply = [...m.data, mode == 1 ? 2 : 4];
        if (m.selector == 0x22 && p == 0) {
          reply = [...m.data, ...ascii.encode(dependencyName)];
        }
        if (m.selector == 0x23 && p == 1) {
          reply = [
            ...m.data,
            0,
            ...Gt1.s14(0),
            ...Gt1.s14(mode == 1 ? 12 : 100),
          ];
        }
        if (reply != null) {
          emitFrame(Gt1.frame(2, 1, m.selector, reply, 0));
          return;
        }
      }
    }
    await super.send(frame);
  }
}

Future<ApexisController> connect(MetadataDevice d) async {
  final c = ApexisController();
  await c.connect(d, port);
  c.setActivePage(0);
  expect(c.error, isNull);
  addTearDown(() async {
    await c.disconnect();
    c.dispose();
  });
  d.queries.clear();
  d.requests.clear();
  return c;
}

void main() {
  test('8 参数普通编辑由 25 条描述查询降为 1 条，控件代次不变', () async {
    final d = MetadataDevice();
    final c = await connect(d);
    await c.selectUnit(3);
    expect(d.queries.length, 25);
    d.queries.clear();
    final generation = c.metadataGeneration;
    await c.patchField(3 * 32 + 6, raw16(63));
    await c.refreshParameters();
    expect(c.error, isNull);
    expect(c.patch!.unit(3).parameter(0), 63);
    expect(c.parameters.first.label, '63');
    expect(c.metadataGeneration, generation);
    expect(d.queries.map((m) => m.selector), [0x21]);
    expect(d.requests.where((m) => m.selector == 0x41).length, 1);
    expect(d.requests.where((m) => m.selector == 0x42).length, 1);
  });

  test('音量、旁路、其他 UNIT 及同值写入不重查当前参数', () async {
    final d = MetadataDevice();
    final c = await connect(d);
    for (final edit in [
      (351, [74]),
      (2, [0]),
      (38, raw16(72)),
      (6, raw16(50)),
    ]) {
      await c.patchField(edit.$1, edit.$2);
      await c.refreshParameters();
    }
    expect(c.error, isNull);
    expect(d.queries, isEmpty);
    expect(c.parameters, hasLength(4));
  });

  test('设备不支持显示文字时缓存 error6，普通变化不再查询', () async {
    final d = MetadataDevice()..unsupported = true;
    final c = await connect(d);
    await c.patchField(6, raw16(64));
    await c.refreshParameters();
    expect(d.queries, isEmpty);
    expect(c.parameters.first.label, '64');
  });

  test('标签慢回复不锁定编辑，也不冒充设备数值', () async {
    final d = MetadataDevice();
    final c = await connect(d);
    d.labelGate = Completer<void>();
    await c.patchField(6, raw16(65));
    await settle();
    expect(d.labelWaiting, isTrue);
    expect(c.editable, isTrue);
    expect(c.parameters.first.label, '65');
    expect(c.revision, d.revision);
    d.labelGate!.complete();
    await c.refreshParameters();
    expect(c.error, isNull);
  });

  test('Sync 改变后重读可见数和范围，旧范围立即失效', () async {
    final d = MetadataDevice()..dynamicSchema = true;
    final c = await connect(d);
    expect(c.parameters[1].max, 100);
    await c.patchField(6, raw16(1));
    await c.refreshParameters();
    expect(c.parameters, hasLength(2));
    expect(c.parameters[1].max, 12);
    expect(d.queries.map((m) => m.selector), containsAll([0x20, 0x22, 0x23]));
  });

  test('外部参数变化同样只更新标签，不回写设备', () async {
    final d = MetadataDevice();
    final c = await connect(d);
    d.externalEdit(Gt1.patchOffset(c.selected, 6), raw16(77));
    await settle();
    await c.refreshParameters();
    expect(c.parameters.first.label, '77');
    expect(d.queries.map((m) => m.selector), [0x21]);
    expect(d.requests.where((m) => m.selector == 0x41), isEmpty);
  });

  test('标签读取期间的外部新值不会被旧结果覆盖', () async {
    final d = MetadataDevice();
    final c = await connect(d);
    d.labelGate = Completer<void>();
    await c.patchField(6, raw16(60));
    await settle();
    d.externalEdit(Gt1.patchOffset(c.selected, 6), raw16(81));
    d.labelGate!.complete();
    await settle();
    await c.refreshParameters();
    expect(c.patch!.unit(0).parameter(0), 81);
    expect(c.parameters.first.label, '81');
    expect(c.error, isNull);
  });

  test('未知固件版本保守重读，模型变化和重同步使缓存失效', () async {
    final d = MetadataDevice(version: 125);
    final c = await connect(d);
    await c.patchField(6, raw16(66));
    await c.refreshParameters();
    expect(d.queries, hasLength(13));
    d.queries.clear();
    await c.patchField(30, raw16(2));
    await c.refreshParameters();
    expect(d.queries, hasLength(13));
    d.queries.clear();
    await c.resync();
    await c.waitReady();
    await c.refreshParameters();
    expect(d.queries, hasLength(13));
  });

  test('Mode 外部变化更新可见数和范围', () async {
    final d = MetadataDevice()
      ..dynamicSchema = true
      ..dependencyName = 'Mode';
    final c = await connect(d);
    d.externalEdit(Gt1.patchOffset(c.selected, 6), raw16(1));
    await settle();
    await c.refreshParameters();
    expect(c.parameters, hasLength(2));
    expect(c.parameters[1].max, 12);
    expect(d.queries.map((m) => m.selector), contains(0x20));
  });

  test('读取中切换 UNIT 丢弃旧结果，隐藏页面不再轮询描述', () async {
    final d = MetadataDevice();
    final c = await connect(d);
    d.labelGate = Completer<void>();
    await c.patchField(6, raw16(61));
    await settle();
    final selecting = c.selectUnit(3);
    d.labelGate!.complete();
    await selecting;
    expect(c.selectedUnit, 3);
    expect(c.parameters, hasLength(8));
    expect(c.parameters.first.label, '50');
    c.setActivePage(1);
    d.queries.clear();
    await c.patchField(3 * 32 + 6, raw16(78));
    await c.refreshParameters();
    expect(d.queries, isEmpty);
    c.setActivePage(0);
    await c.refreshParameters();
    expect(c.parameters.first.label, '78');
    expect(d.queries.map((m) => m.selector), [0x21]);
  });

  test('重新连接不会复用上一台设备的 error6 或参数描述', () async {
    final c = await connect(MetadataDevice()..unsupported = true);
    final next = MetadataDevice();
    await c.connect(next, port);
    expect(next.queries.where((m) => m.selector == 0x21), hasLength(4));
    next.queries.clear();
    await c.patchField(6, raw16(67));
    await c.refreshParameters();
    expect(next.queries.map((m) => m.selector), [0x21]);
    expect(c.parameters.first.label, '67');
  });
}
