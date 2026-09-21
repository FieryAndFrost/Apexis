import 'dart:typed_data';
import '../protocol/codec.dart';
import '../protocol/session.dart';
import 'parameters.dart';

enum TransferPhase { preparing, transferring, committing, closing }

class FileTransfer {
  FileTransfer(
    this.session, {
    required this.onProgress,
    required this.cancelled,
    this.onPhase,
  });
  final ProtocolSession session;
  final void Function(double) onProgress;
  final bool Function() cancelled;
  final void Function(TransferPhase)? onPhase;
  void checkCancelled() {
    if (cancelled()) throw StateError('已取消文件传输，原有参数未提交');
  }

  Future<Uint8List> transfer({
    required bool bank,
    required int preset,
    Uint8List? input,
  }) async {
    checkCancelled();
    if (input != null) PresetFile.validate(input, bank: bank);
    onPhase?.call(TransferPhase.preparing);
    final base = bank ? 0x34 : 0x30;
    final begin = (await session.command(
      0,
      input == null ? 1 : 0,
      base,
      bank ? [] : [preset],
    )).data;
    if (begin.length != 7 || begin[0] != 1) {
      throw const FormatException('文件会话格式无效');
    }
    final ticket = Gt1.integer(begin, 1, 2);
    var committed = false;
    final output = BytesBuilder(copy: false);
    try {
      final advertisedSize = Gt1.integer(
            begin,
            bank ? 3 : 4,
            bank ? 3 : 2,
            65535,
          ),
          maxChunk = Gt1.check(begin[6], 1, 28);
      final size = input?.length ?? advertisedSize;
      if (!bank && begin[3] != preset) throw const FormatException('音色文件目标不匹配');
      if (input != null &&
          input.length != advertisedSize &&
          !(!bank && input.length == 384 && advertisedSize == 386)) {
        throw const FormatException('设备不接受此版本文件长度');
      }
      if (bank ? size != 47956 : !(size == 386 || size == 384)) {
        throw const FormatException('设备文件长度无效');
      }
      onPhase?.call(TransferPhase.transferring);
      for (var at = 0; at < size;) {
        checkCancelled();
        final count = (size - at).clamp(1, maxChunk);
        final prefix = [
          ...Gt1.u14(ticket),
          ...(bank ? Gt1.u16(at) : Gt1.u14(at)),
          count,
        ];
        if (input == null) {
          final d = (await session.command(0, 1, base + 1, prefix)).data;
          if (d.length != prefix.length + count * 2) {
            throw const FormatException('文件分片被截断');
          }
          for (var i = 0; i < prefix.length; i++) {
            if (d[i] != prefix[i]) throw const FormatException('文件分片票据或偏移不符');
          }
          for (var i = prefix.length; i < d.length; i += 2) {
            output.add([
              (Gt1.check(d[i], 0, 15) << 4) | Gt1.check(d[i + 1], 0, 15),
            ]);
          }
        } else {
          final data = [
            ...prefix,
            ...input.sublist(at, at + count).expand((b) => [b >> 4, b & 15]),
          ];
          final d = (await session.command(0, 0, base + 1, data)).data;
          if (d.length != (bank ? 5 : 4) ||
              Gt1.integer(d, 0, 2) != ticket ||
              Gt1.integer(d, 2, bank ? 3 : 2) != at + count) {
            throw const FormatException('文件写入进度不匹配');
          }
        }
        at += count;
        onProgress(at / size);
      }
      checkCancelled();
      if (input != null) {
        onPhase?.call(TransferPhase.committing);
        final d = (await session.command(0, 8, base + 2, Gt1.u14(ticket))).data;
        if (d.length != 3 || d[0] != 1) throw const FormatException('文件提交回执无效');
        committed = true;
        if (d[2] != 0) throw StateError('文件已提交，但设备处于静音状态，请重新同步');
        return input;
      }
      final bytes = output.takeBytes();
      PresetFile.validate(bytes, bank: bank);
      return bytes;
    } finally {
      onPhase?.call(TransferPhase.closing);
      // 导出也结束会话。断线时 session 已失效，保留原始异常。
      try {
        if (!committed && session.isValid) {
          await session.command(0, 7, base + 3, Gt1.u14(ticket));
        }
      } catch (_) {
        /* 设备超时/断线自行清理 */
      }
    }
  }

  Future<void> restoreDefaults() async {
    checkCancelled();
    onPhase?.call(TransferPhase.preparing);
    final d = (await session.command(0, 7, 0x34, [1])).data;
    if (d.length != 7 || d[0] != 1) throw const FormatException('恢复默认会话无效');
    final ticket = Gt1.integer(d, 1, 2);
    var committed = false;
    try {
      checkCancelled();
      onPhase?.call(TransferPhase.committing);
      final reply = (await session.command(0, 8, 0x36, Gt1.u14(ticket))).data;
      if (reply.length != 3 || reply[0] != 1) {
        throw const FormatException('恢复默认提交无效');
      }
      committed = true;
      if (reply[2] != 0) throw StateError('已恢复默认，但设备处于静音状态');
    } finally {
      onPhase?.call(TransferPhase.closing);
      try {
        if (!committed && session.isValid) {
          await session.command(0, 7, 0x37, Gt1.u14(ticket));
        }
      } catch (_) {}
    }
  }
}
