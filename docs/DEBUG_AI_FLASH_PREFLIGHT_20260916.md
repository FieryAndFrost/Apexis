# DEBUG_AI 自身固件烧录准备（2026-09-16）

## 后续现场验证（用户自行烧录后）

用户已自行烧录并重新连接 DEBUG 板。现场读取确认固件为 **010**，构建时间 `Sep 14 2026 14:49:40`，芯片 `AC7911B8`。USB `3654:79B8`、序列号 `JLD00010`，CDC **COM5**，MIDI `SINCO DEBUG MIDI`。

`system.info/status/health`、`led.status`、`resource.list` 查询全部成功；无过流、控制或 CDC 配置错误。COM5 已验证可按 3 Mbps、8N1 打开，但 8 秒监听未收到 GT1 打印，不代表目标串口链路已通过。

本代理未烧录 DEBUG 板。此前缺失的 WL82 SDK 并未因此被补齐，远端源码仍是 006；不应把现场 010 误记为本机编译的产物。以下保留此前无法构建时的准备记录。

## 用户确认的目标

用户明确要求拉取、编译并烧录 DEBUG_AI 板自身的工程，不是本轮烧录 GT1。
照片可见板号 `JL_AUTO_BURNER_V01`。本轮没有发送 BOOT、Flash 写入、目标供电或 USB 路由控制命令。

## 已完成

- 从 `https://git.sincoaudio.xyz/product/ai_debug.git` fetch，并关闭任务副本的稀疏检出，获取完整工程。
- 远端 main 仍为 `1fb04d320f4614decb6cd23b0ace51636c899d03`；源码版本为 006。
- 本地目录：`artifacts/firmware-source/ai_debug/jl_debug`。
- 阅读构建入口、SDK 依赖清单、固件归档清单及 AI 操作说明。
- 当前 Windows 仅发现一台匹配的 DEBUG MASKROM USB 设备：
  `USB\VID_4C4A&PID_8057\8&62D1915&0&1`。
- 本轮没有发现正常 DEBUG `3654:79B8` 或 COM 串口；这只能说明应用接口没有运行，不能据此判断板子损坏。
- 使用本机 CMake 执行 `cmake --preset debug`，配置阶段失败：
  `Set WL82_PLATFORM_ROOT to the reference SDK's wl82_platform directory`。

## 缺失的构建输入

参考 `ai_debug/jl_debug/docs/ARCHIVE.md` 和 `sdk-reference.json`，需要团队的 `791N_AI`：

```text
791N_AI/
  wl82_platform/   # 参考平台 0.3.49-dev，含 cmake、toolchains、generated、sdk
  lib_platform/src/platform_update.c
  lib_connectivity/src/midi/connectivity_control.c
```

工程没有提交上述 SDK、SDK 库、下载程序及密钥。文档中的 `D:/791N_AI` 不存在于本机。
已检查本机 D:/SDK、D:/芯片烧录相关、D:/Project 内相关文件：有旧 WL82 下载工具，但未找到工程要求的 `Wl82ProductBootstrap.cmake`。
尝试常见的 `product/791N_AI/wl82_platform`、`product/791n_ai/wl82_platform`、`product/wl82_platform`、`product/791n_ai` 等 Git 路径均未能访问；这些猜测路径的失败不能证明实际 SDK 仓库不存在或权限不足。
已向用户请求实际 SDK 仓库地址或本地目录。

## 后续步骤

1. 获取实际 SDK，核对参考清单和构建输入，不使用 GT1 的 BR27 平台替代。
2. 构建并执行离线测试；核对 debug-package 的 post-build 为离线封装，不自动烧录。
3. 保存本次产物哈希，复核唯一的 DEBUG MASKROM 设备和生成的下载命令。
4. 显式烧录 DEBUG 自身，记录下载结果及重新枚举；通过 SCSI system.info 验证版本，并核验 CDC。

本轮结论：源码已拉取，编译被外部 SDK 缺失阻断，尚未生成新固件或烧录任何设备。
