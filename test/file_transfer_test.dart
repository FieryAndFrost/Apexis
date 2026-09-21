import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/data/file_transfer.dart';
import 'package:apexis/data/parameters.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/protocol/session.dart';
import 'package:apexis/transport/demo_transport.dart';
import 'package:apexis/transport/transport.dart';

Uint8List makeFile({bool bank = false, bool legacy = false}) {
  final file = Uint8List(
    bank
        ? 47956
        : legacy
        ? 384
        : 386,
  );
  file.setRange(0, 4, ascii.encode(bank ? 'GT1B' : 'GT1S'));
  if (!bank) {
    file.setRange(4, 8, [legacy ? 1 : 2, 0, ...raw16(legacy ? 372 : 374)]);
  }
  for (var at = bank ? 16 : 8; at < file.length - 4; at++) {
    file[at] = (at * 137) & 255;
  }
  ByteData.sublistView(file).setUint32(
    file.length - 4,
    PresetFile.crc32(file.sublist(0, file.length - 4)),
    Endian.little,
  );
  return file;
}

class FileDevice extends DemoTransport {
  FileDevice(this.file, {this.bankFile = false});
  final Uint8List file;
  final bool bankFile;
  bool committed = false, ended = false, stale = false;
  bool holdCommit = false, muted = false;
  int maxChunk = 28, begins = 0;
  final uploaded = <int>[];
  final offsets = <int>[];
  @override
  Future<void> send(Uint8List frame) async {
    final m = Message.parse(frame, response: false),
        base = bankFile ? 0x34 : 0x30;
    if (m.component != 0 || m.selector < base || m.selector > base + 3) {
      await super.send(frame);
      return;
    }
    void reply(List<int> data, [int error = 0]) =>
        emitFrame(Gt1.frame(m.component, m.command, m.selector, data, error));
    final d = m.data;
    if (m.selector == base) {
      begins++;
      reply(
        bankFile
            ? [1, ...Gt1.u14(7), ...Gt1.u16(file.length), maxChunk]
            : [1, ...Gt1.u14(7), 18, ...Gt1.u14(386), maxChunk],
      );
      return;
    }
    if (m.selector == base + 1) {
      final at = Gt1.integer(d, 2, bankFile ? 3 : 2),
          prefix = bankFile ? 6 : 5,
          count = d[prefix - 1];
      offsets.add(at);
      if (stale && at > 0) {
        reply([], 8);
        return;
      }
      if (m.command == 1) {
        reply([
          ...d,
          ...file.sublist(at, at + count).expand((v) => [v >> 4, v & 15]),
        ]);
      } else {
        for (var i = prefix; i < d.length; i += 2) {
          uploaded.add((d[i] << 4) | d[i + 1]);
        }
        reply([
          ...Gt1.u14(7),
          ...(bankFile ? Gt1.u16(uploaded.length) : Gt1.u14(uploaded.length)),
        ]);
      }
      return;
    }
    if (m.selector == base + 2 && m.command == 8) {
      committed = true;
      if (!holdCommit) reply([1, 18, muted ? 1 : 0]);
      return;
    }
    if (m.selector == base + 3) {
      ended = true;
      reply([]);
      return;
    }
  }
}

