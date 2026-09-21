import 'package:apexis/data/controller.dart';
import 'package:apexis/transport/demo_transport.dart';
import 'package:apexis/transport/transport.dart';
import 'package:apexis/ui/app.dart';
import 'package:apexis/ui/widgets.dart';
import 'package:apexis/ui/device_region.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('Windows demo navigation frame timings', (tester) async {
    final c = ApexisController();
    await c.connect(
      DemoTransport(),
      const DevicePort('demo', 'GT1', '演示'),
      demonstration: true,
    );
    await tester.pumpWidget(ApexisApp(controller: c));
    await tester.pumpAndSettle();

    Future<void> cycle() async {
      for (final label in ['全局', '均衡', '效果', '社区', '设置', '参数']) {
        await tester.tap(find.text(label).hitTestable().first);
        // Real vsync-driven frames, not manually pumped 100 ms animation steps.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      }
    }

    await cycle(); // Warm font and shader caches before the measured sequence.
    await binding.watchPerformance(() async {
      for (var i = 0; i < 5; i++) {
        await cycle();
      }
    }, reportKey: 'navigation');
    binding.reportData!['context'] = {
      'mode': const bool.fromEnvironment('dart.vm.product')
          ? 'release'
          : const bool.fromEnvironment('dart.vm.profile')
          ? 'profile'
          : 'debug',
      'logicalWidth':
          tester.view.physicalSize.width / tester.view.devicePixelRatio,
      'logicalHeight':
          tester.view.physicalSize.height / tester.view.devicePixelRatio,
      'devicePixelRatio': tester.view.devicePixelRatio,
      'displayRefreshRate': tester.view.display.refreshRate,
      'switches': 30,
      'demoOnly': true,
      'pageMotionEnabled': tester
          .widget<DirectionalPageTransition>(
            find.byType(DirectionalPageTransition),
          )
          .enabled,
    };
    // Synthetic demo measurements exercise the real render path, not hardware
    // pitch detection. No device commands or parameter writes are issued here.
    await tester.tap(find.text('工具').hitTestable().first);
    c.setActivePage(null);
    c.tunerActive = true;
    c.tunerNote = 3;
    c.emit();
    await tester.pumpAndSettle();
    final builds = <String, int>{};
    DeviceRegion.onBuild = (label) =>
        builds.update(label, (n) => n + 1, ifAbsent: () => 1);
    try {
      await binding.watchPerformance(() async {
        for (var i = 0; i < 50; i++) {
          c.tunerPointer = 90 + i % 40;
          c.emit();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }, reportKey: 'tuner_updates');
      binding.reportData!['tuner_region_builds'] = Map.of(builds);
      expect(builds.keys, everyElement(isIn(['tuner-note', 'tuner-pointer'])));
      expect(builds['tuner-pointer'], 50);
      expect(tester.takeException(), isNull);
    } finally {
      DeviceRegion.onBuild = null;
    }
    await tester.pumpWidget(const SizedBox());
    await c.disconnect();
    c.dispose();
  });
}
