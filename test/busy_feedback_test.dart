import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/data/controller.dart';
import 'package:apexis/transport/demo_transport.dart';
import 'package:apexis/transport/transport.dart';
import 'package:apexis/ui/app.dart';

const port = DevicePort('demo', 'GT1', '演示');

Future<ApexisController> connected() async {
  final c = ApexisController();
  await c.connect(DemoTransport(), port, demonstration: true);
  return c;
}

void main() {
  for (final syncing in [false, true]) {
    testWidgets('${syncing ? '同步' : '操作'}：500 ms 后才显示进度和禁用控件', (tester) async {
      final c = (await tester.runAsync(connected))!;
      await tester.pumpWidget(ApexisApp(controller: c));
      await tester.pumpAndSettle();
      var accessChanges = 0;
      c.view.channel(DeviceAspect.access).addListener(() => accessChanges++);
      final progress = find.descendant(
        of: find.byKey(const ValueKey('feedback-progress-slot')),
        matching: find.byType(LinearProgressIndicator),
      );
      IconButton presetButton() => tester.widget<IconButton>(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '选择预设'),
      );
      void start() {
        c.busy = !syncing;
        c.state = syncing ? LinkState.syncing : LinkState.ready;
        c.emit();
      }

      void finish() {
        c.busy = false;
        c.state = LinkState.ready;
        c.emit();
      }

      start();
      await tester.pump(const Duration(milliseconds: 499));
      expect(c.editable, isTrue);
      expect(presetButton().onPressed, isNotNull);
      expect(progress, findsNothing);
      expect(accessChanges, 0);
      finish();
      await tester.pump(const Duration(milliseconds: 20));
      expect(progress, findsNothing); // Cancelled timer cannot flash later.
      expect(accessChanges, 0);

      start();
      await tester.pump(const Duration(milliseconds: 300));
      c.notice = '无关的状态更新不重置计时';
      c.emit();
      await tester.pump(const Duration(milliseconds: 199));
      expect(progress, findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(c.editable, isFalse);
      expect(presetButton().onPressed, isNull);
      expect(progress, findsOneWidget);
      expect(accessChanges, 1);
      finish();
      await tester.pump();
      expect(progress, findsNothing);
      expect(c.editable, isTrue);
      expect(accessChanges, 2);

      start();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(c.disconnect);
      expect(c.editable, isFalse); // Disconnection is never delayed.
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.showBusyFeedback, isFalse);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  testWidgets('首次连接不能提前编辑，销毁会取消延迟反馈', (tester) async {
    final c = ApexisController();
    c.state = LinkState.connecting;
    c.busy = true;
    c.emit();
    expect(c.editable, isFalse);
    await tester.pump(const Duration(milliseconds: 499));
    expect(c.showBusyFeedback, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(c.showBusyFeedback, isTrue);
    await tester.runAsync(c.disconnect);
    c.state = LinkState.connecting;
    c.emit();
    c.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  test('宽限期的新写入按序执行，使用最新 revision，不静默丢失', () async {
    final c = await connected();
    final gate = Completer<void>();
    final first = c.run(() => gate.future);
    expect(c.busy, isTrue);
    expect(c.editable, isTrue);
    final second = c.writeField(4, [71]);
    final third = c.writeField(5, [72]);
    expect(c.globals[4], isNot(71));
    gate.complete();
    await Future.wait([first, second, third]);
    expect(c.error, isNull);
    expect(c.globals[4], 71);
    expect(c.globals[5], 72);
    expect(c.busy, isFalse);
    expect(c.showBusyFeedback, isFalse);
    await c.disconnect();
    c.dispose();
  });

  testWidgets('连续排队计时不中断，直到整个队列完成才收起反馈', (tester) async {
    final c = (await tester.runAsync(connected))!;
    final firstGate = Completer<void>(), secondGate = Completer<void>();
    final first = c.run(() => firstGate.future);
    final second = c.run(() => secondGate.future);
    await tester.pump(const Duration(milliseconds: 300));
    firstGate.complete();
    await tester.pump();
    expect(c.showBusyFeedback, isFalse);
    await tester.pump(const Duration(milliseconds: 200));
    expect(c.showBusyFeedback, isTrue);
    secondGate.complete();
    await tester.pump();
    await Future.wait([first, second]);
    expect(c.showBusyFeedback, isFalse);
    await tester.runAsync(c.disconnect);
    c.dispose();
  });

  test('重连不等待旧会话队列，旧操作结束不解锁新操作', () async {
    final c = await connected();
    final oldGate = Completer<void>();
    final old = c.run(() => oldGate.future);
    var oldQueuedExecuted = false;
    final oldQueued = c.run(() async => oldQueuedExecuted = true);
    await c.connect(DemoTransport(), port, demonstration: true);
    final newGate = Completer<void>();
    var newStarted = false;
    final current = c.run(() async {
      newStarted = true;
      await newGate.future;
    });
    expect(newStarted, isTrue);
    oldGate.complete();
    await Future.wait([old, oldQueued]);
    expect(oldQueuedExecuted, isFalse);
    expect(c.busy, isTrue);
    newGate.complete();
    await current;
    expect(c.busy, isFalse);
    await c.disconnect();
    c.dispose();
  });

  for (final change in ['断线', '音色', '参数定义', '效果结构', '同步边界']) {
    test('等待操作遇到$change变化时不执行旧编辑', () async {
      final c = await connected();
      final gate = Completer<void>();
      final first = c.run(() => gate.future);
      var executed = false;
      final next = c.run(() async => executed = true);
      switch (change) {
        case '断线':
          await c.disconnect();
        case '音色':
          c.globals[0]++;
          c.emit();
        case '参数定义':
          c.metadataGeneration++;
          c.emit();
        case '效果结构':
          c.patch!.bytes[0]++;
          c.emit();
        case '同步边界':
          await c.resync();
          await c.waitReady();
      }
      gate.complete();
      await Future.wait([first, next]);
      expect(executed, isFalse);
      if (change != '断线') expect(c.notice, contains('已取消'));
      await c.disconnect();
      c.dispose();
    });
  }

  test('同步宽限期接受的操作必须等待 ACK 后再执行', () async {
    final c = await connected();
    c.state = LinkState.syncing;
    c.emit();
    var executed = false;
    final action = c.run(() async => executed = true);
    await Future<void>.delayed(Duration.zero);
    expect(executed, isFalse);
    c.state = LinkState.ready;
    c.emit();
    await action;
    expect(executed, isTrue);
    await c.disconnect();
    c.dispose();
  });
}
