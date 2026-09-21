# GT1 Windows USB CDC 试验

## 状态与边界

2026-09-21：**已烧入 GT1，CDC 实机枚举、协议读取、应用同步和整库参数保留校验通过**。长期稳定性、复杂写入和音频听感仍未完成验证。

## 低延迟更新（同日 15:48～16:05）

已将事件驱动加速固件烧入 **GT1 主板**，没有修改 DEBUG 固件。下面是同一台电脑、同一 DEBUG 直通 USB 路径、同一应用控制器的实测平均值；不是所有效果算法、Flash 操作或音频延迟的保证。

| 项目 | 旧 CDC 固件 | 加速 CDC 固件 |
| --- | ---: | ---: |
| 简单 GET 往返 | 约 30 ms | 0.53 ms |
| 单参数写入并收齐状态通知（30 次） | 66.57 ms | 1.78 ms |
| 当前视图完整同步（10 次） | 180.00 ms | 2.86 ms |
| 控制器连接、同步及元数据加载（单次） | 2,532 ms | 170 ms |

- 后测 3 次软件重连、共 3,000 次 GET 全成功：平均 524.9 us，最小 242 us，最大 2,585 us。
- 写入测试仅在当前音色 0 的 output 参数 37/36 间交替，逐次独立 READ 核实，最后恢复 37；前后均完整读取 47,936 B 参数区，与备份逐字节一致。
- 最新备份：`artifacts/gt1-cdc-fast-backup3-20260921/`，`verified=true`，GT1B CRC 与独立锁定 revision 的 READ 均通过。
- 本轮前两次备份因新上位机异步 I/O 的错误码读取问题中止；未写参数、未烧录。修复为原生侧捕获后，第三次完整备份和后续测试通过。失败证据保留，不把失败试验计为成功。
- 新镜像 SHA256：`ac8f62b8b56911eeb2a109c6ae133e6f278beebe1a26a4173352307f1a3eb1a3`。唯一 BOOT `4C4A:3442` 和目标 USB 位置核验后烧录，下载器实际 Write sector/block、Download completed、退出 0，ERASE MODE NONE。
- 原生分帧/驱动回归通过：立即 TX、IN 中断续发、APP 唤醒合并、任务队列满兜底、DTR、会话代际、背压、ZLP、复位。离线 Flash 包 3 项回归及实包校验通过。
- Flutter 163 项测试通过，包含真实 Windows 内核管道的接收、取消、断端及原子错误码测试；静态分析通过。
- `test_product_sysex.py` 在此工作区无法运行：夹具硬编码依赖不存在的 `gt1_app/` 路径。没有宣称该整套源码回归通过；本轮以独立 C 驱动测试、实际固件构建和实机回归补充。
- UART 仍在部分会话边界出现 `RXCSRP(H)_DataError/RXCSRP_DataError`，本轮查询、同步、参数写入没有失败，也没有确认这些打印的底层根因已经消除。长期、音频同时运行、复杂效果链/Flash 操作仍需专项测试。

对照证据：`artifacts/gt1-cdc-perf-{before,after}-20260921.json`；3,000 次读取：`artifacts/gt1-cdc-fast-stress-20260921.json`；烧录后全库验证：`artifacts/gt1-cdc-fast-postflash-probe-20260921.json`；串口日志：`artifacts/gt1-cdc-fast-{preflash,postflash}-20260921.uart.log`。

连接仍使用 `GT1 CDC (COM6)`，COM5 是 DEBUG 日志桥。正常 VS Code CDC 性能启动项已自动使用新实现，不需要调高波特率。初次连接的 100 ms 旧会话排空仍保留，不施加到逐次参数操作。

## 本次实机烧录结果（15:02～15:12）

