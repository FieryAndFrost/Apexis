import 'dart:convert';
import 'dart:typed_data';
import '../protocol/codec.dart';

int le16(List<int> bytes, int at, {bool signed = false}) {
  final n = bytes[at] | bytes[at + 1] << 8;
  return signed && n >= 32768 ? n - 65536 : n;
}

List<int> raw16(int value) => [value & 255, (value >> 8) & 255];
String presetLabel(int id, {bool factoryUser = false}) =>
    '${factoryUser ? (id < 64 ? 'F' : 'U') : ''}'
    '${((factoryUser ? id % 64 : id) ~/ 4 + 1).toString().padLeft(2, '0')}${'ABCD'[id % 4]}';

class Patch {
  Patch(List<int> data) : bytes = Uint8List.fromList(data) {
    if (bytes.length != 374 || count > 10) {
      throw const FormatException('PATCH 无效');
    }
    if (chain.toSet().length != count || chain.any((id) => id >= count)) {
      throw const FormatException('效果链无效');
    }
  }
  final Uint8List bytes;
  int get count => bytes[349];
  List<int> get chain => bytes.sublist(320, 320 + count);
  String get name => ascii.decode(
    bytes.sublist(332, 349).takeWhile((v) => v != 0).toList(),
    allowInvalid: true,
  );
  int get tempo => le16(bytes, 330);
  int get input => bytes[350];
  int get output => bytes[351];
  int get pan => le16(bytes, 372, signed: true);
  EffectUnit unit(int id) =>
      EffectUnit(id, bytes.sublist(id * 32, id * 32 + 32));
}

class EffectUnit {
  EffectUnit(this.id, this.bytes);
  final int id;
  final List<int> bytes;
  int get type => le16(bytes, 0);
  bool get enabled => bytes[2] == 1;
  int get processor => bytes[3];
  int get count => bytes[5].clamp(0, 12);
  int get model => le16(bytes, 30);
  int parameter(int p) => le16(bytes, 6 + p * 2, signed: true);
}

class DeviceIdentity {
  DeviceIdentity(List<int> d) {
    if (d.length < 17 ||
        d[0] != 1 ||
        d[1] != 1 ||
        d[2] != 1 ||
        Gt1.integer(d, 13, 2) != 12 ||
        d[10] != 32 ||
        d[11] != 4 ||
        d[12] != 10 ||
        d.length != 17 + d[15] + d[16]) {
      throw const FormatException('设备不兼容 GT1 protocol 1 / schema 12');
    }
    name = ascii.decode(d.sublist(17, 17 + d[15]));
    platform = ascii.decode(d.sublist(17 + d[15]));
    major = Gt1.integer(d, 3, 2);
    minor = Gt1.integer(d, 5, 2);
    patchVersion = Gt1.integer(d, 7, 2);
    version = '$major.$minor.$patchVersion${d[9] & 1 != 0 ? '-dev' : ''}';
  }
  late final int major, minor, patchVersion;
  bool get factoryUserPresets =>
      major > 0 || minor > 2 || (minor == 2 && patchVersion >= 122);
  late final String name, platform, version;
}

class EffectType {
  EffectType(this.id, this.name, this.count, this.flags);
  final int id, count, flags;
  final String name;
}

class ModelResource {
  ModelResource(this.ref, this.type, this.name);
  final int ref, type;
  final String name;
}

class ParameterInfo {
  ParameterInfo(this.name, this.min, this.max, this.label);
  final String name, label;
  final int min, max;
}

/// 验证便携文件，拒绝损坏文件；完整字段合法性由设备提交时验证。
abstract final class PresetFile {
  static int crc32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final b in bytes) {
      crc ^= b;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  static void validate(Uint8List bytes, {required bool bank}) {
    if (bytes.length < 12) throw const FormatException('文件过短');
    final magic = ascii.decode(bytes.sublist(0, 4), allowInvalid: true);
    if (magic != (bank ? 'GT1B' : 'GT1S')) {
      throw const FormatException('文件类型不匹配');
    }
    if (bank
        ? bytes.length != 47956
        : !(bytes.length == 386 || bytes.length == 384)) {
      throw const FormatException('文件长度不匹配');
    }
    if (!bank &&
        !((le16(bytes, 4) == 2 &&
                le16(bytes, 6) == 374 &&
                bytes.length == 386) ||
            (le16(bytes, 4) == 1 &&
                le16(bytes, 6) == 372 &&
                bytes.length == 384))) {
      throw const FormatException('GT1S 版本不匹配');
    }
    final actual = ByteData.sublistView(
      bytes,
    ).getUint32(bytes.length - 4, Endian.little);
    if (actual != crc32(bytes.sublist(0, bytes.length - 4))) {
      throw const FormatException('CRC32 校验失败');
    }
  }
}
