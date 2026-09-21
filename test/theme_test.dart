import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/ui/theme.dart';
import 'package:apexis/ui/widgets.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
}

void main() {
  test('主要、次要与状态文本在所有工作台表面满足 4.5:1', () {
    for (final background in [
      AppColors.background,
      AppColors.inset,
      AppColors.surface,
      AppColors.card,
      AppColors.selected,
    ]) {
      for (final foreground in [
        AppColors.text,
        AppColors.muted,
        AppColors.accent,
        AppColors.green,
        AppColors.red,
        AppColors.amber,
      ]) {
        expect(
          contrast(foreground, background),
          greaterThanOrEqualTo(4.5),
          reason: '$foreground on $background',
        );
      }
    }
    expect(
      contrast(AppColors.onAccent, AppColors.accent),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('交互边界与完整滑杆轨道清晰可见，关闭开关不是透明色', () {
    for (final background in [
      AppColors.inset,
      AppColors.surface,
      AppColors.card,
    ]) {
      expect(
        contrast(AppColors.controlBorder, background),
        greaterThanOrEqualTo(3),
      );
      expect(contrast(AppColors.track, background), greaterThanOrEqualTo(3));
    }
    final theme = AppColors.theme;
    expect(theme.sliderTheme.inactiveTrackColor, AppColors.track);
    expect(theme.switchTheme.trackColor!.resolve({}), AppColors.inset);
    expect(
      theme.switchTheme.trackOutlineColor!.resolve({}),
      AppColors.controlBorder,
    );
    expect(
      theme.switchTheme.trackColor!.resolve({WidgetState.selected}),
      AppColors.accent,
    );
    expect(
      theme.switchTheme.trackColor!.resolve({WidgetState.disabled}),
      AppColors.card,
    );
    expect(
      theme.filledButtonTheme.style!.foregroundColor!.resolve({}),
      AppColors.onAccent,
    );
  });

  testWidgets('参数拖动只在松手提交，禁用控件保持禁用', (tester) async {
    final commits = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppColors.theme,
        home: Scaffold(
          body: ValueControl(
            label: 'Gain',
            value: 50,
            min: 0,
            max: 100,
            onCommit: commits.add,
          ),
        ),
      ),
    );
    final slider = find.byType(Slider);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(commits, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(commits, hasLength(1));
    await tester.tap(find.byTooltip('增大 Gain'));
    expect(commits, hasLength(2));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppColors.theme,
        home: const Scaffold(
          body: ValueControl(
            label: 'Gain',
            value: 50,
            min: 0,
            max: 100,
            onCommit: null,
          ),
        ),
      ),
    );
    expect(tester.widget<Slider>(slider).onChanged, isNull);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '增大 Gain',
            ),
          )
          .onPressed,
      isNull,
    );
  });
}
