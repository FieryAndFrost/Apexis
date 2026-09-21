import 'dart:async';
import 'dart:typed_data';

class DevicePort {
  const DevicePort(this.id, this.name, this.kind, {this.rssi});
  final String id, name, kind;
  final int? rssi;
}

abstract class DeviceTransport {
  Stream<List<int>> get bytes;
  Stream<bool> get connected;
  int get payload;
  Future<List<DevicePort>> scan();
  Future<void> connect(DevicePort port);
  Future<void> send(Uint8List frame);
  Future<void> disconnect();
  Future<void> dispose();
}
