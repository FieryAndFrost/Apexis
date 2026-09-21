import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/data/controller.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/transport/demo_transport.dart';
import 'package:apexis/transport/transport.dart';
import 'package:apexis/ui/app.dart';
import 'package:apexis/ui/pages.dart';
import 'package:apexis/ui/theme.dart';
import 'package:apexis/ui/widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  testWidgets('首次显示连接入口，演示设备可进入编辑页', (tester) async {
    final c = ApexisController();
    await tester.pumpWidget(ApexisApp(controller: c));
    expect(find.text('连接你的效果器'), findsOneWidget);
    expect(find.text('进入演示模式'), findsOneWidget);
    await tester.runAsync(
      () => c.connect(
        DemoTransport(),
        const DevicePort('demo', 'GT1', '演示'),
        demonstration: true,
      ),
    );
    expect(c.error, isNull, reason: c.logs.join('\n'));
    await tester.pumpAndSettle();
    expect(find.text('Classic Clean'), findsOneWidget);
    expect(find.text('效果链'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(c.disconnect);
    c.dispose();
  });
  testWidgets('所有页面在手机、横屏和桌面以及大字体下无溢出', (tester) async {
    final c = ApexisController();
    await tester.runAsync(
      () => c.connect(
        DemoTransport(),
        const DevicePort('demo', 'GT1', '演示'),
        demonstration: true,
      ),
    );
    expect(c.error, isNull, reason: c.logs.join('\n'));
    final pages = [
      EffectsPage(c: c),
      GlobalPage(c: c),
      EqualizerPage(c: c),
      LooperPage(c: c),
      DrumPage(c: c),
      TunerPage(c: c),
      ResourcesPage(c: c),
      SettingsPage(c: c),
    ];
    for (final size in [
      const Size(375, 812),
      const Size(320, 640),
      const Size(768, 1024),
      const Size(812, 375),
      const Size(1440, 900),
    ]) {
      await tester.binding.setSurfaceSize(size);
      for (final scale in [1.0, 2.0]) {
        for (final page in pages) {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppColors.theme,
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: page,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '${page.runtimeType} $size scale=$scale',
          );
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
    await tester.runAsync(c.disconnect);
    c.dispose();
  });
  testWidgets('生成桌面和手机效果页预览', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ApexisController();
    await tester.runAsync(
      () => c.connect(
        DemoTransport(),
        const DevicePort('demo', 'GT1', '演示'),
        demonstration: true,
      ),
    );
    for (final item in [
      (const Size(1440, 1000), 'desktop-effects'),
      (const Size(1280, 860), 'windows-effects'),
      (const Size(393, 852), 'mobile-effects'),
      (const Size(812, 375), 'mobile-landscape'),
      (const Size(768, 1024), 'tablet-effects'),
    ]) {
      await tester.binding.setSurfaceSize(item.$1);
      tester.view.physicalSize = item.$1;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('preview'),
          child: ApexisApp(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (Platform.isWindows) {
        await expectLater(
          find.byKey(const ValueKey('preview')),
          matchesGoldenFile('../design/previews/${item.$2}.png'),
        );
        if (item.$2 == 'mobile-effects') {
          await tester.ensureVisible(find.byKey(const ValueKey('dial-Treble')));
          await tester.pumpAndSettle();
          await expectLater(
            find.byKey(const ValueKey('preview')),
            matchesGoldenFile('../design/previews/mobile-parameters.png'),
          );
          // Do not carry the mobile scroll offset into the next viewport.
          await tester.pumpWidget(const SizedBox());
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
    await tester.runAsync(c.disconnect);
    c.dispose();
  });

  testWidgets('完整应用在横屏和大字体下保持导航可见', (tester) async {
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ApexisController();
    await tester.runAsync(
      () => c.connect(
        DemoTransport(),
        const DevicePort('demo', 'GT1', '演示'),
        demonstration: true,
      ),
    );
    for (final size in [
      const Size(375, 812),
      const Size(320, 640),
      const Size(768, 1024),
      const Size(812, 375),
      const Size(1280, 860),
      const Size(1024, 600),
    ]) {
      await tester.binding.setSurfaceSize(size);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      for (final scale in [1.0, 2.0]) {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await tester.pumpWidget(ApexisApp(controller: c));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size scale=$scale');
      }
    }
    await tester.pumpWidget(const SizedBox());
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
    await tester.runAsync(c.disconnect);
    c.dispose();
  });

  testWidgets('手机安全区域与音色操作菜单可用', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    const size = Size(393, 852);
    await tester.binding.setSurfaceSize(size);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 34);
    final c = ApexisController();
    await tester.runAsync(
      () => c.connect(
        DemoTransport(),
        const DevicePort('demo', 'GT1', '演示'),
        demonstration: true,
      ),
    );
    await tester.pumpWidget(ApexisApp(controller: c));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(NavigationBar)).bottom,
      lessThanOrEqualTo(818),
    );
    expect(
      tester.getRect(find.byTooltip('保存音色')).top,
      greaterThanOrEqualTo(44),
    );
    await tester.tap(find.byTooltip('音色操作'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('保存到'), findsOneWidget);
    expect(find.text('交换预设'), findsOneWidget);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect(find.text('重命名音色'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
    await tester.runAsync(c.disconnect);
    c.dispose();
  });

  testWidgets('设置分区在单双列和大字号下均保留 20px 间距', (tester) async {
    final c = ApexisController();
    await tester.runAsync(
      () => c.connect(
        DemoTransport(),
        const DevicePort('demo', 'GT1', '演示'),
        demonstration: true,
      ),
    );
    Rect section(String title) => tester.getRect(
      find.ancestor(of: find.text(title), matching: find.byType(SectionCard)),
    );
    for (final size in [
      const Size(375, 812),
      const Size(799, 900),
      const Size(800, 900),
      const Size(1280, 900),
    ]) {
      await tester.binding.setSurfaceSize(size);
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('settings-preview'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppColors.theme,
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: SettingsPage(c: c),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final device = section('我的设备'), backup = section('音色与备份');
        final rowBottom = device.bottom > backup.bottom
            ? device.bottom
            : backup.bottom;
        expect(
          section('应用信息').top - rowBottom,
          closeTo(20, 0.01),
          reason: '$size scale=$scale',
        );
        expect(tester.takeException(), isNull);
        if (Platform.isWindows &&
            scale == 1 &&
            (size.width == 375 || size.width == 1280)) {
          final scroll = tester.state<ScrollableState>(
            find.byType(Scrollable).first,
          );
          final offset = section('应用信息').top - size.height / 2;
          scroll.position.jumpTo(
            offset.clamp(0, scroll.position.maxScrollExtent),
          );
          await tester.pumpAndSettle();
          await expectLater(
            find.byKey(const ValueKey('settings-preview')),
            matchesGoldenFile(
              '../design/previews/settings-${size.width.toInt()}.png',
            ),
          );
        }
        await tester.pumpWidget(const SizedBox());
      }
    }
    await tester.binding.setSurfaceSize(null);
    await tester.runAsync(c.disconnect);
    c.dispose();
  });

  testWidgets('实际导航按轴和前后方向切换，内容不叠加', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const size = Size(1280, 860);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.binding.setSurfaceSize(size);
    final c = ApexisController();
    await tester.runAsync(
      () => c.connect(
        DemoTransport(),
        const DevicePort('demo', 'GT1', '演示'),
        demonstration: true,
      ),
    );
    await tester.pumpWidget(ApexisApp(controller: c));
    await tester.pumpAndSettle();
    Offset direction() => tester
        .widget<DirectionalPageTransition>(
          find.byType(DirectionalPageTransition),
        )
        .direction;
    expect(find.byType(IntrinsicHeight), findsNothing);
    expect(
      tester
          .widget<DirectionalPageTransition>(
            find.byType(DirectionalPageTransition),
          )
          .enabled,
      isTrue,
    );
    await tester.tap(find.text('全局'));
    await tester.pump();
    expect(direction(), const Offset(1, 0));
    expect(find.byType(EffectsPage), findsNothing);
    expect(find.byType(GlobalPage), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DirectionalPageTransition),
        matching: find.byType(SlideTransition),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('均衡'));
    await tester.pump();
    expect(direction(), const Offset(1, 0));
    await tester.tap(find.text('全局'));
    await tester.pump();
    expect(direction(), const Offset(-1, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('社区'));
    await tester.pump();
    expect(direction(), const Offset(0, 1));
    expect(find.byType(GlobalPage), findsNothing);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('参数'));
    await tester.pump();
    expect(direction(), const Offset(0, -1));
    await tester.pumpAndSettle();
    expect(find.byType(GlobalPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
    await tester.runAsync(c.disconnect);
    c.dispose();
  });

  testWidgets('返回效果页复用有效元数据，失效后重新查询', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    final c = ApexisController();
    final device = DemoTransport();
    await tester.runAsync(
      () => c.connect(
        device,
        const DevicePort('demo', 'GT1', '演示'),
        demonstration: true,
      ),
    );
    await tester.pumpWidget(ApexisApp(controller: c));
    await tester.pumpAndSettle();
    final generation = c.metadataGeneration;
    final metadata = List.of(c.parameters);
    int queries() => device.requests.where((m) => m.component == 2).length;
    final initialQueries = queries();
    await tester.tap(find.text('全局'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('效果'));
    await tester.pumpAndSettle();
    expect(c.parameters, metadata);
    expect(c.metadataGeneration, generation);
    expect(queries(), initialQueries);
    await tester.tap(find.text('全局'));
    await tester.pumpAndSettle();
    // Change the actual demo snapshot while the retained effects page is hidden.
    await tester.runAsync(
      () => c.action(1, 0, 1, [c.selectedUnit, ...Gt1.u14(0x400)]),
    );
    expect(c.parameters, isEmpty);
    await tester.pumpAndSettle();
    await tester.tap(find.text('效果'));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && c.parameters.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(c.parameters.length, 8);
    expect(queries(), greaterThan(initialQueries));
    expect(tester.takeException(), isNull);
    await tester.runAsync(c.disconnect);
    await tester.pumpAndSettle();
    expect(
      find.byType(RetainedPageViewport, skipOffstage: false),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
    await tester.runAsync(c.disconnect);
    c.dispose();
  });

  testWidgets('控件状态与弹窗的视觉回归', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('controls-preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppColors.theme,
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: SectionCard(
                title: '控件状态检查',
                subtitle: '选中 / 未选中 / 禁用',
                child: Column(
                  children: [
                    ValueControl(
                      label: 'Gain',
                      value: 60,
                      min: 0,
                      max: 100,
                      onCommit: (_) {},
                    ),
                    const ValueControl(
                      label: '暂不可编辑',
                      value: 60,
                      min: 0,
                      max: 100,
                      onCommit: null,
                    ),
                    ChoiceControl(
                      label: '输出模式',
                      value: 0,
                      choices: const ['立体声', '单声道'],
                      onChanged: (_) {},
                    ),
                    Row(
                      children: [
                        Switch(value: true, onChanged: (_) {}),
                        Switch(value: false, onChanged: (_) {}),
                        const Switch(value: false, onChanged: null),
                      ],
                    ),
                    const TextField(
                      decoration: InputDecoration(
                        labelText: '音色名称',
                        hintText: 'Classic Clean',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton(
                          onPressed: () {},
                          child: const Text('保存音色'),
                        ),
                        OutlinedButton(
                          onPressed: () {},
                          child: const Text('取消'),
                        ),
                        const FilledButton(
                          onPressed: null,
                          child: Text('暂不可用'),
                        ),
                        Builder(
                          builder: (context) => TextButton(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => const AlertDialog(
                                title: Text('音色名称'),
                                content: TextField(
                                  decoration: InputDecoration(labelText: '新名称'),
                                ),
                              ),
                            ),
                            child: const Text('打开弹窗'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (Platform.isWindows) {
      await expectLater(
        find.byKey(const ValueKey('controls-preview')),
        matchesGoldenFile('../design/previews/controls.png'),
      );
    }
    await tester.tap(find.text('打开弹窗'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (Platform.isWindows) {
      await expectLater(
        find.byKey(const ValueKey('controls-preview')),
        matchesGoldenFile('../design/previews/dialog.png'),
      );
    }
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
