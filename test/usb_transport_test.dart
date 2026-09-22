import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/transport/usb_worker.dart';
import 'package:apexis/transport/windows_usb_transport.dart';
import 'package:apexis/transport/transport.dart';

void fakeUsb(SendPort host) {
  final commands = ReceivePort();
  var opened = false;
  commands.listen((dynamic message) async {
    if (message[0] == 'shutdown') {
      commands.close();
      return;
    }
    final id = message[1], op = message[2];
    Object? result;
    if (op == 'scan') {
      result = [
        ['gt1-private-interface', 'GT1 WinUSB (gt1-private-interface)'],
      ];
    } else if (op == 'open') {
      host.send(['opening']);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      if (message[3] == 'fault-during-open') {
        host.send(['fault', 'RX failed before open reply']);
      }
      opened = true;
    } else if (op == 'close') {
      opened = false;
    } else if (op == 'write') {
      if (!opened) {
        host.send(['reply', id, false, 'closed']);
        return;
      }
      host.send(['data', message[3]]);
    } else if (op == 'fault') {
      opened = false;
      host.send(['fault', 'device removed']);
    } else if (op == 'hang') {
      return;
    } else if (op == 'exit') {
      Isolate.exit();
    } else if (op == 'status') {
      result = opened;
    }
    host.send(['reply', id, true, result]);
  });
  host.send(['ready', commands.sendPort]);
}

void main() {
  test('WinUSB early RX failure never publishes connected=true', () async {
    final worker = UsbWorker(fakeUsb);
    final transport = WindowsUsbTransport(worker: worker);
    final states = <bool>[];
    final errors = <Object>[];
    final stateSub = transport.connected.listen(states.add);
    final byteSub = transport.bytes.listen((_) {}, onError: errors.add);
    await expectLater(
      transport.connect(
        const DevicePort('fault-during-open', 'GT1', 'USB WinUSB'),
      ),
      throwsStateError,
    );
    expect(states, isNot(contains(true)));
    expect(errors, hasLength(1));
    await transport.dispose();
    await stateSub.cancel();
    await byteSub.cancel();
  });
  test(
    'WinUSB scan, copied TX, byte stream, disconnect and reconnect',
    () async {
      final worker = UsbWorker(fakeUsb);
      final transport = WindowsUsbTransport(worker: worker);
      final states = <bool>[];
      final received = <List<int>>[];
      final stateSub = transport.connected.listen(states.add);
      final byteSub = transport.bytes.listen(received.add);
      final port = (await transport.scan()).single;
      expect(port.kind, 'USB WinUSB');
      await transport.connect(port);
      final frame = Uint8List.fromList([0xf0, 1, 0xf7]);
      final sending = transport.send(frame);
      frame[1] = 99;
      await sending;
      await worker.request('status');
      expect(received, [
        [0xf0, 1, 0xf7],
      ]);
      await transport.disconnect();
      await expectLater(transport.send(frame), throwsStateError);
      await transport.connect(port);
      await worker.request('status');
      expect(states.where((value) => value).length, 2);
      await transport.dispose();
      await stateSub.cancel();
      await byteSub.cancel();
    },
  );
  test('WinUSB rejects oversized frames and wrong port types', () async {
    final transport = WindowsUsbTransport(worker: UsbWorker(fakeUsb));
    await expectLater(
      transport.connect(const DevicePort('x', 'x', 'USB MIDI')),
      throwsArgumentError,
    );
    await transport.connect((await transport.scan()).single);
    await expectLater(transport.send(Uint8List(245)), throwsArgumentError);
    await expectLater(transport.send(Uint8List(0)), throwsArgumentError);
    await transport.dispose();
  });
  test('WinUSB unplug reports fault and rejects further writes', () async {
    final worker = UsbWorker(fakeUsb);
    final transport = WindowsUsbTransport(worker: worker);
    final errors = <Object>[];
    final sub = transport.bytes.listen((_) {}, onError: errors.add);
    await transport.connect((await transport.scan()).single);
    final disconnected = transport.connected.firstWhere((online) => !online);
    await worker.request('fault');
    await disconnected;
    expect(errors, hasLength(1));
    await expectLater(
      transport.send(Uint8List.fromList([1])),
      throwsStateError,
    );
    await transport.dispose();
    await sub.cancel();
  });
  test('cancel during WinUSB open closes the newly opened handle', () async {
    final worker = UsbWorker(fakeUsb);
    final transport = WindowsUsbTransport(worker: worker);
    final port = (await transport.scan()).single;
    final entering = worker.events.firstWhere((event) => event[0] == 'opening');
    final opening = expectLater(transport.connect(port), throwsStateError);
    await entering;
    await transport.disconnect();
    await opening;
    expect(await worker.request('status'), isFalse);
    await transport.dispose();
  });
  test(
    'WinUSB worker deadline retires session without hanging caller',
    () async {
      final worker = UsbWorker(
        fakeUsb,
        timeout: const Duration(milliseconds: 200),
      );
      await worker.request('status');
      await expectLater(worker.request('hang'), throwsStateError);
      await expectLater(worker.request('status'), throwsStateError);
      await worker.dispose();
    },
  );
  test('WinUSB worker unexpected exit completes request with error', () async {
    final worker = UsbWorker(fakeUsb);
    await worker.request('status');
    await expectLater(worker.request('exit'), throwsStateError);
    await worker.dispose();
  });
}
