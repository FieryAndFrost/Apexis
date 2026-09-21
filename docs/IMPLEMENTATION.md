# Apexis STD 实现说明

最新实机核对与未完成项见 [Windows 实机通信核对](HARDWARE_AUDIT.md)。下文“已实现”表示客户端代码路径存在，不等于全部功能经过实机验收；鼓机当前固件返回拒绝。

依据 `Apexis_STD功能交互设计.xd`、`GT1_APP_PROTOCOL_HANDOFF.html`（2026-09-14 r2）和参考项目 `D:/Project/M-EFCS_All-Pltoform`。

协议文件 SHA256：`EC2D52E2CAADFE312FF09BE58521B561B23C69DB181BDF2D5A7BD87AAB089FF6`。后续文档更新应重新核对，不能静默沿用偏移。

## 2026-09-16 协议补齐与实机续测

已对照 GT1 `origin/main@0218eb1` 的 r5 交接文档补兼容，根目录 r2 HTML 保留原样。0.2.122 起显示 F/U 分区并限制厂商音色保存、复制目标及交换；旧固件沿用原编号和保存语义。目录未持久化 flags、旁路清尾音开关、独立 Looper 联动鼓型、pending/运行代次/预备拍倒计时均已接入。鼓机拒绝会显示原因并暂停自动重试，可手动刷新。UI/UX 技能用于禁用和错误反馈，未更换当前风格。

真实测试机仍为 0.2.117-dev。完整 PATCH 分包、旋钮映射、旁路清尾音以及 Looper 叠录/UNDO/REDO 已实测；测试后整库逐字节恢复，未出现 STALE。鼓机仍被拒绝：依赖仓库已可读取，源码显示旧默认配置未绑定鼓音源，初始化失败后控制指针为空；新版主分支已加入资源，但尚未刷入测试机，也未验证新版实机行为。不要用 APP 端屏蔽错误代替固件修复。

静态检查无问题，71 项自动回归通过，桌面与手机视觉基线已复核。详细备份路径、实机失败项、源码证据和未验收范围见 [实机核对报告](HARDWARE_AUDIT.md) 最后一节。后文较早日期的测试数和权限阻塞均为历史记录。

## 架构

命令路径：`UI → ApexisController → ProtocolSession → DeviceTransport`。

显示路径：`ApexisController → DeviceViewStore → DeviceRegion → 相关可见控件`。分区快照、字段订阅及迁移边界见 [状态架构](STATE_ARCHITECTURE.md)。

- `lib/protocol/codec.dart`：请求/回执、XOR、流重组、u14/s14/u16_7/u32_7、pack7、范围头与完整字段边界。
- `lib/protocol/session.dart`：串行业务队列、独立通知通道、超时会话失效、连续通知范围组装。
- `lib/data/controller.dart`：设备权威镜像、连接/同步/就绪状态机、字段写、结构编辑、目录和元数据、按页面动态状态读取。
- `lib/data/file_transfer.dart`：GT1S/GT1B 的 ticket 会话、nibble 分片、提交/取消/结束与真实传输进度。
- `lib/transport/native_transport.dart`：Android/iOS 私有 BLE GATT；Windows/macOS USB MIDI。按系统报告的 MTU 分包，不加 BLE-MIDI 时间戳，不二次编码 SysEx。
- `lib/transport/demo_transport.dart`：独立内存演示设备，走同一编解码与同步流程。示例 TYPE/参数不用于真实硬件。
- `lib/ui/`：主题、响应式导航、参数、资源、工具、社区占位与设置。

参考项目仅复用了 `local_packages/flutter_midi_command_windows`（保留 LICENSE）。未修改参考项目，也未复制签名、账号或服务端凭证。没有复用其旧设备协议、FFI 内存布局和旧全局状态。

## 已实现功能

