import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'windows_cdc_native.dart';

final _waitForMultipleObjects = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<
      Uint32 Function(Uint32, Pointer<IntPtr>, Int32, Uint32),
      int Function(int, Pointer<IntPtr>, int, int)
    >('WaitForMultipleObjects');

/// One event-driven reader per connection. The owner must await [close] before
/// closing the serial handle. No polling timer and no native wait on the UI.
class WindowsCdcReader {
  WindowsCdcReader._(this._stop, this._data, this._fault);

  final int _stop;
  final void Function(Uint8List) _data;
  final void Function(Object) _fault;
  final _messages = ReceivePort();
  final _ready = Completer<void>();
  final _stopped = Completer<void>();
  bool _closing = false, _failed = false;
  Future<void>? _closingFuture;

  static Future<WindowsCdcReader> start(
    int handle, {
    required void Function(Uint8List) onData,
    required void Function(Object) onFault,
  }) async {
    final stop = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    if (stop == 0) throw StateError('CDC 停止事件创建失败：${GetLastError()}');
    final reader = WindowsCdcReader._(stop, onData, onFault);
    // Register error handling before spawning: startup can fail before the
    // parent resumes from Isolate.spawn (e.g. missing native dependency).
    final readiness = reader._ready.future.then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    reader._messages.listen(reader._message);
    try {
      await Isolate.spawn(
        windowsCdcReadLoop,
        [handle, stop, reader._messages.sendPort],
        onExit: reader._messages.sendPort,
        onError: reader._messages.sendPort,
        errorsAreFatal: true,
        debugName: 'Windows CDC event RX',
      );
    } catch (_) {
      reader._messages.close();
      CloseHandle(stop);
      rethrow;
    }
    try {
      final error = await readiness;
      if (error != null) throw error;
      return reader;
    } catch (_) {
      await reader.close();
      rethrow;
    }
  }

  void _message(dynamic message) {
    if (message == null) {
      if (!_stopped.isCompleted) _stopped.complete();
      if (!_closing && !_failed) _error(StateError('CDC 接收线程已退出'));
    } else if (message is List && message[0] == 'ready') {
      if (!_ready.isCompleted) _ready.complete();
    } else if (message is List && message[0] == 'data') {
      if (!_closing && !_failed) _data(message[1] as Uint8List);
    } else {
      _error(StateError('CDC 接收失败：$message'));
    }
  }

  void _error(Object error) {
    if (_failed || _closing) return;
    _failed = true;
    if (!_ready.isCompleted) {
      _ready.completeError(error);
    } else {
      _fault(error);
    }
  }

  Future<void> close() => _closingFuture ??= (() async {
    _closing = true;
    SetEvent(_stop);
    // Exit is sent only after cancellation completes and native RX memory is
    // released. Never kill the isolate/free buffers while a driver owns them.
    await _stopped.future;
    _messages.close();
    CloseHandle(_stop);
  })();
}

/// Also exercised against a real Windows overlapped named pipe in tests.
void windowsCdcReadLoop(List<Object> args) {
  final handle = args[0] as int, stop = args[1] as int;
  final host = args[2] as SendPort;
  GetLastError(); // Resolve the lazy binding before the first failing API call.
  final buffer = calloc<Uint8>(4096);
  final count = calloc<Uint32>();
  final overlapped = calloc<OVERLAPPED>();
  final events = calloc<IntPtr>(2);
  var pending = false;
  try {
    final event = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    if (event == 0) throw StateError('创建接收事件：${GetLastError()}');
    overlapped.ref.hEvent = event;
    events[0] = stop; // Stop wins if both events are signaled.
    events[1] = event;
    host.send(['ready']);
    while (WaitForSingleObject(stop, 0) == WAIT_TIMEOUT) {
      ResetEvent(event);
      final error = cdcRead(handle, buffer, 4096, overlapped);
      if (error != 0) {
        if (error != ERROR_IO_PENDING) throw StateError('ReadFile：$error');
        pending = true;
        final result = _waitForMultipleObjects(2, events, FALSE, INFINITE);
        if (result == WAIT_OBJECT_0) break;
        if (result != WAIT_OBJECT_0 + 1) {
          throw StateError('等待 CDC 数据：${GetLastError()}');
        }
      }
      final completion = cdcResult(handle, overlapped, count, FALSE);
      if (completion != ERROR_IO_INCOMPLETE) pending = false;
      if (completion != 0) throw StateError('完成 CDC 读取：$completion');
      if (count.value > 0) {
        host.send([
          'data',
          Uint8List.fromList(buffer.asTypedList(count.value)),
        ]);
      }
    }
  } catch (e) {
    host.send(['fault', e.toString()]);
  } finally {
    if (pending) {
      CancelIoEx(handle, overlapped);
      // CancelIoEx only requests cancellation; wait for actual completion.
      cdcResult(handle, overlapped, count, TRUE);
    }
    if (overlapped.ref.hEvent != 0) CloseHandle(overlapped.ref.hEvent);
    calloc.free(events);
    calloc.free(overlapped);
    calloc.free(count);
    calloc.free(buffer);
  }
}
