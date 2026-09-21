import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'cdc_device_filter.dart';
import 'windows_cdc_reader.dart';
import 'windows_cdc_native.dart';

void _check(int result, String operation) {
  if (result == 0) {
    throw StateError('$operation 失败，Windows 错误 ${GetLastError()}');
  }
}

List<List<String>> _scan() => using((arena) {
  // Resolve the lazy FFI binding before a failing API call; GetProcAddress
  // during the first GetLastError invocation can otherwise overwrite it.
  GetLastError();
  final guid = GUIDFromString(
    '{4D36E978-E325-11CE-BFC1-08002BE10318}',
    allocator: arena,
  );
  final devices = SetupDiGetClassDevs(guid, nullptr, 0, DIGCF_PRESENT);
  if (devices == INVALID_HANDLE_VALUE) {
    throw StateError('CDC 枚举失败：${GetLastError()}');
  }
  final info = arena<SP_DEVINFO_DATA>()..ref.cbSize = sizeOf<SP_DEVINFO_DATA>();
  final buffer = arena<Uint8>(4096);
  String property(int key) {
    buffer.asTypedList(4096).fillRange(0, 4096, 0);
    if (SetupDiGetDeviceRegistryProperty(
          devices,
          info,
          key,
          nullptr,
          buffer,
          4096,
          nullptr,
        ) ==
        0) {
      return '';
    }
    return buffer.cast<Utf16>().toDartString();
  }

  try {
    final result = <List<String>>[];
    for (var index = 0; ; index++) {
      if (SetupDiEnumDeviceInfo(devices, index, info) == 0) {
        final error = GetLastError();
        if (error != ERROR_NO_MORE_ITEMS) {
          throw StateError('CDC 枚举中断：$error');
        }
        break;
      }
      // First REG_MULTI_SZ hardware ID is the most specific ID.
      if (!isGt1CdcHardwareId(property(SPDRP_HARDWAREID))) continue;
      final name = property(SPDRP_FRIENDLYNAME);
      final port = cdcPortFromName(name);
      if (port != null) result.add([port, 'GT1 CDC ($port)']);
    }
    return result;
  } finally {
    SetupDiDestroyDeviceInfoList(devices);
  }
});

