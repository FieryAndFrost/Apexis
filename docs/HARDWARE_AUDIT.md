# Windows 实机通信核对（更新至 2026-09-16）

## 结论

**15:38 新发现：多效果边界测试已复现下位机失去响应。** 两个 Room stereo 实时运行正常，添加第三个后请求超时并持续 `timer_no_response: app_core`。证据强烈指向实时音频负载/控制任务调度问题，精确阻塞位置尚未取得；不能将此前主要通信测试通过理解为任意效果组合稳定。当前未修复，详见 [多效果诊断](CHAIN_LIMIT_DIAGNOSIS_20260916.md)。

不是“全部功能已验收”。已修复 Windows MIDI 传输缺陷及写入后完整视图被提前 ACK 的同步问题。9 月 16 日补齐协议字段 UI、新版 F/U 音色兼容，并完成完整 PATCH、旋钮映射、旁路清尾音和 Looper 叠录/撤销/恢复实测。最新已使用配套预编译算法库烧录 GT1 0.2.124-dev；旧固件鼓机 GET 的 error=1 已消失，目录/状态/启停通过，写入测试后整库逐字节校验恢复。下表及其后的旧版本记录保留历史覆盖范围；最新烧录后结果见文末，不代表音频听感、手机或全部业务条件验收。

依据：`README.md`、`IMPLEMENTATION.md`、`STATE_ARCHITECTURE.md` 与 `GT1_APP_PROTOCOL_HANDOFF.html`（2026-09-14 r2）。协议 SHA256 与实现说明一致：`EC2D52E2CAADFE312FF09BE58521B561B23C69DB181BDF2D5A7BD87AAB089FF6`。

设备：Windows USB MIDI `SINCO-MIDI`，身份 `GT1 / AC703N / 0.2.117-dev`，Protocol 1、Schema 12。本轮三次连接均为音色 01A、revision 20、空效果链（0 UNIT），TYPE 目录 71 项，已安装模型目录 0 项。这些是设备返回值，不是客户端默认演示数据。

## 功能核对

| 范围 | 客户端实现 | 本轮实机证据 / 限制 |
|---|---|---|
| USB MIDI 连接、同步、重连 | 已实现，传输层已修复 | 三次连续连接/重连成功；GLOB64+PATCH374 与独立 READ 逐字节相同；ACK 后就绪 |
| BLE 手机连接 | 已实现 | 本轮只有 Windows USB，未验收 BLE/MTU/A2DP 共存 |
| 音色目录、选择、命名、复制/交换、RAM 保存 | 已实现 | 128 个名称分页读取成功；未切换、覆盖或保存音色 |
| TYPE、效果链、实例开关、增删替换与重排 | 已实现 | 71 个 TYPE、当前链读取成功；当前链为空，未实测效果应用/删除/CPU1 约束 |
| 参数名称、范围、标签、单字段写入 | 已实现 | 现有模拟回归通过；无活动 UNIT，未实测 Mode/Sync 元数据或写入 |
| INPUT/OUTPUT/PAN/BPM、全局/USB/EQ | 已实现 | 原始镜像读取正确，相应旧 GET 回执长度符合协议；未修改或做声音验收 |
| 物理旋钮映射 | 已实现 | 两个 GET20 映射正常；未改绑定、范围或做物理接管验收 |
| 模型目录和加载 | 已实现 | 设备目录返回 0，不伪造资源；未测试加载模型 |
| 鼓机 | 界面和命令路径已实现 | **GET 状态、GET 目录均返回 error=1，实机不可验收** |
| Looper 控制、进度、自动录音、定长、预备拍 | 已实现主要路径 | 状态、24B 进度、偏好 GET 正常；未录音/播放/清空/撤销；未验证音频与动作完成时序 |
| 调音器 | 已实现 | 结果 GET 返回 note=255、pointer=128；未主动进入调音或测试有音高输入 |
| 自动关机、蓝牙音频连接状态 | 已实现 | GET 正常；未软关机、未验证持久化 |
| GT1S/GT1B 导入导出与恢复默认 | 已实现文件会话路径 | 模拟文件往返/取消测试通过，仅实测会话状态 GET；没有导入、导出会话或提交 |
| 协议附加字段的专用 UI | **9 月 16 日已补齐本行所列字段** | 原缺项：`clear_on_bypass`、独立 `looper_drum_pattern`、Looper pending/generation/预备拍剩余时长、预设 flags；新版及旧版兼容测试见文末 |
| 社区、账号、云音色、AI、音轨分离、OTA、模型/IR/鼓资源上传 | **未实现服务能力** | 现有交接协议未提供对应接口；占位入口不算实现 |