- DEBUG `AC7911B8 / 010 / JLD00010` 已确认；目标仅由 DEBUG 目标 USB 供电。初始供电 OFF、路由 disconnect，开启后 GT1 原固件正常启动，原 MIDI GET 应答恢复。
- 最新只读备份 `artifacts/gt1-cdc-backup-20260921/`：`verified=true / mutationsStarted=false`，GT1B 47,956 B、GT1S 386 B，已做 CRC 和独立、锁定 revision 的 READ 对照。
- USBKEY 单次 10 us 半周期，6 包 ACK；Windows BOOT 为唯一 `4C4A:3442`，位于 `PCIROOT(0)#PCI(0803)#PCI(0000)#USBROOT(0)#USB(1)#USB(4)#USB(2)`。不是 DEBUG 板。
- 校验后执行 `package_firmware.py --build build-debug-cdc --download`。下载器记录实际 Write sector / Write block、`Download completed.`、重启，退出码 **0**，`ERASE MODE: NONE`；未执行格式化或恢复出厂。
- 镜像 `jl_isd.bin` SHA256：`ea16da34cc01cfc8d61b736df7f665e9eff0bfc4a56f9a6bebfd62d74ff504d6`。
- 重启后 `3654:4B55` 正常枚举：**COM6 是 GT1 CDC，COM5 是 DEBUG**；SINCO-AUDIO 保留。UART 确认 CPU1 online、NO_BT、APP services started。
- `tool/probe_gt1_cdc.dart`：3 次重新连接、60 次连续 GET 全部通过；首轮计时约 25～32 ms。该数字是本轮查询往返，不能当作参数提交/所有操作延迟保证。
- Flutter 实机只读检查：3 次控制器连接/同步成功，24 项读取均 `ok`，128 个音色名称、71 个效果类型正常；当前视图与独立 READ 一致。证据 `artifacts/gt1-cdc-readonly-20260921.json`。
- 烧录后独立读取整库 **47,936 B**，与升级前 GT1B 的参数区逐字节一致，`differentOffsets=[]`；没有导入/恢复旧备份。证据 `artifacts/gt1-cdc-bank-verify-20260921.json`。
- DEBUG 最终 target_power=true、usb_route=pc、overcurrent=false，control_errors/cdc_config_errors/overcurrent_trips 均 0，USBKEY inactive。保持供电和电脑直通。
- UART 仍出现过 `RXCSRP_DataError` 打印，本轮未伴随查询失败或 APP 停止；不能宣布底层 USB 异常和此前死机根因已经完全消除。

本轮证据还包括 `artifacts/gt1-cdc-{connect,boot,postflash-probe,final-debug}-20260921.json`、`gt1-cdc-download-20260921.{stdout,stderr}.log`、`gt1-cdc-flash-20260921.uart.log`。

- 应用默认在 Windows 使用 CDC，扫描不调用 WinMM，也不自动回退到 MIDI。
- 固件是 **UAC 音频 + CDC ACM**，不是 UAC + MIDI + CDC。预编译 USB 栈的 `MAX_INTERFACE_NUM=6`，三者同时开启需要 7 个接口，不能直接修改该常量破坏 ABI。
- 保留此前 NO_BT 诊断设置、看门狗和电压保护；没有新增恢复出厂、擦除参数或自动烧录动作。
- CDC 保留原 GT1 `F0…F7` 命令、7-bit 编码、XOR 校验、应答、修订号和通知协议。不添加另一份参数状态。
- 此试验固件不提供 USB MIDI PC/CC/时钟，也不提供 MIDI OTA/进入 BOOT 通道。回退/后续烧录依赖 DEBUG/官方烧录方式。手机、云端不在本轮范围内。
- 更换传输不能证明已修复音频/参数处理内部的死机。

## 运行与回退

VS Code 的“运行和调试”已提供：

- `Apexis · Windows CDC 试验（性能模式）`：配合本次 CDC 固件。
- `Apexis · Windows MIDI 回退（原固件）`：配合原 MIDI 固件。

当前板子仍为 MIDI 固件时，CDC 启动项扫描为空是预期结果。不要据此判断固件丢失。

Windows 产物：`build/windows/x64/runner/Profile/apexis.exe`。可以使用以下命令重新构建：

```powershell
flutter build windows --profile --dart-define=GT1_USB_TRANSPORT=cdc
```

在 `artifacts/firmware-source/gt1` 下：

```powershell
cmake --preset app-debug-cdc
cmake --build --preset app-debug-cdc --parallel 8
python -B tools/package_firmware.py --build build-debug-cdc --verify
```

试验包：`build-debug-cdc/flash-package/`。
已校验的 MIDI 回退包：`build-debug-factory-fix/flash-package/`。
不要使用更旧的 `build-debug-no-bt` 包直接回退：它未通过现行构建收据校验。

本次源码的 `apps/hw/br27/sdk_config.h` 中 `PRODUCT_USB_CDC_TRIAL` 默认是 `1`，**其它固件 preset 也会使用这个源码开关**；`app-debug-cdc` 负责隔离输出目录，不是额外的宏选择器。要重新构建 MIDI 版本，先将该开关改为 `0`，使用独立目录冷构建并重新校验，不能仅更换 preset 名称。

## 实现要点

