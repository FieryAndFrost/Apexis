import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';

import 'package:flutter_midi_command_windows/ble_midi_device.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:win32/win32.dart';
import 'package:device_manager/device_event.dart';
import 'package:device_manager/device_manager.dart';
import 'midi_worker.dart';
import 'win_mm_worker.dart';

const bool _kLogComm = false;
void _log(String msg) {
  if (_kLogComm) debugPrint(msg);
}

class FlutterMidiCommandWindows extends MidiCommandPlatform {
  final _rxCtrl = StreamController<MidiPacket>.broadcast();
  final _setupCtrl = StreamController<String>.broadcast();
  final _bleCtrl = StreamController<String>.broadcast();

  late final Stream<MidiPacket> _rxStream = _rxCtrl.stream;
  late final Stream<String> _setupStream = _setupCtrl.stream;
  late final Stream<String> _bleStream = _bleCtrl.stream;

  final Map<String, MidiDevice> _connected = {};
  final Set<String> _opening = {}, _closing = {};
  final MidiWorker _worker;
  final Map<String, BLEMidiDevice> _bleDev = {};
  String _bleState = 'unknown';

  // ─── 单例 ───

  factory FlutterMidiCommandWindows() =>
      _instance ??= FlutterMidiCommandWindows._();

  static FlutterMidiCommandWindows? _instance;

  FlutterMidiCommandWindows._() : _worker = MidiWorker(winMmWorkerMain) {
    _listenWorker();
    _initDeviceManager();
  }

  @visibleForTesting
  FlutterMidiCommandWindows.forTesting(this._worker) {
    _listenWorker();
  }

  void _reportError(Object error) {
    debugPrint('Windows MIDI: $error');
    if (!_rxCtrl.isClosed) _rxCtrl.addError(error);
  }

  void _listenWorker() {
    _worker.events.listen((event) {
      if (event[0] == 'data') {
        final device = _connected[event[1]];
        if (device != null && !_rxCtrl.isClosed) {
          _rxCtrl.add(MidiPacket(event[2] as Uint8List, 0, device));
        }
      } else if (event[0] == 'error' || event[0] == 'fault') {
        _reportError(StateError(event[1].toString()));
        if (event[0] == 'fault') {
          for (final device in _connected.values) {
            device.connected = false;
          }
          _connected.clear();
          if (!_setupCtrl.isClosed) _setupCtrl.add('deviceDisconnected');
        }
      }
    });
  }

  static void registerWith() {
    MidiCommandPlatform.instance = FlutterMidiCommandWindows();
  }

  // ─── 热插拔监听 ───

  void _initDeviceManager() async {
    await Future.delayed(const Duration(seconds: 3));
    DeviceManager().addListener(() {
      final ev = DeviceManager().lastEvent;
      if (ev == null) return;
      if (ev.eventType == EventType.add) {
        _setupCtrl.add('deviceAppeared');
      } else if (ev.eventType == EventType.remove) {
        _setupCtrl.add('deviceDisappeared');
      }
    });
  }

  // ─── 设备枚举 ───

  @override
  Future<List<MidiDevice>> get devices async {
    final result = <String, MidiDevice>{};
    final descriptors = await _worker.request('scan') as List;
    for (final descriptor in descriptors) {
      final id = descriptor['id'] as String;
      final device = MidiDevice(id, descriptor['name'] as String, 'native',
          _connected.containsKey(id));
      for (final p in descriptor['inputs'] as List) {
        device.inputPorts.add(MidiPort(p[1] as int, MidiPortType.IN));
      }
      for (final p in descriptor['outputs'] as List) {
        device.outputPorts.add(MidiPort(p[1] as int, MidiPortType.OUT));
      }
      result[id] = device;
    }

    result.addAll(_bleDev);
    return result.values.toList();
  }

  // ─── 连接 ───

  @override
  Future<void> connectToDevice(MidiDevice device,
      {List<MidiPort>? ports}) async {
    if (device.type == 'native') {
      if (_closing.contains(device.id) || !_opening.add(device.id)) {
        throw StateError('MIDI 端口正在连接或关闭，请稍后重试');
      }
      try {
        if (_connected.containsKey(device.id)) return;
        await _worker.request('connect', device.id);
        // disconnectDevice() may have cancelled this opening while awaiting.
        if (!_opening.contains(device.id)) {
          throw StateError('MIDI 连接已取消');
        }
        device.connected = true;
        _connected[device.id] = device;
        if (!_setupCtrl.isClosed) _setupCtrl.add('deviceConnected');
        _log('WinMIDI: connected "${device.id}" '
            '(total=${_connected.length})');
      } finally {
        _opening.remove(device.id);
      }
    } else if (device is BLEMidiDevice) {
      device.connect();
    }
  }