| 交互 | 实现 |
|---|---|
| 搜索与连接 | BLE 扫描和权限、USB MIDI 枚举、Notify 先启用、身份和 schema 验证、断线失效、手动重新连接 |
| 效果编辑 | 10 UNIT、实例独立开关、添加/替换/删除、按钮重排、动态参数名称/范围/标签、输入/输出/PAN/BPM |
| 音色 | 分页设备预设目录、选择、名称、另存/复制、交换、RAM 保存状态提示 |
| 资源 | 查询已安装模型目录，匹配 TYPE 后选择；空目录不伪造资源 |
| 全局 | 输出路由、USB 录音模式和混音、伴奏/USB 录音音量、BPM/同步、MIDI 通道 |
| EQ | 低切/高切、4 段 Gain/Frequency/Q、启用、JSON 文件导入导出；曲线仅示意 |
| Looper | 录制/播放/停止/清空/撤销，位置、音量、同步、自动录音、阈值、小节、拍号、预备拍、真实进度查询 |
| 鼓机 | 安装目录、播放/停止、音量、BPM、同步、载入速度、空间效果 |
| 调音器 | 进入/退出、A4 基准、指针和音符、无音高状态；不把原始指针值当作音分 |
| 设置 | 身份/版本、音频连接状态、旋钮映射、15 分钟自动关机、帮助与诊断 |
| 参数文件 | GT1S v1/v2 校验，GT1S/GT1B 导入导出，恢复默认；覆盖前确认，取消不提交 |

## r2 同步约束

1. 新连接清除旧片段，发送 `09/00/42 [03]`。只有匹配的 action03 回执到达后才接纳快照通知，拒绝旧队列尾片。
2. 首次必须收齐同 revision 的 GLOB64 和 PATCH374，且 GLOB.selected 与 PATCH 地址一致。
3. 发出 ACK 不等于就绪；必须确认回执 `error=0 / action=2 / state=3 / revision 匹配` 才发布镜像。
4. 通知和用户输入分开，设备通知不触发写入。完整声明范围收齐才 ACK，视图之外范围也消费。
5. WRITE 在完整字段边界内分片。相同事务使用相同 revision 和 ID；每片回执检查 request_id、filled、total、state。设备忙时退避重试原帧，仍忙则保留重试入口；结构变化或重同步使旧重试失效。
6. STALE 后重新同步，不重放旧编辑。非幂等动作超时不盲重发。超时连接失效，防止旧回执匹配后来的同类命令。
7. 普通拖动显示局部临时值，在松手时发送最终值；确认状态来自设备。未采用每个像素变化都发送的模式。
8. 效果 Mode/Sync/TYPE 等变更使元数据缓存失效；元数据只在编辑页面需要时查询。不会根据 kind 猜测物理单位。

## 设计来源

XD 原始文件保留，解包内容位于 `design/xd/`。2026-09-15 用户选定第一套“现代音频插件”概念稿，当前界面改为石墨黑、薄荷绿与矢量金属旋钮：背景 `#101415`、面板 `#1C2224`、控件底 `#14191B`、强调 `#82EFC5`。保持参数/音色/工具/社区/设置五栏；桌面侧栏、手机竖屏底栏、手机横屏紧凑侧导航。

UI/UX 技能用于响应式布局、点击区域、语义标签、禁用与加载反馈、大字体和减少动画。设计稿优先于技能给出的通用配色建议。使用 Flutter Material 矢量图标。

渲染预览：`design/previews/desktop-effects.png`、`windows-effects.png`（1280×860）、`mobile-effects.png`、`mobile-parameters.png`、`mobile-landscape.png`、`tablet-effects.png`、`controls.png`、`dialog.png`。这些是实际 Flutter widget 渲染，不是生成式概念图。测试加载本机微软雅黑以验证中文布局，字体文件未复制或分发。

### 控件对比度与视觉修订

