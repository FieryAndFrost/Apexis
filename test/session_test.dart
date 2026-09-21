import 'dart:async';
import 'dart:typed_data';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/protocol/session.dart';
import 'package:apexis/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';

class TestTransport implements DeviceTransport {
  final rx = StreamController<List<int>>.broadcast();
  final link = StreamController<bool>.broadcast();
  bool failSend = false, hold = false, failDisconnect = false;
  int sent = 0, disconnected = 0;
  @override
  Stream<List<int>> get bytes => rx.stream;
  @override
  Stream<bool> get connected => link.stream;
  @override
  int get payload => 244;
  @override
  Future<List<DevicePort>> scan() async => [];
  @override
  Future<void> connect(DevicePort port) async {}
  @override
  Future<void> send(Uint8List frame) async {
    sent++;
    if (failSend) throw StateError('native send failed');
    if (hold) return;
    final m = Message.parse(frame, response: false);
    rx.add(Gt1.frame(m.component, m.command, m.selector, [], 0));
  }

  @override
  Future<void> disconnect() async {
    disconnected++;
    if (failDisconnect) throw StateError('native disconnect failed');
    link.add(false);
  }

  @override
  Future<void> dispose() async {
    await rx.close();
    await link.close();
  }
}

void main() {
  test(
    'timeout identifies command; disconnect error cannot escape or mask it',
    () async {
      final t = TestTransport()
        ..hold = true
        ..failDisconnect = true;
      final s = ProtocolSession(
        t,
        requestTimeout: const Duration(milliseconds: 20),
      );
      final faults = <Object>[];
      s.faults.listen(faults.add);
      await expectLater(
        s.command(0, 8, 0x36, [7, 0]),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains('00/08/36'),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(s.isValid, isFalse);
      expect(t.sent, 1);
      expect(t.disconnected, 1);
      expect(
        faults.map((e) => e.toString()).join(),
        contains('native disconnect failed'),
      );
      await expectLater(s.command(0, 8, 0x36), throwsStateError);
      expect(t.sent, 1);
      await s.dispose();
      await t.dispose();
    },
  );
  test('invalid local frame does not poison the request queue', () async {
    final transport = TestTransport();
    final s = ProtocolSession(transport);
    await expectLater(
      s.request(Uint8List.fromList([0xf0, 0xf7])),
      throwsFormatException,
    );
    expect((await s.command(9, 1, 0x22)).error, 0);
    expect(transport.sent, 1);
    await s.dispose();
    await transport.dispose();
  });
  test(
    'native send failure invalidates queued requests, no blind replay',
    () async {
      final t = TestTransport()..failSend = true;
      final s = ProtocolSession(t);
      final faults = <Object>[];
      s.faults.listen(faults.add);
      final first = expectLater(s.command(9, 1, 0), throwsStateError);
      final second = expectLater(s.command(9, 1, 0x20), throwsStateError);
      await Future.wait([first, second]);
      await Future<void>.delayed(Duration.zero);
      expect(t.sent, 1);
      expect(t.disconnected, 1);
      expect(faults.single.toString(), contains('native send failed'));
      await s.dispose();
      await t.dispose();
    },
  );
  test(
    'native receive error is reported and terminates the pending request',
    () async {
      final t = TestTransport()..hold = true;
      final s = ProtocolSession(t);
      final fault = s.faults.first;
      final pending = expectLater(s.command(9, 1, 0), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      t.rx.addError(StateError('native input failed'));
      expect((await fault).toString(), contains('native input failed'));
      await pending;
      expect(t.disconnected, 1);
      await s.dispose();
      await t.dispose();
    },
  );
}
