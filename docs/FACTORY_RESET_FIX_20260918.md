# 恢复出厂 CPU0 异常：实机复现与修复

## 复现证据

- 用户确认没有旋钮操作；前次参数通知仍出现输入/输出音量变化。此问题与恢复出厂异常分开记录，尚未证明 ADC 原始噪声原因。
- 16:52 恢复 DEBUG 目标供电和 PC 路由。DEBUG 的 USB reset 计数已由前次 4 增至 8；源码 `jl_debug_usb.c` 在 USB 总线复位时调用 `jl_debug_make_safe()`，会关闭目标供电和路由。尚未定位 Windows 为什么触发该复位，未移除安全策略。
- `hardware_factory_test.dart` 先保存当前 GT1S，临时关闭当前音色两个旋钮映射，再完整导出 GT1B，并以独立、revision 锁定的 47936 字节回读逐字节验证。
- 备份目录：`artifacts/gt1-factory-test-20260918/`。`quiet-before.gt1b` 为实机校验的隔离旋钮后整库；`original.gt1s` 为隔离前当前音色；`restoration.gt1b` 是将原始 GT1S 放回校验整库并重新计算 CRC 的恢复文件，不冒充同一时刻直接导出的文件。
- 16:55:50 仅提交一次恢复出厂。`00/08/36` 四秒无回执，应用会话失效，不自动重试。主 isolate 心跳最大间隔 64 ms，应用线程未冻结。
- UART `artifacts/gt1-factory-20260918.uart.log` 第 282 行起：`Chip Exception, Current CPU0`、`cpu0 write hmem excption`。RETS `0x060483AE`，RETI `0x06128104`，CPU0 Trace 末尾 `0x061280BC`。
- 异常后 DEBUG 供电仍 ON、路由 PC、无过流，USB reset 计数仍 8。本次异常不是 DEBUG 断电导致。
- 本次失败后尚未自动恢复参数，因为会话失效；完整恢复文件已保存。不能将 `restored=false` 描述为已经恢复。

## 根因

与在机镜像匹配的旧 ELF SHA256：
`e8ded168d9ce8812d03874f658f1b7bbf668cf8fea22462be7183693914a4dab`。

ELF 符号及反汇编显示：

1. 恢复默认的 `publish_globals → product_settings_live_publish → music_looper_psram_set_autorecord` 调用 `powf`。
2. `__ieee754_powf` 在 `0x060483A8` 调用 `fabsf`，返回地址为现场的 `0x060483AE`。
3. `fabsf` 来自预编译 `lib_dsp.a(dsp_vendor_math_abi.c.obj)`，位于独立 `.text.fabsf`，地址 `0x061280BC`，大小 4 字节。该地址同时是旧 `text_end/data_begin`。
4. BR27 链接脚本只收集 `.text`、`*.text`，漏了 `.text.*`；下载打包仅提取 `.text`、`.data`、`.data_code`。因此 ELF 中存在函数，但实际 app.bin 中该地址是后接的数据，不是函数指令。与实机跳到此处随后非法写内存的异常链一致。

这不是恢复出厂“需要重启”、不是丢失整份固件，也不是需要禁用看门狗。

## 修复范围

- 修复 `br27_platform/sdk/cpu/br27/sdk_ld.c`，在 Flash `.text` 中收集 `*(.text.*)`。
- 同步本地平台清单中该链接脚本的文件指纹、SDK 树指纹、human/domain base 及外层 payload 指纹。保留全部原始库归档及其构建来源记录，不宣称这些归档重新编译；公开头文件和接口未修改。本地派生包仍须通过原有完整校验，未放宽校验规则。
- GT1 新增 `tools/audit_packaged_code.py`：拒绝任何不在已打包输出段中的非空可执行段，逐字节核对 ELF 三段、各 bin 及拼接 app.bin。构建/下载验证收据同时绑定校验脚本和各段文件。
- 旧镜像被新校验明确拒绝：`.text.fabsf at 0x61280bc, 4 bytes`。
- 新增 4 项 ELF/遗漏段/镜像损坏回归，现有 8 项构建收据和 3 项工厂打包回归均通过。
- 新构建目录 `build-debug-factory-fix`；保持既有 NO-BT 诊断开关，不开启蓝牙。不改算法实现、看门狗、电源阈值或 DEBUG 安全策略。

## 验证状态

