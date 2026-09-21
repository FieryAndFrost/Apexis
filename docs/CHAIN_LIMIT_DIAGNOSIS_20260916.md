# GT1 多效果失去响应诊断（2026-09-16）

## 结论与边界

已获得可重现的同类故障：GT1 0.2.124-dev，在当前空音色上依次添加 TYPE 2313 `Room stereo`，显式重新选择当前音色以启用实时效果处理；前两个分别运行 6 秒且系统 GET 正常，添加第三个后无回执，4 秒请求超时。UART 从此持续 `timer_no_response: app_core`，USB 仍枚举正常。

这不是“第九个槽位必然越界”：10 个 Volume 添加通过，同类混响在安全旁路下可建立 9 个，第 10 个返回 error=1。不能将旁路下的创建容量等同于实际处理容量。

强证据指向实时音频 CPU 预算不足/调度饥饿：一只 Room 的稳定窗口处理峰值 `p554 us`，两只为 `p1097 us`；48 kHz / 64 点对应 1333.3 us 的持续帧周期。第三只启用后主任务的五秒诊断也停止，系统定时器持续报告它不响应。同样三个实例在旁路下能够创建，故不足以解释为纯实例数量或纯分配容量限制。

尚未取得卡住时 PC/任务堆栈，不能把精确阻塞函数或每一条算法路径当作已证明。原用户随机 8→9 的效果组合未知；本次复现的是同类不响应症状，不宣称还原原组合。当前没有修复或重刷固件。

## 证据

测试入口：`integration_test/hardware_chain_limit_test.dart`，独立 driver：`test_driver/hardware_chain_limit.dart`。先备份并通过独立整库 READ 验证；仅当前音色 RAM 修改，不 SAVE、不格式化、不写其它音色、不导入整库、不切 BOOT。每次添加之前落盘 type、顺序和 revision，另行持续记录 COM5 / 3 Mbaud UART。

| 目录后缀 | 结果 |
| --- | --- |
| `hardware-chain-limit-20260916-01` | Volume 连续 10 个通过。混合链第 9 个 Volume 的添加本身 error=0，同步阶段因 revision 连续变化返回 STALE；期间 OUTPUT 字段通知变化，不是持续死机。最终恢复操作已提交，但测试器把历史同步错误误当恢复失败。第二轮整库 READ 证明基线完全恢复。 |
| `hardware-chain-limit-20260916-02` | 连续 4 个 Clean Stereo 通过，第 5 个明确拒绝 error=1，无超时。恢复已提交，测试器仍持有上一条拒绝错误；第三轮独立整库 READ 证明恢复。拒绝后固件进入安全旁路，因此之后必须重新激活效果链才能测实时负载。 |
| `hardware-chain-limit-20260916-03` | 修正诊断恢复判断后，禁用旋钮的单字节写被客户端完整字段校验拦截，未执行新增效果。已改为完整 10 字节映射写；本轮整库恢复验证为 true。这是测试脚本问题，不作为固件故障证据。 |
| `hardware-chain-limit-20260916-04` | 安全旁路下 9 个 Room 创建通过，第 10 个 error=1；独立整库验证恢复 true。不算实时运行通过。 |
| `hardware-chain-limit-20260916-05` | 验证上一轮完整基线后，禁用两只旋钮映射、输出音量设 0，并重新选择当前音色激活处理。15:37:49 添加第 1 个、15:37:56 第 2 个，均正常；15:38:02 第 3 个超时，持续主任务不响应。未能恢复当前 RAM，restored=false。 |

目录均位于 `artifacts/`，各自有 `report.json` 和 `before.gt1s` / `before.gt1b`。对应 UART 为 `artifacts/gt1-chain-limit-20260916-01.uart.log` 至 `-05.uart.log`。从第三轮起可复用上一轮备份文件，但必须以当前整库独立 READ 完全一致为前提，记录 `backupSource` / `previousBaselineVerified`；不是伪称重新执行了导出。

第五轮最后一条实际上线路的 TX：`F0 00 59 01 01 00 01 02 09 12 41 F7`，即 UNIT 2 / TYPE 2313；后面没有重发或恢复写包。测试器曾因 UI 的 ready 标志尚未更新而进入恢复函数，但被已失效 ProtocolSession 在发送前拒绝；已补充 TimeoutException/失效会话直接跳过恢复的诊断保护。报告原样保留，不改写为成功。

## 相关代码路径

- `apps/business/core/product_control.h`：10 个 UNIT 槽、独立 3 个 CPU1 stage 限制。
- `apps/business/product_control.c`：配置校验→静音→锁定→整池重建→恢复模式；构建失败转安全旁路。当前入口没有完整组合的实时 CPU 预算准入检查。
- `apps/business/core/preset_nav.c:Preset_chg_proc`：重新选择当前音色可在成功加载后 `eff_run()`，用于退出构建失败后的安全旁路，不必改其它音色。
- `br27_platform/sdk/apps/soundbox/audio/adc2dac_passthrough.c`：`audio_task` 持续从 frame semaphore 取帧并处理；耗时诊断只统计超限，没有据此实现控制任务可恢复的过载保护。
- `apps/app_main.c`：音频 `usr_audio` priority 20，业务 `app_core` priority 1。需进一步用运行时调度/任务现场确认精确饥饿路径。

后续修复方向应是重负载可恢复性：实时预算检测、超载时可安全停止/旁路且保留控制响应、拒绝过载组合并反馈原因；不能只把 UI 数量上限改成 8。任何修复后必须复测轻量十实例、重型少实例、混合链、资源拒绝、恢复和声音表现。

## 当前设备状态

第五轮重现后设备仍上电且 USB 枚举存在，但主任务不响应；已关闭诊断测试进程和串口采集，没有自动断电、重发添加、保存或重刷。第五轮 RAM 修改未恢复，需要用户重新上电后先核对完整基线。正常软关机可能将测试状态保存，当前不发送软关机命令。
