import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/data/controller.dart';
import 'package:apexis/transport/demo_transport.dart';
import 'package:apexis/transport/transport.dart';
import 'package:apexis/ui/app.dart';
import 'package:apexis/ui/device_region.dart';
import 'package:apexis/ui/widgets.dart';

void main() {
  testWidgets('空值投影不会退回到整分区订阅', (tester) async {
    final c = ApexisController();
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceRegion(
          store: c.view,
          aspects: const [DeviceAspect.feedback],
          select: (s) => s.feedback.progress,
          builder: (_) {
            builds++;
            return const SizedBox();
          },
        ),
      ),
    );
    c.error = 'unrelated';
    c.emit();
    await tester.pump();
    expect(builds, 1);
    c.progress = 0.5;
    c.emit();
    await tester.pump();
    expect(builds, 2);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('参数、导航和高频状态不带动外壳，缓存页暂停订阅并恢复最新值', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    final c = ApexisController();
    await tester.runAsync(
      () => c.connect(
        DemoTransport(),
        const DevicePort('demo', 'GT1', '演示'),
        demonstration: true,
      ),
    );
    final builds = <String, int>{};
    DeviceRegion.onBuild = (label) =>
        builds.update(label, (v) => v + 1, ifAbsent: () => 1);
    addTearDown(() => DeviceRegion.onBuild = null);
    await tester.pumpWidget(ApexisApp(controller: c));
    await tester.pumpAndSettle();
    builds.clear();
    c.patch!.bytes[350]++;
    c.emit();
    await tester.pump();
    expect(builds, {'patch-350': 1});
    builds.clear();
    final parameterOffset = c.selectedUnit * 32 + 6;
    c.patch!.bytes[parameterOffset]++;
    c.emit();
    await tester.pump();
    expect(builds, {'parameter-${c.selectedUnit}-0': 1});
    builds.clear();
    await tester.tap(find.text('全局'));
    await tester.pumpAndSettle();
    expect(builds.containsKey('shell'), isFalse);
    expect(builds.containsKey('header'), isFalse);
    builds.clear();
    c.patch!.bytes[350] = 22;
    c.globals[4] = 80;
    c.emit();
    await tester.pump();
    expect(builds, {'global-4': 1});
    await tester.tap(find.text('效果'));
    await tester.pumpAndSettle();
    final input = tester.widget<RotaryControl>(
      find.byWidgetPredicate(
        (w) => w is RotaryControl && w.label == 'INPUT · 输入增益',
      ),
    );
    expect(input.value, 22);
    await tester.tap(find.text('工具'));
    await tester.pumpAndSettle();
    c.setActivePage(null); // Deterministic synthetic updates, no timer races.
    c.tunerActive = true;
    c.tunerNote = 3;
    c.emit();
    await tester.pumpAndSettle();
    builds.clear();
    for (var i = 0; i < 10; i++) {
      c.tunerPointer = 100 + i;
      c.emit();
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(builds.keys, everyElement(isIn(['tuner-note', 'tuner-pointer'])));
    expect(builds['tuner-pointer'], 10);
    builds.clear();
    c.emit();
    await tester.pump();
    expect(builds, isEmpty);
    c.tunerActive = false;
    c.emit();
    await tester.tap(find.text('参数'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LOOP'));
    c.setActivePage(null);
    await tester.pumpAndSettle();
    builds.clear();
    for (var i = 0; i < 10; i++) {
      c.loopPosition = 100000 + i * 100000;
      c.emit();
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(builds, {'loop-progress': 10});
    await tester.runAsync(c.disconnect);
    await tester.pumpAndSettle();
    expect(
      find.byType(RetainedPageViewport, skipOffstage: false),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