/// Serial handles live on this worker and its event-driven RX isolate;
/// writes have a 250 ms driver deadline. No MIDI API or Flutter isolate FFI.
void windowsCdcWorker(SendPort host) {
  final commands = ReceivePort();
  var handle = INVALID_HANDLE_VALUE;
  var retired = false;
  WindowsCdcReader? reader;
  Future<void>? closing;
  var settling = true;
  final buffer = calloc<Uint8>(4096);
  final count = calloc<Uint32>();
  final tx = calloc<OVERLAPPED>();
  tx.ref.hEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
  Future<void> close() {
    if (closing != null) return closing!;
    final old = handle;
    handle = INVALID_HANDLE_VALUE;
    final oldReader = reader;
    reader = null;
    return closing = (() async {
      await oldReader?.close();
      if (old != INVALID_HANDLE_VALUE) {
        EscapeCommFunction(old, CLRDTR);
        CloseHandle(old);
      }
    })();
  }

  Future<void> fault(Object error) async {
    host.send(['fault', error.toString()]);
    await close();
  }

  Future<void> open(String port) async {
    await close();
    closing = null;
    settling = true;
    if (tx.ref.hEvent == 0) throw StateError('CDC 写入事件创建失败');
    // Revalidate before open: COM numbers can be reassigned after unplugging.
    if (!_scan().any((row) => row[0] == port)) {
      throw StateError('GT1 CDC 端口已移除或设备身份不匹配');
    }
    using((arena) {
      handle = CreateFile(
        '\\\\.\\$port'.toNativeUtf16(allocator: arena),
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED,
        0,
      );
      if (handle == INVALID_HANDLE_VALUE) {
        throw StateError('无法打开 $port：${GetLastError()}（可能被其它程序占用）');
      }
      try {
        final dcb = arena<DCB>()..ref.DCBlength = sizeOf<DCB>();
        _check(GetCommState(handle, dcb), '读取串口配置');
        dcb.ref
          ..BaudRate = 115200
          ..ByteSize = 8
          ..Parity = NOPARITY
          ..StopBits = ONESTOPBIT
          // fBinary=1; flow control, parity checking and DTR/RTS initially off.
          ..bitfield = 1;
        _check(SetCommState(handle, dcb), '设置 8N1');
        final timeouts = arena<COMMTIMEOUTS>();
        timeouts.ref
          ..ReadIntervalTimeout = 0xffffffff
          // Return buffered bytes immediately, otherwise wait for the first
          // byte. The 1 s idle deadline is NOT a per-message batching delay.
          ..ReadTotalTimeoutMultiplier = 0xffffffff
          ..ReadTotalTimeoutConstant = 1000
          ..WriteTotalTimeoutMultiplier = 0
          ..WriteTotalTimeoutConstant = 250;
        _check(SetCommTimeouts(handle, timeouts), '设置串口超时');
        _check(PurgeComm(handle, PURGE_RXCLEAR | PURGE_TXCLEAR), '清空旧会话');
        _check(EscapeCommFunction(handle, SETDTR), '开启 CDC 会话');
      } catch (_) {
        CloseHandle(handle);
        handle = INVALID_HANDLE_VALUE;
        rethrow;
      }
    });
    Object? openingFault;
    try {
      reader = await WindowsCdcReader.start(
        handle,
        onData: (data) {
          if (!settling && handle != INVALID_HANDLE_VALUE) {
            host.send(['data', data]);
          }
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
    } catch (_) {
      await close();
      rethrow;
    }
    // The device can still have one IN packet from the previous DTR session
    // in hardware. Drain it before any protocol request is allowed. This is
    // connection-only, not a delay on individual parameter writes.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (retired || handle == INVALID_HANDLE_VALUE) {
      throw StateError('CDC 连接初始化期间已断开');
    }
    settling = false;
  }

  Future<void> tail = Future<void>.value();
  Future<void> dispatch(dynamic value) async {
    if (retired) return;
    final message = value as List;
    if (message[0] == 'shutdown') {
      retired = true;
      await close();
      if (tx.ref.hEvent != 0) CloseHandle(tx.ref.hEvent);
      calloc.free(tx);
      calloc.free(buffer);
      calloc.free(count);
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
          if (handle == INVALID_HANDLE_VALUE) throw StateError('CDC 未连接');
          final data = (message[3] as List).cast<int>();
          if (data.isEmpty || data.length > 244) throw ArgumentError('帧长度越界');
          buffer.asTypedList(data.length).setAll(0, data);
          try {
            ResetEvent(tx.ref.hEvent);
            final error = cdcWrite(handle, buffer, data.length, tx);
            if (error != 0 && error != ERROR_IO_PENDING) {
              throw StateError('CDC 写入失败：$error');
            }
            final completion = cdcResult(handle, tx, count, TRUE);
            if (completion != 0) throw StateError('CDC 写入完成失败：$completion');
            // Never retry a partial non-idempotent request. Retire the session.
            if (count.value != data.length) throw StateError('CDC 写入超时/不完整');
          } catch (e) {
            await fault(e);
            rethrow;
          }
        default:
          throw UnsupportedError('未知 CDC 操作 ${message[2]}');
      }
      host.send(['reply', sequence, true, result]);
    } catch (e) {
      host.send(['reply', sequence, false, e.toString()]);
    }
  }

  commands.listen((dynamic value) {
    // Shutdown/open/close cannot overlap across async reader teardown.
    tail = tail.then((_) => dispatch(value));
  });
  host.send(['ready', commands.sendPort]);
}