- 区分装饰边界 `border` 和交互边界 `controlBorder`，显式配置完整滑杆轨道、开关、按钮、选项、输入框与弹窗，避免依赖 Material 默认深色配色。
- 主要、辅助及状态文字在五种背景上对比度至少 4.5:1；轨道和交互边界对相邻表面至少 3:1，由 `test/theme_test.dart` 自动验证。薄荷绿实心按钮使用深色文字。
- 侧栏选中底色使用独立 Material 承载，避免墨水层绘制在不透明容器后；选中效果同时显示边框与“编辑中”，选项显示勾选，不仅靠颜色。
- 桌面效果参数与音色控制使用 5:3 布局，旋钮网格根据实际宽度采用 3 / 2 / 1 列；手机默认双列，极窄屏和大字体单列。效果链放不下时单行横向浏览，不拆散处理顺序，自动展示当前选中项。手机音色操作合并到“…”菜单。
- 效果链支持鼠标直接拖拽卡片排序，边缘自动滚动，触屏长按后拖动。删除参数区“向前移动/向后移动”按钮；保留右键“放到第 N 位”、Alt + 方向键及原生排序语义作为替代操作。拖动过程仅本地预览，松手后只提交一次链顺序，等待回复期间拦截重复拖动，失败恢复确认顺序，不修改 UNIT 内容或选中项。音色/链结构变化会取消过期拖动。
- 效果参数与输入/输出/声像/BPM 使用 `RotaryControl`；其它设置保留直观的滑杆并统一换肤。旋钮为 Flutter `CustomPainter` 矢量绘制，不包含位图贴图、外部字体或动画依赖。
- 旋钮向上拖动增大、向下拖动减小，横向拖动不调节；仅松手提交。旋钮外仍可纵向滚动页面。指针取消、禁用、零范围、断开不提交，保留 48dp 加减按钮、数值输入、焦点/方向键/Home/End 和读屏增减操作。输入值按设备原始整数范围校验，INPUT/PAN 显示使用明确的协议换算。
- 参数控件将提交锁与等待外观分离：立即阻止重复写入，但前 500 ms 保持旋钮、滑条和加减按钮原有颜色，不追加省略号；超过阈值才显示等待样式。断开或外部禁用立即生效。回复后采用实际回读值，失败回到已确认值；完成及销毁时取消计时器。`test/parameter_feedback_test.dart` 覆盖快速/慢速回复、重复点击、拒绝写入、断开与销毁。
- 预设选择、重命名、确认和旋钮输入弹窗允许内容滚动；SafeArea 避开系统状态栏和手势区域。
- UI/UX 技能用于层级、颜色对比度、状态和可访问性检查；未采纳不适合原生效果器控制器的营销页模板，也未增加外部字体或动画依赖。
- 通信协议、参数范围和连接状态机保持不变。源码运行方式不变，VS Code 增加不固定平台的手机调试启动项。

第一套风格验证：静态检查、协议/文件测试、对比度与旋钮交互测试，以及全部 8 个页面在 320×640、375×812、768×1024、812×375、1440×900 和 1 / 2 倍字号下的布局检查。测试禁用动画；只有深色主题，未宣称实现浅色主题。原生触摸、读屏器和真实硬件通信仍需实机验收。

2026-09-15 本次验收：`flutter analyze --no-pub` 无问题，`flutter test --no-pub` 32 项通过；额外验证手机 44px 顶部、34px 底部安全区及音色操作菜单。Windows Release 与 Android Debug 安装包已重新构建，输出仍为 `APP/Apexis/` 和 `APP/Apexis-debug.apk`。Android 系统栏通过 `AnnotatedRegion<SystemUiOverlayStyle>` 使用浅色图标；iOS 尚未在本机构建。

## 验证边界与后续联调

### 实机读写联调修订（2026-09-15）

- Windows MIDI 输入按驱动队列顺序消费；输出等待驱动释放所有权后回收内存。连接/发送失败、接收流异常均可见，错误包含命令三元组。
- 实机复现写入 BPM/全局值后收到主动 GLOB+PATCH 完整视图，旧 READY 分支提前 ACK GLOB，产生 STALE。现对完整记录通知重新 action03 建立双段边界，收齐并确认后才发布；孤立 PATCH 同样不能被误认完整视图。
- 用户授权后已实测当前音色写入、AI Gate 增删/参数/开关/重排、全局参数、GT1S 取消及提交恢复、调音器、空 Looper 基本录放清空。完整 GT1B 备份落盘；恢复后锁定 revision 读取整库，逐字节一致。
- 鼓机仍被固件拒绝。已只读检查用户提供的 GT1 仓库，定位到 `drum_control == NULL` 拒绝分支；具体初始化原因尚需外部 `lib_music_tools` 与资源/运行日志，不删除判空来假报成功。
- 62 项自动回归通过、静态检查无问题，Windows Release 更新至 `APP/Apexis/`；Android 未更新。后续追加实机备份曾遇 USB 重新枚举，在写入前安全中止，不能承诺链路不再中断。原始报文、逐项结果及限制见 [实机核对报告](HARDWARE_AUDIT.md)。

### 设置间距与页签动效修订

