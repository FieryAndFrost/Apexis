# DEBUG 目标意外断电：固件专项审计

## 范围与版本

本轮仅检查 DEBUG 固件及主机控制库，不修改设备供电、路由、USB 电源管理，不复位、不烧录。不将 Windows 上游掉线直接归因于硬件，也不把可能的固件断电路径冒充此次已确定的触发原因。

- 在板身份：AC7911B8，010，构建 `Sep 14 2026 14:49:40`。
- 2026-09-21 重新执行远端 heads/tags 查询：`ai_debug.git` 仅公布 main `1fb04d320f4614decb6cd23b0ace51636c899d03`，无 tag；本地工作树干净，`PRODUCT_VERSION_TEXT` 为 006。
- 因版本不一致，以下源码发现及离线测试适用于 006；不能声称已证明 010 同样执行这些路径。
- 本次在板只读信息：目标供电 OFF、路由 disconnect；control_errors=0、cdc_config_errors=0、overcurrent_trips=0、usb_resets=2、session_active=false；reset_reason=256/power_on，没有寄存器快照。

## 源码确认的机制

1. `apps/jl_debug_usb.c::jld_usb_isr`：SUSPEND 立即调用 `jl_debug_make_safe()`；RESUME 只清除挂起标志并唤醒任务，不恢复目标供电。
2. `jld_endpoint_reset` 与 `jld_usb_worker` 的 USB generation 更新分支：调用同一个安全收尾。存储类 BOT Reset (`jld_control_interface`，0x21/0xff) 也执行该收尾，不仅重置存储接口。
3. `jld_control_poll`：非法 CBW 进入 BOT_LOCKED 时增加 control_errors 并安全收尾。此路径与 USB/SUSPEND 的无 control_errors 路径需区分。
4. `jl_debug_make_safe` → `jld_actions_safe`：关闭目标供电、两个继电器并执行 `jld_safe_apply`，后者断开目标 USB、停止 USBKEY、清理 UART/GPIO。不需要过流条件。
5. `apps/jld_actions.c`：已显式开启的 session 到期或 session.close 会安全收尾；没有活动 session 时，普通空闲本身不会自动断电。
6. `apps/hw/product_hardware.c::jl_debug_hardware_init`：每次初始化默认目标供电 OFF、USB 路由 disconnect，没有恢复先前供电配置的逻辑。
7. `host/jl_debug/client.py::DebugControl.close` 仅关闭传输句柄，不发送 session.close 或 target.power；不能把只读脚本退出本身当成断电命令。

## 判断

对连续给 GT1 供电的使用场景，006 将主机 USB 通信事件与目标断电直接绑定：一次挂起或接口恢复即可让 GT1 消失，恢复通信后仍保持断电。这是需要审视的固件策略；仓库文档明确将其作为安全策略，不能仅凭存在此路径就称为随机内存崩溃或认定它触发了今天的事件。

现有 `system.health` 没有最近关电原因/时间、suspend 计数或每次安全收尾记录；`system.crash_info` 只有芯片最近复位原因，不是目标电源变化记录；trace 是最近命令，不是完整的异步事件日志。因而“无过流、无控制错误”不能排除 USB 事件触发的固件关电，也不能在这些状态上确定事件先后因果。

## 本轮离线验证

使用 Windows 原生 GCC `D:/SDK/QT6/Tools/mingw1310_64/bin/gcc.exe`，直接编译实际 006 C 源码；硬件输出使用桩，不连接/操纵实板。

`artifacts/debug-firmware-audit-20260921/power_policy_probe.c` 的四项断言全部通过：

- 无 session 的空闲 tick 不关电。
- safe 调用在过流计数为零时关电，后续 tick 不恢复供电。
- 显式 session 超时关闭供电、清除 session，但不增加过流计数。
- 过流是单独的关电路径并增加计数。

重新运行仓库 `test_firmware_runtime`（5 个原生可执行测试）、`test_scsi_usb_descriptors_and_reset_routing`、`test_hardware_and_usb_guards`，全部通过。BOT Reset 测试明确断言会调用安全收尾。这证明当前实现行为和既有测试预期一致，不代表真实 USB 时序/长时间稳定性通过，更不是 010 实板复现。

## 下一步需要的输入与修正方向

需要用户实际烧入的 010 完整工程路径或对应 Git 提交；远端当前没有公布该版本。编译还需该版本匹配的 WL82 平台输入，不以 GT1 的 BR27 SDK 替代。

拿到对应源码后，优先补可查询的关电原因、事件时间/计数及启动标识，区分 USB suspend/reset、BOT recovery、session expiry、explicit off 和 overcurrent。随后按产品要求区分正常 PC 通信模式与烧录/受控会话模式的断电策略；过流、明确断电、烧录安全收尾仍保留。不能盲删所有 `make_safe`，也不能在未知故障后循环强制上电。

本轮没有修改生产固件或应用代码，没有生成或烧录新的 DEBUG 固件。
