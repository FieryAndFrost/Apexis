import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/data/controller.dart';
import 'package:apexis/transport/demo_transport.dart';
import 'package:apexis/transport/transport.dart';
import 'package:apexis/ui/app.dart';
import 'package:apexis/ui/pages.dart';
import 'package:apexis/ui/widgets.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader('Microsoft YaHei')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
    }
  });
  for (final size in [
    const Size(1280, 860),
    const Size(375, 812),
    const Size(812, 375),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('提示及进度不改变正文位置或滚动 $size / $scale', (tester) async {
        await tester.binding.setSurfaceSize(size);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
        });
        final c = ApexisController();
        await tester.runAsync(
          () => c.connect(
            DemoTransport(),
            const DevicePort('demo', 'GT1', '演示'),
            demonstration: true,
          ),
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('feedback-preview'),
            child: ApexisApp(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        final viewport = find.byKey(const ValueKey('workspace-viewport'));
        final pages = find.byType(RetainedPageViewport);
        final scrollables = find.descendant(
          of: pages,
          matching: find.byType(Scrollable),
        );
        final scroll = tester
            .stateList<ScrollableState>(scrollables)
            .firstWhere(
              (s) =>
                  s.position.axis == Axis.vertical &&
                  s.position.maxScrollExtent > 0,
            );
        scroll.position.jumpTo(scroll.position.maxScrollExtent * 0.6);
        await tester.pump();
        final frame = tester.getRect(viewport);
        final pageFrame = tester.getRect(pages);
        final scrollFrame = tester.getRect(find.byWidget(scroll.widget));
        final offset = scroll.position.pixels;
        final extent = scroll.position.maxScrollExtent;
        final pageState = tester.state(pages);

        void stable() {
          expect(tester.getRect(viewport), frame);
          expect(tester.getRect(pages), pageFrame);
          expect(tester.getRect(find.byWidget(scroll.widget)), scrollFrame);
          expect(tester.state(pages), same(pageState));
          expect(scroll.position.pixels, offset);
          expect(scroll.position.maxScrollExtent, extent);
          expect(tester.takeException(), isNull);
        }

        for (var i = 0; i < 5; i++) {
          c.busy = true;
          c.progress = i / 5;
          c.error = '同步提示 $i：${List.filled(i + 1, '设备参数已更新，等待同步确认。').join()}';
          c.notice = '操作完成';
          c.emit();
          await tester.pump();
          stable();
          expect(
            find.byKey(const ValueKey('feedback-message')),
            findsOneWidget,
          );
          expect(
            tester
                .getSize(find.byKey(const ValueKey('feedback-progress-slot')))
                .height,
            2,
          );
          c.busy = false;
          c.progress = null;
          c.error = null;
          c.notice = '';
          c.emit();
          await tester.pump();
          stable();
          expect(find.byKey(const ValueKey('feedback-message')), findsNothing);
        }
        c.state = LinkState.syncing;
        c.emit();
        await tester.pump();
        stable();
        c.state = LinkState.ready;
        c.emit();
        await tester.pump();
        stable();

        // The notice is bounded, can be dismissed, and does not consume taps
        // outside its card (navigation remains accessible on phone/desktop).
        if (Platform.isWindows && scale == 1) {
          c.error = '设备参数已更新，正在重新同步。';
          c.busy = true;
          c.progress = 0.5;
          c.emit();
          await tester.pump(ApexisController.busyFeedbackDelay);
          await expectLater(
            find.byKey(const ValueKey('feedback-preview')),
            matchesGoldenFile(
              '../design/previews/feedback-${size.width.toInt()}.png',
            ),
          );
          c.busy = false;
          c.progress = null;
        }
        c.error = List.filled(60, '很长的错误详情').join();
        var retries = 0;
        c.retryEdit = () async {
          retries++;
        };
        c.emit();
        await tester.pump();
        stable();
        final card = tester.getRect(
          find.byKey(const ValueKey('feedback-message')),
        );
        expect(frame.contains(card.topLeft), isTrue);
        expect(frame.contains(card.bottomRight), isTrue);
        await tester.tap(find.text('重试'));
        await tester.pump();
        expect(retries, 1);
        stable();
        c.retryEdit = null;
        await tester.tap(find.byTooltip('关闭提示'));
        await tester.pump();
        expect(c.error, isNull);
        stable();
        c.notice = '操作完成';
        c.emit();
        await tester.pump();
        await tester.runAsync(() async {
          await tester.tap(find.byIcon(Icons.settings_outlined));
          for (var i = 0; i < 100 && c.busy; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pumpAndSettle();
        expect(find.byType(SettingsPage), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(c.disconnect);
        c.dispose();
      });
    }
  }
}
