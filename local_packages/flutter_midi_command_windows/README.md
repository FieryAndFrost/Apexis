# flutter_midi_command_windows

This is the windows specific implementation of [FlutterMidiCommand](https://pub.dev/packages/flutter_midi_command)

# Apexis 本地修复：Windows MIDI 线程隔离

所有 WinMM 访问（包括枚举、打开、发送、轮询和关闭）由
`win_mm_worker.dart` 中的专用 isolate 执行，UI 通过 `midi_worker.dart`
串行消息队列访问。不要在 UI 中直接实例化 `WindowsMidiDevice`；该类型
只供原生工作线程和缓冲管理测试使用。

单个请求超过 5 秒会使该 worker 会话失效，未发送请求被拒绝、迟到数据
被丢弃；不自动重建 worker 或重放命令，也不强行释放驱动持有的缓冲区。
恢复需重新启动应用，操作系统 MIDI 服务本身挂起时还需排查系统服务。
这修复应用被同步 `midiOutClose` 卡住的路径，不保证修复外部设备固件故障。

回归测试：在此包目录执行 `flutter test`。