- 新固件全部 12 步构建、平台完整性、库接口、最终链接、内存预算、资源和工厂包校验通过。预编译模式不包含算法源码专项审计。
- 新 ELF SHA256：`d3462f61d47d3d144b5bf606a32f48334a0854aaae2d6b52f2524c488b96e465`。
- 新 `jl_isd.fw` SHA256：`9aa39db3188bb79ce148e51ee5b6669a1ea9e6035548862fa34104d295f4fb6e`。
- `fabsf` 现位于已打包 `.text` 内的 `0x06049A7A`；新镜像通过 ELF/三段/app.bin 逐字节校验。
- 17:12 通过原 DEBUG 目标 USB 进入 GT1 BOOT，`4C4A:3442` 和此前物理位置一致，6 个 USBKEY 包取得 ACK。随后只运行一次受保护下载，实际 Write sector/Write block、`Download completed.`、重启，下载命令退出 0；未格式化、未烧 DEBUG。
- 证据：`artifacts/gt1-factory-fixed-20260918.boot.json`、`.download.log`、`.uart.log`。后者开头可能包含烧录前旧程序的残余异常输出，须以下载后的启动段区分，不能将旧异常当新固件异常。
- 应用文件传输/恢复出厂对话框/协议会话回归共 17 项通过。
- 17:15:25 修复版实机恢复出厂 ACK 为 **40 ms**，随后读取到默认 F01A / 0 个效果；持续 5 秒的 10 次系统查询全部通过。`artifacts/gt1-factory-fixed-test-20260918/report.json` 的 `resetVerified=true`。
- 17:15:39 恢复原备份的分片暂存阶段连接中断，尚未发出整库 COMMIT。DEBUG 的 `usb_resets` 从 8 增至 10，目标电源 OFF、路由 disconnect、无过流。这是独立的 USB 连接/供电故障，不应描述为恢复出厂 CPU 异常复发，也不能描述为参数已经恢复。
- 17:18 恢复连接前 DEBUG reset 计数已为 12；受保护连接脚本仅开启 PC 路由和目标供电，GT1 正常枚举，未重烧。
- 新增 `hardware_restore_test.dart`，仅导入原先独立校验且 CRC 正确的备份，无恢复出厂、固件或电源命令，无自动重试。静态分析通过。本次运行在首次只读握手 `09/01/22` 超时，未开始导入；证据 `artifacts/gt1-restore-only-20260918/report.json`。
- 17:20～17:21 串口仍见正常音频运行统计，随后 COM5 的读取被 Windows 中止，GT1 消失；一度连 DEBUG MIDI / SCSI 控制通道也不可用。暂停写入，不盲目循环重烧。当前 `restored=false`，测试前备份仍保存在 `artifacts/gt1-factory-test-20260918/`。
- Windows 当前电源方案 USB 选择性暂停 AC/DC 均已禁用；现有系统事件日志未提供此次 USB 复位的根因。尚不能断言是线材、主机驱动或 DEBUG 固件导致。

## 2026-09-20：GT1 直连电脑对照测试

- 用户确认改为 GT1 直连电脑；测试前后 PnP 均只有 GT1 `3654:4D55` 音频/MIDI，无 DEBUG `3654:79B8`。WinMM 输入/输出打开关闭探测通过。
- 未重烧固件，未执行恢复出厂，未重启 MIDI 服务；设备协议版本为 `0.2.124-dev`。没有 DEBUG/独立串口接收设备，本轮仅有应用侧协议记录，不能声称取得 GT1 UART 异常堆栈。
- 测试工具先只读保存本轮当前 GT1S/GT1B，CRC 校验通过后才允许写入。新备份位于 `artifacts/gt1-direct-restore-20260920/before.gt1s`、`before.gt1b`；这一步是文件 CRC 校验，不冒充独立整库回读验证。
- 10:01:47 开始导入 9 月 18 日已独立验证的 `quiet-before.gt1b`；10:02:21 上传完成并收到提交回执。随后 47936 字节整库回读与备份负载逐字节一致。
- 10:02:29 导回原 `original.gt1s`，原音色和旋钮映射回读一致，`restored=true`；之后 30 次、间隔 1 秒的系统查询全部通过，10:03:00 完成。整个测试没有连接中断，退出码 0，完成后系统仍识别 SINCO-MIDI。
- 证据：`artifacts/gt1-direct-restore-20260920/report.json`（通信帧、步骤、回读验证和结果）及 `phases.jsonl`（带时间的准备/传输/提交阶段）。`hardware_restore_test.dart` 静态分析通过，文件传输单元回归 10 项通过。
- 结论：本次直连成功完成此前中断的备份恢复，9 月 18 日参数恢复待办已完成。单次对照结果提高对 DEBUG 链路的怀疑，但不证明 DEBUG 固件一定有错，也不能排除 GT1 偶发故障；原掉线的最初触发原因仍未证实。未进行断电后持久化验证，也未再次重复恢复出厂流程。

## 2026-09-20：追加 5 轮直连通信测试

- 用户要求多次测试直连 GT1。`hardware_restore_test.dart` 增加显式 `RESTORE_ROUNDS`（默认 1、最多 5），每轮主动关闭并重建 MIDI 会话（首轮为初始连接），执行 3 次完整同步、50 次系统查询、一次完整 GT1B 导入/提交/逐字节回读，以及一次原 GT1S 导入/回读。未执行恢复出厂、重烧、电源控制或异常自动重试。
- 测试前重新保存当前 CRC 合法的 GT1B/GT1S，路径 `artifacts/gt1-direct-repeat-20260920/before.*`。本轮证据为同目录 `report.json`、`phases.jsonl`，阶段事件新增 round 字段。
- 10:37:35 开始，总测试约 7 分钟，5 轮全部通过。每轮 47936 字节整库回读一致，原音色及旋钮映射均恢复，最后额外持续 30 秒的 30 次查询通过，测试进程退出码 0。
- 250 次计时系统查询：平均 27.296 ms，中位数 30 ms，P95 32 ms，最大 34 ms。这是该只读系统命令的往返延迟，不是整库导入耗时或全部命令延迟。
- 本轮未观察到意外掉线、查询超时、设备非零错误回执或无法解析的响应。主动断开/重连是测试步骤，不计为意外掉线。未连接 UART 接收器，无 GT1 串口堆栈记录。
- 结论：加上前一轮，共 6 次直连整库恢复均通过，更支持优先排查 DEBUG 板及 USB/供电链路；不能据此认定 DEBUG 固件已定位，也不构成长时间压力、所有音色组合或断电持久化验证。当前保持用户原音色和旋钮映射，不遗留临时禁用映射。
- 修改后的测试静态分析通过；文件传输单元回归 10 项通过。
