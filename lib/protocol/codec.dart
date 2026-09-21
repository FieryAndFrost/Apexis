import 'dart:typed_data';

/// GT1 protocol 1 / schema 12。线路整数与原始 LE 参数不可混用。
abstract final class Gt1 {
  static const schema = 12, bankSize = 47936, patchSize = 374;
  static int check(int value, int min, int max) {
    if (value < min || value > max) throw RangeError.range(value, min, max);
    return value;
  }

  static List<int> number(int value, int width, int max) {
    check(value, 0, max);
    return List.generate(width, (i) => (value >> (7 * i)) & 127);
  }

  static List<int> u14(int v) => number(v, 2, 16383);
  static List<int> s14(int v) => u14(check(v, -8192, 8191) & 16383);
  static List<int> u16(int v) => number(v, 3, 65535);
  static List<int> u32(int v) => number(v, 5, 0xffffffff);
  static int integer(List<int> b, int at, int width, [int? max]) {
    if (at < 0 || at + width > b.length) throw const FormatException('整数被截断');
    var value = 0;
    for (var i = 0; i < width; i++) {
      value |= check(b[at + i], 0, 127) << (7 * i);
    }
    return check(value, 0, max ?? ((1 << (width * 7)) - 1));
  }

  static int signed14(List<int> b, int at) {
    final v = integer(b, at, 2);
    return v >= 8192 ? v - 16384 : v;
  }

  static List<int> pack7(List<int> raw) {
    final out = <int>[];
    for (var at = 0; at < raw.length; at += 7) {
      final group = raw.skip(at).take(7).toList();
      var mask = 0;
      for (var i = 0; i < group.length; i++) {
        check(group[i], 0, 255);
        mask |= (group[i] >> 7) << i;
      }
      out.addAll([mask, ...group.map((v) => v & 127)]);
    }
    return out;
  }

  static Uint8List unpack7(List<int> wire, int count) {
    if (wire.length != count + (count + 6) ~/ 7) {
      throw const FormatException('pack7 长度错误');
    }
    final out = Uint8List(count);
    var p = 0;
    for (var at = 0; at < count; at += 7) {
      final n = (count - at).clamp(0, 7);
      final mask = check(wire[p++], 0, (1 << n) - 1);
      for (var i = 0; i < n; i++) {
        out[at + i] = check(wire[p++], 0, 127) | (((mask >> i) & 1) << 7);
      }
    }
    return out;
  }

  static Uint8List frame(
    int component,
    int command,
    int selector, [
    List<int> data = const [],
    int? error,
  ]) {
    final body = [0, 0x59, 1, component, command, selector, ?error, ...data];
    for (final v in body) {
      check(v, 0, 127);
    }
    final bytes = [0xf0, ...body, body.fold(0, (a, b) => a ^ b), 0xf7];
    if (bytes.length > 244) throw const FormatException('帧超过 244 B');
    return Uint8List.fromList(bytes);
  }

  static int patchOffset(int id, [int field = 0]) =>
      64 + check(id, 0, 127) * patchSize + check(field, 0, 373);
  static Uint8List read(int revision, int offset, int count) {
    check(offset, 0, bankSize - 1);
    check(count, 1, 193);
    check(offset + count, 1, bankSize);
    return frame(9, 1, 0x40, [...u32(revision), ...u16(offset), ...u14(count)]);
  }

  static Uint8List write(
    int revision,
    int id,
    int offset,
    int total,
    int fragmentOffset,
    List<int> raw,
  ) {
    check(revision, 1, 0xffffffff);
    check(id, 1, 16383);
    check(offset, 0, bankSize - 1);
    check(total, 1, 374);
    check(fragmentOffset, 0, total - 1);
    check(raw.length, 1, 191);
    final available = offset < 64 ? 64 - offset : 374 - (offset - 64) % 374;
    if (total > available || fragmentOffset + raw.length > total) {
      throw const FormatException('写入跨记录或越过事务边界');
    }
    validateFieldBoundary(offset);
    validateFieldBoundary(offset + total);
    return frame(9, 0, 0x41, [
      ...u32(revision),
      ...u14(id),
      ...u16(offset),
      ...u14(total),
      ...u14(fragmentOffset),
      ...u14(raw.length),
      ...pack7(raw),
    ]);
  }

