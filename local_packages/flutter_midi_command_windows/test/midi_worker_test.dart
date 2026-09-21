import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_midi_command_windows/midi_worker.dart';
import 'package:flutter_midi_command_windows/flutter_midi_command_windows.dart';

void fakeWorker(SendPort host) {
  final port = ReceivePort();
  var active = 0;
  port.listen((dynamic message) async {
    if (message[0] == 'shutdown') {
      Isolate.exit();
    }
    final sequence = message[1];
    final op = message[2];
    if (op == 'exit') Isolate.exit();
    if (op == 'crash') throw StateError('worker failed');
    if (op == 'reject') {
      host.send(['reply', sequence, false, 'rejected']);
      return;
    }
    active++;
    if (op == 'block' || op == 'disconnect') {
      host.send(['entered', op]);
      // A genuinely blocking call in the worker, not an asynchronous delay.
      sleep(const Duration(milliseconds: 900));
      host.send([
        'data',
        'gt1',
        Uint8List.fromList([0xf0, 0xf7])
      ]);
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    Object? result = [message[3], active];
    if (op == 'scan') {
      result = [
        {
          'id': 'gt1',
          'name': 'GT1',
          'inputs': [
            [0, 1]
          ],
          'outputs': [
            [0, 1]
          ]
        }
      ];
    }
    if (op == 'send') host.send(['data', 'gt1', message[3][1]]);
    host.send(['reply', sequence, true, result]);
    active--;
  });
  host.send(['ready', port.sendPort]);
}

void slowStart(SendPort host) {
  sleep(const Duration(milliseconds: 900));
  fakeWorker(host);
}

void main() {
  test('commands are serialized; rejection does not poison healthy worker',
      () async {
    final worker = MidiWorker(fakeWorker);
    final results =
        await Future.wait(List.generate(8, (i) => worker.request('echo', i)));
    for (var i = 0; i < results.length; i++) {
      expect(results[i], [i, 1]);
    }
    await expectLater(worker.request('reject'), throwsStateError);
    expect(await worker.request('echo', 9), [9, 1]);
    await worker.dispose();
  });

  test(
      'blocked native-equivalent call cannot freeze caller; timeout retires queue',
      () async {
    final worker =
        MidiWorker(fakeWorker, timeout: const Duration(milliseconds: 300));
    await worker.request('echo'); // Exclude isolate startup from deadline test.
    var ticks = 0;
    final timer =
        Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++);
    final events = <List<Object?>>[];
    worker.events.listen(events.add);
    final watch = Stopwatch()..start();
    final blocked = expectLater(worker.request('block'), throwsStateError);
    final queued = expectLater(
        worker.request('send', ['gt1', Uint8List(1)]), throwsStateError);
    await Future.wait([blocked, queued]);
    expect(ticks, greaterThan(5));
    expect(watch.elapsedMilliseconds, lessThan(850));
    await expectLater(worker.request('echo'), throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 750));
    expect(events.where((e) => e[0] == 'fault').length, 1);
    expect(events.where((e) => e[0] == 'data'), isEmpty,
        reason: 'Late packets discarded');
    timer.cancel();
    await worker.dispose();
  });

  for (final operation in ['exit', 'crash']) {
    test('worker $operation fails pending request without hanging', () async {
      final worker = MidiWorker(fakeWorker);
      await expectLater(worker.request(operation), throwsStateError);
      await expectLater(worker.request('echo'), throwsStateError);
      await worker.dispose();
    });
  }

  test(
      'startup timeout disposes late worker and never dispatches queued command',
      () async {
    final worker =
        MidiWorker(slowStart, timeout: const Duration(milliseconds: 300));
    await expectLater(worker.request('echo'), throwsA(isA<TimeoutException>()));
    await worker.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 750));
  });

  test(
      'dispose completes in-flight and queued requests without waiting on driver',
      () async {
    final worker = MidiWorker(fakeWorker);
    await worker.request('echo');
    final entered = worker.events.firstWhere((e) => e[0] == 'entered');
    final blocked = expectLater(worker.request('block'), throwsStateError);
    final queued = expectLater(worker.request('echo'), throwsStateError);
    await entered;
    await worker.dispose();
    await Future.wait([blocked, queued]);
    await Future<void>.delayed(const Duration(milliseconds: 950));
  });

  test(
      'plugin proxies bytes, detaches immediately, rejects reopen during close',
      () async {
    final worker =
        MidiWorker(fakeWorker, timeout: const Duration(milliseconds: 300));
    final plugin = FlutterMidiCommandWindows.forTesting(worker);
    final packets = <List<int>>[], errors = <Object>[];
    final sub = plugin.onMidiDataReceived!
        .listen((p) => packets.add(p.data), onError: errors.add);
    final device = (await plugin.devices).single;
    expect(device.inputPorts.length, 1);
    expect(device.outputPorts.length, 1);
    await plugin.connectToDevice(device);
    expect(device.connected, isTrue);
    final frame = Uint8List.fromList([0xf0, 1, 0xf7]);
    plugin.sendData(frame, deviceId: device.id);
    frame[1] = 99;
    await worker.request('echo');
    expect(packets.single, [0xf0, 1, 0xf7]);
    plugin.disconnectDevice(device);
    expect(device.connected, isFalse);
    await expectLater(plugin.connectToDevice(device), throwsStateError);
    expect(() => plugin.sendData(frame, deviceId: device.id), throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(errors, isNotEmpty);
    expect(packets.length, 1);
    await sub.cancel();
    plugin.teardown();
  });

  test('disconnect during open cannot publish a stale successful connection',
      () async {
    final worker = MidiWorker(fakeWorker);
    final plugin = FlutterMidiCommandWindows.forTesting(worker);
    final device = (await plugin.devices).single;
    final connecting =
        expectLater(plugin.connectToDevice(device), throwsStateError);
    plugin.disconnectDevice(device);
    await connecting;
    expect(device.connected, isFalse);
    plugin.teardown();
    await Future<void>.delayed(const Duration(milliseconds: 950));
  });
}