“GET 正常”是报文与读取路径验证，不等于写入、实时音频或所有业务条件通过。GT1B 在客户端检查类型、长度和 CRC，完整版本/字段合法性仍依赖固件提交校验；不宣称客户端具有完整离线 schema 校验器。

## 本轮修复

1. **输入缓冲区乱序**：旧实现固定扫描下标 0..7。若消费至槽 5，再同时收到槽 6、7、0、1，旧实现会先交付 0、1。改为按缓冲区入队顺序消费，并让协议层统一处理 SysEx 分片/粘包。
2. **发送缓冲区过早释放**：旧实现固定 20ms 后释放内存，不检查驱动所有权。改为等待 DONE 且 `midiOutUnprepareHeader` 成功；STILLPLAYING 时保留内存。断开时 reset 后也必须完成安全回收，不能用固定延时替代。
3. **资源生命周期与失败可见性**：句柄/结构零初始化；枚举不再为每个临时设备分配泄漏的句柄指针；连接中途失败清理已打开的输入端；发送/打开失败不再静默吞掉；只展示具有输入和输出的原生 MIDI 端点。
4. **会话健壮性**：接收流错误上报并失效会话；原生发送失败中止队列，避免后续请求误收旧回执；非法本地帧在入队前拒绝，避免毒化队列；避免同一错误重复 disconnect。
5. **诊断信息**：设备拒绝附带命令三元组、error 码和 data，不再只显示泛化文字。

