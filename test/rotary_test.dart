import 'dart:async';
import 'dart:ui' show PointerDeviceKind, SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/ui/theme.dart';
import 'package:apexis/ui/widgets.dart';

void main() {
  Widget host({
    FutureOr<void> Function(int)? commit,
    int min = 0,
    int max = 100,
    int value = 50,
    String Function(int)? format,
  }) => MaterialApp(
    theme: AppColors.theme,
    home: Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            RotaryControl(
              label: 'Gain',
              value: value,
              min: min,
              max: max,
              onCommit: commit,
              format: format,
            ),
            const SizedBox(height: 1500),
          ],
        ),
      ),
    ),
  );
  final dial = find.byKey(const ValueKey('dial-Gain'));
  final increase = find.byWidgetPredicate(
    (w) => w is IconButton && w.tooltip == '增大 Gain',
  );

  testWidgets('滑条异步提交也保留待确认值并使用实际回读', (tester) async {
    final ack = Completer<void>();
    Widget slider({int value = 50, bool active = true}) => MaterialApp(
      theme: AppColors.theme,
      home: Scaffold(
        body: ValueControl(
          label: 'Level',
          value: value,
          min: 0,
          max: 100,
          onCommit: active ? (_) => ack.future : null,
        ),
      ),
    );
    await tester.pumpWidget(slider());
    await tester.tap(find.byTooltip('增大 Level'));
    await tester.pump();
    expect(find.text('51'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('51 …'), findsOneWidget);
    await tester.pumpWidget(slider(active: false));
    expect(find.text('51 …'), findsOneWidget);
    ack.complete();
    await tester.pumpWidget(slider(value: 52));
    await tester.pump();
    expect(find.text('52'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('异步提交保留待确认值，收到规范化实际值后再显示', (tester) async {
    final ack = Completer<void>();
    await tester.pumpWidget(host(commit: (_) => ack.future));
    await tester.tap(increase);
    await tester.pump();
    expect(find.text('51'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('51 …'), findsOneWidget);
    expect(tester.widget<IconButton>(increase).onPressed, isNull);
    // Controller busy disables callbacks; this must not flash the old value.
    await tester.pumpWidget(host());
    expect(find.text('51 …'), findsOneWidget);
    await tester.pumpWidget(host(value: 49));
    ack.complete();
    await tester.pump();
    expect(find.text('49'), findsOneWidget);
    expect(find.text('51 …'), findsNothing);
  });

  testWidgets('设备拒绝调整时回到实际值，卸载后完成不 setState', (tester) async {
    final ack = Completer<void>();
    await tester.pumpWidget(host(commit: (_) => ack.future));
    await tester.tap(increase);
    await tester.pump();
    ack.complete(); // Controller reports the error without changing the mirror.
    await tester.pump();
    expect(find.text('50'), findsOneWidget);
    final lateAck = Completer<void>();
    await tester.pumpWidget(host(commit: (_) => lateAck.future));
    await tester.tap(increase);
    await tester.pumpWidget(const SizedBox());
    lateAck.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('旋钮上下拖动只在松手提交，取消及横拖不提交，空白处可滚动', (tester) async {
    final commits = <int>[];
    await tester.pumpWidget(host(commit: commits.add));
    var gesture = await tester.startGesture(tester.getCenter(dial));
    await gesture.moveBy(const Offset(0, -25));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(commits, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(commits, hasLength(1));
    expect(commits.single, greaterThan(50));
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(scroll.pixels, 0);
    commits.clear();
    gesture = await tester.startGesture(tester.getCenter(dial));
    await gesture.moveBy(const Offset(0, 25));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(commits, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(commits, hasLength(1));
    expect(commits.single, lessThan(50));
    expect(scroll.pixels, 0);
    commits.clear();
    gesture = await tester.startGesture(tester.getCenter(dial));
    await gesture.moveBy(const Offset(0, -40));
    await gesture.cancel();
    await tester.pump();
    expect(commits, isEmpty);
    await tester.drag(dial, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(commits, isEmpty);
    expect(scroll.pixels, 0);
    await tester.dragFrom(const Offset(20, 400), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(commits, isEmpty);
    expect(scroll.pixels, greaterThan(0));
  });

  testWidgets('鼠标上下拖动遵守范围且横向分量不改变数值', (tester) async {
    final commits = <int>[];
    await tester.pumpWidget(
      host(commit: commits.add, min: -50, max: 50, value: 0),
    );
    for (final dy in [-1000.0, 1000.0]) {
      final gesture = await tester.startGesture(
        tester.getCenter(dial),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(Offset(0, dy.sign * 25));
      await gesture.moveBy(Offset(0, dy));
      await tester.pump();
      final beforeHorizontal = tester
          .widget<Text>(find.text(dy < 0 ? '50' : '-50'))
          .data;
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();
      expect(find.text(beforeHorizontal!), findsOneWidget);
      await gesture.up();
      await tester.pump();
    }
    expect(commits, [50, -50]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旋钮禁用、零范围与拖动期间断开均不提交', (tester) async {
    final commits = <int>[];
    await tester.pumpWidget(host());
    await tester.drag(dial, const Offset(0, -100));
    expect(tester.widget<IconButton>(increase).onPressed, isNull);
    await tester.pumpWidget(host(commit: commits.add, min: 50, max: 50));
    await tester.drag(dial, const Offset(0, -100));
    expect(commits, isEmpty);
    await tester.pumpWidget(host(commit: commits.add));
    final gesture = await tester.startGesture(tester.getCenter(dial));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pumpWidget(host());
    await gesture.up();
    await tester.pumpAndSettle();
    expect(commits, isEmpty);
  });

  testWidgets('旋钮键盘、边界与语义替代操作', (tester) async {
    final commits = <int>[];
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(host(commit: commits.add));
    final focus = Focus.of(tester.element(dial));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    expect(commits, [51, 0, 100]);
    final node = tester.getSemantics(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == 'Gain',
      ),
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
    expect(node.getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);
    await tester.pumpWidget(host(commit: commits.add, value: 100));
    expect(tester.widget<IconButton>(increase).onPressed, isNull);
    semantics.dispose();
  });

  testWidgets('精确输入校验范围，取消不写入；格式化读数正确', (tester) async {
    final commits = <int>[];
    await tester.pumpWidget(
      host(
        commit: commits.add,
        min: 0,
        max: 30,
        value: 15,
        format: (v) => '${v - 15} dB',
      ),
    );
    expect(find.text('0 dB'), findsOneWidget);
    await tester.tap(find.byTooltip('输入 Gain'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '31');
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(find.text('请输入 0～30 的整数'), findsOneWidget);
    expect(commits, isEmpty);
    await tester.enterText(find.byType(TextField), '20');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(commits, [20]);
    await tester.tap(find.byTooltip('输入 Gain'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(commits, [20]);
  });
}
