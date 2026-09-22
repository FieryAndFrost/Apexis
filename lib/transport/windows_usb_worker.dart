import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'windows_usb_native.dart';
import 'windows_usb_reader.dart';

List<List<String>> _scan() => using((arena) {
  final buffer = arena<Uint16>(32768);
  final used = arena<Uint32>();
  final error = usbScan(buffer.cast(), 32768, used);
  if (error != 0) throw StateError('WinUSB 枚举失败：$error');
  final result = <List<String>>[];
  var at = 0;
  while (at < used.value && buffer[at] != 0) {
    final path = (buffer + at).cast<Utf16>().toDartString();
    result.add([path, 'GT1 USB']);
    at += path.length + 1;
  }
  return result;
});

/// Serialized ownership of the vendor interface; RX uses a separate isolate.
/// No COM/MIDI APIs, pipe/device resets, retries, or audio interface claims.
void windowsUsbWorker(SendPort host) {
  final commands = ReceivePort();
  Pointer<Void> handle = nullptr;
  WindowsUsbReader? reader;
  var retired = false, settling = true;
  Future<void>? closing;
  final buffer = calloc<Uint8>(244);
  Future<void> close() {
    if (closing != null) return closing!;
    final old = handle;
    handle = nullptr;
    final oldReader = reader;
    reader = null;
    return closing = (() async {
      await oldReader?.close();
      if (old != nullptr) usbClose(old);
    })();
  }

  Future<void> fault(Object error) async {
    host.send(['fault', error.toString()]);
    await close();
  }

  Future<void> open(String path) async {
    await close();
    closing = null;
    settling = true;
    using((arena) {
      final output = arena<Pointer<Void>>();
      final error = usbOpen(path.toNativeUtf16(allocator: arena), output);
      if (error != 0) throw StateError('无法打开 GT1 WinUSB：$error');
      handle = output.value;
    });
    Object? openingFault;
    try {
      reader = await WindowsUsbReader.start(
        handle.address,
        onData: (data) {
          if (!settling && handle != nullptr) host.send(['data', data]);
        },
        onFault: (error) {
          if (reader == null) {
            openingFault = error;
          } else {
            unawaited(fault(error));
          }
        },
      );
      if (openingFault != null) throw openingFault!;
      // Connection-only drain of an already submitted old IN packet.
      // This delay is never inserted between parameter operations.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (retired || handle == nullptr) throw StateError('WinUSB 初始化时已断开');
      settling = false;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> dispatch(dynamic value) async {
    if (retired) return;
    final message = value as List;
    if (message[0] == 'shutdown') {
      retired = true;
      await close();
      calloc.free(buffer);
      commands.close();
      return;
    }
    final sequence = message[1];
    try {
      Object? result;
      switch (message[2]) {
        case 'scan':
          result = _scan();
        case 'open':
          await open(message[3] as String);
        case 'close':
          await close();
        case 'write':
          if (handle == nullptr) throw StateError('WinUSB 未连接');
          final data = (message[3] as List).cast<int>();
          if (data.isEmpty || data.length > 244) throw ArgumentError('帧长度越界');
          buffer.asTypedList(data.length).setAll(0, data);
          final error = usbWrite(handle, buffer, data.length);
          if (error != 0) {
            final failure = StateError('WinUSB 写入失败：$error（不自动重发）');
            await fault(failure);
            throw failure;
          }
        default:
          throw UnsupportedError('未知 WinUSB 操作 ${message[2]}');
      }
      host.send(['reply', sequence, true, result]);
    } catch (e) {
      host.send(['reply', sequence, false, e.toString()]);
    }
  }

  Future<void> tail = Future<void>.value();
  commands.listen((dynamic value) {
    tail = tail.then((_) => dispatch(value));
  });
  host.send(['ready', commands.sendPort]);
}
