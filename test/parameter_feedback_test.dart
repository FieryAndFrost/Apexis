import 'dart:async';
import 'package:apexis/ui/theme.dart';
import 'package:apexis/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final rotary in [true, false]) {
    final name = rotary ? '旋钮' : '滑条';
    Widget host({Future<void> Function(int)? commit, int value = 50}) =>
        MaterialApp(
          theme: AppColors.theme,
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: rotary
                  ? RotaryControl(
                      label: 'Level',
                      value: value,
                      min: 0,
                      max: 100,
                      onCommit: commit,
                    )
                  : ValueControl(
                      label: 'Level',
                      value: value,
                      min: 0,
                      max: 100,
                      onCommit: commit,
                    ),
            ),
          ),
        );
    final plus = find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == '增大 Level',
    );
    final minus = find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == '减小 Level',
    );

    void expectAppearance(WidgetTester tester, {required bool active}) {
      for (final button in [plus, minus]) {
        final icon = find.descendant(of: button, matching: find.byType(Icon));
        expect(
          IconTheme.of(tester.element(icon)).color,
          active ? AppColors.text : AppColors.disabled,
        );
      }
      if (rotary) {
        final paint = tester.widget<CustomPaint>(
          find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is DialPainter,
          ),
        );
        expect((paint.painter! as DialPainter).enabled, active);
        expect(
          tester.widget<Text>(find.text('Level')).style!.color,
          active ? AppColors.text : AppColors.disabled,
        );
      } else {
        final slider = find.byType(Slider);
        final theme = SliderTheme.of(tester.element(slider));
        expect(
          theme.disabledActiveTrackColor,
          active ? theme.activeTrackColor : AppColors.disabled,
        );
        expect(
          theme.disabledInactiveTrackColor,
          active ? theme.inactiveTrackColor : AppColors.border,
        );
        expect(
          theme.disabledThumbColor,
          active ? theme.thumbColor : AppColors.disabled,
        );
      }
    }

    testWidgets('$name：300 ms 快速提交不闪烁、不重复写入', (tester) async {
      final ack = Completer<void>();
      final commits = <int>[];
      Future<void> commit(int value) {
        commits.add(value);
        return ack.future;
      }

      await tester.pumpWidget(host(commit: commit));
      await tester.tap(plus);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('51'), findsOneWidget);
      expect(find.text('51 …'), findsNothing);
      expectAppearance(tester, active: true);
      expect(tester.widget<IconButton>(plus).onPressed, isNull);
      await tester.tap(plus);
      await tester.pump(const Duration(milliseconds: 200));
      expect(commits, [51]);
      expectAppearance(tester, active: true);
      await tester.pumpWidget(host(commit: commit, value: 51));
      ack.complete();
      await tester.pump();
      expect(find.text('51'), findsOneWidget);
      expect(tester.widget<IconButton>(plus).onPressed, isNotNull);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('51 …'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$name：499 ms 外观不变，500 ms 显示等待，回读后恢复', (tester) async {
      final ack = Completer<void>();
      Future<void> commit(int _) => ack.future;
      await tester.pumpWidget(host(commit: commit));
      await tester.tap(plus);
      await tester.pump(const Duration(milliseconds: 499));
      expectAppearance(tester, active: true);
      expect(find.text('51'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('51 …'), findsOneWidget);
      // Material button disabled styles may finish their color tween later.
      await tester.pump(const Duration(milliseconds: 200));
      expectAppearance(tester, active: false);
      await tester.pumpWidget(host(commit: commit, value: 52));
      ack.complete();
      await tester.pumpAndSettle();
      expect(find.text('52'), findsOneWidget);
      expect(find.text('51 …'), findsNothing);
      expect(tester.widget<IconButton>(plus).onPressed, isNotNull);
    });

    testWidgets('$name：快速失败回到确认值，断开不等待 500 ms', (tester) async {
      var ack = Completer<void>();
      Future<void> commit(int _) => ack.future;
      await tester.pumpWidget(host(commit: commit));
      await tester.tap(plus);
      await tester.pump(const Duration(milliseconds: 100));
      // The controller reports a rejected write without updating its value.
      ack.complete();
      await tester.pump();
      expect(find.text('50'), findsOneWidget);
      ack = Completer<void>();
      await tester.tap(plus);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(host());
      await tester.pump(const Duration(milliseconds: 200));
      expectAppearance(tester, active: false);
      expect(tester.widget<IconButton>(plus).onPressed, isNull);
      ack.complete();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('50'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$name：销毁取消延迟反馈，迟到回复不更新已销毁控件', (tester) async {
      final ack = Completer<void>();
      await tester.pumpWidget(host(commit: (_) => ack.future));
      await tester.tap(plus);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      ack.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
