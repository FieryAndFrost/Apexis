import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win32/win32.dart';
import 'package:apexis/transport/windows_cdc_reader.dart';
import 'package:apexis/transport/windows_cdc_native.dart';

/// Real Windows kernel I/O exercises pending completion/cancellation; no GT1,
/// DEBUG, serial ports, or device writes. Message pipes complete short reads.
class _Pipe {
  late final int server, client;
  bool serverClosed = false;
  _Pipe() {
    using((arena) {
      final name =
          '\\\\.\\pipe\\apexis-cdc-$pid-${DateTime.now().microsecondsSinceEpoch}'
              .toNativeUtf16(allocator: arena);
      server = CreateNamedPipe(
        name,
        PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
        1,
        4096,
        4096,
        0,
        nullptr,
      );
      expect(server, isNot(INVALID_HANDLE_VALUE));
      client = CreateFile(
        name,
        GENERIC_READ | FILE_WRITE_ATTRIBUTES,
        0,
        nullptr,
        OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED,
        0,
      );
      expect(client, isNot(INVALID_HANDLE_VALUE));
      final mode = arena<Uint32>()..value = PIPE_READMODE_MESSAGE;
      expect(SetNamedPipeHandleState(client, mode, nullptr, nullptr), isNot(0));
    });
  }
  void write(List<int> bytes) {
    using((arena) {
      final data = arena<Uint8>(bytes.length);
      data.asTypedList(bytes.length).setAll(0, bytes);
      final count = arena<Uint32>();
      final op = arena<OVERLAPPED>();
      op.ref.hEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
      try {
        expect(
          cdcWrite(server, data, bytes.length, op),
          anyOf(0, ERROR_IO_PENDING),
        );
        expect(cdcResult(server, op, count, TRUE), 0);
        expect(count.value, bytes.length);
      } finally {
        CloseHandle(op.ref.hEvent);
      }
    });
  }

  void closeServer() {
    if (serverClosed) return;
    serverClosed = true;
    CloseHandle(server);
  }

  void close() {
    CloseHandle(client);
    closeServer();
  }
}

void main() {
  test(
    'native CDC helper captures immediate error and pending atomically',
    () {
      final pipe = _Pipe();
      using((arena) {
        final data = arena<Uint8>(64), count = arena<Uint32>();
        final op = arena<OVERLAPPED>();
        op.ref.hEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
        try {
          expect(
            cdcRead(INVALID_HANDLE_VALUE, data, 64, op),
            ERROR_INVALID_HANDLE,
          );
          expect(
            cdcWrite(INVALID_HANDLE_VALUE, data, 64, op),
            ERROR_INVALID_HANDLE,
          );
          expect(cdcRead(pipe.client, data, 64, op), ERROR_IO_PENDING);
          SetLastError(
            0,
          ); // Later FFI transitions cannot change the saved result.
          CancelIoEx(pipe.client, op);
          expect(
            cdcResult(pipe.client, op, count, TRUE),
            ERROR_OPERATION_ABORTED,
          );
        } finally {
          CloseHandle(op.ref.hEvent);
        }
      });
      pipe.close();
    },
    skip: !Platform.isWindows,
  );
  test(
    'event RX handles buffered and pending packets in order',
    () async {
      final pipe = _Pipe();
      final received = <int>[];
      final complete = Completer<void>();
      final errors = <Object>[];
      pipe.write([1, 2, 3]);
      final reader = await WindowsCdcReader.start(
        pipe.client,
        onData: (Uint8List bytes) {
          received.addAll(bytes);
          if (received.length == 8) complete.complete();
        },
        onFault: errors.add,
      );
      try {
        pipe.write([4, 5]);
        pipe.write([6, 7, 8]);
        await complete.future.timeout(const Duration(seconds: 3));
        expect(received, [1, 2, 3, 4, 5, 6, 7, 8]);
        expect(errors, isEmpty);
      } finally {
        await reader.close();
        pipe.close();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'event RX cancels idle pending read and close is idempotent',
    () async {
      for (var cycle = 0; cycle < 8; cycle++) {
        final pipe = _Pipe();
        final errors = <Object>[];
        final reader = await WindowsCdcReader.start(
          pipe.client,
          onData: (_) => fail('Unexpected idle data'),
          onFault: errors.add,
        );
        try {
          await Future.wait([
            reader.close(),
            reader.close(),
          ]).timeout(const Duration(seconds: 3));
          expect(errors, isEmpty);
        } finally {
          pipe.close();
        }
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'event RX peer removal reports fault and drains native I/O',
    () async {
      final pipe = _Pipe();
      final failed = Completer<Object>();
      final reader = await WindowsCdcReader.start(
        pipe.client,
        onData: (_) {},
        onFault: (error) {
          if (!failed.isCompleted) failed.complete(error);
        },
      );
      try {
        pipe.closeServer();
        await failed.future.timeout(const Duration(seconds: 3));
        await reader.close().timeout(const Duration(seconds: 3));
      } finally {
        await reader.close();
        pipe.close();
      }
    },
    skip: !Platform.isWindows,
  );
}
