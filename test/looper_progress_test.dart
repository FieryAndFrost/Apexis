import 'package:apexis/data/controller.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/protocol/session.dart';
import 'package:apexis/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/firmware_demo.dart';

class SnapshotBusyDemo extends FirmwareDemo {
  SnapshotBusyDemo(super.firmwarePatch);
  int failures = 0, code = 1, queries = 0;
  @override
  Future<void> send(frame) async {
    final m = Message.parse(frame, response: false);
    if (m.component == 4 && m.command == 1 && m.selector == 0x21) {
      queries++;
      if (failures-- > 0) {
        emitFrame(Gt1.frame(4, 1, 0x21, [], code));
        return;
      }
    }
    await super.send(frame);
  }
}

void main() {
  Future<ApexisController> open(SnapshotBusyDemo d) async {
    final c = ApexisController();
    await c.connect(d, const DevicePort('demo', 'GT1', 'demo'));
    expect(c.error, isNull);
    addTearDown(() async {
      await c.disconnect();
      c.dispose();
    });
    return c;
  }

  test('0.2.124 transient snapshot rejection retries reads only', () async {
    final d = SnapshotBusyDemo(124)..failures = 2;
    final c = await open(d);
    d.requests.clear();
    expect(await c.readLooperProgress(), hasLength(24));
    expect(d.queries, 3);
    expect(d.requests.every((m) => m.command == 1), isTrue);
  });
  test('persistent rejection is surfaced after four attempts', () async {
    final d = SnapshotBusyDemo(124)..failures = 100;
    final c = await open(d);
    await expectLater(c.readLooperProgress(), throwsA(isA<DeviceError>()));
    expect(d.queries, 4);
  });
  test('unknown firmware error 1 is not reinterpreted', () async {
    final d = SnapshotBusyDemo(125)..failures = 2;
    final c = await open(d);
    await expectLater(c.readLooperProgress(), throwsA(isA<DeviceError>()));
    expect(d.queries, 1);
  });
  test('explicit BUSY is retryable; unsupported is not', () async {
    final d = SnapshotBusyDemo(125)
      ..failures = 1
      ..code = 7;
    final c = await open(d);
    expect(await c.readLooperProgress(), hasLength(24));
    expect(d.queries, 2);
    d.failures = 1;
    d.code = 6;
    await expectLater(c.readLooperProgress(), throwsA(isA<DeviceError>()));
    expect(d.queries, 3);
  });
  test('disconnect cancels pending snapshot retry', () async {
    final d = SnapshotBusyDemo(124)..failures = 100;
    final c = await open(d);
    final pending = c.readLooperProgress();
    final rejected = expectLater(pending, throwsStateError);
    while (d.queries == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await c.disconnect();
    await rejected;
    expect(d.queries, 1);
  });
}