void main() {
  Future<(FileDevice, ProtocolSession)> open(
    bool bank, {
    bool legacy = false,
  }) async {
    final device = FileDevice(
      makeFile(bank: bank, legacy: legacy),
      bankFile: bank,
    );
    await device.connect(const DevicePort('file', 'GT1', '演示'));
    return (device, ProtocolSession(device));
  }

  for (final bank in [false, true]) {
    test('${bank ? 'GT1B' : 'GT1S'} 导出逐字节一致、票据结束、宽偏移', () async {
      final (device, session) = await open(bank);
      final transfer = FileTransfer(
        session,
        onProgress: (_) {},
        cancelled: () => false,
      );
      final result = await transfer.transfer(bank: bank, preset: 18);
      expect(result, device.file);
      expect(device.ended, isTrue);
      expect(device.committed, isFalse);
      if (bank) expect(device.offsets.last, greaterThan(32767));
      await session.dispose();
      await device.dispose();
    });
  }
  test('兼容 v1 单音色导入，上传完整后才提交', () async {
    final (device, session) = await open(false, legacy: true);
    final transfer = FileTransfer(
      session,
      onProgress: (_) {
        expect(device.committed, isFalse);
      },
      cancelled: () => false,
    );
    await transfer.transfer(bank: false, preset: 18, input: device.file);
    expect(device.uploaded, device.file);
    expect(device.committed, isTrue);
    expect(device.ended, isFalse, reason: 'commit already retired the ticket');
    await session.dispose();
    await device.dispose();
  });
  test('导入中途取消不提交，清理会话', () async {
    final (device, session) = await open(false);
    var cancel = false;
    final transfer = FileTransfer(
      session,
      onProgress: (p) {
        if (p > 0.2) cancel = true;
      },
      cancelled: () => cancel,
    );
    await expectLater(
      transfer.transfer(bank: false, preset: 18, input: device.file),
      throwsStateError,
    );
    expect(device.committed, isFalse);
    expect(device.ended, isTrue);
    expect(device.uploaded.length, lessThan(device.file.length));
    await session.dispose();
    await device.dispose();
  });
  test('整库导出 STALE 丢弃部分文件，不继续拼接', () async {
    final (device, session) = await open(true);
    device.stale = true;
    final transfer = FileTransfer(
      session,
      onProgress: (_) {},
      cancelled: () => false,
    );
    await expectLater(
      transfer.transfer(bank: true, preset: 18),
      throwsA(isA<DeviceError>().having((e) => e.code, 'code', 8)),
    );
    expect(device.offsets.length, 2);
    expect(device.ended, isTrue);
    await session.dispose();
    await device.dispose();
  });
  test('invalid chunk size still cleans up the acquired ticket', () async {
    final (device, session) = await open(false);
    device.maxChunk = 0;
    await expectLater(
      FileTransfer(
        session,
        onProgress: (_) {},
        cancelled: () => false,
      ).transfer(bank: false, preset: 18),
      throwsRangeError,
    );
    expect(device.ended, isTrue);
    await session.dispose();
    await device.dispose();
  });
  test('cancel before begin sends no commands', () async {
    final (device, session) = await open(true);
    final t = FileTransfer(session, onProgress: (_) {}, cancelled: () => true);
    await expectLater(t.restoreDefaults(), throwsStateError);
    await expectLater(t.transfer(bank: true, preset: 18), throwsStateError);
    expect(device.begins, 0);
    expect(device.committed, isFalse);
    await session.dispose();
    await device.dispose();
  });
  for (final muted in [false, true]) {
    test('factory commit retires ticket, muted=$muted', () async {
      final (device, session) = await open(true);
      device.muted = muted;
      final phases = <TransferPhase>[];
      final work = FileTransfer(
        session,
        onProgress: (_) {},
        onPhase: phases.add,
        cancelled: () => false,
      ).restoreDefaults();
      if (muted) {
        await expectLater(
          work,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('静音'),
            ),
          ),
        );
      } else {
        await work;
      }
      expect(device.committed, isTrue);
      expect(device.ended, isFalse);
      expect(phases, [
        TransferPhase.preparing,
        TransferPhase.committing,
        TransferPhase.closing,
      ]);
      await session.dispose();
      await device.dispose();
    });
  }
  test('lost factory commit reply is not retried or cancelled', () async {
    final device = FileDevice(makeFile(bank: true), bankFile: true)
      ..holdCommit = true;
    await device.connect(const DevicePort('file', 'GT1', '演示'));
    final session = ProtocolSession(
      device,
      requestTimeout: const Duration(milliseconds: 30),
    );
    await expectLater(
      FileTransfer(
        session,
        onProgress: (_) {},
        cancelled: () => false,
      ).restoreDefaults(),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('00/08/36'),
        ),
      ),
    );
    expect(device.begins, 1);
    expect(device.committed, isTrue);
    expect(device.ended, isFalse);
    expect(session.isValid, isFalse);
    await session.dispose();
    await device.dispose();
  });
}