  @override
  void disconnectDevice(MidiDevice device, {bool remove = true}) {
    if (device.type == 'native') {
      final wasOpening = _opening.remove(device.id);
      final d = _connected.remove(device.id);
      device.connected = false;
      if (d != null) d.connected = false;
      if ((d != null || wasOpening) && _closing.add(device.id)) {
        if (!_setupCtrl.isClosed) _setupCtrl.add('deviceDisconnected');
        unawaited(_worker
            .request('disconnect', device.id)
            .then<void>((_) {}, onError: (Object e) => _reportError(e))
            .whenComplete(() {
          _closing.remove(device.id);
        }));
      }
    } else if (device is BLEMidiDevice) {
      device.disconnect();
    }
  }

  // ─── 发送 ───

  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    if (deviceId != null) {
      _log('WinMIDI: sendData → "$deviceId", '
          'connected=${_connected.keys.toList()}');
      final native = _connected[deviceId];
      if (native != null) _sendNative(native, data);
      var delivered = native != null;
      for (final d in _bleDev.values) {
        if (d.deviceId == deviceId) {
          d.send(data);
          delivered = true;
        }
      }
      if (!delivered) {
        throw StateError('MIDI endpoint is not connected: $deviceId');
      }
    } else {
      for (final d in _connected.values) {
        _sendNative(d, data);
      }
      for (final d in _bleDev.values.where((e) => e.connected)) {
        d.send(data);
      }
    }
  }

  void _sendNative(MidiDevice device, Uint8List data) {
    // Copy at enqueue time so later caller mutation cannot alter a frame.
    unawaited(_worker
        .request('send', [device.id, Uint8List.fromList(data)]).then<void>(
            (_) {},
            onError: (Object e) => _reportError(e)));
  }

  // ─── 流 ───

  @override
  Stream<MidiPacket>? get onMidiDataReceived => _rxStream;

  @override
  Stream<String>? get onMidiSetupChanged => _setupStream;

  // ─── BLE ───

  @override
  Future<void> startBluetoothCentral() async {
    UniversalBle.timeout = const Duration(seconds: 10);
    UniversalBle.onAvailabilityChange = (s) {
      _bleState = s.name;
      _bleCtrl.add(s.name);
    };
    UniversalBle.onScanResult = (r) {
      if (!_bleDev.containsKey(r.deviceId) && r.name != null) {
        _bleDev[r.deviceId] = BLEMidiDevice(r.deviceId, r.name!, _rxCtrl);
        _setupCtrl.add('deviceAppeared');
      }
    };
    UniversalBle.onConnectionChange = (id, ok, _) {
      if (_bleDev.containsKey(id)) {
        if (ok) {
          _bleDev[id]!.connectionState = BleConnectionState.connected;
          _setupCtrl.add('deviceConnected');
        } else {
          _bleDev.remove(id);
          _setupCtrl.add('deviceDisconnected');
        }
      }
    };
    UniversalBle.onValueChange = (id, _, data) => _bleDev[id]?.handleData(data);
    UniversalBle.onPairingStateChange =
        (id, paired) => _bleDev[id]?.pairingState = paired;
  }

  @override
  Stream<String>? get onBluetoothStateChanged => _bleStream;

  @override
  Future<String> bluetoothState() async => _bleState;

  @override
  Future<void> startScanningForBluetoothDevices() async {
    try {
      await UniversalBle.startScan(
          scanFilter: ScanFilter(withServices: [MIDI_SERVICE_ID]));
    } catch (e) {
      _log('BLE scan error: $e');
    }
  }

  @override
  void stopScanningForBluetoothDevices() => UniversalBle.stopScan();

  @override
  void teardown() {
    for (final d in _connected.values) {
      d.connected = false;
    }
    _connected.clear();
    _opening.clear();
    unawaited(_worker.dispose());
    _setupCtrl.add('deviceDisconnected');
    _rxCtrl.close();
  }

  @override
  void addVirtualDevice({String? name}) {}

  @override
  void removeVirtualDevice({String? name}) {}

  @override
  Future<bool?> get isNetworkSessionEnabled async => false;

  @override
  void setNetworkSessionEnabled(bool enabled) {}

  // 保留兼容性（轮询模式不再需要此方法）
  MidiDevice? findMidiDeviceForSource(int src) => null;
}

String midiErrorMessage(int status) {
  switch (status) {
    case MMSYSERR_ALLOCATED:
      return 'Resource already allocated';
    case MMSYSERR_BADDEVICEID:
      return 'Device ID out of range';
    case MMSYSERR_INVALFLAG:
      return 'Invalid dwFlags';
    case MMSYSERR_INVALPARAM:
      return 'Invalid pointer or structure';
    case MMSYSERR_NOMEM:
      return 'Unable to allocate or lock memory';
    case MMSYSERR_INVALHANDLE:
      return 'Invalid handle';
    default:
      return 'Status $status';
  }
}