  static void validateFieldBoundary(int offset) {
    if (offset <= 64) {
      if ({13, 15, 19, 21, 35, 37, 40, 44, 48, 52}.contains(offset)) {
        throw const FormatException('写入必须覆盖完整 LE16 字段');
      }
      return;
    }
    final p = (offset - 64) % 374;
    final valid = p < 320
        ? {
            0,
            2,
            3,
            4,
            5,
            6,
            8,
            10,
            12,
            14,
            16,
            18,
            20,
            22,
            24,
            26,
            28,
            30,
          }.contains(p % 32)
        : {320, 330, 332, 349, 350, 351, 352, 362, 372}.contains(p);
    if (!valid) throw const FormatException('写入必须覆盖完整参数字段');
  }

  static List<int> header(int revision, int offset, int count) => [
    1,
    ...u14(schema),
    ...u32(revision),
    ...u16(offset),
    ...u14(count),
  ];
}

class Message {
  Message(this.component, this.command, this.selector, this.data, this.error);
  final int component, command, selector, error;
  final Uint8List data;
  bool get notification =>
      component == 9 && command == 0x7e && selector == 0x42;
  factory Message.parse(List<int> b, {bool response = true}) {
    if (b.length < (response ? 10 : 9) ||
        b.length > 244 ||
        b.first != 0xf0 ||
        b.last != 0xf7 ||
        b[1] != 0 ||
        b[2] != 0x59 ||
        b[3] != 1) {
      throw const FormatException('非法 GT1 帧');
    }
    for (final v in b.sublist(1, b.length - 1)) {
      Gt1.check(v, 0, 127);
    }
    if (b.sublist(1, b.length - 2).fold(0, (a, b) => a ^ b) !=
        b[b.length - 2]) {
      throw const FormatException('XOR 校验失败');
    }
    return Message(
      b[4],
      b[5],
      b[6],
      Uint8List.fromList(b.sublist(response ? 8 : 7, b.length - 2)),
      response ? b[7] : 0,
    );
  }
}

/// 每个连接独立重组，忽略合法 MIDI 实时消息，坏帧不污染下一条。
class FrameDecoder {
  final _buffer = <int>[];
  void reset() => _buffer.clear();
  List<Uint8List> add(List<int> chunk) {
    final frames = <Uint8List>[];
    for (final byte in chunk) {
      if (byte >= 0xf8) continue;
      if (byte == 0xf0) {
        _buffer.clear();
        _buffer.add(byte);
        continue;
      }
      if (_buffer.isEmpty) continue;
      if (byte != 0xf7 && byte >= 128) {
        reset();
        continue;
      }
      _buffer.add(byte);
      if (_buffer.length > 244) {
        reset();
        continue;
      }
      if (byte == 0xf7) {
        frames.add(Uint8List.fromList(_buffer));
        reset();
      }
    }
    return frames;
  }
}

class RangeReply {
  RangeReply(Message m, {bool capability = false}) {
    final d = m.data;
    if (d.length < 13 || d[0] != 1 || Gt1.integer(d, 1, 2) != Gt1.schema) {
      throw const FormatException('不支持的范围格式 / schema');
    }
    revision = Gt1.integer(d, 3, 5, 0xffffffff);
    offset = Gt1.integer(d, 8, 3, 65535);
    count = Gt1.integer(d, 11, 2);
    var start = 13;
    if (capability) {
      if (d.length != 13 ||
          offset != Gt1.bankSize ||
          count < 1 ||
          count > 193) {
        throw const FormatException('范围能力不匹配');
      }
      return;
    }
    if (m.notification) {
      rangeStart = Gt1.integer(d, 13, 3, 65535);
      rangeTotal = Gt1.integer(d, 16, 3, 65535);
      start = 19;
      if (count == 0 ||
          rangeTotal == 0 ||
          offset < rangeStart ||
          offset + count > rangeStart + rangeTotal ||
          rangeStart + rangeTotal > Gt1.bankSize) {
        throw const FormatException('通知范围无效');
      }
    } else if (m.selector == 0x41) {
      if (d.length < 20) throw const FormatException('WRITE 回执被截断');
      requestId = Gt1.integer(d, 13, 2);
      state = Gt1.check(d[15], 0, 3);
      filled = Gt1.integer(d, 16, 2);
      total = Gt1.integer(d, 18, 2);
      start = 20;
    }
    if (offset + count > Gt1.bankSize) throw const FormatException('范围越界');
    raw = Gt1.unpack7(d.sublist(start), count);
  }
  late final int revision, offset, count;
  int rangeStart = 0,
      rangeTotal = 0,
      requestId = 0,
      state = 0,
      filled = 0,
      total = 0;
  Uint8List raw = Uint8List(0);
}
