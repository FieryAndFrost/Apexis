# GT1 临时屏蔽蓝牙初始化：实机结果

用户要求“先屏蔽一下蓝牙初始化试试”。本轮已完成代码修改、编译校验、烧录和只读通信验证，没有修改应用 UI 或 DEBUG 固件。

## 固件与验证边界

- 新产物：`artifacts/firmware-source/gt1/build-debug-no-bt/`；原版 `build-debug-prebuilt/` 完整保留，两个包均重新 `--verify` 通过。
- 诊断宏 `PRODUCT_DIAGNOSTIC_SKIP_BT_INIT=1`，保留蓝牙代码链接和受审计缓冲区，跳过实际启动调用；蓝牙状态查询直接返回无连接。USB、音频、CPU1、运行时和保护机制未关闭。
- 协议版本仍为 0.2.124-dev，日志有独立 `DIAG NO-BT` 标记；BLE/Classic/A2DP 暂不可用。
- 2 项预处理测试（每项包含启用/恢复两种状态）通过；12 步构建、内存布局、链接、身份、资源、预编译库和烧录包校验通过。保留源码专项审计未运行与已有栈告警的限制，未跳过失败审计。
- 诊断 ELF SHA256 `e8ded168d9ce8812d03874f658f1b7bbf668cf8fea22462be7183693914a4dab`；`jl_isd.fw` SHA256 `59b7c5a1215423d043a6bcf30b64029680c75d5cca612b4c3fb6bdb5498e2194`。
- 代码和恢复方法：`artifacts/firmware-source/gt1/docs/NO_BT_DIAGNOSTIC_20260917.md`。当前源码默认诊断开关为 1，后续正常功能构建前应明确恢复为 0。

## 实际写入

- 同一 DEBUG 010、原已确认目标 USB 单路供电与物理拓扑；无过流、无会话、无并行 USBKEY。
- 单轮 USBKEY，6 包后 ACK；Windows 确認 GT1 为 `4C4A:3442`，物理端口 `PCIROOT(0)#PCI(0803)#PCI(0000)#USBROOT(0)#USB(1)#USB(4)#USB(2)`。BOOT 工具退出 0。
- 下载前再次限定唯一 GT1 BOOT 身份与位置。产品 `--download` 返回 0，日志实际写 sector/block，`Download completed.` 后重启。Flash 2 MiB、UUID 与之前同一 GT1 相符。
- `ERASE MODE: NONE`，不执行整片格式化、恢复出厂或音色导入。由于此前设备间歇复位，本次没有取得最新参数备份；历史备份保留，不保证未保存音色恢复。

## 结果

- UART 确认 `DIAG NO-BT: Bluetooth stack initialization SKIPPED`，随后 `APP services started`；诊断启动后持续统计至运行时间 80.618 秒，1 次诊断启动、0 次低压复位、0 次看门狗复位、0 次实际蓝牙初始化日志。
- Windows 正常枚举 SINCO-MIDI/SINCO-AUDIO；采集结束关闭 COM5 后的 PnP 查询仍均为 OK。
- Flutter 实机只读检查退出 0：三次连接均为 0.2.124-dev/revision 6，当前视图与独立 READ 相同；24 项查询全部 OK（含系统、参数、音色目录、鼓机、Looper、调音器等）；128 个音色名称读取完成。
- 蓝牙 links 查询成功仅意味着禁用状态应答正确，不表示 BLE 或 A2DP 可用。USB 音频设备枚举和音频运行统计也不等于完成听感验收。
- UART 运行 25.780 秒时有 `RXCSRP(H)_DataError / RXCSRP_DataError`，后续三次连接仍通过；不声称 USB 底层零异常或长期掉线问题已彻底解决。
- 日志文件前半段包含刷写前旧固件及 BOOT 日志：旧固件也曾正常运行约 15 秒，且存在先前低压复位。因此必须从 DIAG 标记后统计诊断结果；不能将此短时对照直接当作已证明蓝牙库是唯一根因。
- 当前保留诊断固件和目标供电/PC 直通，供用户继续验证。下一步可用持续运行结果及供电测量区分蓝牙启动负载、校准/电源配置与电气问题。

## 证据

- `artifacts/gt1-no-bt-20260917-1522.boot.json`
- `artifacts/gt1-no-bt-20260917-1522.stdout.log` / `.stderr.log`
- `artifacts/gt1-no-bt-20260917-1522.uart.log`（180 秒采集窗口，包含烧录准备阶段；不是 180 秒诊断运行）
- `artifacts/gt1-no-bt-20260917-1522.readonly.json`
- 原只读报告另存 `artifacts/hardware-readonly-before-no-bt-20260917-1522.json`。