- SDK 基础描述符 PID 随设备类组合变化：MIDI 为 `3654:4D55`，CDC 试验为 `3654:4B55`。音频接口 00～02，CDC 为 03～04；数据 EP4 IN/OUT，通知 EP1 IN，音频仍用 EP3。
- Windows 使用 SetupAPI 只筛选 `VID_3654&PID_4B55&MI_03`（允许 REV 字段），重新核验 COM 号后打开；不会打开 DEBUG 或其它串口。随后仍由现有协议会话读取 GT1 身份。
- Windows 加速实现：串口使用 overlapped I/O，独立接收 isolate 等待数据/停止事件，不再使用 2 ms 定时轮询；写入配置 250 ms 驱动超时，外层请求还有 5 s 截止。部分写入不重发，断开会话，防止重复执行非幂等命令。
- `windows/cdc_io` 随 Windows 应用自动编译和打包 `apexis_cdc_io.dll`，在原生侧原子捕获 ReadFile/WriteFile/GetOverlappedResult 的错误码。不能把正常的 `ERROR_IO_PENDING` 当作断线。关闭时先取消并等待接收完成，再释放句柄/内存。
- 打开时 DTR 建立新会话，先排空旧的在途数据 100 ms；这仅发生在连接时，不施加到每次参数修改。
- 固件加速实现：USB 事件合并唤醒 app_core；APP 一轮有界排空最多 4 个 64 B 包；回执生成后同轮发出第一包，IN 完成事件续发下一包。参数/Flash/音频工作仍只在 APP 执行。244 B 帧缓冲、单帧 TX 和硬件 NAK 背压保留；10 ms 定时器仅作为唤醒队列满/事务忙的兜底。
- 总线复位、DTR 改变、释放接口均更新 generation。源槽 3 在 MIDI/CDC 互斥构建间复用，避免改动四客户端通知 ABI。
- 发送先检查端点忙状态；64 B 整包后的空闲使用 ZLP 收尾。半帧超过 500 ms 丢弃，下一个 F0 重新分帧。
- `apps/common/device/usb/device/{midi,usb_device,task_pc,user_setup}.c` 是产品侧 SDK 覆盖文件，构建脚本将产品 `apps/` 合并到 SDK staging。CDC 实现由互斥的 `midi.c` 编译单元引入。没有修改预编译库或篡改平台包校验；升级 SDK 时须复核这四个覆盖文件。

Windows 超时设置依据 [COMMTIMEOUTS 官方说明](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-commtimeouts)。CDC 使用 Windows 内置串口驱动的设计依据 [Usbser.sys 官方说明](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/usb-driver-installation-based-on-compatible-ids)；本机新固件的 COM6 已通过上面的实际收发测试。

独立 Dart 探针和 Windows 单元测试需先构建原生辅助库（VS Code 正常启动应用无需手动执行）：

```powershell
cmake -S windows/cdc_io -B build/cdc_io -G "Visual Studio 17 2022" -A x64
cmake --build build/cdc_io --config Release
flutter test
```

异步取消遵循 [CancelIoEx](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelioex)：发起取消不等于完成，等待原生 I/O 退出后才能释放内存。错误码原子捕获的背景见 [win32 的 FFI 错误码说明](https://win32.pub/docs/migration/5xx-to-6xx)；这里保留当前依赖版本，使用小型原生桥接，不全局升级 win32。

## 已完成验证

- `flutter analyze --no-pub`：无问题。
- `flutter test`：159 项通过，包含 7 项新增 CDC 传输测试。
- Windows Profile 构建通过。
- 原生只读扫描 `dart run tool/probe_cdc_scan.dart`：正常返回空 CDC 列表，没有调用 MIDI 或打开串口。
- 主机 C 分帧测试：拆包、长度边界、噪声/坏帧重新同步、超时、满帧保留。
- 主机 C 驱动测试：描述符/接口编号、控制请求、DTR、generation、队列满、TX 忙、ZLP、复位。使用模拟 USB 控制器，不等同于实机枚举验证。
- PI32 固件构建、内存预算、最终链接契约、代码封装审计、离线 Flash 打包及包校验通过。算法库使用经校验的预编译归档；没有声称完成算法源码审计。
- 全量测试发现并补齐原 EQ 拖拽取消和大字体刻度溢出问题；保留键盘/原滑块替代操作。

日志：`artifacts/cdc-{firmware-build,windows-build,all-tests,flutter-analyze,flutter-test}.log`。

## 烧录前状态与后续验证

首次准备时 Windows 仅检测到原 `SINCO-MIDI` / `SINCO-AUDIO`，没有 DEBUG/串口；当时只读 MIDI 探针在 15 s 截止内未能完成打开，`artifacts/gt1-before-cdc-readonly-20260921.json` 查询列表为空。之后用户接回 DEBUG，已恢复通信并取得最新完整备份，详见上面的实机记录。

1. 已完成接线核验、备份、烧录、CDC/音频枚举、身份/能力/参数读取、软件重新连接和参数保留校验。
2. 后续仍需验证单参数写入回读与恢复、连续拖动、实体旋钮、效果链、音色写入、鼓机/节拍器操作等；本轮只有读取，没有声称这些写操作已经通过 CDC 实测。
3. 压力与故障测试仍需覆盖物理插拔、忙时排队、音频同时运行、超时和长期稳定性。恢复出厂另做备份和日志准备后再测试。
