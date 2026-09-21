import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/protocol/session.dart';
import 'package:apexis/data/parameters.dart';

String hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
void main() {
  test('r2 的 10 条完整报文逐字节一致', () {
    final vectors = <List<int>, String>{
      Gt1.frame(9, 1, 0x22): 'F0 00 59 01 09 01 22 72 F7',
      Gt1.frame(9, 1, 0x40): 'F0 00 59 01 09 01 40 10 F7',
      Gt1.frame(9, 0, 0x42, [3]): 'F0 00 59 01 09 00 42 03 10 F7',
      Gt1.frame(9, 0, 0x42, [1]): 'F0 00 59 01 09 00 42 01 12 F7',
      Gt1.read(1, 0, 64):
          'F0 00 59 01 09 01 40 01 00 00 00 00 00 00 00 40 00 51 F7',
      Gt1.write(
        1,
        1,
        415,
        1,
        0,
        [80],
      ): 'F0 00 59 01 09 00 41 01 00 00 00 00 01 00 1F 03 00 01 00 00 00 01 00 00 50 5C F7',
      Gt1.frame(9, 0, 0x42, [2, ...Gt1.u32(2)]):
          'F0 00 59 01 09 00 42 02 02 00 00 00 00 13 F7',
      Gt1.frame(0, 0, 0, [18]): 'F0 00 59 01 00 00 00 12 4A F7',
      Gt1.frame(3, 3, 0): 'F0 00 59 01 03 03 00 58 F7',
      Gt1.frame(5, 1, 0): 'F0 00 59 01 05 01 00 5C F7',
    };
    for (final v in vectors.entries) {
      expect(hex(v.key), v.value);
      Message.parse(v.key, response: false);
    }
  });
  test('pack7 所有尾组和高位往返、padding 严格校验', () {
    expect(
      hex(Gt1.pack7([0, 127, 128, 255, 85, 170, 1, 254])),
      '2C 00 7F 00 7F 55 2A 01 01 7E',
    );
    for (var n = 0; n <= 374; n++) {
      final raw = List.generate(n, (i) => (i * 137 + n) & 255);
      expect(Gt1.unpack7(Gt1.pack7(raw), n), raw);
    }
    expect(() => Gt1.unpack7([2, 0], 1), throwsRangeError);
    expect(() => Gt1.unpack7([0], 1), throwsFormatException);
    for (final v in [0, 1, 127, 128, 0x80000000, 0xffffffff]) {
      expect(Gt1.integer(Gt1.u32(v), 0, 5, 0xffffffff), v);
    }
    expect(Gt1.signed14(Gt1.s14(-8192), 0), -8192);
    expect(() => Gt1.u16(65536), throwsRangeError);
  });
  test('跨记录、半字段和错误 XOR 不被接受', () {
    expect(() => Gt1.write(1, 1, 63, 2, 0, [1, 2]), throwsFormatException);
    expect(() => Gt1.write(1, 1, 13, 1, 0, [1]), throwsFormatException);
    expect(
      () => Gt1.write(1, 1, 64 + 333, 16, 0, List.filled(16, 0)),
      throwsFormatException,
    );
    final corrupt = Gt1.frame(9, 1, 0x22)..[7] ^= 1;
    expect(
      () => Message.parse(corrupt, response: false),
      throwsFormatException,
    );
  });
  test('流重组支持任意分片、粘包、重同步与实时 MIDI 字节', () {
    final a = Gt1.frame(9, 1, 0x22, [], 0), b = Gt1.frame(5, 1, 0, [], 0);
    for (var split = 1; split < a.length; split++) {
      final decoder = FrameDecoder();
      expect(decoder.add(a.sublist(0, split)), isEmpty);
      final frames = decoder.add([...a.sublist(split), ...b]);
      expect(frames, [a, b]);
    }
    final decoder = FrameDecoder();
    expect(decoder.add([0xf0, ...List.filled(245, 1), ...a]), [a]);
    expect(decoder.add([0xf0, 1, 2, ...a.take(4), 0xf8, ...a.skip(4)]), [a]);
  });
  test('通知必须同代次连续且收齐后才发布', () {
    RangeReply part(int revision, int offset, int count) => RangeReply(
      Message.parse(
        Gt1.frame(9, 0x7e, 0x42, [
          ...Gt1.header(revision, offset, count),
          ...Gt1.u16(64),
          ...Gt1.u16(374),
          ...Gt1.pack7(List.filled(count, 3)),
        ], 0),
      ),
    );
    final assembler = RangeAssembler();
    expect(assembler.add(part(1, 64, 187)), isNull);
    expect(() => assembler.add(part(2, 251, 187)), throwsFormatException);
    expect(assembler.add(part(2, 64, 187)), isNull);
    expect(assembler.add(part(2, 251, 187))!.raw.length, 374);
    expect(() => assembler.add(part(2, 251, 187)), throwsFormatException);
  });
  test('GT1S CRC32 校验拒绝损坏文件', () {
    expect(PresetFile.crc32(ascii.encode('123456789')), 0xcbf43926);
    final file = Uint8List(386)
      ..setRange(0, 8, [...ascii.encode('GT1S'), 2, 0, 118, 1]);
    ByteData.sublistView(
      file,
    ).setUint32(382, PresetFile.crc32(file.sublist(0, 382)), Endian.little);
    PresetFile.validate(file, bank: false);
    file[50] ^= 1;
    expect(() => PresetFile.validate(file, bank: false), throwsFormatException);
  });
}