- 设置页为“应用信息”显式预留 20px 上方间距，单双列保持一致；`responsiveColumns` 的既有调用行为不变。
- 参数/工具子页签选中背景水平滑动，桌面主导航选中背景垂直滑动（180ms，easeOutCubic）；连续点击从当前动画位置转向新目标。通过 `FractionalTranslation` 做绘制位移，代替逐帧改变布局的 `AnimatedAlign`，背景与导航内容分别隔离重绘。
- 整页位移动画已恢复（240ms、6% 位移），首帧完成后再启动动画计时，避免新页构建/布局消耗动画时长；使用 `RepaintBoundary` 复用内容绘制，不叠加旧页交互控件。参数子页按左右方向、桌面主导航按上下方向滑入。连续切换会废弃过期的首帧回调。
- 重绘计数回归复现：原实现连续 6 个动画帧会额外调用内容 paint 6 次，修改后为 0 次。这是绘制行为测试，不是实际设备 FPS 或卡顿完全消除的证明。VS Code 增加 `Apexis · Windows 性能模式`（profile），便于运行时帧性能验证。
- 系统减少动画时内容与指示器直接切换；重复点击当前页签不重复查询或播放动画。手机底部导航沿用原生导航动效。
- 桌面侧栏移除 `IntrinsicHeight` 和 `Spacer`，改为最小视口高度配合 `spaceBetween`，避免额外的固有尺寸计算；短窗口和大字号仍能滚动。
- 2026-09-15 从用户正在运行的 Windows Debug VM 时间线取得诊断样本：LAYOUT P95 35.769ms、BUILD P95 21.691ms、PAINT P95 3.503ms、GPU Draw P95 3.199ms；timeDilation 为 1。样本包含调试开销，不是受控基准，也不能单凭这些数值把瓶颈归因到某个控件。临时开启的详细布局分析已恢复关闭。读取消耗统计可使用 `tool/measure_windows_frames.ps1 -VmServiceUri <当前 VM Service URI>`，不清空时间线。
- 返回效果页复用仍然有效的参数元数据，不再无条件 `selectUnit` 清空参数列表，避免控件先移除再重建。设备快照、TYPE/UNIT 变化和重新同步的既有失效机制保留；无有效参数时，子页签和主导航返回均重新查询。回归测试覆盖复用时不查询、失效后必须查询。
- `RetainedPageViewport` 按需保留访问过的页面（最多 12 页），不提前创建未访问页面；返回时保留滚动位置、更新当前控件数据。隐藏页不绘制、不接收焦点和指针、关闭 ticker，不随活动页通知重建；切换设备会话或音色编号、断连时清理缓存。隐藏期间取消旋钮/滑杆草稿，迟到的拖动结束回调不可提交。测试覆盖元素复用、参数失效、隐藏焦点/ticker/提交以及断连清理。
- 新增独立 Windows Profile 演示导航回归：`integration_test/navigation_performance_test.dart`，使用真实 vsync 帧、预热一轮后切页 30 次，不连接硬件；结果通过 driver 写入 `build/performance/`。测试不能代替实机通信与输入端到端延迟验收。Android APK 尚未包含本轮间距和动画优化。
- 本轮静态检查无问题，45 项自动测试通过，Windows Release 已重新打包至 `APP/Apexis/`；Android APK 未更新。
- 原生 Profile 样本（相同演示设备、预热一轮、30 次切页、整页动画开启）：保留页面前 UI 帧 P99 18.111ms、最慢 31.768ms、11/780 帧超过 16.7ms；最终复测 P99 10.526ms、最慢 18.918ms、3/1568 帧超时，GPU 最慢 4.149ms、无超时。中间缓存版本曾测得 0/1440 超时，但以最终复测为准，不宣称完全消除掉帧。结果分别在 `build/performance/navigation-after.json` 和 `navigation-final.json`；单轮测量受系统负载、调度和帧数波动影响，不是端到端延迟或刷新率保证。Windows driver 已收到并保存结果；SDK 在 Windows 输出的 integration_test 原生插件提示不影响本次 driver 结果回传。

### 分区状态架构修订（2026-09-15）

