import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import '../data/parameters.dart';
import '../protocol/codec.dart';
import 'transport.dart';

/// 独立协议模拟器：所有演示编辑同样经过真实编解码和回执状态机。
/// 示例 TYPE/资源只存在于演示设备，不能作为真实硬件目录。
class DemoTransport implements DeviceTransport {
  DemoTransport({int selected = 0, this.payload = 197}) {
    bank[0] = selected;
    bank[4] = 64;
    bank[5] = 65;
    bank[6] = 80;
    bank[7] = 80;
    bank[8] = 1;
    bank.setRange(12, 14, raw16(120));
    bank.setRange(14, 16, raw16(120));
    bank[32] = 1;
    bank.setRange(34, 36, raw16(19));
    bank.setRange(36, 38, raw16(20500));
    for (var i = 0; i < 4; i++) {
      bank.setRange(39 + 4 * i, 41 + 4 * i, raw16([100, 750, 1600, 4000][i]));
      bank[41 + 4 * i] = 7;
    }
    bank[54] = 20;
    bank[56] = 50;
    bank[61] = 100;
    for (var id = 0; id < 128; id++) {
      final start = Gt1.patchOffset(id);
      for (var u = 0; u < 6; u++) {
        bank.setRange(start + u * 32, start + u * 32 + 2, raw16(typeIds[u]));
        bank[start + u * 32 + 2] = u == 2 ? 0 : 1;
        bank[start + u * 32 + 5] = u == 3 ? 8 : 4;
        for (var p = 0; p < bank[start + u * 32 + 5]; p++) {
          bank.setRange(
            start + u * 32 + 6 + p * 2,
            start + u * 32 + 8 + p * 2,
            raw16(50),
          );
        }
        bank[start + 320 + u] = u;
      }
      bank.setRange(start + 330, start + 332, raw16(120));
      final name = ascii.encode(
        [
          'Classic Clean',
          'Edge of Breakup',
          'Midnight Lead',
          'Ambient Space',
        ][id % 4],
      );
      bank.setRange(start + 332, start + 332 + name.length, name);
      bank[start + 349] = 6;
      bank[start + 350] = 15;
      bank[start + 351] = 65;
      bank[start + 358] = 1;
      bank[start + 361] = 1;
      bank[start + 356] = 30;
      bank[start + 368] = 2;
      bank[start + 371] = 1;
      bank[start + 366] = 100;
    }
  }
  static const typeIds = [0x100, 0x200, 0x300, 0x400, 0x500, 0x600];
  static const typeNames = ['GATE', 'COMP', 'DRIVE', 'AMP', 'DELAY', 'REVERB'];
  final bank = Uint8List(Gt1.bankSize);
  int revision = 1;
  final requests = <Message>[];
  final _bytes = StreamController<List<int>>.broadcast();
  final _connected = StreamController<bool>.broadcast();
  bool online = false, subscribed = false;
  int drum = 0, loop = 0;
  bool tuner = false;
  Stopwatch clock = Stopwatch();
  int loopLength = 0;
  int? _writeId;
  int _writeOffset = 0, _writeTotal = 0, _writeRevision = 0;
  final _staging = <int>[];
  bool wrongAck = false;
  @override
  final int payload;
  @override
  Stream<List<int>> get bytes => _bytes.stream;
  @override
  Stream<bool> get connected => _connected.stream;
  @override
  Future<List<DevicePort>> scan() async => [
    const DevicePort('demo', 'Apexis STD · 演示设备', '演示'),
  ];
  @override
  Future<void> connect(DevicePort port) async {
    online = true;
    _connected.add(true);
  }

  @override
  Future<void> disconnect() async {
    online = false;
    subscribed = false;
    _staging.clear();
    _connected.add(false);
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _bytes.close();
    await _connected.close();
  }

  void _reply(Message m, [List<int> data = const [], int error = 0]) =>
      emitFrame(Gt1.frame(m.component, m.command, m.selector, data, error));
  void emitFrame(List<int> frame) {
    if (!online) return;
    for (var i = 0; i < frame.length; i += payload) {
      _bytes.add(frame.sublist(i, min(i + payload, frame.length)));
    }
  }

