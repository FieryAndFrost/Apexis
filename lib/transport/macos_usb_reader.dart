import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'macos_usb_native.dart';

/// One blocking RX isolate per connection. Reads complete on packet arrival;
/// idle timeouts only bound shutdown. The owner must await [close] before free.
class MacosUsbReader {
  MacosUsbReader._(this._handle, this._data, this._fault);

  final int _handle;
  final void Function(Uint8List) _data;
  final void Function(Object) _fault;
  final _messages = ReceivePort();
  final _ready = Completer<void>();
  final _stopped = Completer<void>();
  bool _closing = false, _failed = false;
  Future<void>? _closingFuture;

  static Future<MacosUsbReader> start(
    int handle, {
    required void Function(Uint8List) onData,
    required void Function(Object) onFault,
  }) async {
    final reader = MacosUsbReader._(handle, onData, onFault);
    // Register error handling before spawning: startup can fail before the
    // parent resumes from Isolate.spawn (e.g. missing native dependency).
    final readiness = reader._ready.future.then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    reader._messages.listen(reader._message);
    try {
      await Isolate.spawn(
        macosUsbReadLoop,
        [handle, reader._messages.sendPort],
        onExit: reader._messages.sendPort,
        onError: reader._messages.sendPort,
        errorsAreFatal: true,
        debugName: 'macOS USB RX',
      );
    } catch (_) {
      reader._messages.close();
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
      if (!_closing && !_failed) _error(StateError('macOS USB 接收线程已退出'));
    } else if (message is List && message[0] == 'ready') {
      if (!_ready.isCompleted) _ready.complete();
    } else if (message is List && message[0] == 'data') {
      if (!_closing && !_failed) _data(message[1] as Uint8List);
    } else {
      _error(StateError('macOS USB 接收失败：$message'));
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
    macUsbStop(Pointer<Void>.fromAddress(_handle));
    // Exit is sent only after cancellation completes and native RX memory is
    // released. Never kill the isolate/free buffers while a driver owns them.
    await _stopped.future;
    _messages.close();
  })();
}

/// A blocking native wait runs only on this dedicated RX isolate.
void macosUsbReadLoop(List<Object> args) {
  final handle = Pointer<Void>.fromAddress(args[0] as int);
  final host = args[1] as SendPort;
  final buffer = calloc<Uint8>(64);
  final count = calloc<Uint32>();
  try {
    final read = macUsbRead;
    host.send(['ready']);
    while (true) {
      final error = read(handle, buffer, 64, count);
      if (error == 1) break; // Owner requested stop; idle read is bounded.
      if (error != 0) throw StateError('macOS USB 读取失败：${macUsbError(error)}');
      if (count.value > 64) throw StateError('macOS USB 接收长度越界');
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
    calloc.free(count);
    calloc.free(buffer);
  }
}
