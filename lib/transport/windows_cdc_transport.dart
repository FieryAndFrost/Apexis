import 'dart:async';
import 'dart:typed_data';
import 'cdc_worker.dart';
import 'windows_cdc_worker.dart';
import 'transport.dart';

class WindowsCdcTransport implements DeviceTransport {
  WindowsCdcTransport({CdcWorker? worker})
    : _worker = worker ?? CdcWorker(windowsCdcWorker) {
    _events = _worker.events.listen((event) {
      if (_disposed) return;
      if (event[0] == 'data' && _online) {
        _bytes.add((event[1] as List).cast<int>());
      } else if (event[0] == 'fault') {
        _online = false;
        _bytes.addError(StateError(event[1].toString()));
        _connected.add(false);
      }
    });
  }
  final CdcWorker _worker;
  late final StreamSubscription<List<Object?>> _events;
  final _bytes = StreamController<List<int>>.broadcast();
  final _connected = StreamController<bool>.broadcast();
  bool _online = false, _disposed = false;
  bool _hasSession = false;
  int _epoch = 0;
  @override
  Stream<List<int>> get bytes => _bytes.stream;
  @override
  Stream<bool> get connected => _connected.stream;
  @override
  int get payload => 244;
  @override
  Future<List<DevicePort>> scan() async {
    final rows = await _worker.request('scan') as List;
    return rows.map((row) {
      final item = row as List;
      return DevicePort(item[0] as String, item[1] as String, 'USB CDC');
    }).toList();
  }

  @override
  Future<void> connect(DevicePort port) async {
    if (_disposed) throw StateError('CDC 已关闭');
    if (port.kind != 'USB CDC') throw ArgumentError('不是 CDC 端口');
    await disconnect();
    final epoch = _epoch;
    if (_disposed) throw StateError('CDC 已关闭');
    _hasSession = true;
    try {
      await _worker.request('open', port.id);
    } catch (_) {
      if (epoch == _epoch) _hasSession = false;
      rethrow;
    }
    if (_disposed || epoch != _epoch) throw StateError('CDC 连接已取消');
    _online = true;
    _connected.add(true);
  }

  @override
  Future<void> send(Uint8List frame) async {
    if (!_online || _disposed) throw StateError('CDC 未连接');
    if (frame.isEmpty || frame.length > payload) {
      throw ArgumentError('CDC 帧长度必须为 1～244 字节');
    }
    await _worker.request('write', Uint8List.fromList(frame));
  }

  @override
  Future<void> disconnect() async {
    _epoch++;
    final hadSession = _hasSession;
    _hasSession = false;
    _online = false;
    if (hadSession) await _worker.request('close');
    if (!_disposed) _connected.add(false);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await disconnect();
    } catch (_) {
      // A failed driver session may already be retired. Dispose still has to
      // release listeners and let the worker close a late-returning handle.
    } finally {
      await _events.cancel();
      await _worker.dispose();
      await _bytes.close();
      await _connected.close();
    }
  }
}
