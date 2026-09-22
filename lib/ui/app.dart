import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../data/controller.dart';
import '../transport/demo_transport.dart';
import '../transport/native_transport.dart';
import '../transport/transport.dart';
import 'pages.dart';
import 'theme.dart';
import 'widgets.dart';
import 'device_region.dart';

class ApexisApp extends StatelessWidget {
  const ApexisApp({super.key, this.controller, this.autoDemo = false});
  final ApexisController? controller;
  final bool autoDemo;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Apexis STD',
    debugShowCheckedModeBanner: false,
    theme: AppColors.theme,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: AppColors.background,
      ),
      child: child!,
    ),
    home: ApexisShell(controller: controller, autoDemo: autoDemo),
  );
}

class ApexisShell extends StatefulWidget {
  const ApexisShell({super.key, this.controller, this.autoDemo = false});
  final ApexisController? controller;
  final bool autoDemo;
  @override
  State<ApexisShell> createState() => _ApexisShellState();
}

class _ApexisShellState extends State<ApexisShell> with WidgetsBindingObserver {
  late final ApexisController c = widget.controller ?? ApexisController();
  final navigation = ValueNotifier((
    tab: 0,
    subtab: 0,
    tool: 0,
    direction: const Offset(1, 0),
  ));
  int get tab => navigation.value.tab;
  int get subtab => navigation.value.subtab;
  int get tool => navigation.value.tool;
  Offset get pageDirection => navigation.value.direction;
  void navigate({
    int? main,
    int? parameter,
    int? utility,
    required Offset direction,
  }) {
    navigation.value = (
      tab: main ?? tab,
      subtab: parameter ?? subtab,
      tool: utility ?? tool,
      direction: direction,
    );
  }

