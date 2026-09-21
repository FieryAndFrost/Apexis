# 恢复出厂后应用未响应：现场诊断

## 2026-09-17 15:43–15:48 观察

- 用户报告点击恢复出厂后崩溃；诊断期间未重复恢复出厂、未重新上电、未烧写固件、未重启 Windows MIDI 服务或应用。
- `apexis.exe` PID 2604 仍存在，Windows `Responding=False`，窗口标题 `Apexis STD`。属于已观察到的应用卡死，不是进程退出。
- SINCO-MIDI / SINCO-AUDIO（VID 3654 / PID 4D55）和 DEBUG（3654 / 79B8、COM5）仍枚举。枚举不能证明 GT1 业务线程正常。
- 在故障发生后监听 COM5 35 秒，收到 0 字节。最近一次既有 UART 日志结束于 15:24:35，未覆盖本次恢复出厂事件；不能据此认定 GT1 已复位或没有复位。
- Dart VM 的 `getVM` 可返回，但主 isolate 的 `getIsolate` / `getStack` 均 8 秒超时。
- 使用 CDB 非侵入且不暂停目标的 `-pvr` 方式读取线程栈，主线程现场如下：

```
ntdll!NtAlpcSendWaitReceivePort
RPCRT4!LRPC_BASE_CCALL::DoSendReceive
RPCRT4!LRPC_CCALL::SendReceive
RPCRT4!NdrpClientCall3
RPCRT4!NdrClientCall3
wdmaud2!CMidi2MidiSrv::Shutdown
wdmaud2!CMidiPort::Shutdown
wdmaud2!CMidiPorts::Close
wdmaud2!CMidiPorts::ModMessage
wdmaud2!modMessage
winmmbase!midiOutClose
```

证据：`artifacts/apexis-factory-hang-20260917-1546.stacks.log` 第 67–80 行。其他 Flutter 帧缺少精确私有符号，不能根据最近的导出符号名称归因 GPU。

## 判断与边界

当前应用未响应的直接阻塞点是 Windows MIDI 输出关闭：`midiOutClose` 正等待 MIDI 服务 RPC 返回。代码 `local_packages/flutter_midi_command_windows/lib/windows_midi_device.dart` 的 `_finishClose()` 同步调用 `_api.outputClose()`，后者直接 FFI 调用 `midiOutClose`；此处阻塞能连带冻结 UI 和 Dart 定时器。

尚不能确认最初为何进入关闭流程，也不能确认 GT1 在恢复出厂时是否另有故障。需先保留现场，再检查断线/错误前后的通信记录；不能将当前应用卡死直接等同于固件丢失、低压复位、看门狗或蓝牙初始化失败。

修复方向是将可能阻塞的 Windows MIDI 原生生命周期调用与 UI 隔离，并处理会话失效、在途缓冲区及关闭结果；仅在同一 Dart isolate 外包 `Future.timeout` 不能解除同步 FFI 阻塞。本轮仅诊断，没有修改通信实现。

## 后续修复（2026-09-17）

- 新增 `MidiWorker` 请求队列及 `winMmWorkerMain`：WinMM 枚举、连接、收发、轮询、reset/unprepare/close 全部在专用 isolate 中执行；UI 仅持有设备描述和收发消息，不持有原生句柄。
- 请求严格串行，5 秒内未返回则将工作会话标记为失效，拒绝未发送的新请求并丢弃迟到数据，不自动重试恢复出厂等非幂等操作。
- 不强杀仍在驱动调用中的 isolate，不提前释放驱动仍拥有的 MIDIHDR/数据缓冲；若调用后来返回，执行安全清理。系统 MIDI 服务自身永久阻塞不能由此代码保证恢复，但不应再冻结应用 UI。
- 关闭时立即解除 UI 连接；正在关闭的端点禁止并发重新打开，连接过程中取消不会再发布陈旧的连接成功事件。NativeTransport 忽略旧代次扫描结果，避免晚到错误写入已关闭的流。
- 工作会话失效后会提示重新启动应用；未自动重启系统 MIDI 服务、未终止用户旧应用、未触发恢复出厂或改写固件。

### 下位机缓存补查

16:48:18 通过 DEBUG SCSI 的只读 `system.status` / `uart.stats` / `uart.read` 取出 UART0 独立控制缓存（未发送 UART 字节，未切换供电或 USB 路由）。结果：

- 目标供电 ON、路由 PC、无过流。
- 累计接收 4,836,979 字节；控制缓存 8,192 字节已满，累计丢弃 4,828,787 字节；UART 读错误 0。
- 取出的内容是早先的启动日志，末尾止于启动时间约 0.617 秒。没有可靠主机时间能与本次恢复出厂关联，不能将其中旧 POR/PMU 信息当作本次崩溃证据。
- 缓存已读取并保存在 `artifacts/gt1-factory-buffer-20260917-1552.json`（文件名时间不准确，以 JSON 内 `time` 为准）。因此仍然没有本次恢复出厂的有效下位机卡死日志；需要后续在完整日志采集已开启时受控复现。

### 自动化验证

- 主应用 `flutter test`：98 项通过。
- Windows MIDI 本地包 `flutter test`：13 项通过（5 项原生缓冲/FIFO/清理测试、8 项隔离队列/同步阻塞/超时/退出/取消连接测试）。
- 新增真实 Windows 集成检查仅枚举端点并验证 UI/定时器响应，不连接 GT1、不写参数、不复现恢复出厂。
- 真实 Windows Profile 集成检查通过：87 ms 扫描到 SINCO DEBUG MIDI 与 SINCO-MIDI，5 次定时器触发、1 次 UI 点击成功，`uiResponsive=true`。报告：`build/diagnostics/windows-midi-isolation.json`。
- `flutter analyze` 无问题。上述验证不包含恢复出厂的实机复测，也不证明下位机执行恢复出厂正常。
- Windows Release 构建及打包完成：`APP/Apexis/apexis.exe`，对应 `data/app.so` 已更新。旧的未响应 Debug 进程没有被自动终止，需要退出旧实例后启动新版。
