import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_midi_command_windows/windows_midi_device.dart';
import 'package:flutter_midi_command_windows/win_mm_api.dart';
import 'package:win32/win32.dart';

class FakeWinMm extends WinMmApi {
  final input = Queue<Pointer<MIDIHDR>>();
  final output = <Pointer<MIDIHDR>>[];
  int inputClosed = 0, outputClosed = 0, outputReleased = 0;
  bool rejectOpen = false, rejectSend = false, stillPlaying = false;
  @override
  int inputOpen(Pointer<HMIDIIN> h, int index) {
    h.value = 1;
    return 0;
  }

  @override
  int outputOpen(Pointer<IntPtr> h, int index) {
    if (rejectOpen) return MMSYSERR_ALLOCATED;
    h.value = 2;
    return 0;
  }

  @override
  int inputPrepare(int h, Pointer<MIDIHDR> p) {
    p.ref.dwFlags = 2;
    return 0;
  }

  @override
  int inputAdd(int h, Pointer<MIDIHDR> p) {
    expect(p.ref.dwFlags & 2, 2, reason: 'Must preserve PREPARED');
    p.ref.dwFlags = 2 | 4;
    input.add(p);
    return 0;
  }

  @override
  int inputStart(int h) => 0;
  @override
  int inputReset(int h) {
    for (final p in input) {
      p.ref.dwFlags = 2 | 1;
    }
    input.clear();
    return 0;
  }

  @override
  int inputUnprepare(int h, Pointer<MIDIHDR> p) => 0;
  @override
  int inputClose(int h) {
    inputClosed++;
    return 0;
  }

  @override
  int outputPrepare(int h, Pointer<MIDIHDR> p) {
    expect(List.generate(8, (i) => p.ref.dwReserved[i]), everyElement(0));
    p.ref.dwFlags = 2;
    return 0;
  }

  @override
  int outputSend(int h, Pointer<MIDIHDR> p) {
    if (rejectSend) return MMSYSERR_ERROR;
    p.ref.dwFlags = 2 | 4;
    output.add(p);
    return 0;
  }

  @override
  int outputReset(int h) {
    for (final p in output) {
      p.ref.dwFlags = 2 | 1;
    }
    return 0;
  }

  @override
  int outputUnprepare(int h, Pointer<MIDIHDR> p) {
    if (stillPlaying) return MIDIERR_STILLPLAYING;
    output.remove(p);
    outputReleased++;
    return 0;
  }

  @override
  int outputClose(int h) {
    outputClosed++;
    return 0;
  }

  void receive(int value) {
    final p = input.removeFirst();
    p.ref.lpData.cast<Uint8>().value = value;
    p.ref.dwBytesRecorded = 1;
    p.ref.dwFlags = 2 | 1;
  }
}

void main() {
  late FakeWinMm api;
  late WindowsMidiDevice device;
  late StreamController<MidiPacket> rx;
  late StreamController<String> setup;
  setUp(() {
    api = FakeWinMm();
    rx = StreamController<MidiPacket>.broadcast(sync: true);
    setup = StreamController<String>.broadcast();
    device = WindowsMidiDevice('test', 'test', rx, setup, 0, api: api);
    final ic = calloc<MIDIINCAPS>(), oc = calloc<MIDIOUTCAPS>();
    device.addInput(0, ic.ref);
    device.addOutput(0, oc.ref);
    calloc.free(ic);
    calloc.free(oc);
  });
  tearDown(() async {
    api.stillPlaying = false;
    device.disconnect();
    device.poll();
    expect(device.hasNativeHandles, isFalse);
    await rx.close();
    await setup.close();
  });
  test('input remains FIFO across buffer ring wraparound', () {
    final received = <int>[];
    rx.stream.listen((p) => received.addAll(p.data));
    device.connect();
    for (var i = 0; i < 6; i++) {
      api.receive(i);
    }
    device.poll();
    // Complete slots 6,7,0,1 before the next poll: scanning 0..7 is wrong.
    for (var i = 6; i < 10; i++) {
      api.receive(i);
    }
    device.poll();
    expect(received, List.generate(10, (i) => i));
  });
  test('output still owned after 20ms; DONE alone does not permit freeing',
      () async {
    device.connect();
    device.send(Uint8List.fromList([0xf0, 0, 0xf7]));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(device.pendingOutputCount, 1);
    expect(api.outputReleased, 0);
    api.output.single.ref.dwFlags = 2 | 1;
    api.stillPlaying = true;
    device.poll();
    expect(device.pendingOutputCount, 1);
    api.stillPlaying = false;
    device.poll();
    expect(device.pendingOutputCount, 0);
    expect(api.outputReleased, 1);
  });
  test('disconnect retains handle and buffers until driver releases them', () {
    device.connect();
    device.send(Uint8List.fromList([0xf0, 0xf7]));
    api.stillPlaying = true;
    device.disconnect();
    expect(device.connected, isFalse);
    expect(device.pendingOutputCount, 1);
    expect(api.outputClosed, 0);
    api.stillPlaying = false;
    device.poll();
    expect(api.outputClosed, 1);
    expect(device.hasNativeHandles, isFalse);
    device.disconnect();
    expect(api.inputClosed, 1);
    expect(api.outputClosed, 1);
  });
  test('partial open failure closes input and can reconnect', () {
    api.rejectOpen = true;
    expect(device.connect, throwsStateError);
    expect(device.hasNativeHandles, isFalse);
    expect(api.inputClosed, 1);
    api.rejectOpen = false;
    expect(device.connect(), isTrue);
  });
  test('send failure propagates and releases prepared memory', () {
    device.connect();
    api.rejectSend = true;
    expect(
        () => device.send(Uint8List.fromList([0xf0, 0xf7])), throwsStateError);
    expect(device.pendingOutputCount, 0);
    expect(api.outputReleased, 1);
  });
}
