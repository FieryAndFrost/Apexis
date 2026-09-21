# GT1 USB 烧录记录（2026-09-16）

## 最新结果：已使用预编译库烧录 0.2.124-dev

本节取代下方历史记录中的“未烧录/必须提供算法源码”状态。用户选择直接使用配套库；完整算法仍保留，没有用空实现代替算法。

- 新增独立 `app-debug-prebuilt` preset。使用 `br27_platform@22f67e0f0c5954e73ea070fe2611d3f2f2ce0d08` 的配套归档、头文件及清单；原源码审计模式仍保留。
- 构建 12 步及平台接口/归档、最终链接、身份、内存、资源和工厂包校验通过。源码级非 LTO 指令生成专项审计明确记录为 `not_run_prebuilt_mode`，不冒充通过。新增 8 项校验测试、3 项打包回归及真实烧录包复核通过。
- 产物位于 `artifacts/firmware-source/gt1/build-debug-prebuilt/`。ELF SHA256：`eb021dcf1de5963e31ef8533924ba1381452b8f01e17c126497cd8abf8655b5d`；`flash-package/jl_isd.fw` SHA256：`a476438115e8089212d7e90fcd64bde1bd8e0b67d45f265ce978282f7f212996`。
- 工厂镜像 1,302,528 B，实机 Flash 2 MiB；包含 128 鼓型、16 鼓音色，鼓资源 453,365 B；未安装模型。完整资源槽位并未预留，不能据此宣称满容量模型验收。
- 烧录前备份：`artifacts/hardware-backup-20260916-pre124-03/`。GT1S/GT1B CRC 及独立整库 READ 比较通过，`verified=true`、`mutationsStarted=false`；旧版为 0.2.117-dev / revision 5。前两次记录保留，不替代第三次成功备份。
- 用户确认 GT1 仅由 DEBUG 目标 USB 供电。DEBUG 010 连接和供电成功；随后一次 SCSI `target.power(false)` 返回 Windows 31，立即停止该控制链路，没有自动重放。证据：`artifacts/gt1-boot-20260916-pre124-01.*`。
- 保留 USB 直通和供电，通过已核实身份、版本、当前参数及备份的 GT1 MIDI 端点，只发送一次固件支持的 `F0 22 24 35 7D F7`。UART 确认软件 BOOT 请求并复位；BOOT 身份 `4C4A:3442`，物理位置 `PCIROOT(0)#PCI(0803)#PCI(0000)#USBROOT(0)#USB(1)#USB(4)#USB(2)` 与原 GT1 一致。
- 使用产品 wrapper `python -B tools/package_firmware.py --build build-debug-prebuilt --download`。厂商日志确认 2 MiB Flash、实际 sector/block 写入、`Download completed.` 和重启；未使用 `-format`、OTA 或整库导入。PowerShell 未取得子进程退出码，成功判断依据实际下载日志、启动 UART 和后续实机查询，不冒称拿到 exit 0。
- UART 确认 `app_core task entered GT1 0.2.124-dev`、CPU1 online、APP services started；正常 USB `3654:4D55` 及 SINCO-MIDI/SINCO-AUDIO 已恢复。完整证据：`artifacts/gt1-flash-prebuilt-20260916-01.stdout.log`、`.stderr.log`、`.uart.log`。
- 启动日志仍有 `P boot=-5 (RAM defaults; Flash unchanged)`。旧版 128 KiB 与新版 48 KiB F/U 存储布局没有自动迁移；旧备份保留，未假定烧录后旧音色已恢复。
- 烧录后只读测试通过，三次连接均为 0.2.124-dev / revision 7，完整当前视图与独立 READ 一致；鼓机状态和目录正常，`allQueriedFeaturesAvailable=true`。报告：`artifacts/hardware-readonly-post124-20260916.json`。这不代表音频听感、BLE、持久化及所有业务条件验收。

