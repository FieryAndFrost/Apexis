# DEBUG USB 掉线：2026-09-20 只读诊断

## 当前实机证据

- GT1 直连此前已完成 6 次整库恢复，其中追加的 5 轮持续约 7 分钟，无意外掉线，详见 `FACTORY_RESET_FIX_20260918.md`。
- 用户重新接入 DEBUG、GT1 接在 DEBUG 上后，Windows 发现集线器 `USB\VID_0424&PID_2512\7&31912F88&0&4`，最后到达时间 10:50:20。
- 该集线器当前 `Status=Error`、`DEVPKEY_Device_ProblemCode=43`，`DEVPKEY_Device_DriverProblemDesc=USB 集线器无法重置。`，驱动服务 USBHUB3。
- DEBUG 设备 `USB\VID_3654&PID_79B8\JLD00010` 的缓存属性显示其父设备正是该集线器；最后到达 10:50:21，最后移除 10:50:28。约 7 秒后被移除。此时没有运行备份恢复、GT1 写入、重烧或设备复位操作。
- 读取时仅该故障集线器 Present，DEBUG 应用、DEBUG MASKROM、GT1 应用均不在 Present 列表；没有可用 DEBUG SCSI/CDC，无法查询本轮版本、USB 计数或 UART。
- 故障集线器父设备是 `USB\VID_05E3&PID_0610\6&2ba7b727&0&1`。拓扑说明故障位于 DEBUG 的上游集线器这一层，不足以仅凭 VID/PID 判定故障元件或责任固件。

## 源码检查及限制

- 本地 `ai_debug` 工作树干净，HEAD 与远端 main 均为 `1fb04d320f4614decb6cd23b0ace51636c899d03`。
- `jl_debug/apps/config/product_config.h` 声明版本 006；9 月 18 日实板 SCSI 身份报告版本 010、build `Sep 14 2026 14:49:40`。当前仓库源码与此前在板版本不匹配，不能把 006 审计结论当作 010 的已证实根因。
- 006 的 `apps/jl_debug_usb.c` 在 USB RESET/BABBLE 回调、SUSPEND、MSC BOT Reset 及无效 CBW 锁定路径调用 `jl_debug_make_safe()`，关闭目标电源、断开目标 USB 路由。这能解释发生上述事件后 GT1 为何消失，但不解释最初是谁触发事件。
- `system.health.usb_resets` 来自端点复位回调 generation，不是带时间和原因的独立 USB 事件日志。仅靠该计数不能反推 USB 复位的最初原因。
- 仓库既有文档记录 SCSI Windows 31 尚未定位，也明确要求同步 USB 抓包和 PC9 日志；不能拿历史问题直接认定本次 Code 43 的原因。

## 离线验证

当前 Python 无 pytest，未安装或修改环境。通过原测试函数直接调用、GCC 编译运行三个测试入口：`test_firmware_runtime`、`test_scsi_usb_descriptors_and_reset_routing`、`test_hardware_and_usb_guards`，均通过。这些覆盖产品 C 的协议/动作/SCSI/USBKEY/指示灯及 USB 描述符/保护路径，不覆盖 USB 硬件时序，也不是在板 010 验证。

## 下一步

先让 DEBUG 单独连接电脑、暂时拔掉 GT1，观察其父集线器是否仍 Code 43，以隔离目标负载与上游枚举问题。取得可用连接后先核验板上实际版本及只读状态。需要与 010 对应的源码/构建来源及独立 PC9 日志，才能继续定位固件时序，不盲目降级烧录 006。

本轮未修改生产固件、未移除安全保护、未发出电源/复位/BOOT/烧录命令。当前目标真实供电状态无法通过控制通道确认。

## 10:55：用户拔掉 GT1、仅保留 DEBUG 后

- 10:55:19～10:55:57 的只读检查没有发现 DEBUG/GT1 应用或 MASKROM；DEBUG 缓存 `IsPresent=false`，最后移除仍为 10:50:28，未观察到重新枚举。
- 这次报错进一步出现在更上游的 `USB\VID_05E3&PID_0610\6&2BA7B727&0&1`：Code 43、`USB 集线器无法重置。`，父设备为 `USB\ROOT_HUB30\5&1ec663a7&0&0`。不能将先前 0424:2512 的状态与现在 05E3:0610 的状态混为一谈。
- 同时此前 Present 的 USB 摄像头和 MediaTek USB 蓝牙接口已不在本次列表；System 日志中 10:52:42、10:52:54 出现 BTHUSB 17，本地蓝牙适配器失败、驱动卸载。这说明故障观测范围不止 DEBUG 的 MIDI/SCSI 接口，但不证明因果起点。
- 不能凭“GT1 已拔掉但设备未恢复”断言已排除 GT1：上游集线器可能仍保持故障状态。下一步让 DEBUG 单独换到电脑另一物理 USB 口，并绕过可绕过的外接扩展坞/集线器，先恢复独立枚举，再做只读固件诊断。
- 未重启/禁用上游集线器或主机控制器，以免影响其他 USB 设备；未收到 DEBUG 版本/健康状态响应，不声称已进行单板 SCSI 稳定性测试。

## 11:31：用户要求检查电脑 USB 接口

- 三个 AMD USB 主机控制器及三个根集线器均由 Windows 报告 OK，主机控制器 ConfigManagerErrorCode 均为 0；这只是系统状态，不构成电气完好证明。
- 05E3:0610 集线器仍 Present 且 Code 43，提示“USB 集线器无法重置。”。这是当前可直接确认的异常节点，不是仅有历史错误记录。
- 缓存拓扑确认 USB 摄像头 1BCF:28C4、蓝牙复合设备 13D3:3585、DEBUG 上游 0424:2512 均位于该异常集线器下，当前均不 Present；DEBUG 位于 0424:2512 的下游。故障覆盖共享上游链路，不只 DEBUG 固件接口。
- 不能从这些只读信息分辨端口物理损坏、供电/信号问题、挂起的集线器或驱动状态；尚未测电压或使用另一台电脑交叉验证。未重启控制器、卸载驱动、改变电源管理设置或进行烧录。

## 14:28～14:29：经用户同意重启异常集线器

- 操作前再次确认唯一目标 `USB\VID_05E3&PID_0610\6&2BA7B727&0&1` Present、Code 43；当前可见磁盘只有内部 NVMe，无 DEBUG/GT1 应用接口。
- 只执行一次 `pnputil /restart-device`，参数为上述完整实例 ID，不使用通配符、设备类、force 或 reboot。命令报告 Device restarted successfully，退出码 0。未重启其他主机控制器、未卸载驱动、未烧固件。
- 14:28:32 集线器、蓝牙、摄像头开始恢复；14:29:03 再查集线器 ProblemCode=0、HasProblem=false。0424:2512 集线器、DEBUG 正常复合设备、大容量存储接口、SINCO DEBUG MIDI、COM5 均重新 Present 且 OK。
- 随后 DEBUG SCSI 四项查询全部 `ok=true`：`system.info` 报 AC7911B8、版本 010、build `Sep 14 2026 14:49:40`；`system.status` 报目标供电 OFF、路由 disconnect、无过流；`system.health` 报 usb_resets=2、control_errors=0、cdc_config_errors=0、overcurrent_trips=0、无活动 session；`system.crash_info` 报 power_on、无寄存器快照。
- 结论：不重烧即可恢复 DEBUG 枚举和程序正常响应，本次无法识别不能归因于“固件已经丢失”。已恢复的是当前链路状态；最初导致集线器无法重置的原因，以及是否会复发，仍未确定。没有打开目标供电或路由，也未复位/烧录 DEBUG 或 GT1。
