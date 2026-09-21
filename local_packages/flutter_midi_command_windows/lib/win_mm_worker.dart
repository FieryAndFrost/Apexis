import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:win32/win32.dart';
import 'windows_midi_device.dart';

/// Runs only in a dedicated isolate. No method-channel/plugin registration.
void winMmWorkerMain(SendPort host) {
  final commands = ReceivePort();
  final devices = <String, WindowsMidiDevice>{};
  final rx = StreamController<MidiPacket>.broadcast();
  final setup = StreamController<String>.broadcast();
  var stopping = false;
  rx.stream.listen((packet) {
    if (!stopping) host.send(['data', packet.device.id, packet.data]);
  }, onError: (Object error) {
    if (!stopping) host.send(['error', error.toString()]);
  });

  Future<void> closeDevice(String id) async {
    final device = devices[id];
    if (device == null) return;
    device.disconnect();
    // Native buffers remain owned by this worker until unprepare succeeds.
    while (device.hasNativeHandles) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    devices.remove(id);
  }

  commands.listen((dynamic value) async {
    final message = value as List;
    if (message[0] == 'shutdown') {
      if (stopping) return;
      stopping = true;
      for (final id in devices.keys.toList()) {
        await closeDevice(id);
      }
      await rx.close();
      await setup.close();
      commands.close();
      Isolate.exit();
    }
    if (stopping) return;
    final sequence = message[1] as int;
    try {
      Object? result;
      switch (message[2]) {
        case 'scan':
          result = _scan();
        case 'connect':
          final id = message[3] as String;
          if (devices.containsKey(id)) throw StateError('MIDI 端口正在使用或关闭');
          final descriptor = _scan().where((d) => d['id'] == id).firstOrNull;
          if (descriptor == null) throw StateError('MIDI 端点已移除');
          final device =
              WindowsMidiDevice(id, descriptor['name'] as String, rx, setup, 0);
          // Register ownership before opening: partial failures may need cleanup.
          devices[id] = device;
          for (final p in descriptor['inputs'] as List) {
            device.addInputPort(p[0] as int, p[1] as int);
          }
          for (final p in descriptor['outputs'] as List) {
            device.addOutputPort(p[0] as int, p[1] as int);
          }
          try {
            device.connect();
          } catch (_) {
            await closeDevice(id);
            rethrow;
          }
        case 'send':
          final args = message[3] as List;
          final device = devices[args[0]];
          if (device == null) throw StateError('MIDI 端点未连接');
          device.send(args[1] as Uint8List);
        case 'disconnect':
          await closeDevice(message[3] as String);
        default:
          throw UnsupportedError('Unknown MIDI operation ${message[2]}');
      }
      host.send(['reply', sequence, true, result]);
    } catch (e) {
      host.send(['reply', sequence, false, e.toString()]);
    }
  });
  host.send(['ready', commands.sendPort]);
}

List<Map<String, Object>> _scan() {
  final result = <String, Map<String, Object>>{};
  final input = calloc<MIDIINCAPS>(), output = calloc<MIDIOUTCAPS>();
  try {
    final duplicates = <String, int>{};
    for (var i = 0; i < midiInGetNumDevs(); i++) {
      if (midiInGetDevCaps(i, input, sizeOf<MIDIINCAPS>()) != 0) continue;
      final name = input.ref.szPname;
      final number = duplicates.update(name, (n) => n + 1, ifAbsent: () => 0);
      final id = number == 0 ? name : '$name ($number)';
      result[id] = {
        'id': id,
        'name': name,
        'inputs': [
          [i, input.ref.wPid]
        ],
        'outputs': <List<int>>[],
      };
    }
    duplicates.clear();
    for (var i = 0; i < midiOutGetNumDevs(); i++) {
      if (midiOutGetDevCaps(i, output, sizeOf<MIDIOUTCAPS>()) != 0) continue;
      final name = output.ref.szPname;
      final number = duplicates.update(name, (n) => n + 1, ifAbsent: () => 0);
      final id = number == 0 ? name : '$name ($number)';
      final descriptor = result.putIfAbsent(
          id,
          () => {
                'id': id,
                'name': name,
                'inputs': <List<int>>[],
                'outputs': <List<int>>[],
              });
      (descriptor['outputs'] as List).add([i, output.ref.wPid]);
    }
    return result.values.toList();
  } finally {
    calloc.free(input);
    calloc.free(output);
  }
}