- 15:01 写入测试完成：`artifacts/hardware-write-post124-20260916-01/report.json`，20 项通过、厂家音色 RAM SAVE 1 项跳过、0 失败。鼓机启停、参数及效果链编辑、调音器、Looper 均通过；`allChecksPassed=true`、`restored=true`，完整 47936 B 参数库与新版测试前备份一致。没有将此恢复结果冒充旧版音色迁移成功。F/U 另存/复制/交换及软关机持久化尚未验收。

构建说明见 `artifacts/firmware-source/gt1/docs/PREBUILT_BUILD.md`。

## 14:13 历史续测记录（状态已由上节更新）

- 用户已自行烧录 DEBUG 板。现场 `system.info` 确認 `AC7911B8 / 010 / Sep 14 2026 14:49:40`，正常 USB 身份 `3654:79B8 / JLD00010`，CDC 为 COM5；不再是此前的 WL82 MASKROM 状态。
- 身份、状态、健康、LED、资源查询均 `ok=true`。无过流，控制和 CDC 配置错误为 0，没有活动会话；目标供电为 false、USB 路由为 disconnect。尚无 GT1 正常设备枚举。
- COM5 成功以 3000000 baud、8N1、DTR=true 打开并接收监听 8 秒，收到 0 字符；没有发送串口数据。关闭端口后 SCSI 确认 UART0 为 3000000 baud，读写错误和丢弃计数均为 0，TX 总计仍为 0。原有 RX 累计 6 字节没有增加，不能视为已接收到有效 GT1 日志。
- 已询问 GT1 是否仅由 DEBUG 目标 USB 供电，尚未得到确认；没有操作目标供电、路由或 USBKEY。
- `gt1` 与 `ai_debug` 远端 main 均未更新。DEBUG 远端源码仍是 006，不能把它冒充当前板上 010 的完整源码。
- 重新执行 `cmake --build --preset app-debug --parallel 8`：平台、固件身份、128 鼓型/16 音色资源、最终链接契约通过；第 11/12 步 `verify_mk300_target.py` 因缺少 `lib_algor/src/comm/pitch_amdf.h` 失败，退出码 1。未跳过校验。
- 本轮重建 ELF SHA256：`153cd0dac5303368836b22aa43c8f383c48a75650dc87725159a444d61cac6c1`。它取代下面历史记录中的 ELF，但同样不是全部校验完成的可烧录交付物。
- `product/703n_ai/lib_algor.git` 仍无法访问，已请求实际仓库/本地源码或已校验的 GT1 完整烧录包。所需源码提交仍为 `a2e4a1fb56ca71c8daaabd5d3a0e90b5be5891c7`。
- 本轮未烧录 GT1、未取得新的升级前备份、未验证鼓机固件修复。待供电方式确认后可先恢复 GT1 正常连接及备份；烧录还必须补齐算法源码或合格烧录包。

## 以下为较早准备记录

用户已明确授权烧录并验证通信。当前停在实际写入之前：固件最终目标代码校验缺少算法库源码，且当前在线 USB BOOT 设备身份与 GT1 收据不符。没有发送 BOOT 切换命令、没有运行下载器写 Flash、没有格式化或恢复出厂。

## 已完成

