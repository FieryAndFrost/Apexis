import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'windows_usb_native.dart';

/// One event-driven reader per connection. The owner must await [close] before
/// closing the USB handle. No polling timer and no native wait on the UI.
class WindowsUsbReader {
  WindowsUsbReader._(this._stop, this._data, this._fault);

  final int _stop;
  final void Function(Uint8List) _data;
  final void Function(Object) _fault;
  final _messages = ReceivePort();
  final _ready = Completer<void>();
  final _stopped = Completer<void>();
  bool _closing = false, _failed = false;
  Future<void>? _closingFuture;

  static Future<WindowsUsbReader> start(
    int handle, {
    required void Function(Uint8List) onData,
    required void Function(Object) onFault,
  }) async {
    final stop = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    if (stop == 0) throw StateError('WinUSB 停止事件创建失败：${GetLastError()}');
    final reader = WindowsUsbReader._(stop, onData, onFault);
    // Register error handling before spawning: startup can fail before the
    // parent resumes from Isolate.spawn (e.g. missing native dependency).
    final readiness = reader._ready.future.then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    reader._messages.listen(reader._message);
    try {
      await Isolate.spawn(
        windowsUsbReadLoop,
        [handle, stop, reader._messages.sendPort],
        onExit: reader._messages.sendPort,
        onError: reader._messages.sendPort,
        errorsAreFatal: true,
        debugName: 'Windows WinUSB event RX',
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
      if (!_closing && !_failed) _error(StateError('WinUSB 接收线程已退出'));
    } else if (message is List && message[0] == 'ready') {
      if (!_ready.isCompleted) _ready.complete();
    } else if (message is List && message[0] == 'data') {
      if (!_closing && !_failed) _data(message[1] as Uint8List);
    } else {
      _error(StateError('WinUSB 接收失败：$message'));
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

/// A blocking native wait runs only on this dedicated RX isolate.
void windowsUsbReadLoop(List<Object> args) {
  final handle = args[0] as int, stop = args[1] as int;
  final host = args[2] as SendPort;
  final buffer = calloc<Uint8>(64);
  final count = calloc<Uint32>();
  try {
    // Load the library before declaring readiness.
    final read = usbRead;
    host.send(['ready']);
    while (WaitForSingleObject(stop, 0) == WAIT_TIMEOUT) {
      final error = read(
        Pointer<Void>.fromAddress(handle),
        buffer,
        64,
        count,
        stop,
      );
      if (error == ERROR_OPERATION_ABORTED &&
          WaitForSingleObject(stop, 0) == WAIT_OBJECT_0) {
        break;
      }
      if (error != 0) throw StateError('WinUSB 读取失败：$error');
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
    // usbRead does not return until any pending native operation is completed.
    calloc.free(count);
    calloc.free(buffer);
  }
}
