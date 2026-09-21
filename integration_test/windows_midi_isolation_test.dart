import 'dart:async';
import 'package:apexis/transport/native_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Enumeration only: never opens GT1, writes a parameter, resets or power-cycles.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real Windows MIDI scan keeps UI and timers responsive', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: TextButton(
              onPressed: () => setState(() => taps++),
              child: Text('点击 $taps'),
            ),
          ),
        ),
      ),
    );
    final native = NativeTransport();
    final watch = Stopwatch()..start();
    var ticks = 0, completed = false;
    final timer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => ticks++,
    );
    final report = <String, Object?>{
      'readOnly': true,
      'operation': 'scan only',
    };
    final scan = native
        .scan()
        .then<void>(
          (ports) {
            report['ports'] = ports.map((p) => p.name).toList();
          },
          onError: (Object error) {
            report['error'] = '$error';
          },
        )
        .whenComplete(() => completed = true);
    for (var i = 0; !completed && i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (i == 5) await tester.tap(find.byType(TextButton));
    }
    expect(
      completed,
      isTrue,
      reason: 'Driver failure must have a bounded deadline',
    );
    await scan;
    await tester.tap(find.byType(TextButton));
    await tester.pump();
    expect(taps, greaterThan(0));
    expect(watch.elapsedMilliseconds, lessThan(8000));
    report['elapsedMs'] = watch.elapsedMilliseconds;
    report['timerTicks'] = ticks;
    report['taps'] = taps;
    report['uiResponsive'] = true;
    binding.reportData = report;
    timer.cancel();
    await native.dispose();
  });
}
