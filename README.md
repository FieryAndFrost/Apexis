# Apexis STD

Flutter 效果器控制应用，按 Apexis STD 交互稿与 GT1 protocol 1 / schema 12 实现；兼容原 2026-09-14 r2 及新版 r5 的 F/U 音色规则。

Windows 已切换为 **USB Audio + 私有 Bulk / WinUSB**，不再提供 CDC/MIDI 回退入口。需要配套的新 GT1 固件；旧 CDC 固件不会出现在新应用的扫描结果中。实现和验证状态见 [WinUSB 说明](docs/GT1_WINUSB_20260922.md)。

## 运行

### VS Code 点击运行（Windows）

1. 在 VS Code 中打开整个 `D:\Project\Apexis` 文件夹，并安装推荐的 Flutter 扩展（会同时安装 Dart 扩展）。
2. 点击左侧“运行和调试”（`Ctrl+Shift+D`），日常体验选择 `Apexis · Windows 性能模式`，点击绿色 ▶ 或按 `F5`；需要断点/热重载时选择 `Apexis · Windows 调试`。
3. 无硬件时可选择 `Apexis · Windows 演示模式`，启动后自动进入演示界面。

Windows 启动项已固定设备。Debug 支持断点与热重载，但切页耗时包含调试开销；`Ctrl+F5` 只是不附加调试器，不会自动把 Debug 编译改成 Profile。
`Apexis · Windows 性能模式` 使用 profile 构建，不支持热重载；修改代码后需要重新运行。原来的 Debug 启动项仍保留。已经打开的 Debug 窗口不能通过热重载切成 Profile，需要先结束该会话再用性能模式启动。
本项目隐藏了 Code Runner 的编辑器运行图标，避免将 Flutter 应用误当成普通 Dart 脚本执行；请使用上面的“运行和调试”入口。
若在其他电脑运行，需先安装 Flutter SDK 和带有“使用 C++ 的桌面开发”工作负载的 Visual Studio。

### 手机端调试

Android 手机开启 USB 调试并连接电脑，在 VS Code 状态栏选择手机，使用 `Apexis · 手机调试（先选择设备）` 启动项按 `F5`。该启动项不固定 Windows；也可先运行 `flutter devices` 确认设备可见。iPhone 需要在 macOS / Xcode 环境中构建和签名。

当前界面采用第一套“现代音频插件”风格：石墨黑面板、薄荷绿状态和矢量旋钮。手机竖屏使用底部导航、双列参数；窄屏/大字号自动单列，手机横屏使用紧凑侧导航。旋钮左右拖动、松手提交，支持加减微调、点击数值输入及键盘方向键。输入框明确使用设备原始整数值，不猜测算法单位。

### 命令行运行

```powershell
flutter pub get
flutter run -d windows
```

Windows 启动后搜索 GT1 私有 USB 接口；手机端搜索 BLE 设备。无设备时点击“进入演示模式”。也可以直接启动演示：

```powershell
flutter run -d windows --dart-define=DEMO=true
flutter run -d chrome --dart-define=DEMO=true
```

## 验证与打包

```powershell
flutter analyze
cmake -S windows/usb_io -B build/usb_io -G "Visual Studio 17 2022" -A x64 -DAPEXIS_USB_TESTS=ON
cmake --build build/usb_io --config Release
ctest --test-dir build/usb_io -C Release --output-on-failure
flutter test
powershell -ExecutionPolicy Bypass -File tool/package_windows.ps1
powershell -ExecutionPolicy Bypass -File tool/package_android.ps1
```

Windows 输出 `APP/Apexis/apexis.exe`，运行与分发需保留整个 `APP/Apexis` 文件夹。
Android 开发安装包输出 `APP/Apexis-debug.apk`，不是商店发布签名。

界面预览在 `design/previews/`。金图测试在 Windows 上加载系统字体；需要有意更新渲染基线时运行 `flutter test test/widget_test.dart --update-goldens`。

Windows 原生帧性能回归（独立演示窗口，不连接硬件）：

```powershell
$env:APEXIS_PERF_LABEL = 'navigation'
flutter drive --profile -d windows --driver=test_driver/navigation_performance.dart --target=integration_test/navigation_performance_test.dart
```

预热一轮后执行 30 次切页，再执行 50 次间隔 100ms 的模拟调音状态更新，以原生 vsync 驱动动画，输出 `build/performance/navigation.json`。结果分别记录导航和调音的构建/布局、栅格化帧耗时，以及调音区域重建次数和屏幕刷新率；不代表硬件通信延迟或鼠标输入端到端延迟。SDK 的超时计数按约 16.7ms 统计，高刷新率屏幕应另外按实际刷新周期评估。首次 Profile 原生构建较慢；不要以 Debug 模式的耗时替代正式性能测量。

功能范围、协议状态机、设计来源及实机联调事项见 [实现说明](docs/IMPLEMENTATION.md)。

界面采用分区快照与精确订阅，重建依赖和迁移边界见 [状态架构](docs/STATE_ARCHITECTURE.md)。

2026-09-16 的 Windows 实机读写检查、MIDI/完整视图 ACK 修复、F/U 兼容、备份与恢复证明、鼓机初始化源码核对及当时的未验收功能见 [历史实机核对报告](docs/HARDWARE_AUDIT.md)。该报告不是当前 WinUSB 固件的验收结论。

设备参数写入与保存回执表示 RAM 状态；正常软关机才持久化。新版 F 厂商区只供编辑试听，需要另存到 U 用户区保留。社区、AI 音色、音轨分离与固件升级服务尚未接入。
