# 应用功能联调记录（2026-09-17）

## 本轮状态与实机边界

本轮未写 GT1 参数、未恢复出厂、未断电、未重刷固件。不能据此宣布当前下位机的恢复出厂或全部功能已修复。

- Windows 能枚举 SINCO-MIDI / SINCO-AUDIO 与 SINCO DEBUG MIDI / COM5；枚举成功不等于业务通信正常。
- 只读备份集成测试在打开 MIDI 端口时 5 秒超时，未进入参数协议。报告：`artifacts/function-audit-20260917-1726-backup/report.json`，`verified=false`、`mutationsStarted=false`，没有生成可用备份。
- UART 连续 RX 采集 300 秒收到 0 字节：`artifacts/gt1-function-audit-20260917-1724.uart.log`。没有本轮恢复出厂的固件崩溃现场，不能推断看门狗、欠压或固件丢失。
- 用 `tool/probe_windows_midi.py` 在独立 Python 子进程直接调用 WinMM，不经过 Flutter，也不发送 MIDI 数据。GT1 和 DEBUG 均停在 `midiInOpen`，12 秒后由父进程终止自己的测试子进程。说明当前打开端口阻塞不局限于 Flutter 应用。
- 用户允许重启 Windows MIDI 服务后，`sc.exe stop midisrv` 返回 `STOP_PENDING`；后续状态一直保持该值、checkpoint 0x3，PID 4452。核实为独立 `C:\Windows\system32\midisrv.exe` 后尝试结束该服务进程，系统拒绝（Access is denied）。启动请求失败 1056。没有自动提权或重启电脑；服务尚未恢复。

需要管理员恢复 MIDI 服务后，先重启应用连接会话、重新验证只读备份，再继续实机写入测试。

## 已修复

1. 文件操作错误被收尾同步错误覆盖：保留首次错误及堆栈，同步失败单独记录；无效或被替换的会话不再用于收尾同步。
2. 提交阶段误导性的“取消”：区分准备、传输、提交、收尾阶段；提交后不可取消，显示请勿断电。取消已请求时禁用重复点击。
3. 已提交票据的多余 CANCEL：固件在单音色 `00/08/32` 和整库/恢复默认 `00/08/36` 执行提交前已释放票据，成功（包括已提交但静音）后不再发送 RESET/CANCEL。未提交会话仍进行清理。
4. BEGIN 返回非法分片大小等元数据时遗漏票据清理：将取得票据后的元数据解析纳入 finally 清理范围。
5. 文件选择/确认期间连接或目标音色变化：冻结最初确认的目标，执行前再次验证，拒绝将导入或恢复默认转发到新的连接/音色；导出文件名使用实际导出的音色编号。
6. 协议超时缺少命令定位：包含组件/命令/选择器，如恢复默认提交 `[00/08/36]`；结果未知时不自动重放。
7. 故障后的异步 disconnect 抛错：纳入错误流，不再成为未处理的异步异常；同步抛出的 send 异常同样纳入请求错误处理。

UI/UX 检查用于明确不可取消的提交阶段、可读的错误反馈、触控目标及可滚动弹窗；未更换已有风格。

## 自动化覆盖

| 范围 | 验证性质 |
| --- | --- |
| 协议编解码、分片、通知/ACK、STALE/BUSY、快速编辑队列 | 本机自动化、模拟传输 |
| 文件导入导出、CRC、取消、票据清理、提交回执丢失、静音提交 | 本机自动化、模拟传输 |
| 恢复默认失败与同步失败同时发生、确认期间重连 | Widget + 模拟设备 |
| 效果链添加至 10、编辑、旁路、排序、拒绝第 11 个、删除 | 模拟设备；不证明实机 DSP 负载或第 9 效果问题已解决 |
| U 区复制、交换、重命名、保存、目录读回 | 模拟设备；不证明 Flash 掉电持久化 |
| 鼓机启停、Looper 录制/停止/播放/清空、调音模式、连接状态 | 模拟设备；不包含音频听测 |
| 页面切换、重建范围、500ms 忙碌反馈、提示不挤压布局 | Widget 回归 |
| 手机 375px、横屏、桌面、2 倍字号、减少动态效果 | Widget 布局/已有视觉回归；非手机真机验证 |
| Windows 原生 MIDI 缓冲生命周期、队列和超时隔离 | 本地包单元测试 |

本轮新增 `test/file_actions_test.dart`、`test/functional_workflow_test.dart`，并扩展文件传输和协议会话测试。

最终验证：主应用 `flutter test` 110 项通过；Windows MIDI 包 13 项通过；`flutter analyze` 无问题。Windows Release 构建和打包成功，入口 `APP/Apexis/apexis.exe`。打包的 `data/app.so` 与 Release 原件 SHA-256 一致：`A30FBCCE047E144246962A7E2173931BD3C7A53D38B12A7B56C2B577B242CA9C`。正在运行的旧应用实例未被自动终止。

### 管理员恢复服务

当前普通终端无权终止卡住的服务。由用户在管理员 PowerShell 中执行（会中断本机 MIDI 连接，不擦写设备参数）：

```powershell
Stop-Process -Name MidiSrv -Force -ErrorAction Stop
Start-Service midisrv
Get-Service midisrv
```

若仍失败，保留错误输出，不自动继续反复重启。服务恢复至 Running 后，退出旧应用，再启动新版并进行备份验证。

### 17:46 后续尝试

用户要求由代理直接执行后，检查发现当前令牌已有管理员组身份，因此此前仅归因于“普通终端未提权”不准确。通过 `Start-Process -Verb RunAs` 启动限定目标的 `tool/recover_midi_service.ps1`，脚本仍在停止 MidiSrv PID 4452 时收到 Access is denied；独立 `taskkill /F /PID 4452` 也失败。`sc qprotection midisrv` 显示 NONE，不能据此声称是受保护服务。实际拒绝访问的进一步原因尚未确定。

证据：`artifacts/midi-service-recovery-20260917-174631.log`。服务仍为 Stop Pending，未恢复。建议保存工作后重启 Windows 以恢复系统 MIDI 状态；未获单独确认前不重启电脑，不更改服务 ACL、系统安全策略或固件。

## 待实机完成

1. Windows MIDI 服务恢复后验证 GT1 打开/关闭与多次重连。
2. 导出 GT1S/GT1B，CRC + 全库逐字节校验成功后再写入。
3. 参数、效果、鼓机、Looper、调音器、音色保存/复制/交换的实机回读及恢复原始备份。
4. 提前开启 UART 和协议日志，受控测试恢复出厂，并验证恢复备份；如无回执不得重复提交。
5. 重载 DSP、实际音频、软关机后持久化另行验证。手机 BLE/iOS、当前 NO_BT 诊断固件禁用的蓝牙，以及尚无后端的云端功能不在本次已通过范围内。