Windows 缓冲区释放规则依据：[Microsoft midiOutUnprepareHeader](https://learn.microsoft.com/en-us/windows/win32/api/mmeapi/nf-mmeapi-midioutunprepareheader)。缓冲区尚在驱动队列内时必须保留，不能忽略 STILLPLAYING 后释放。

原实例历史出现多次 STALE 和首次快照不一致。输入乱序是已复现的客户端缺陷，但没有原错误时段的完整线路记录，**不能把全部历史 STALE 都归因于它**；用户/其他端真实改值也会合法触发 STALE。本轮稳定参数条件下未再复现同步错误。

## 实机结果

9 月 15 日原始线路记录已归档：`artifacts/hardware-readonly-20260915.json`。`build/diagnostics/hardware-readonly.json` 会被后续运行替换，不再用作历史证据路径。

- 三次连续连接/重连，revision 均为 20，当前音色均为 01A。
- 每次独立读取 GLOB64 与 PATCH374，与已 ACK 镜像逐字节一致。
- 303 条 TX、312 条 RX；无非法帧、无底层传输错误、无同步重建日志。
- 71 项 TYPE 目录在每次连接读取；128 个预设名称分页读取完成。
- 两条合法设备拒绝均属于鼓机，`allQueriedFeaturesAvailable=false`。测试完成不表示鼓机通过。
- 查询耗时包含 Windows 定时器、协议往返和系统调度，不是声音延迟，也不作为本轮帧性能基准。

鼓机原始报文：

```text
GET 状态 TX: F0 00 59 01 03 01 00 5A F7
         RX: F0 00 59 01 03 01 00 01 5B F7
GET 目录 TX: F0 00 59 01 03 01 20 7A F7
         RX: F0 00 59 01 03 01 20 01 7B F7
```

两条 RX 的帧、XOR、命令匹配均正确，error=01、data 为空。请求与协议一致，无法据此确定是资源未安装、鼓机初始化失败或固件实现差异；需要 `product_sysex.c`、鼓机后端及设备日志继续定位。没有将它误报为“空目录成功”，也没有改用猜测的指令。

## 复测方式

先停止其它占用同一 MIDI 端点的程序，然后明确选择真实端点：

```powershell
flutter test --no-pub test local_packages/flutter_midi_command_windows/test/windows_midi_device_test.dart
flutter drive --no-pub --profile -d windows --driver=test_driver/hardware_readonly.dart --target=integration_test/hardware_readonly_test.dart --dart-define=HARDWARE_AUDIT=true --dart-define=MIDI_DEVICE=SINCO-MIDI
```

实机测试发送层带白名单：允许 GET（排除文件导出 BEGIN/CHUNK）、action03 同步和 ACK；拒绝参数写入、音频动作、文件提交/恢复。不自动改音色或创建效果，不以“同值写入”冒充只读。

当前 VS Code Debug 实例也可用 `tool/inspect_running_device.ps1 -Mode Snapshot` 读取状态，`-Mode Probe` 通过现有串行会话发起基础 GET（结果记入连接诊断日志）。该辅助脚本依赖本机 VS Code connector `127.0.0.1:19192`；不适用于 Release 或未配置 connector 的电脑。

验收结果：`flutter analyze --no-pub` 无问题；全量 59 项自动测试通过（包括 5 项 WinMM 可控测试和 3 项会话错误测试）；Windows 原生只读集成检查完成。未更改固件，未测试手机，也未修改设备参数或执行保存/恢复。

Windows Release 已重新构建并更新至 `APP/Apexis/`；Android APK 未更新。涉及原生缓冲区和句柄生命周期，旧实例应完全停止再启动，不使用热重载跨越此版本。

## 授权写入复测准备（2026-09-15）

用户已明确授权测试机写入。新增 `integration_test/hardware_write_test.dart` 和 `test_driver/hardware_write.dart`：先导出并校验 GT1S/GT1B、落盘备份，再静音测试当前音色参数、效果增删/开关/重排、全局参数、文件取消、调音器、鼓机与空 Looper 的录放清空；结束恢复当前音色与已改全局，并读取整库逐字节核对。不执行恢复出厂、固件刷写、其它音色覆盖或整库导入；已有 Looper 内容时跳过录音清空。

第一次 Profile 实机启动已构建成功，但扫描不到 `SINCO-MIDI`，在任何备份/写入命令之前终止。Windows `Get-PnpDevice -PresentOnly` 也没有 SINCO 设备；历史 SINCO-MIDI / SINCO-AUDIO 条目为 Unknown。这次没有生成设备备份、没有写入参数。随后设备重新出现，已继续测试。重跑时必须使用新的备份目录，例如：

```powershell
flutter drive --no-pub --profile -d windows --driver=test_driver/hardware_write.dart --target=integration_test/hardware_write_test.dart --dart-define=HARDWARE_WRITE_TEST=true --dart-define=MIDI_DEVICE=SINCO-MIDI --dart-define=AUDIT_DIRECTORY=D:/Project/Apexis/artifacts/hardware-write-new-run
```

测试器记录逐项失败后仍执行恢复；最终版本在恢复后汇总失败并返回测试失败。早期 02/03 运行只记录失败，进程仍可能成功，因此必须检查 `report.json` 的每项 `checks`，以及 `restored=true` 的整库恢复证明。测试不代替音频听感、手机 BLE 或全部业务约束的验收。

## 写入发现及修复

`artifacts/hardware-write-20260915-02/` 保存修复前原始记录与两份备份。重新开机后基线 revision=5，音色仍为 01A 空链。修改 BPM、伴奏音量及恢复伴奏音量时，共出现 3 次 `09/00/42 error=8`：

1. WRITE 回执已成功返回新 revision。
2. 设备发送 GLOB64，然后发送同代 PATCH374，属于主动重建当前视图。
3. 客户端仍在 READY 分支，将 GLOB 当普通增量，提前 ACK；设备尚未完成 PATCH，返回 state=1/STALE。

这不是参数真的被另一端修改，也不是传输坏帧。修复在 READY 收到完整 GLOB 或孤立完整 PATCH 时，以 action03 明确重建双段边界，再收齐、ACK 并开放编辑。不重发参数写入，不发布半份镜像，也兼容旧交接说明中恰好完整记录长度的增量。代价是这类事件增加一次同步请求，普通小范围增量不变。

新增 3 项控制器回归：主动完整视图、64B 全局增量、丢失 GLOB 的孤立 PATCH。已有同值写、STALE、分包、BUSY、重连和 UI 回归保留。

## 修复后写入结果

`artifacts/hardware-write-20260915-03/`：19:35:23～19:36:28，基线 revision=20，最终 revision=42，`restored=true`。

- GT1S 386B、GT1B 47956B 导出/CRC 校验/落盘完成；整库导出约 47.4 秒。
- OUTPUT 静音与独立 READ、同值写不增 revision；INPUT、PAN=-23、BPM=97、名称写入通过。
- 伴奏、USB 录音音量、EQ gain、调音 A4 偏移写入与独立 READ 通过。
- TYPE 512 `AI Gate`：添加、参数写入、旁路/启用、重复 TYPE、位置交换、删除通过。不是全 71 TYPE 或 CPU1 资源约束验收。
- 单音色导入上传一片后取消，原音色不变；原 GT1S 提交恢复后重新同步成功。
- 调音器进入/查询/退出通过；Looper 首录、停止完成、播放、停止、清空通过（原 Looper 为空）。未测试叠录/UNDO、真实输入音高、录音内容质量。
- RAM 保存回执通过；未软关机验证 Flash 持久化。
- 所有改过的全局值恢复；最终锁定 revision 读取完整 47936B 参数库，与备份载荷逐字节一致，其它音色未变。
- 0 次 STALE、0 次非法帧/底层传输错误。设备拒绝：2 次参数标签 GET21 error=6（按协议退回原始整数）、1 次鼓机目录 error=1、1 次成功提交后 RESET33 error=1（票据已结束，提交与恢复均已独立验证）。不能把所有非零回执统称为通信损坏。
- 鼓机步骤失败于目录 GET，未继续发 PLAY。**不宣称鼓机启停通过。**

追加验证：`hardware-write-20260915-04` 在整库导出途中于 19:38:46 断连，保护门禁在任何写入前终止测试；本轮无完整 GT1B 备份，不能标记恢复完成。Windows PnP 的 SINCO-MIDI `LastArrivalDate=19:38:53`，说明之后发生了重新枚举；不能单凭它断言是线材、电源、固件复位还是 USB 栈重启。此前 02/03 的 GT1S 与 GT1B 文件 SHA256 分别完全相同，03 的完整恢复证据不受此后只读中断影响。

最终静态检查无问题，62 项自动回归通过。新增“孤立 PATCH”防护已由单测覆盖；其追加实机运行因上述备份阶段断连未进入写入，不混称为完整实机通过。

最终 Windows Release 已重新构建并复制至 `APP/Apexis/`（`data/app.so` 更新时间 19:39:47）；Android APK 未更新。正常 VS Code Debug 已重新启动，不保留实机测试专用窗口。

19:40:46 正常应用重新连接成功：非演示、ready、error=null、71 TYPE、01A 空链。设备 revision 已重新从较小值增长（先读到 7，随后 8）；相对 03 备份，全局无差异，当前 PATCH 仅 INPUT 偏移 350 从 29 变为 30。重连期间没有发送参数写入；保留设备最新值，不在测试结束后自动用旧备份覆盖设备新的变化。整库一致的恢复证明对应 03 测试结束时刻。

## 固件源码交叉核对

本节记录 9 月 15 日的定位过程；当时的依赖仓库权限阻塞已解除，最新结论见下一节。

用户提供仓库 `https://git.sincoaudio.xyz/product/703n_ai/gt1`。只读拉取至 `artifacts/firmware-source/gt1`，未修改、提交、推送或刷写固件。

- 当前 HEAD `d02228b694c057a418d82cb1ea27cf95af97372b` 为 0.2.120-dev，实机仍是 0.2.117-dev；已同时检查以 0.2.117-dev 为首条 CHANGELOG 的历史提交 `0f0c046`。版本字符串不能证明实机二进制与该提交逐字节一致。
- 两个版本的 `apps/business/product_sysex.c` 都明确将完整 GLOB/PATCH 视为两段当前视图，验证了上述客户端提前 ACK 的根因。
- 两个版本的 C_DRUM 分支均先检查 `drum_control`，为空立即返回 result=-1 → error=1。合法的空目录 GET 和状态 GET 都被同样拒绝，与实机证据吻合；不是客户端帧校验或命令编号写错。
- `apps/business/core/product_audio.c` 通过 `music_tools_init` 设置该指针，失败不终止其它音频功能；`local_audio_mode.c` 使用默认 `MUSIC_TOOLS_CONFIG_INIT`。产品文档明确鼓机正式资源交付尚未完成。
- `music_tools_init` 和默认宏的完整定义位于外部 `lib_music_tools`，不在 GT1 仓库；构建依赖外部 `br27_platform`。尝试 GT1 同级地址均不可访问，已询问实际仓库地址。**目前定位到未就绪指针的拒绝分支，不能无日志断言具体是缺资源还是分配/任务初始化失败。** 不用删除判空检查伪造可用鼓机。

## 2026-09-16 续测与交付

### 仓库权限与鼓机初始化链路

三个仓库现均可读取，源码保存在 `artifacts/firmware-source/`；未提交、推送或刷写固件。

- GT1 `origin/main`：`0218eb15f2dc157eec643a518ac754d4cb8f6a1c`，0.2.124-dev。工作目录仍停留于历史 `d02228b`；本次新版对照使用 `git show origin/main:<path>`，不是把旧工作目录当成最新源码。
- `lib_music_tools`：`70fef7242afe6f1e33551c1aba4fb255becb9ee9`；同时对照资源格式变更前的 `f0162c4`。
- `br27_platform`：`22f67e0f0c5954e73ea070fe2611d3f2f2ce0d08`。

对应 0.2.117-dev 的历史 GT1 `local_audio_mode.c` 使用默认 `MUSIC_TOOLS_CONFIG_INIT`，默认宏将鼓型、鼓音源地址置 NULL、长度置 0。`music_tools_asset_get` 对空地址或零长度返回失败；`drum_note_init` 取不到 DRUM_NOTE 时返回 -2，早于音源状态内存分配。`music_tools_init` 随后清理并返回 NULL；`product_audio.c` 允许其他音频功能继续运行，但 `product_sysex.c` 的 C_DRUM 分支在 `drum_control == NULL` 时统一返回 error=1。历史 music 提交中也存在同一资源检查路径。

这是一条能解释两条合法 GET 同时被拒绝的完整源码路径，支持“旧配置没有绑定鼓音源，导致鼓机未初始化”的判断。当前 GT1 主分支已绑定 `gt1_flash_drum_patterns` / `gt1_flash_drum_kit` 并纳入资源清单（16 个鼓音色 WAV、128 个 GDRM 鼓型）。但**源码版本不等于板上二进制**：未取得板上构建指纹或启动串口日志，也尚未验证新版资源在该板的加载结果；不能仅凭源码宣称实机鼓机已修复。

### 客户端补齐与兼容边界

在原有 r2 实现基础上，对照 GT1 主分支 2026-09-15 r5 交接文档；用户根目录的旧 HTML 未被覆盖。

- 固件 0.2.122 起按 64 个厂商 F 音色、64 个用户 U 音色显示；旧版 0.2.117 保留原 01A～32D 编号和 RAM 保存操作。根据设备身份版本判断，不从名称猜测，也不把最新仓库版本套到旧实机。
- F 区当前编辑仅用于试听；保存入口改为另存 U 区。复制目标限制为 U 区、交换限制为 U 与 U；控制器也拦截非法操作，不只禁用 UI。目录 flags bit0 显示未持久化提示；另存不会擅自切换当前音色。新规则仅经模拟兼容回归，当前旧固件无法验收新版持久化行为。
- 增加 UNIT `clear_on_bypass` 开关，仅 TYPE 支持 reset 时可编辑；增加独立 Looper 联动鼓型选择；展示 Looper pending、运行代次和预备拍剩余时间。多条状态 GET 完成后核对页面/会话 epoch，再原子发布，避免迟到响应更新旧页面。
- 鼓机拒绝不再伪装成空目录。页面明确显示设备端不可用、禁用播放并暂停持续失败的自动轮询；保留手动刷新重试。UI/UX 技能用于禁用原因和错误反馈，保留现有主题及手机布局。

### 本轮只读与写入证据

只读报告：`artifacts/hardware-readonly-20260916.json`。三次连接均为真实 `SINCO-MIDI / GT1 0.2.117-dev`，revision=9、当前 01A 空链、71 TYPE；GLOB/PATCH 与独立 READ 一致。鼓机 GET 状态与目录仍为 error=1，`allQueriedFeaturesAvailable=false`。只读采集完成并不意味着所有功能可用。

写入报告及备份：`artifacts/hardware-write-20260916-01/`，09:59:39～10:00:48，基线 revision=9，最终 revision=34，`restored=true`、`allChecksPassed=false`。

- 写入前备份 GT1S 386B、GT1B 47956B，并验证 CRC；所有写入在备份落盘后进行。
- 原有 INPUT/OUTPUT/PAN/BPM/名称、全局 USB/EQ/调音基准、效果增删/重复实例/重排/参数/开关、文件取消、调音器进出、RAM 保存和 GT1S 提交恢复复测通过。
- 完整 374B PATCH 按字段边界原子分包写入成功，独立 READ 一致；旋钮 0 完整映射记录禁用后，READ 和 GET 均验证成功，随后恢复。
- AI Gate 的 `clear_on_bypass=1` 写入和 READ 成功，`clearOnBypassTested=true`；不是声音尾音听感验收。
- 原 Looper 为空；首录、播放、叠录、停止、UNDO、REDO、清空通过，校验运行代次和录音总长；不是音频内容质量验收。
- 鼓机步骤唯一失败于目录 GET `03/01/20 error=1`，未继续发送 PLAY。测试器完成恢复后以失败退出，不把恢复成功误报为全功能通过。
- 所有改动过的全局参数及当前 GT1S 已恢复；锁定最终 revision 读取完整 47936B 参数库，与备份载荷逐字节一致，其他音色未改变。
- TX 2213、RX 2319；无 STALE、无非法帧或底层传输错误。非零设备回执为参数标签 error=6 两次（降级为原始整数）、鼓机 error=1 一次、已提交文件票据的 RESET33 error=1 一次；最后一项发生在成功提交后，整库恢复已独立验证。

### 自动验证与未完成项

`flutter analyze --no-pub` 无问题；`flutter test --no-pub test local_packages/flutter_midi_command_windows/test/windows_midi_device_test.dart` 全部 71 项通过。新增 6 项固件兼容测试和 3 项 UI 测试；原桌面/手机/横屏/平板、大字号、分区重建和协议回归保留。新增旁路开关引起的效果页金图已人工检查并更新，之后全量测试未使用 `--update-goldens`。

Windows Release 已通过 `tool/package_windows.ps1` 构建并更新 `APP/Apexis/`，`data/app.so` 时间为 2026-09-16 10:05:28。EXE 启动壳未改动，不能仅用 EXE 时间戳判断 Dart 程序是否更新；分发仍需整个目录。Android APK 本次未更新。

10:06:50 正常 VS Code Debug 应用重新连接成功：非演示、`ready`、`error=null`、0.2.117-dev、revision=34、01A 空链、71 TYPE；未遗留实机测试窗口，重连未写入参数。日常流畅度体验仍应选择 VS Code 的“Windows 性能模式”，Debug 连接验证不是性能测量。

当时剩余主要阻塞是设备固件部署：需匹配硬件的新版固件及资源包、可靠刷写方式，并在升级后重测鼓机和 F/U 保存语义；该轮未刷机、未恢复出厂、未整库导入。部署与鼓机已在下节完成，其他未完成项仍保留。

## 2026-09-16 15:01：预编译库烧录与实机复测

- 用户选择直接使用平台预编译库。GT1 新增独立 `app-debug-prebuilt` 构建模式；算法未移除。源码专项审计记为 `not_run_prebuilt_mode`，其余平台/接口/链接/身份/内存/资源/Flash 包校验通过。详细过程、产物哈希与旧版备份见 `FIRMWARE_FLASH_PREFLIGHT_20260916.md`。
- 唯一 GT1 MIDI 端点请求软件 BOOT，确认 BR27 `4C4A:3442` 及相同物理 USB 路径后，通过产品 wrapper 烧录。厂商日志包含实际 sector/block 写入、`Download completed.`；UART 和应用协议均识别 `0.2.124-dev`。没有格式化、恢复出厂或整库导入。
- 只读报告：`artifacts/hardware-readonly-post124-20260916.json`。三次重连均 revision 7，71 TYPE，当前 GLOB/PATCH 与独立 READ 一致。24 项查询检查通过，包含鼓机状态/目录及 128 个音色名称；`allQueriedFeaturesAvailable=true`。
- 写入报告与新固件测试基线备份：`artifacts/hardware-write-post124-20260916-01/`。15:00:28～15:01:34，revision 7→32，20 项通过、1 项明确跳过、0 失败；`allChecksPassed=true`、`restored=true`。旧版烧录前备份另存 `artifacts/hardware-backup-20260916-pre124-03/`，没有用新版基线冒充旧版恢复。
- INPUT/PAN/BPM/名称、USB/EQ/调音基准、完整 PATCH 原子写入、旋钮映射、效果添加/参数/旁路/重复/重排/删除、GT1S 取消、调音器、鼓机启停、Looper 首录/播放/叠录/撤销/重做/清空均通过。鼓机先查目录，再 PLAY 并查运行状态，最后 STOP；不再出现旧版 GET error=1。
- 所有修改过的全局字段与当前音色已恢复；独立读取完整 47936 B 参数库，与本次写入前 GT1B 载荷逐字节一致。其它音色没有写入。
- TX 2215、RX 2318，非法帧和底层传输错误均为 0。两次参数标签 error=6 按已有逻辑降级原始整数；一次 error=1 是成功提交 GT1S 后对已退役票据的 CANCEL，不是鼓机失败，整库恢复另行验证。
- 当前是厂家 F01A，因此 `RAM_save_ack` 明确跳过，未擅自另存、复制、交换或覆盖 U 音色。F/U Save As、COPY/MOVE、软关机持久化仍需独立验收。启动仍为 `P boot=-5 (RAM defaults; Flash unchanged)`，旧存储布局未自动迁移。
- 手机 BLE、实际音频听感、全部算法及满容量模型/CPU1 约束、社区/AI/OTA 服务未纳入本轮；模型资源当前为空。DEBUG 010 的 SCSI 曾发生 Windows 31 失步，本轮改用 GT1 MIDI 软件 BOOT 完成烧录，不能将 GT1 成功当成该 DEBUG 控制问题已修复。
