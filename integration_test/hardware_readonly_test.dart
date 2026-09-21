import 'dart:async';
import 'dart:typed_data';
import 'package:apexis/data/controller.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/protocol/session.dart';
import 'package:apexis/transport/native_transport.dart';
import 'package:apexis/transport/transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Wire-level allowlist: no parameter writes, musical actions or file sessions.
class ReadOnlyTransport implements DeviceTransport {
  ReadOnlyTransport(this.inner, this.trace) {
    sub = inner.bytes.listen((chunk) {
      for (final frame in decoder.add(chunk)) {
        try {
          final m = Message.parse(frame);
          trace.add({'rx': frame.toList(), 'error': m.error});
        } catch (e) {
          trace.add({'invalid_rx': frame.toList(), 'error': '$e'});
        }
      }
    }, onError: (Object e) => trace.add({'transport_error': '$e'}));
  }
  final DeviceTransport inner;
  final List<Map<String, Object?>> trace;
  final decoder = FrameDecoder();
  late final StreamSubscription<List<int>> sub;
  @override
  Stream<List<int>> get bytes => inner.bytes;
  @override
  Stream<bool> get connected => inner.connected;
  @override
  int get payload => inner.payload;
  @override
  Future<List<DevicePort>> scan() => inner.scan();
  @override
  Future<void> connect(DevicePort port) => inner.connect(port);
  @override
  Future<void> send(Uint8List frame) {
    final m = Message.parse(frame, response: false);
    final sync =
        m.component == 9 &&
        m.command == 0 &&
        m.selector == 0x42 &&
        ((m.data.length == 1 && m.data[0] == 3) ||
            (m.data.length == 6 && m.data[0] == 2));
    final get =
        m.command == 1 &&
        !(m.component == 0 && [0x30, 0x31, 0x34, 0x35].contains(m.selector));
    if (!get && !sync) {
      throw StateError('Hardware audit blocked a non-read-only command');
    }
    trace.add({'tx': frame.toList()});
    return inner.send(frame);
  }

  @override
  Future<void> disconnect() => inner.disconnect();
  @override
  Future<void> dispose() async {
    await sub.cancel();
    await inner.dispose();
  }
}

Future<Uint8List> readRange(
  ProtocolSession session,
  int revision,
  int offset,
  int size,
) async {
  final bytes = BytesBuilder();
  while (bytes.length < size) {
    final remaining = size - bytes.length;
    final count = remaining.clamp(1, 193);
    final part = RangeReply(
      await session.request(Gt1.read(revision, offset + bytes.length, count)),
    );
    expect(part.revision, revision);
    expect(part.offset, offset + bytes.length);
    expect(part.count, inInclusiveRange(1, count));
    bytes.add(part.raw);
  }
  return bytes.takeBytes();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('explicitly opted-in Windows hardware read-only audit', (
    tester,
  ) async {
    const enabled = bool.fromEnvironment('HARDWARE_AUDIT');
    const target = String.fromEnvironment('MIDI_DEVICE');
    if (!enabled || target.isEmpty) {
      fail(
        'Requires --dart-define=HARDWARE_AUDIT=true and an exact MIDI_DEVICE name',
      );
    }
    final trace = <Map<String, Object?>>[];
    final cycles = <Map<String, Object?>>[];
    final checks = <Map<String, Object?>>[];
    binding.reportData = {
      'hardware': {
        'device': target,
        'readOnly': true,
        'cycles': cycles,
        'checks': checks,
        'trace': trace,
      },
    };
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('GT1 只读通信检查 · 不修改设备参数'))),
      ),
    );
    for (var cycle = 0; cycle < 3; cycle++) {
      final native = NativeTransport();
      final ports = (await native.scan())
          .where((p) => p.name == target)
          .toList();
      expect(
        ports,
        hasLength(1),
        reason: 'Exact, unambiguous MIDI endpoint required',
      );
      final controller = ApexisController();
      try {
        await controller.connect(
          ReadOnlyTransport(native, trace),
          ports.single,
        );
        expect(controller.error, isNull);
        expect(controller.ready, isTrue);
        expect(controller.demo, isFalse);
        final s = controller.session!, revision = controller.revision;
        final globals = await readRange(s, revision, 0, 64);
        final patch = await readRange(
          s,
          revision,
          Gt1.patchOffset(globals[0]),
          374,
        );
        expect(globals, controller.globals);
        expect(patch, controller.patch!.bytes);
        cycles.add({
          'cycle': cycle + 1,
          'version': controller.identity!.version,
          'revision': revision,
          'selected': globals[0],
          'units': patch[349],
          'types': controller.types.length,
          'currentViewMatchesRead': true,
          'logs': List.of(controller.logs),
        });
        if (cycle == 0) {
          // Legacy readbacks independently check the corresponding protocol paths.
          for (final q in <(String, int, int, List<int>, int)>[
            ('system', 9, 0, [], 4),
            ('links', 9, 0x20, [], 2),
            ('autooff', 9, 0x21, [], 3),
            ('preset', 0, 0x7f, [], 13),
            ('preset-directory-capability', 0, 0x23, [], 5),
            ('chain', 1, 0x7f, [], 1 + patch[349] * 4),
            ('resource-count', 1, 0x20, [], 3),
            ('global', 6, 0x20, [], 8),
            ('usb-volume', 6, 0x21, [], 2),
            ('usb-mode', 6, 0x22, [], 2),
            ('eq', 7, 0x20, [], 35),
            ('drum-state', 3, 0, [], 7),
            ('drum-catalogue', 3, 0x20, [], 6),
            ('looper-state', 4, 0, [], 8),
            ('looper-progress', 4, 0x21, [], 24),
            ('looper-auto', 4, 0x22, [], 3),
            ('looper-length', 4, 0x23, [], 8),
            ('looper-countin', 4, 0x24, [], 7),
            ('tuner-result', 5, 0, [], 6),
            ('knob-0', 8, 0x20, [0], 11),
            ('knob-1', 8, 0x20, [1], 11),
            ('preset-file-status', 0, 0x32, [], 7),
            ('bank-file-status', 0, 0x36, [], 7),
          ]) {
            final watch = Stopwatch()..start();
            try {
              final reply = await s.command(q.$2, 1, q.$3, q.$4);
              checks.add({
                'name': q.$1,
                'status': reply.data.length == q.$5 ? 'ok' : 'invalid_length',
                'milliseconds': watch.elapsedMilliseconds,
                'data': reply.data.toList(),
              });
              expect(reply.data, hasLength(q.$5), reason: q.$1);
            } on DeviceError catch (e) {
              checks.add({
                'name': q.$1,
                'status': 'device_rejected',
                'code': e.code,
                'data': e.data.toList(),
              });
            }
          }
          for (var at = 0; at < 128; at += 12) {
            await controller.loadPresetPage(at);
            expect(controller.error, isNull);
          }
          checks.add({
            'name': 'preset-names',
            'status': 'ok',
            'count': controller.presetNames.length,
          });
          expect(controller.presetNames, hasLength(128));
          expect(
            controller.revision,
            revision,
            reason: 'Read-only audit must not change parameters',
          );
        }
      } finally {
        await controller.disconnect();
        controller.dispose();
      }
    }
    expect(
      trace.where(
        (e) => e.containsKey('invalid_rx') || e.containsKey('transport_error'),
      ),
      isEmpty,
    );
    // A completed audit can report firmware rejection; that is not feature acceptance.
    binding.reportData!['allQueriedFeaturesAvailable'] = !checks.any(
      (c) => c['status'] != 'ok',
    );
  });
}
