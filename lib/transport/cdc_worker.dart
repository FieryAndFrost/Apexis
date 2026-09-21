import 'dart:async';
import 'dart:isolate';

/// Only messages cross this boundary; all serial handles/buffers stay in the
/// worker. A synchronous driver call must never run on the Flutter isolate.
class CdcWorker {
  CdcWorker(this.entryPoint, {this.timeout = const Duration(seconds: 5)});
  final void Function(SendPort) entryPoint;
  final Duration timeout;
  final _events = StreamController<List<Object?>>.broadcast();
  Stream<List<Object?>> get events => _events.stream;
  ReceivePort? _receive, _errors, _exits;
  SendPort? _commands;
  Future<void>? _starting;
  Future<void> _tail = Future<void>.value();
  Completer<SendPort>? _ready;
  Completer<Object?>? _reply;
  int _sequence = 0;
  Object? _failure;
  bool _disposed = false;

  Future<void> _start() => _starting ??= (() async {
    _ready = Completer<SendPort>();
    _receive = ReceivePort()
      ..listen((dynamic value) {
        final message = (value as List).cast<Object?>();
        if (message[0] == 'ready') {
          _commands = message[1] as SendPort;
          if (!_ready!.isCompleted) _ready!.complete(_commands);
          // Startup may have completed after its deadline. Retire, do not reuse.
          if (_failure != null || _disposed) _commands!.send(['shutdown']);
        } else if (message[0] == 'reply') {
          if (message[1] != _sequence ||
              _reply == null ||
              _reply!.isCompleted) {
            return;
          }
          if (message[2] == true) {
            _reply!.complete(message[3]);
          } else {
            _reply!.completeError(StateError(message[3].toString()));
          }
        } else if (!_disposed && _failure == null) {
          _events.add(message);
        }
      });
    _errors = ReceivePort()
      ..listen((dynamic error) {
        _fail(StateError('Windows CDC 工作线程异常：$error'));
      });
    _exits = ReceivePort()
      ..listen((_) {
        if (!_disposed && _failure == null) {
          _fail(StateError('Windows CDC 工作线程已退出，请重新启动应用'));
        }
        _receive?.close();
        _errors?.close();
        _exits?.close();
      });
    // Register the ready waiter before spawning, including its error handler.
    final waiting = _ready!.future.timeout(timeout);
    try {
      await Future.wait<Object?>([
        Isolate.spawn(
          entryPoint,
          _receive!.sendPort,
          onError: _errors!.sendPort,
          onExit: _exits!.sendPort,
          errorsAreFatal: true,
          debugName: 'Windows CDC',
        ),
        waiting,
      ], eagerError: true);
    } catch (e) {
      _fail(StateError('Windows CDC 工作线程启动失败：$e'));
      rethrow;
    }
  })();

  void _fail(Object error) {
    if (_failure != null) return;
    _failure = error;
    if (_ready != null && !_ready!.isCompleted) _ready!.completeError(error);
    if (_reply != null && !_reply!.isCompleted) _reply!.completeError(error);
    if (!_disposed) _events.add(['fault', error.toString()]);
    // Do not kill a worker or free native memory while the driver owns it.
    // If the call returns later it can clean up, but never execute more work.
    _commands?.send(['shutdown']);
  }

  Future<Object?> request(String operation, [Object? arguments]) {
    final result = Completer<Object?>();
    _tail = _tail.then((_) async {
      try {
        if (_disposed) throw StateError('Windows CDC 已关闭');
        if (_failure != null) throw _failure!;
        await _start();
        if (_failure != null) throw _failure!;
        if (_disposed) throw StateError('Windows CDC 已关闭');
        final reply = _reply = Completer<Object?>();
        final waiting = reply.future.timeout(timeout);
        _commands!.send(['request', ++_sequence, operation, arguments]);
        try {
          result.complete(await waiting);
        } on TimeoutException {
          final error = StateError(
            'Windows CDC $operation 超时，已停止本次连接；界面仍可操作。'
            '请关闭并重新启动应用，若仍无法连接请检查 GT1 的 CDC 固件和 USB 连接。',
          );
          _fail(error);
          result.completeError(error);
        } finally {
          _reply = null;
        }
      } catch (e, st) {
        if (!result.isCompleted) result.completeError(e, st);
      }
    });
    return result.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _fail(StateError('Windows CDC 已关闭'));
    await _events.close();
  }
}