- 将本任务克隆的 GT1 checkout 更新为 `0218eb15f2dc157eec643a518ac754d4cb8f6a1c`（0.2.124-dev），展开完整源码及资源。不是修改旧用户工作目录，源码无本地改动。
- 展开 `br27_platform@22f67e0f0c5954e73ea070fe2611d3f2f2ce0d08`。`verify-package.ps1` 通过，平台 0.2.33-dev、8 个归档、217 个 payload 文件，payload SHA256 `3273089f60381bdd80c3dada5402b3b758a98b0b061a10c427669c05166b847e`。
- 从杰理官方工具链入口下载签名有效的 2.5.2 工具包；只解包，没有执行安装程序或修改系统 PATH。下载来源：`https://pkgman.jieliapp.com/s/win-toolchain`，重定向到 `https://jl-update.oss-cn-shenzhen.aliyuncs.com/2.5.2.exe`。安装包 SHA256 `1ec78e3315a5987d4e82ecd002536c84240e5c832b1875beff7ce55450124ee5`。
- 工具放在 `artifacts/toolchains/jieli-2.5.2/`；新增 `C:/JL/pi32` 目录联接，指向 `D:/Project/Apexis/artifacts/toolchains/jieli-2.5.2/C$/JL/pi32`，满足上游脚本的固定路径。原路径不存在，没有覆盖已有安装。不要删除项目内工具目录后留下悬空联接。
- 解包辅助工具来自 [innoextract 官方下载页](https://constexpr.org/innoextract/)，1.9 Windows 压缩包 MD5 与官网公布值一致；辅助工具保留于 `artifacts/toolchains/innoextract-1.9/`。
- `clang.exe` SHA256 `0ae79bfb1e79018a12f401050674b6ddc90c202bf81a07832e37a73c3a447c25`，与平台库 artifact 记录完全一致。
- CMake `app-debug` 配置通过，`APP_SKIP_AUTO_DOWNLOAD=ON`。产品已完成链接、固件身份/资源 XIP 内容/内存预算/最终链接契约校验。128 鼓型、16 音色，鼓资源 453365 B，位于 512 KiB 预算内。
- 当前链接产物 `artifacts/firmware-source/gt1/build-debug/sdk.elf` SHA256 `ab49b9ae538754f4a378c6f1f2fe809d613c1135c621f6127ae6c8850815abfa`。**它尚不是完成全部校验的交付烧录包，不可直接烧录。**
- 新增升级前专用只读备份入口 `integration_test/hardware_backup_test.dart` 与 `test_driver/hardware_backup.dart`：仅允许读取、同步和文件导出/结束，不允许参数写入或进入 BOOT；保存 GT1S/GT1B 后以独立 revision 锁定的整库 READ 比对。静态检查通过，但本轮尚未运行实机备份；以前的备份不能冒充本次烧录前最新状态。

## 阻塞

1. `verify_mk300_target.py` 会独立编译 CPU1 音频/算法实现，不能仅凭产品成功链接就跳过。补充读取 `lib_audio_app@67f901b33f87986d27bd5faeb2ca72a48f0defc5` 成功；`https://git.sincoaudio.xyz/product/703n_ai/lib_algor.git` 返回“project not found or no permission”。平台所需算法源码提交为 `a2e4a1fb56ca71c8daaabd5d3a0e90b5be5891c7`。需要对应源码读取权限/本地目录，或提供经过同等校验、匹配硬件的完整成品烧录包。不得注释、绕过或伪造校验成功。
2. 当前 `SINCO-MIDI` / `SINCO-AUDIO` 已不在线；出现的是 `WL82 UBOOT1.00 USB Device`，USB `VID_4C4A&PID_8057`。GT1 历史烧录文档记录 `BR27 UBOOT1.00 USB Device`、`VID_4C4A&PID_3442`。不能仅凭同为杰理 BOOT 就认为是同一颗芯片。需要用户确认当前连接硬件，先恢复目标 GT1 的正常应用枚举，再备份并通过已核对的软件入口切换，保留明确身份链路。

## 继续条件和安全边界

- 算法源代码与平台 pin 对齐后重跑完整构建；通过全部目标校验、离线工厂打包和 `package_firmware.py --verify` 后才允许下载。
- 下载使用产品生成的 wrapper，不直接调用上游原始 SDK `download.bat`，不使用 `-format all` 或 `-format vm`。
- 旧版 128 KiB GT1P 与新版 48 KiB F/U 布局不同，仓库明确没有自动原地迁移。需取得最新备份、检查实际打包布局和迁移行为，不假设普通下载自动保留所有旧音色。
- 本机曾出现的 WL82 设备及参考项目里的 WL82 `sdk.elf` 均不属于可替代的 GT1 镜像或目标，不能互刷。
- 烧录后必须重新确认设备身份、独立 READ/WRITE 与恢复、鼓机目录/状态/启停和 F/U 保存语义；下载器成功不是通信或音频验收成功。
