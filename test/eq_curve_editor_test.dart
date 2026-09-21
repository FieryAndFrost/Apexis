import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'package:apexis/ui/eq_curve_editor.dart';
import 'package:apexis/ui/theme.dart';
import 'package:apexis/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const initialBands = <EqBand>[
  (100, 0, 1),
  (500, 0, 2),
  (2000, 0, 3),
  (8000, 0, 4),
];
Widget host({
  List<EqBand> bands = initialBands,
  Object version = 1,
  Future<void> Function(int, int, int)? commit,
  bool enabled = true,
  bool active = true,
  double scale = 1,
}) => MaterialApp(
  theme: AppColors.theme,
  home: Scaffold(
    body: SingleChildScrollView(
      child: MediaQuery(
        data: MediaQueryData(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: TickerMode(
          enabled: active,
          child: EqCurveEditor(
            bands: bands,
            enabled: enabled,
            version: version,
            onCommit: commit,
          ),
        ),
      ),
    ),
  ),
);
Finder handle(int i) => find.byKey(ValueKey('eq-handle-$i'));
EqPainter painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.byWidgetPredicate(
                (w) => w is CustomPaint && w.painter is EqPainter,
              ),
            )
            .painter!
        as EqPainter;

void main() {
  testWidgets('EQ drag previews both axes and submits only once on release', (
    tester,
  ) async {
    final commits = <(int, int, int)>[];
    final ack = Completer<void>();
    await tester.pumpWidget(
      host(
        commit: (i, f, g) {
          commits.add((i, f, g));
          return ack.future;
        },
      ),
    );
    final start = tester.getCenter(handle(1));
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(start + const Offset(80, -38));
    await tester.pump();
    expect(commits, isEmpty);
    final preview = painter(tester).bands[1];
    expect(preview.$1, greaterThan(500));
    expect(preview.$2, 10);
    expect(preview.$3, 2);
    await gesture.up();
    await tester.pump();
    expect(commits, [(1, preview.$1.round(), 10)]);
    await tester.drag(handle(2), const Offset(20, -20));
    expect(commits.length, 1);
    await tester.pump(const Duration(milliseconds: 499));
    expect(find.textContaining('提交中'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.textContaining('提交中'), findsOneWidget);
    ack.complete();
    await tester.pumpAndSettle();
    expect(
      painter(tester).bands,
      initialBands,
    ); // No ACK readback => no false success value.
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'EQ drag clamps both extremes and failed commit returns to confirmed values',
    (tester) async {
      final commits = <(int, int, int)>[];
      await tester.pumpWidget(
        host(
          commit: (i, f, g) async {
            commits.add((i, f, g));
            throw StateError('rejected');
          },
        ),
      );
      await tester.drag(handle(0), const Offset(2000, -1000));
      await tester.pumpAndSettle();
      expect(commits, [(0, 20000, 18)]);
      expect(find.text('提交失败，请重试'), findsOneWidget);
      expect(painter(tester).bands, initialBands);
      await tester.drag(handle(0), const Offset(-2000, 1000));
      await tester.pumpAndSettle();
      expect(commits.last, (0, 20, -18));
    },
  );

  for (final reason in [
    'cancel',
    'escape',
    'disconnect',
    'external',
    'version',
    'hidden',
  ]) {
    testWidgets('EQ unfinished drag is discarded on $reason', (tester) async {
      var writes = 0;
      Future<void> commit(int i, int f, int g) async {
        writes++;
      }

      await tester.pumpWidget(host(commit: commit));
      final start = tester.getCenter(handle(0));
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(start + const Offset(50, -25));
      await tester.pump();
      if (reason == 'cancel') {
        await gesture.cancel();
      } else {
        if (reason == 'escape') {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        }
        if (reason == 'disconnect') await tester.pumpWidget(host());
        if (reason == 'external') {
          await tester.pumpWidget(
            host(commit: commit, bands: [(200, 1, 1), ...initialBands.skip(1)]),
          );
        }
        if (reason == 'version') {
          await tester.pumpWidget(host(commit: commit, version: 2));
        }
        if (reason == 'hidden') {
          await tester.pumpWidget(host(commit: commit, active: false));
        }
        await gesture.up();
      }
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('EQ overlapping bands can be selected and edited with keyboard', (
    tester,
  ) async {
    final commits = <(int, int, int)>[];
    await tester.pumpWidget(
      host(
        bands: List.filled(4, (500, 0, 1)),
        commit: (i, f, g) async {
          commits.add((i, f, g));
        },
      ),
    );
    await tester.tap(find.text('P3'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(commits, [(2, 500, 1)]);
  });

  testWidgets('EQ tap does not write; bypass still allows parameter editing', (
    tester,
  ) async {
    var writes = 0;
    await tester.pumpWidget(
      host(
        enabled: false,
        commit: (i, f, g) async {
          writes++;
        },
      ),
    );
    await tester.tap(handle(0));
    await tester.pumpAndSettle();
    expect(writes, 0);
    await tester.drag(handle(0), const Offset(50, 20));
    await tester.pumpAndSettle();
    expect(writes, 1);
  });

  testWidgets('EQ responsive controls fit with large text and reduced motion', (
    tester,
  ) async {
    for (final size in [
      const Size(375, 812),
      const Size(812, 375),
      const Size(1440, 900),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(host(scale: 2, commit: (i, f, g) async {}));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(handle(0)), const Size(48, 48));
    }
    await tester.binding.setSurfaceSize(null);
  });
}