- 新增不可变 `DeviceSnapshot` 和分区 `DeviceViewStore`，一次完整发布后只通知变化分区；主界面不再监听 Controller 全局通知。字段投影将参数、全局控件、EQ、调音和 LOOP 进一步隔离。
- 导航改用本地状态，切 Tab 不重建外壳和顶栏；隐藏页取消数据订阅，返回时读取最新快照。保留现有滑动动画、页面缓存、手机布局和减少动画支持。UI/UX 技能用于明确状态更新边界，未更换当前视觉风格。
- 去除关闭调音器时的无效查询及相同轮询结果通知，丢弃离开页面后的过期响应/异常。协议 ACK、revision/epoch、写入门禁与文件事务保持不变；目录查询仍沿用全局 busy 协调，未放开协议并发。
- `flutter analyze --no-pub` 无问题，`flutter test --no-pub` 全部 51 项通过，包含实际区域构建计数与既有视觉/响应式回归。新状态存储在 Controller 构造时初始化，升级后必须停止应用再重新启动，不能只热重载。
- 本轮 Windows Release 构建与打包成功，已更新 `APP/Apexis/`；Android APK 未重新构建。运行和分发需保留完整目录，不能只复制 EXE。
- 同轮导航对照：改造前 UI P99 11.638ms、峰值 17.799ms、3/770 帧超过 16.7ms；改造后首次测量为 11.639ms、18.411ms、3/774 帧。没有证据表明此次状态拆分明显改善切页首帧。
- 最终 Profile 复测记录于 `build/performance/architecture-final.json`：30 次导航 UI P99 10.814ms、峰值 22.717ms，4/1560 帧超过 16.7ms；栅格化峰值 4.328ms。该次屏幕报告 144Hz（约 6.94ms/帧），按此周期 UI 有 44 帧超预算，栅格化为 0；不能用 60Hz 阈值宣称高刷新率完全流畅。
- 同一实际窗口中，50 次间隔 100ms 的模拟调音更新仅产生 50 次指针区域构建、3 次调准颜色相关音符区域构建，其它区域为 0。采集的 728 个帧样本 UI P99 1.048ms、峰值 1.476ms，栅格化峰值 3.157ms，均未超过 144Hz 单阶段帧预算。采集帧数包含实时测试帧，不等于数据更新次数；此为演示数据测试，不是实机音高检测或端到端延迟测试。

2026-09-14 本机验证：`flutter analyze` 无问题，`flutter test` 22 项通过；Windows Release 已构建并打包至 `APP/Apexis/`。测试覆盖 r2 的 10 条报文、整数/pack7 边界、坏帧、通知缺片、ACK 就绪门禁、旧快照丢弃、BUSY/STALE、20/197 B 载荷、原子分片写、文件往返/取消以及页面在 375×812、812×375、1440×900 和两倍字体下的布局。

Windows 交付程序通过后台启动存活检查，检查进程已关闭；Web 演示构建通过（`flutter build web --dart-define=DEMO=true`）。页面渲染检查使用 Flutter widget tests，尚未代替原生设备触摸和硬件通信联调。

Android 在修正 Kotlin 跨盘符配置后重新构建成功，交付 `APP/Apexis-debug.apk`。应用 ID `com.apexis.apexis`，版本 `1.0.0+1`，最低 API 24，目标 API 36，包含 arm64-v8a、armeabi-v7a、x86_64。此包用于开发与联调，不是正式发布签名。

自动测试使用设备模拟器，不代表硬件验收。需要实机确认：Android/iOS 权限和 BLE 吞吐、不同手机重连、USB 不拔线重开程序、三端同时编辑、重型效果 CPU1 限制、音频听感、软关机持久化、文件提交后音频恢复。

社区、账号、反馈后台、云音色、AI 生成、音轨分离引擎、OTA、模型/IR/鼓音源上传尚未提供项目所需的服务接口，本实现保留明确不可用状态。参考项目中对应业务不能假定与 Apexis 账号和固件兼容。

固件没有 USB 回放独立音量字段，因此没有将设计稿中的“USB 音量”错误映射成 USB 录音音量。只有已定义的伴奏与 USB 录制音量可调。

Android 开发 APK 使用 debug 签名；未配置发布签名。iOS/macOS 工程与配置已生成，需在 macOS/Xcode 上构建和签名。浏览器仅用于演示预览，设备通信运行原生应用。

Windows Android 构建：本机 Pub 缓存在 C:、项目在 D:，Kotlin 增量缓存会报 `this and base files have different roots`。仅在本工程 `android/gradle.properties` 关闭 Kotlin 增量编译并使用进程内编译，避免跨盘符缓存错误；未修改全局 Gradle 或参考项目设置。

依赖 API 核对：[flutter_blue_plus 1.36.8](https://pub.dev/packages/flutter_blue_plus/versions/1.36.8)、[flutter_midi_command 0.5.3](https://pub.dev/packages/flutter_midi_command/versions/0.5.3)，文件选择 API 以本地锁定的 file_picker 11.0.3 源码为准。
