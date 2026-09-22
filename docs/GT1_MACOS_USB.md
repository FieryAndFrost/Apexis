# GT1 macOS 私有 USB 通信

## 实现范围与验证边界

macOS 使用系统 IOKit / IOUSBLib 的用户态接口，通过 Dart FFI 连接 GT1；Windows 继续使用 WinUSB。两端共享同一套 GT1 线协议与传输生命周期。不添加 CDC 或 MIDI 回退，也不引入 libusb / Homebrew 运行时依赖。

当前开发环境是 Windows，**尚未在 Mac 编译或连接 GT1 验收**。Dart 模拟回归不能证明 IOKit 枚举、沙盒访问、原生链接和真实 USB 读写已经通过。Windows 现有实机速度数字也不能用作 Mac 性能结论。

本次 Windows 本地检查：`flutter analyze --no-pub` 无问题，`flutter test --no-pub` 共 166 项通过，其中两种桌面后端各跑 7 项模拟传输生命周期回归。新增的原生 IOKit vtable mock 测试已提供，但只能在 Apple SDK 环境编译执行，本机未运行。

Windows Profile 应用构建通过，改用桌面工厂后的只读枚举仍能找到 GT1。另一次 GET 回归在打开接口时返回 WinUSB 错误 5；当时已有 Apexis 进程运行，可能占用接口，未强行关闭。因此本轮不能宣称 Windows 实机 GET 回归通过。失败证据在本地忽略目录 `artifacts/macos-backend-windows-regression-20260922.json`，未发送参数写入。

GT1 沿用已烧入的私有 USB 固件（Windows 报告中的 `bcdDevice=0x0202`），不需要另烧 Mac 固件。本次没有修改或烧录下位机。

## USB 契约

- VID `0x3654` / PID `0x4E55`；接口 `3`，alternate `0`，class/subclass/protocol `FF/00/01`。
- Bulk OUT `0x04` / IN `0x84`；每个端点最大包长 `64` 字节。
- 控制请求：`bmRequestType=0x41, bRequest=0x30, wIndex=3, wLength=0`，`wValue=0/1` 关闭/打开会话。
- 沿用 F0…F7 分帧、7-bit 编码、XOR 校验，单帧最多 `244` 字节；原有 revision、响应与通知状态机不变。
- macOS 不使用 Microsoft OS 描述符或 Windows 设备接口 GUID；通过 IORegistry 和接口描述符匹配。

## 线程、超时与资源

`NativeTransport` 在 macOS 选择 `MacosUsbTransport`，Windows 选择 `WindowsUsbTransport`。共用 `UsbTransport` 处理连接状态、早期读取失败、取消、帧复制、长度检查与断开。

macOS 的扫描/打开/写入/关闭在 USB worker isolate 执行；RX 在独立 isolate 执行。UI isolate 不做 USB 阻塞调用。原生 C++ 直接编入 Runner，并导出给 `DynamicLibrary.process()`，随应用签名，无额外 dylib 分发要求。

- 只打开接口 03，重复检查 VID/PID、接口和两个端点；不接管音频接口、不 seize、不 detach 系统驱动、不重置设备或切换配置。
- 每次读 64 字节，收到 USB 包即返回；100 ms 是空闲读的退出期限，**不是每条命令的等待间隔**。
- 打开后有一次 100 ms 旧包排空期，不插在参数操作之间。
- 写入超时 500 ms；出错可能已经发出部分数据，因此关闭会话并报错，不自动重发。
- 关闭时设置原子停止标志，等待 RX 原生调用返回、isolate 退出，然后关闭会话和释放接口；不强杀持有原生缓冲区的 isolate。
- worker 操作上限 5 秒；异常后停止使用该 worker，不让界面无限等待。
- Registry ID 只用于本次枚举到的接口，不当作设备序列号；重新插拔后必须重新扫描。

## 在 Mac 上运行

安装 Flutter、完整 Xcode、CocoaPods，先运行 `flutter doctor -v`、`flutter pub get`。工程保留 App Sandbox，并在 Debug/Profile/Release entitlement 中启用 `com.apple.security.device.usb`。

```sh
flutter run -d macos --profile
```

VS Code：选择 **Apexis · macOS 私有 USB（性能模式）** 后 F5。需要断点时选 **Apexis · macOS 调试**。看到系统 USB 配件许可提示时选择允许，不需要安装私有 USB 驱动。

## 验收顺序

先关闭其它 GT1 控制应用。先跑原生 mock 测试和只读测试，读通后再做参数写入与恢复。不要把 mock 成功当作实机成功。

```sh
# 1. 使用真正的 Apple SDK 编译原生桥和 mock IOKit 契约测试
cmake -S macos/usb_io -B build/macos_usb -DCMAKE_BUILD_TYPE=Debug
cmake --build build/macos_usb
ctest --test-dir build/macos_usb --output-on-failure

# 2. 不写 GT1 参数：枚举、3 次重连，每次 1000 个 GET
dart run tool/probe_usb_scan.dart
GT1_USB_PROBE_QUERIES=1000 dart run tool/probe_gt1_usb.dart build/macos-usb-readonly.json

# 3. 真正应用构建、检查 USB 权限及 FFI 符号保留
flutter build macos --release
codesign -d --entitlements :- build/macos/Build/Products/Release/apexis.app
nm -gU build/macos/Build/Products/Release/apexis.app/Contents/MacOS/apexis | grep apexis_macos_usb
```

独立 Dart 探针从 `build/macos_usb/libapexis_macos_usb.dylib` 读取原生桥；应用使用内置符号。独立探针并不能验证 App Sandbox，必须实际启动签名应用再扫描连接。

有硬件、愿意写测试参数时，先备份并验证（目录必须不存在）：

```sh
dart run tool/backup_gt1_usb.dart build/macos-usb-backup
flutter drive --profile -d macos \
  --driver=test_driver/hardware_usb_performance.dart \
  --target=integration_test/hardware_usb_performance_test.dart \
  --dart-define=HARDWARE_USB_PERF=true \
  --dart-define=USB_PERF_BACKUP=/absolute/path/to/Apexis/build/macos-usb-backup/before.gt1b \
  --dart-define=USB_PERF_REPORT=/absolute/path/to/Apexis/build/macos-usb-performance.json
```

上一步会小幅改变当前音色的一个输出参数，再恢复原值并与备份逐字节核对；使用测试机和真实绝对路径。报告路径必须不存在，使用后检查 `passed`、`restored`。Mac 沙盒对外部文件的权限也需要验收，不要用生产音色试验。

还需实测：Intel / Apple Silicon、空闲超过读超时后继续通信、接收和发送中拔线、连接中取消、反复连接、正常退出、USB Hub、系统睡眠恢复，以及音频播放/录音与参数调节并行。效果链资源耗尽、恢复出厂卡死等固件问题不属于本次通信接入已解决的范围。

## 参考

- [Apple USB 用户态接口](https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/USBBook/USBDeviceInterfaces/USBDevInterfaces.html)
- [Apple IOUSBInterfaceInterface300](https://developer.apple.com/documentation/iokit/iousbinterfaceinterface300)
- [Apple App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [Flutter 静态 C ABI / FFI 接入](https://docs.flutter.dev/platform-integration/legacy-ffi-plugin)
