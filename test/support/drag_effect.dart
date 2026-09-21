import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercise the real pointer route and drop animation, never call onReorder.
Future<void> dragEffectCard(WidgetTester tester, int id, int target) async {
  Finder card(int unit) => find.byKey(ValueKey('chain-unit-$unit'));
  await tester.ensureVisible(card(id));
  await tester.pumpAndSettle();
  final start = tester.getCenter(card(id));
  final finish = tester.getCenter(card(target));
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  for (var step = 1; step <= 16; step++) {
    await gesture.moveTo(Offset.lerp(start, finish, step / 16)!);
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pump(const Duration(milliseconds: 300));
  await gesture.up();
  // Pump the drop animation and service transport events in their real zone.
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
  }
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}
