import 'dart:async';
import 'dart:typed_data';
import '../transport/transport.dart';
import 'codec.dart';

class DeviceError implements Exception {
  DeviceError(this.code, this.data, {this.request});
  final int code;
  final Uint8List data;
  final Message? request;
  @override
  String toString() {
    final description =
        const {
          1: '设备拒绝该操作，请检查参数或运行状态',
          2: '校验失败',
          3: '报文长度错误',
          4: '设备编号不符',
          5: '组件不支持',
          6: '设备尚未实现此能力',
          7: '设备忙，请稍后重试',
          8: '参数已被其他端修改，正在重新同步',
          9: '应用参数失败，设备可能处于静音状态',
        }[code] ??
        '设备错误 $code';
    String hex(int n) => n.toRadixString(16).padLeft(2, '0').toUpperCase();
    final r = request;
    return r == null
        ? description
        : '$description [${hex(r.component)}/${hex(r.command)}/${hex(r.selector)}, error=${hex(code)}, data=${data.map(hex).join(' ')}]';
  }
}

/// 仅一个待匹配业务请求；通知独立分流。超时后关闭会话，防止迟到
/// 回执被相同三元组的新请求误认。非幂等动作不自动重发。
class ProtocolSession {
  ProtocolSession(
    this.transport, {
    this.requestTimeout = const Duration(seconds: 4),
  }) {
    _rx = transport.bytes.listen(
      _receive,
      onError: (Object e) {
        if (!_valid) return;
        _faults.add(e);
        invalidate();
        unawaited(_disconnectAfterFault());
      },
    );
    _link = transport.connected.listen((v) {
      if (!v) invalidate();
    });
  }
  final DeviceTransport transport;
  final Duration requestTimeout;
  bool get isValid => _valid;

  Future<void> _disconnectAfterFault() async {
    try {
      await transport.disconnect();
    } catch (e) {
      // Cleanup must not become an unhandled asynchronous exception or hide
      // the command/receive error that caused the disconnect.
      if (!_faults.isClosed) _faults.add(e);
    }
  }

  final _decoder = FrameDecoder();
  final _notifications = StreamController<Message>.broadcast(sync: true);
  final _faults = StreamController<Object>.broadcast();
  late final StreamSubscription<List<int>> _rx;
  late final StreamSubscription<bool> _link;
  Future<void> _tail = Future.value();
  Completer<Message>? _pending;
  Message? _request;
  bool _valid = true;
  void Function(Message)? onMatchedReply;
  Stream<Message> get notifications => _notifications.stream;
  Stream<Object> get faults => _faults.stream;
  void _receive(List<int> chunk) {
    if (!_valid) return;
    for (final frame in _decoder.add(chunk)) {
      try {
        final m = Message.parse(frame);
        if (m.notification) {
          _notifications.add(m);
          continue;
        }
        final r = _request;
        if (r != null &&
            m.component == r.component &&
            m.command == r.command &&
            m.selector == r.selector &&
            _pending != null &&
            !_pending!.isCompleted) {
          onMatchedReply?.call(m);
          _pending!.complete(m);
        }
      } catch (e) {
        _faults.add(e);
      }
    }
  }

  Future<Message> command(int c, int op, int s, [List<int> data = const []]) =>
      request(Gt1.frame(c, op, s, data));
  Future<Message> request(Uint8List frame) {
    late final Message request;
    try {
      request = Message.parse(frame, response: false);
    } catch (e, st) {
      return Future.error(e, st);
    }
    final result = Completer<Message>();
    _tail = _tail.then((_) async {
      if (!_valid) {
        result.completeError(StateError('连接会话已失效，请重新连接'));
        return;
      }
      _pending = Completer<Message>();
      _request = request;
      // 在 send 前注册等待者，避免立即回执丢失。
      String hex(int value) =>
          value.toRadixString(16).padLeft(2, '0').toUpperCase();
      final target =
          '${hex(request.component)}/${hex(request.command)}/${hex(request.selector)}';
      TimeoutException timeout(String phase) => TimeoutException(
        '$phase超时 [$target]；结果未确认，请重新连接并读取设备状态，勿重复提交',
        requestTimeout,
      );
      final reply = _pending!.future.timeout(
        requestTimeout,
        onTimeout: () => throw timeout('等待设备回执'),
      );
      try {
        // Future.sync also catches transports that throw before returning a
        // Future, so the reply listener is always installed by Future.wait.
        final sending = Future<void>.sync(
          () => transport.send(frame),
        ).timeout(requestTimeout, onTimeout: () => throw timeout('发送命令'));
        final values = await Future.wait<Object?>([
          reply,
          sending,
        ], eagerError: true);
        final m = values[0] as Message;
        if (m.error != 0) throw DeviceError(m.error, m.data, request: request);
        result.complete(m);
      } catch (e, st) {
        if (e is! DeviceError && _valid) {
          invalidate();
          _faults.add(e);
          unawaited(_disconnectAfterFault());
        }
        result.completeError(e, st);
      } finally {
        _pending = null;
        _request = null;
      }
    });
    return result.future;
  }

  void invalidate() {
    _valid = false;
    _decoder.reset();
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.completeError(StateError('连接已断开'));
    }
  }

  Future<void> dispose() async {
    invalidate();
    await _rx.cancel();
    await _link.cancel();
    await _notifications.close();
    await _faults.close();
  }
}

class CompletedRange {
  CompletedRange(this.revision, this.start, this.raw);
  final int revision, start;
  final Uint8List raw;
}

class RangeAssembler {
  RangeReply? _first;
  final _data = <int>[];
  void reset() {
    _first = null;
    _data.clear();
  }

  CompletedRange? add(RangeReply r) {
    if (r.offset == r.rangeStart) {
      reset();
      _first = r;
    }
    final first = _first;
    if (first == null ||
        first.revision != r.revision ||
        first.rangeStart != r.rangeStart ||
        first.rangeTotal != r.rangeTotal ||
        r.offset != first.rangeStart + _data.length) {
      reset();
      throw const FormatException('通知不连续，需重新同步');
    }
    _data.addAll(r.raw);
    if (_data.length != first.rangeTotal) return null;
    final completed = CompletedRange(
      first.revision,
      first.rangeStart,
      Uint8List.fromList(_data),
    );
    reset();
    return completed;
  }
}