  void notifyRange(int start, int length) {
    if (!subscribed) return;
    final maxRaw = payload == 20 ? 113 : 187;
    for (var at = 0; at < length; at += maxRaw) {
      final count = min(maxRaw, length - at);
      emitFrame(
        Gt1.frame(9, 0x7e, 0x42, [
          ...Gt1.header(revision, start + at, count),
          ...Gt1.u16(start),
          ...Gt1.u16(length),
          ...Gt1.pack7(bank.sublist(start + at, start + at + count)),
        ], 0),
      );
    }
  }

  void currentView() {
    notifyRange(0, 64);
    notifyRange(Gt1.patchOffset(bank[0]), 374);
  }

  void externalEdit(int offset, List<int> value) {
    bank.setRange(offset, offset + value.length, value);
    revision++;
    notifyRange(offset, value.length);
  }

  @override
  Future<void> send(Uint8List frame) async {
    if (!online) throw StateError('演示设备已断开');
    final m = Message.parse(frame, response: false);
    requests.add(m);
    final d = m.data, c = m.component, op = m.command, s = m.selector;
    final start = Gt1.patchOffset(bank[0]);
    if (c == 9 && op == 1 && s == 0x22) {
      _reply(m, [
        1,
        1,
        1,
        ...Gt1.u14(0),
        ...Gt1.u14(2),
        ...Gt1.u14(117),
        1,
        32,
        4,
        10,
        ...Gt1.u14(12),
        3,
        6,
        ...ascii.encode('GT1AC703N'),
      ]);
      return;
    }
    if (c == 9 && op == 1 && s == 0x40) {
      if (d.isEmpty) {
        _reply(
          m,
          Gt1.header(revision, Gt1.bankSize, payload == 20 ? 119 : 193),
        );
        return;
      }
      final rev = Gt1.integer(d, 0, 5),
          offset = Gt1.integer(d, 5, 3),
          count = min(Gt1.integer(d, 8, 2), payload == 20 ? 119 : 193);
      if (rev != 0 && rev != revision) {
        _reply(m, [], 8);
        return;
      }
      _reply(m, [
        ...Gt1.header(revision, offset, count),
        ...Gt1.pack7(bank.sublist(offset, offset + count)),
      ]);
      return;
    }
    if (c == 9 && op == 0 && s == 0x42) {
      if (d[0] == 2) {
        final rev = Gt1.integer(d, 1, 5);
        _reply(m, [
          2,
          wrongAck ? 2 : 3,
          ...Gt1.u32(revision),
        ], rev == revision ? 0 : 8);
        return;
      }
      subscribed = d[0] != 0;
      _reply(m, [d[0], subscribed ? 1 : 0, ...Gt1.u32(revision)]);
      if (subscribed) currentView();
      return;
    }
    if (c == 9 && op == 0 && s == 0x41) {
      final rev = Gt1.integer(d, 0, 5),
          id = Gt1.integer(d, 5, 2),
          offset = Gt1.integer(d, 7, 3),
          total = Gt1.integer(d, 10, 2),
          at = Gt1.integer(d, 12, 2),
          count = Gt1.integer(d, 14, 2);
      final raw = Gt1.unpack7(d.sublist(16), count);
      if (rev != revision) {
        _reply(m, [], 8);
        return;
      }
      if (at == 0) {
        _writeId = id;
        _writeOffset = offset;
        _writeTotal = total;
        _writeRevision = rev;
        _staging.clear();
      }
      if (id != _writeId ||
          offset != _writeOffset ||
          total != _writeTotal ||
          rev != _writeRevision ||
          at != _staging.length) {
        _reply(m, [], 1);
        return;
      }
      _staging.addAll(raw);
      final complete = _staging.length == total;
      var changed = false;
      if (complete) {
        for (var i = 0; i < total; i++) {
          if (bank[offset + i] != _staging[i]) changed = true;
        }
        bank.setRange(offset, offset + total, _staging);
        if (changed) revision++;
      }
      final readCount = complete ? min(total, payload == 20 ? 113 : 187) : 0;
      _reply(m, [
        ...Gt1.header(revision, offset, readCount),
        ...Gt1.u14(id),
        complete ? 1 : 0,
        ...Gt1.u14(_staging.length),
        ...Gt1.u14(total),
        ...Gt1.pack7(bank.sublist(offset, offset + readCount)),
      ]);
      if (changed) notifyRange(offset, total);
      return;
    }
    if (c == 0 && op == 0 && s == 0) {
      bank[0] = d[0];
      revision++;
      _reply(m);
      currentView();
      return;
    }
    if (c == 0 && op == 8 && s == 0) {
      _reply(m, [1]);
      return;
    }
    if (c == 0 && op == 1 && s == 0x23) {
      if (d.isEmpty) {
        _reply(m, [1, 32, 4, 16, 3]);
        return;
      }
      final out = [1, d[0], d[1], bank[0]];
      for (var i = d[0]; i < d[0] + d[1]; i++) {
        final name = ascii.encode(
          Patch(
            bank.sublist(Gt1.patchOffset(i), Gt1.patchOffset(i) + 374),
          ).name,
        );
        out.addAll([0, name.length, ...name]);
      }
      _reply(m, out);
      return;
    }
    if (c == 0 && (op == 0x0a || op == 0x0c)) {
      if (op == 0x0c && d[0] == d[1]) {
        _reply(m);
        return;
      }
      final a = Gt1.patchOffset(d[0]),
          b = Gt1.patchOffset(d[1]),
          old = bank.sublist(a, a + 374);
      if (op == 0x0c) {
        bank.setRange(a, a + 374, bank.sublist(b, b + 374));
        // GT1 MOVE swaps records; the currently playing content follows its
        // new address, matching the firmware and the real-device audit.
        if (bank[0] == d[0]) {
          bank[0] = d[1];
        } else if (bank[0] == d[1]) {
          bank[0] = d[0];
        }
      }
      bank.setRange(b, b + 374, old);
      revision++;
      _reply(m);
      currentView();
      return;
    }
    if (c == 1 && op == 1 && s == 0x22) {
      if (d.isEmpty) {
        _reply(m, Gt1.u14(typeIds.length));
        return;
      }
      final i = Gt1.integer(d, 0, 2);
      _reply(m, [
        ...Gt1.u14(i),
        ...Gt1.u14(typeIds[i]),
        0,
        i == 3 ? 8 : 4,
        4,
        ...ascii.encode(typeNames[i]),
      ]);
      return;
    }
    if (c == 1 && op == 1 && s == 0x20) {
      _reply(m, Gt1.u16(0));
      return;
    }
    if (c == 1 && op == 0 && s == 1) {
      final id = d[0], type = Gt1.integer(d, 1, 2), i = typeIds.indexOf(type);
      if (i < 0 || id > bank[start + 349] || id >= 10) {
        _reply(m, [], 1);
        return;
      }
      bank.fillRange(start + id * 32, start + id * 32 + 32, 0);
      bank.setRange(start + id * 32, start + id * 32 + 2, raw16(type));
      bank[start + id * 32 + 2] = 1;
      bank[start + id * 32 + 5] = i == 3 ? 8 : 4;
      for (var p = 0; p < bank[start + id * 32 + 5]; p++) {
        bank.setRange(
          start + id * 32 + 6 + p * 2,
          start + id * 32 + 8 + p * 2,
          raw16(50),
        );
      }
      if (id == bank[start + 349]) {
        bank[start + 320 + id] = id;
        bank[start + 349]++;
      }
      revision++;
      _reply(m);
      currentView();
      return;
    }
    if (c == 1 && op == 0x0b && s == 0) {
      final id = d[0], count = bank[start + 349];
      if (id >= count) {
        _reply(m, [], 1);
        return;
      }
      final chain = bank
          .sublist(start + 320, start + 320 + count)
          .where((v) => v != id)
          .map((v) => v > id ? v - 1 : v)
          .toList();
      bank.setRange(
        start + id * 32,
        start + (count - 1) * 32,
        bank.sublist(start + (id + 1) * 32, start + count * 32),
      );
      bank.fillRange(start + (count - 1) * 32, start + count * 32, 0);
      bank.fillRange(start + 320, start + 330, 0);
      bank.setRange(start + 320, start + 320 + chain.length, chain);
      bank[start + 349]--;
      revision++;
      _reply(m);
      currentView();
      return;
    }
    if (c == 2 && op == 1) {
      final id = d[0], count = bank[start + id * 32 + 5];
      if (s == 0x20) {
        _reply(m, [...d, count]);
        return;
      }
      final p = d[3],
          value = le16(bank, start + id * 32 + 6 + 2 * p, signed: true);
      if (s == 0x23) {
        _reply(m, [...d, 0, ...Gt1.s14(0), ...Gt1.s14(100)]);
        return;
      }
      if (s == 0x22) {
        _reply(m, [
          ...d,
          ...ascii.encode(
            [
              'Gain',
              'Bass',
              'Middle',
              'Treble',
              'Presence',
              'Resonance',
              'Bright',
              'Level',
            ][p % 8],
          ),
        ]);
        return;
      }
      if (s == 0x21) {
        _reply(m, [...d, ...ascii.encode('$value')]);
        return;
      }
    }
    if (c == 3 && op == 1 && s == 0x20) {
      if (d.isEmpty) {
        _reply(m, [1, ...Gt1.u14(3), ...Gt1.u14(0), 16]);
        return;
      }
      final id = Gt1.integer(d, 0, 2),
          name = ascii.encode(
            ['ROCK 01', 'BLUES 01', 'METRONOME'][Gt1.integer(d, 0, 2)],
          );
      _reply(m, [
        1,
        ...Gt1.u14(id),
        ...Gt1.u16(0),
        name.length,
        ...name.expand((v) => [v >> 4, v & 15]),
      ]);
      return;
    }
    if (c == 3 && op == 1 && s == 0) {
      _reply(m, [
        drum,
        bank[5],
        ...Gt1.u14(le16(bank, 14)),
        ...Gt1.u14(le16(bank, 18)),
        bank[17],
      ]);
      return;
    }
    if (c == 3 && (op == 3 || op == 4)) {
      drum = op == 3 ? 1 : 0;
      _reply(m);
      return;
    }
    if (c == 4 && op == 1 && s == 0x21) {
      final elapsed = clock.elapsedMicroseconds;
      final position = loop == 1 && loopLength > 0
          ? elapsed % loopLength
          : elapsed;
      _reply(m, [
        1,
        loop,
        loopLength > 0 ? 1 : 0,
        0,
        ...Gt1.u32(1),
        ...Gt1.u32(min(position, 30000000)),
        ...Gt1.u32(loopLength),
        ...Gt1.u32(30000000),
      ]);
      return;
    }
    if (c == 4 && op >= 0x12 && op <= 0x16) {
      if (op == 0x14) {
        loop = 2;
        clock
          ..reset()
          ..start();
      }
      if (op == 0x13) {
        if (loop == 2) loopLength = min(clock.elapsedMicroseconds, 30000000);
        loop = 0;
        clock.stop();
      }
      if (op == 0x12) {
        if (loopLength == 0) {
          _reply(m, [], 1);
          return;
        }
        loop = 1;
        clock
          ..reset()
          ..start();
      }
      if (op == 0x15) {
        loop = 0;
        loopLength = 0;
        clock
          ..stop()
          ..reset();
      }
      _reply(m);
      return;
    }
    if (c == 5 && (op == 3 || op == 4)) {
      tuner = op == 3;
      _reply(m);
      return;
    }
    if (c == 5 && op == 1 && s == 0) {
      _reply(m, [...Gt1.s14(0), ...Gt1.u14(255), ...Gt1.u14(128)]);
      return;
    }
    if (c == 9 && op == 1 && s == 0) {
      _reply(m, [tuner ? 4 : 0, 1, 48, 64]);
      return;
    }
    if (c == 9 && op == 1 && s == 0x20) {
      _reply(m, [1, 0]);
      return;
    }
    if (c == 8 && op == 0 && s == 0x20) {
      final offset = start + 352 + 10 * d[0];
      bank.setRange(offset, offset + 10, [
        ...raw16(Gt1.integer(d, 3, 2)),
        ...raw16(Gt1.signed14(d, 6)),
        ...raw16(Gt1.signed14(d, 8)),
        d[1],
        d[2],
        d[5],
        d[10],
      ]);
      revision++;
      _reply(m);
      currentView();
      return;
    }
    _reply(m, [], 6);
  }
}
