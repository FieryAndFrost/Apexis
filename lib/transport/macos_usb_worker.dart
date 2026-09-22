import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'macos_usb_native.dart';
import 'macos_usb_reader.dart';

List<List<String>> _scan() => using((arena) {
  final ids = arena<Uint64>(128);
  final count = arena<Uint32>();
  final error = macUsbScan(ids, 128, count);
  if (error != 0) throw StateError('macOS USB 枚举失败：${macUsbError(error)}');
  if (count.value > 128) throw StateError('macOS USB 枚举结果越界');
  return [
    for (var index = 0; index < count.value; index++)
      ['iokit:${ids[index]}', 'GT1 USB'],
  ];
});

/// Serialized ownership of the vendor interface; RX uses a separate isolate.
/// No COM/MIDI APIs, pipe/device resets, retries, or audio interface claims.
void macosUsbWorker(SendPort host) {
  final commands = ReceivePort();
  Pointer<Void> handle = nullptr;
  MacosUsbReader? reader;
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
      if (old != nullptr) macUsbClose(old);
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
      final id = RegExp(r'^iokit:([1-9][0-9]*)$').firstMatch(path);
      if (id == null) throw ArgumentError('不是有效的 GT1 IOKit 端口');
      final error = macUsbOpen(int.parse(id[1]!), output);
      if (error != 0) {
        throw StateError('无法打开 GT1 macOS USB：${macUsbError(error)}');
      }
      handle = output.value;
    });
    Object? openingFault;
    try {
      reader = await MacosUsbReader.start(
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
      if (retired || handle == nullptr) throw StateError('macOS USB 初始化时已断开');
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
          if (handle == nullptr) throw StateError('macOS USB 未连接');
          final data = (message[3] as List).cast<int>();
          if (data.isEmpty || data.length > 244) throw ArgumentError('帧长度越界');
          buffer.asTypedList(data.length).setAll(0, data);
          final error = macUsbWrite(handle, buffer, data.length);
          if (error != 0) {
            final failure = StateError(
              'macOS USB 写入失败：${macUsbError(error)}（不自动重发）',
            );
            await fault(failure);
            throw failure;
          }
        default:
          throw UnsupportedError('未知 macOS USB 操作 ${message[2]}');
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
