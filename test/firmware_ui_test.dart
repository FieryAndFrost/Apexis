import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/data/controller.dart';
import 'package:apexis/transport/transport.dart';
import 'package:apexis/ui/app.dart';
import 'package:apexis/ui/pages.dart';
import 'package:apexis/ui/theme.dart';
import 'support/firmware_demo.dart';

void main() {
  testWidgets('新版厂商另存直接进入 U 区，未持久化提示可见', (tester) async {
    final c = ApexisController();
    await tester.runAsync(
      () => c.connect(FirmwareDemo(124), const DevicePort('demo', 'GT1', '演示')),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppColors.theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPresets(context, c, copy: true),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('打开'));
      for (var i = 0; i < 100 && c.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('U01A'), findsOneWidget);
    expect(find.text('F01A'), findsNothing);
    expect(find.text('未持久化 · 等待软关机'), findsWidgets);
    final previous = tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '上一页'));
    expect(previous.onPressed, isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(c.disconnect);
    c.dispose();
  });
  testWidgets('新版 F/U 页在手机横竖屏和大字模式不溢出', (tester) async {
    final c = ApexisController();
    await tester.runAsync(
      () => c.connect(FirmwareDemo(124), const DevicePort('demo', 'GT1', '演示')),
    );
    for (final size in [
      const Size(375, 812),
      const Size(812, 375),
      const Size(1440, 900),
    ]) {
      await tester.binding.setSurfaceSize(size);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pumpWidget(ApexisApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.text('F01A'), findsOneWidget);
      expect(find.byTooltip('另存用户音色'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$size');
    }
    tester.platformDispatcher.clearAllTestValues();
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
    await tester.runAsync(c.disconnect);
    c.dispose();
  });
  testWidgets('鼓机错误就地可见、播放禁用、刷新仍可用', (tester) async {
    final c = ApexisController();
    await tester.runAsync(
      () => c.connect(
        FirmwareDemo(117)..rejectDrum = true,
        const DevicePort('demo', 'GT1', '演示'),
      ),
    );
    await tester.runAsync(c.loadPatterns);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppColors.theme,
        home: Scaffold(
          body: SingleChildScrollView(child: DrumPage(c: c)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('设备鼓机尚不可用'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '播放鼓机'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '刷新设备鼓型目录'))
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(c.disconnect);
    c.dispose();
  });
}