  Widget navigationRegion(WidgetBuilder builder) => ValueListenableBuilder(
    valueListenable: navigation,
    builder: (context, _, _) => builder(context),
  );
  bool scanning = false;
  List<DevicePort> ports = [];
  String? scanError;
  static const labels = ['参数', '音色', '工具', '社区', '设置'];
  static const icons = [
    Icons.tune,
    Icons.library_music_outlined,
    Icons.graphic_eq,
    Icons.explore_outlined,
    Icons.settings_outlined,
  ];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (widget.autoDemo) {
          connectDemo();
        } else if (!kIsWeb) {
          scan();
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setPolling();
    } else {
      c.setActivePage(null);
    }
  }

  void _setPolling() => c.setActivePage(
    tab == 0
        ? subtab
        : tab == 2 && tool == 0
        ? 5
        : null,
  );
  Future<void> scan() async {
    if (scanning) return;
    setState(() {
      scanning = true;
      scanError = null;
      ports = [];
    });
    final channel = NativeTransport();
    try {
      final result = await channel.scan();
      if (mounted) setState(() => ports = result);
    } catch (e) {
      if (mounted) setState(() => scanError = e.toString());
    } finally {
      await channel.dispose();
      if (mounted) setState(() => scanning = false);
    }
  }

  Future<void> connectDemo() async {
    await c.connect(
      DemoTransport(),
      const DevicePort('demo', 'Apexis STD', '演示'),
      demonstration: true,
    );
    _setPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    navigation.dispose();
    if (widget.controller == null) c.dispose();
    super.dispose();
  }

  void changeTab(int value) {
    if (value == tab) return;
    if (c.tunerActive && value != 2) unawaited(c.setTuner(false));
    final size = MediaQuery.sizeOf(context);
    final vertical =
        size.width >= 900 || (size.width >= 600 && size.height < 500);
    final direction = value > tab ? 1.0 : -1.0;
    navigate(
      main: value,
      direction: vertical ? Offset(0, direction) : Offset(direction, 0),
    );
    _setPolling();
    if (value == 0 && subtab == 0 && c.parameters.isEmpty) {
      unawaited(c.selectUnit(c.selectedUnit));
    }
    if (value == 1 && c.ready) unawaited(c.loadResources());
    if (value == 4 && c.ready) unawaited(c.readLinks());
  }

  @override
  Widget build(BuildContext context) => DeviceRegion(
    store: c.view,
    aspects: const [DeviceAspect.connection],
    label: 'shell',
    select: (s) => [
      s.connection.phase != LinkState.disconnected,
      s.connection.demo,
      s.connection.name,
      s.connection.kind,
      s.connection.session,
      s.patch != null,
    ],
    builder: (context) {
      final connected = c.state != LinkState.disconnected;
      return Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 900;
              final landscape =
                  !wide && box.maxWidth >= 600 && box.maxHeight < 500;
              if (!connected) {
                return DeviceRegion(
                  store: c.view,
                  aspects: const [
                    DeviceAspect.connection,
                    DeviceAspect.feedback,
                    DeviceAspect.access,
                  ],
                  label: 'connection',
                  builder: (_) => connectionPage(),
                );
              }
              return Row(
                children: [
                  if (wide) navigationRegion((_) => sideBar()),
                  if (landscape)
                    navigationRegion(
                      (_) => SingleChildScrollView(
                        child: IntrinsicHeight(
                          child: NavigationRail(
                            minWidth: 72,
                            selectedIndex: tab,
                            onDestinationSelected: changeTab,
                            backgroundColor: AppColors.inset,
                            indicatorColor: AppColors.selected,
                            selectedIconTheme: const IconThemeData(
                              color: AppColors.accent,
                            ),
                            destinations: List.generate(
                              labels.length,
                              (i) => NavigationRailDestination(
                                icon: Tooltip(
                                  message: labels[i],
                                  child: Icon(icons[i]),
                                ),
                                label: Text(labels[i]),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Column(
                      children: [
                        DeviceRegion(
                          store: c.view,
                          aspects: const [
                            DeviceAspect.preset,
                            DeviceAspect.access,
                            DeviceAspect.connection,
                          ],
                          label: 'header',
                          builder: (_) => header(wide),
                        ),
                        if (c.demo && wide && box.maxHeight > 1000)
                          Container(
                            width: double.infinity,
                            color: AppColors.inset,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 7,
                            ),
                            child: const Text(
                              '演示模式 · 参数保存在本次会话，不连接真实设备',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.muted,
                              ),
                            ),
                          ),
                        Expanded(
                          child: Stack(
                            key: const ValueKey('workspace-viewport'),
                            fit: StackFit.expand,
                            children: [
                              DeviceRegion(
                                store: c.view,
                                aspects: const [
                                  DeviceAspect.connection,
                                  DeviceAspect.preset,
                                ],
                                select: (s) => [
                                  s.connection.session,
                                  s.preset.selected,
                                  s.patch != null,
                                ],
                                label: 'page-host',
                                builder: (_) =>
                                    navigationRegion((_) => patchBody()),
                              ),
                              // A fixed overlay slot: progress never changes the
                              // body's constraints, even for very short writes.
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                height: 2,
                                child: DeviceRegion(
                                  store: c.view,
                                  aspects: const [
                                    DeviceAspect.access,
                                    DeviceAspect.feedback,
                                  ],
                                  select: (s) =>
                                      (s.access, s.feedback.progress),
                                  label: 'progress',
                                  builder: (_) => SizedBox(
                                    key: const ValueKey(
                                      'feedback-progress-slot',
                                    ),
                                    child: c.showBusyFeedback
                                        ? LinearProgressIndicator(
                                            value: c.progress,
                                            minHeight: 2,
                                            semanticsLabel: '设备同步或操作进行中',
                                          )
                                        : null,
                                  ),
                                ),
                              ),
                              DeviceRegion(
                                store: c.view,
                                aspects: const [
                                  DeviceAspect.feedback,
                                  DeviceAspect.access,
                                ],
                                label: 'feedback',
                                builder: (_) {
                                  final text = c.error ?? c.notice;
                                  if (text.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  return LayoutBuilder(
                                    builder: (_, constraints) => Align(
                                      alignment: Alignment.bottomRight,
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: ConstrainedBox(
                                          constraints: BoxConstraints(
                                            maxWidth: 520,
                                            maxHeight:
                                                (constraints.maxHeight - 24)
                                                    .clamp(0, 220),
                                          ),
                                          // One card is updated in place. Repeated
                                          // errors cannot queue up or push the page.
                                          child: message(text, c.error != null),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        if (!wide && !landscape)
                          navigationRegion(
                            (_) => NavigationBar(
                              selectedIndex: tab,
                              onDestinationSelected: changeTab,
                              destinations: List.generate(
                                labels.length,
                                (i) => NavigationDestination(
                                  icon: Icon(icons[i]),
                                  label: labels[i],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
  Widget message(String text, bool error) => Semantics(
    container: true,
    liveRegion: true,
    child: Material(
      key: const ValueKey('feedback-message'),
      color: AppColors.card,
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: error ? AppColors.red : AppColors.accent),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          children: [
            Icon(
              error ? Icons.error_outline : Icons.info_outline,
              size: 18,
              color: error ? AppColors.red : AppColors.accent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SingleChildScrollView(
                // Long protocol details stay readable without growing the card past
                // the viewport; close/retry remain outside this scrollable area.
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(text, style: const TextStyle(fontSize: 12)),
                ),
              ),
            ),
            if (error && c.retryEdit != null)
              TextButton(
                onPressed: c.editable ? c.retryEdit : null,
                child: const Text('重试'),
              ),
            IconButton(
              tooltip: '关闭提示',
              onPressed: () {
                if (error) {
                  c.error = null;
                } else {
                  c.notice = '';
                }
                c.emit();
              },
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    ),
  );
  Widget sideBar() => Container(
    width: MediaQuery.textScalerOf(context).scale(14) > 19 ? 232 : 192,
    decoration: const BoxDecoration(
      color: AppColors.inset,
      border: Border(right: BorderSide(color: AppColors.border, width: 0.5)),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          // Use the viewport minimum height without an intrinsic layout pass.
          // Short windows still scroll; the footer stays at the bottom otherwise.
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 32, 16, 6),
                    child: Text(
                      'APEXIS',
                      style: TextStyle(
                        letterSpacing: 3,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 24, bottom: 36),
                    child: Text(
                      'STD  /  TONE CONTROL',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 0.5,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  SlidingSelection(
                    key: const ValueKey('main-tab-indicator'),
                    axis: Axis.vertical,
                    selected: tab,
                    count: labels.length,
                    color: AppColors.selected,
                    inset: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    radius: 10,
                    child: Column(
                      children: [
                        for (var i = 0; i < labels.length; i++)
                          SizedBox(
                            height:
                                MediaQuery.textScalerOf(context).scale(14) > 19
                                ? 80
                                : 64,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              child: Material(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  selected: tab == i,
                                  selectedTileColor: Colors.transparent,
                                  leading: Icon(icons[i]),
                                  title: Text(
                                    labels[i],
                                    style: TextStyle(
                                      fontWeight: tab == i
                                          ? FontWeight.w700
                                          : FontWeight.w400,
                                    ),
                                  ),
                                  trailing: tab == i
                                      ? const Icon(
                                          Icons.chevron_right,
                                          size: 18,
                                        )
                                      : null,
                                  onTap: () => changeTab(i),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatusTag(
                      label: c.demo ? '演示模式' : '设备已连接',
                      color: c.demo ? AppColors.amber : AppColors.green,
                      icon: c.demo
                          ? Icons.science_outlined
                          : Icons.check_circle_outline,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      c.demo ? '本地预览 · 不写入设备' : c.port?.kind ?? '',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      '让每个音符，成为你的声音。',
                      style: TextStyle(color: AppColors.muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget header(bool wide) => Container(
    padding: EdgeInsets.symmetric(horizontal: wide ? 24 : 16, vertical: 12),
    decoration: const BoxDecoration(
      gradient: AppColors.panelGradient,
      border: Border(bottom: BorderSide(color: AppColors.border)),
    ),
    child: Row(
      children: [
        Container(
          width: c.factoryUserPresets ? 70 : 52,
          height: 48,
          decoration: BoxDecoration(
            color: AppColors.selected,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Text(
              c.labelForPreset(c.selected),
              style: const TextStyle(
                color: AppColors.accent,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: InkWell(
            onTap: c.editable ? () => showPresets(context, c) : null,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.patch == null
                        ? '正在连接设备'
                        : c.demo
                        ? 'APEXIS STD · 演示模式'
                        : c.currentFactoryPreset
                        ? '厂商试听 · 保留请另存 U 区'
                        : 'APEXIS STD · PRESET',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.muted,
                    ),
                  ),
                  Text(
                    c.patch?.name ?? '正在同步当前音色…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: wide ? 20 : 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (wide)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: StatusTag(
              label: c.presentationReady && (c.ready || !c.showBusyFeedback)
                  ? '已同步 · REV ${c.revision}'
                  : '正在同步',
              color: c.presentationReady && (c.ready || !c.showBusyFeedback)
                  ? AppColors.green
                  : AppColors.amber,
            ),
          ),
        IconButton(
          tooltip: '选择预设',
          onPressed: c.editable ? () => showPresets(context, c) : null,
          icon: const Icon(Icons.grid_view_outlined),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: c.currentFactoryPreset ? '另存用户音色' : '保存音色',
          style: IconButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: AppColors.onAccent,
            disabledBackgroundColor: AppColors.card,
          ),
          onPressed: !c.editable
              ? null
              : c.currentFactoryPreset
              ? () => showPresets(context, c, copy: true)
              : c.save,
          icon: const Icon(Icons.save_outlined),
        ),
      ],
    ),
  );
  Widget patchBody() {
    if (c.patch == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 24),
            Text('正在读取设备身份和当前音色…'),
          ],
        ),
      );
    }
    final pageId =
        '$tab-${tab == 0
            ? subtab
            : tab == 2
            ? tool
            : 0}';
    return Column(
      children: [
        if (tab == 0)
          subTabs(['效果', '全局', '均衡', 'LOOP', '鼓机'], subtab, (i) {
            if (i == subtab) return;
            navigate(parameter: i, direction: Offset(i > subtab ? 1 : -1, 0));
            _setPolling();
            if (i == 4 && c.patterns.isEmpty) unawaited(c.loadPatterns());
            // Device snapshots already invalidate metadata when effects change.
            // A navigation-only return must not clear and remount valid controls.
            if (i == 0 && c.parameters.isEmpty) {
              unawaited(c.selectUnit(c.selectedUnit));
            }
          }),
        if (tab == 2)
          subTabs(['调音表', '音轨分离', 'AI 音色'], tool, (i) {
            if (i == tool) return;
            if (c.tunerActive && i != 0) unawaited(c.setTuner(false));
            navigate(utility: i, direction: Offset(i > tool ? 1 : -1, 0));
            _setPolling();
          }),
        Expanded(
          child: DirectionalPageTransition(
            pageId: pageId,
            direction: pageDirection,
            child: RetainedPageViewport(
              pageId: pageId,
              cacheToken: (c.session, c.selected),
              child: SingleChildScrollView(
                key: ValueKey('page-$pageId'),
                padding: EdgeInsets.all(
                  MediaQuery.sizeOf(context).width < 600 ? 12 : 24,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1200),
                    child: switch (tab) {
                      0 => switch (subtab) {
                        0 => EffectsPage(c: c),
                        1 => GlobalPage(c: c),
                        2 => EqualizerPage(c: c),
                        3 => LooperPage(c: c),
                        _ => DrumPage(c: c),
                      },
                      1 => ResourcesPage(c: c),
                      2 => switch (tool) {
                        0 => TunerPage(c: c),
                        1 => const EmptyFeature(
                          icon: Icons.multitrack_audio,
                          title: '音轨分离',
                          description: '交互入口已保留。当前尚未接入音轨分离引擎与音频文件处理服务。',
                        ),
                        _ => const EmptyFeature(
                          icon: Icons.auto_awesome_outlined,
                          title: 'AI 音色',
                          description: '敬请期待。当前设备协议尚未提供 AI 音色生成与资源上传能力。',
                        ),
                      },
                      3 => const EmptyFeature(
                        icon: Icons.explore_outlined,
                        title: '发现更多声音',
                        description: '社区服务尚未配置。你可以在设置中导入、导出本地音色文件，保存自己的创作。',
                      ),
                      _ => SettingsPage(c: c),
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget subTabs(List<String> names, int selected, ValueChanged<int> change) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: AppColors.border, width: 0.5),
          ),
        ),
        child: SlidingSelection(
          key: ValueKey('sub-tab-indicator-$tab'),
          axis: Axis.horizontal,
          selected: selected,
          count: names.length,
          color: AppColors.accent,
          inset: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(
            children: List.generate(
              names.length,
              (i) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 12,
                      ),
                      backgroundColor: Colors.transparent,
                      foregroundColor: i == selected
                          ? AppColors.onAccent
                          : AppColors.muted,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: () => change(i),
                    isSemanticButton: true,
                    child: Semantics(
                      selected: i == selected,
                      child: Text(names[i]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
  Widget connectionPage() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          children: [
            const Text(
              'APEXIS',
              style: TextStyle(
                fontSize: 42,
                letterSpacing: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'STD  /  YOUR SOUND, CONNECTED',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 2,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 48),
            Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(32),
                color: AppColors.card,
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(
                scanning ? Icons.radar : Icons.cable,
                size: 52,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(height: 28),
            Text(
              scanning ? '正在搜索可用设备' : '连接你的效果器',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(
              kIsWeb
                  ? '浏览器用于界面预览，Windows 应用通过私有 USB 连接。'
                  : '手机通过蓝牙连接，Windows 通过私有 USB（WinUSB）连接。',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 28),
            if (scanning) const LinearProgressIndicator(),
            if (scanError != null || c.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  scanError ?? c.error!,
                  style: const TextStyle(color: AppColors.red),
                  textAlign: TextAlign.center,
                ),
              ),
            for (final p in ports)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(12),
                    leading: Icon(
                      p.kind == 'BLE' ? Icons.bluetooth : Icons.usb,
                    ),
                    title: Text(p.name),
                    subtitle: Text(
                      '${p.kind}  ${p.rssi != null ? '${p.rssi} dBm' : p.id}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await c.connect(NativeTransport(), p);
                      _setPolling();
                    },
                  ),
                ),
              ),
            if (!scanning && ports.isEmpty && !kIsWeb)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  '未发现设备时，请确认电源、蓝牙或 USB 连接。',
                  style: TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: scanning || kIsWeb ? null : scan,
                icon: const Icon(Icons.refresh),
                label: const Text('重新搜索'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: scanning ? null : connectDemo,
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('进入演示模式'),
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'Apexis STD · GT1',
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ],
        ),
      ),
    ),
  );
}
