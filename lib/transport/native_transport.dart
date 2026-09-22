import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:permission_handler/permission_handler.dart';
import 'transport.dart';
import 'usb_unsupported.dart'
    if (dart.library.ffi) 'windows_usb_transport.dart';

class NativeTransport implements DeviceTransport {
  bool get mobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  final _bytes = StreamController<List<int>>.broadcast();
  final _connected = StreamController<bool>.broadcast();
  late final _midi = MidiCommand();
  WindowsUsbTransport? _usb;
  StreamSubscription<List<int>>? _usbBytes;
  StreamSubscription<bool>? _usbState;
  BluetoothDevice? _ble;
  BluetoothCharacteristic? _write;
  MidiDevice? _midiDevice;
  StreamSubscription<List<int>>? _notify;
  StreamSubscription<BluetoothConnectionState>? _bleState;
  StreamSubscription<MidiPacket>? _midiRx;
  Timer? _monitor;
  bool _checking = false;
  int _connectionGeneration = 0;
  @override
  Stream<List<int>> get bytes => _bytes.stream;
  @override
  Stream<bool> get connected => _connected.stream;
  @override
  int get payload => _ble == null ? 244 : max(20, min(197, _ble!.mtuNow - 3));

  @override
  Future<List<DevicePort>> scan() async {
    if (kIsWeb) throw UnsupportedError('浏览器预览使用演示模式；设备连接请运行原生应用');
    if (!mobile) {
      // Windows uses only the GT1 vendor interface; never open WinMM/COM.
      if (defaultTargetPlatform == TargetPlatform.windows) {
        return (_usb ??= WindowsUsbTransport()).scan();
      }
      final devices = await _midi.devices ?? [];
      return devices
          .where(
            (d) =>
                d.type == 'native' &&
                d.inputPorts.isNotEmpty &&
                d.outputPorts.isNotEmpty,
          )
          .map((d) => DevicePort(d.id, d.name, 'USB MIDI'))
          .toList();
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      final grants = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      if (grants[Permission.bluetoothScan]!.isPermanentlyDenied ||
          grants[Permission.bluetoothConnect]!.isPermanentlyDenied) {
        throw StateError('蓝牙权限被拒绝，请在系统设置中允许附近设备权限');
      }
    }
    await FlutterBluePlus.adapterState
        .where((s) => s == BluetoothAdapterState.on)
        .first
        .timeout(
          const Duration(seconds: 8),
          onTimeout: () => throw StateError('请开启蓝牙并允许蓝牙权限'),
        );
    final found = <String, DevicePort>{};
    Object? scanFailure;
    final sub = FlutterBluePlus.onScanResults.listen(
      (results) {
        for (final r in results) {
          final name = r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : r.device.platformName;
          found[r.device.remoteId.str] = DevicePort(
            r.device.remoteId.str,
            name.isEmpty ? '未命名 BLE 设备' : name,
            'BLE',
            rssi: r.rssi,
          );
        }
      },
      onError: (Object error) {
        scanFailure = error;
      },
    );
    try {
      // 不按 AE40 广播过滤：设备可能只广播 BLE-MIDI 服务。
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 6),
        androidUsesFineLocation: true,
      );
      await FlutterBluePlus.isScanning.where((v) => !v).first;
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
    if (scanFailure != null) throw StateError('扫描失败：$scanFailure');
    return found.values.toList()
      ..sort((a, b) => (b.rssi ?? -100).compareTo(a.rssi ?? -100));
  }

  @override
  Future<void> connect(DevicePort port) async {
    await disconnect();
    final generation = _connectionGeneration;
    try {
      if (port.kind == 'USB WinUSB') {
        final usb = _usb ??= WindowsUsbTransport();
        _usbBytes = usb.bytes.listen(_bytes.add, onError: _bytes.addError);
        _usbState = usb.connected.listen((online) {
          if (!online && generation == _connectionGeneration) {
            _connected.add(false);
          }
        });
        await usb.connect(port);
        if (generation != _connectionGeneration) throw StateError('连接已取消');
      } else if (port.kind == 'BLE') {
        final device = _ble = BluetoothDevice.fromId(port.id);
        await device.connect(timeout: const Duration(seconds: 12), mtu: 200);
        _bleState = device.connectionState.listen((state) {
          if (state == BluetoothConnectionState.disconnected) {
            _connected.add(false);
          }
        });
        final services = await device.discoverServices();
        final service = services
            .where((s) => s.uuid == Guid('AE40'))
            .firstOrNull;
        if (service == null) throw StateError('设备未提供 GT1 AE40 控制服务');
        _write = service.characteristics
            .where((c) => c.uuid == Guid('AE41'))
            .firstOrNull;
        final tx = service.characteristics
            .where((c) => c.uuid == Guid('AE42'))
            .firstOrNull;
        if (_write == null ||
            tx == null ||
            !_write!.properties.writeWithoutResponse ||
            !tx.properties.notify) {
          throw StateError('设备 AE41/AE42 特征不兼容');
        }
        _notify = tx.onValueReceived.listen(
          _bytes.add,
          onError: _bytes.addError,
        );
        await tx.setNotifyValue(true);
      } else {
        final devices = await _midi.devices ?? [];
        if (generation != _connectionGeneration) throw StateError('连接已取消');
        final device = devices.where((d) => d.id == port.id).firstOrNull;
        if (device == null) throw StateError('MIDI 端点已移除');
        _midiDevice = device;
        _midiRx = _midi.onMidiDataReceived?.listen((p) {
          if (p.device.id == device.id) _bytes.add(p.data);
        }, onError: _bytes.addError);
        await _midi.connectToDevice(device);
        if (generation != _connectionGeneration) throw StateError('连接已取消');
        _monitor = Timer.periodic(const Duration(seconds: 1), (_) async {
          if (_checking) return;
          _checking = true;
          try {
            final current = await _midi.devices ?? [];
            if (generation != _connectionGeneration) return;
            if (!current.any((d) => d.id == device.id)) {
              _monitor?.cancel();
              _connected.add(false);
            }
          } catch (e, st) {
            if (generation == _connectionGeneration && !_bytes.isClosed) {
              _bytes.addError(e, st);
            }
          } finally {
            _checking = false;
          }
        });
      }
      _connected.add(true);
    } catch (_) {
      if (generation == _connectionGeneration) await disconnect();
      rethrow;
    }
  }

  @override
  Future<void> send(Uint8List frame) async {
    if (_usbBytes != null) {
      await _usb!.send(frame);
    } else if (_write != null) {
      final size = payload;
      for (var at = 0; at < frame.length; at += size) {
        await _write!.write(
          frame.sublist(at, min(at + size, frame.length)),
          withoutResponse: true,
        );
      }
    } else if (_midiDevice != null) {
      // GT1 帧已经 MIDI-safe，不再使用参考项目的二次 SysEx 编码。
      _midi.sendData(frame, deviceId: _midiDevice!.id);
    } else {
      throw StateError('设备未连接');
    }
  }

  @override
  Future<void> disconnect() async {
    _connectionGeneration++;
    _monitor?.cancel();
    _monitor = null;
    await _usbBytes?.cancel();
    await _usbState?.cancel();
    _usbBytes = null;
    _usbState = null;
    final usb = _usb;
    _usb = null;
    await usb?.dispose();
    await _notify?.cancel();
    await _bleState?.cancel();
    await _midiRx?.cancel();
    _notify = null;
    _bleState = null;
    _midiRx = null;
    _write = null;
    final ble = _ble;
    _ble = null;
    if (ble != null) await ble.disconnect();
    final midi = _midiDevice;
    _midiDevice = null;
    if (midi != null) _midi.disconnectDevice(midi);
    if (!_connected.isClosed) _connected.add(false);
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _usb?.dispose();
    await _bytes.close();
    await _connected.close();
  }
}
