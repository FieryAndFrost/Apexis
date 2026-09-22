import 'dart:typed_data';
import 'transport.dart';

class WindowsUsbTransport implements DeviceTransport {
  @override
  Stream<List<int>> get bytes => const Stream.empty();
  @override
  Stream<bool> get connected => const Stream.empty();
  @override
  int get payload => 244;
  @override
  Future<List<DevicePort>> scan() async => [];
  @override
  Future<void> connect(DevicePort port) async =>
      throw UnsupportedError('WinUSB 试验目前仅支持 Windows');
  @override
  Future<void> send(Uint8List frame) async => throw StateError('WinUSB 未连接');
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {}
}
