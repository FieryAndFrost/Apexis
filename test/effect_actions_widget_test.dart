import 'dart:ui' show PointerDeviceKind;
import 'package:apexis/data/controller.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/transport/transport.dart';
import 'package:apexis/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/firmware_demo.dart';
import 'support/drag_effect.dart';

class RejectMovementDemo extends FirmwareDemo {
  RejectMovementDemo() : super(124);
  @override
  Future<void> send(frame) async {
    final m = Message.parse(frame, response: false);
    if (m.component == 9 &&
        m.command == 0 &&
        m.selector == 0x41 &&
        Gt1.integer(m.data, 7, 3) == Gt1.patchOffset(0, 320)) {
      emitFrame(Gt1.frame(9, 0, 0x41, [], 1));
      return;
    }
    await super.send(frame);
  }
}

void main() {
  Future<(ApexisController, FirmwareDemo)> open(
    WidgetTester tester, {
    int count = 6,
    FirmwareDemo? device,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    final c = ApexisController(), d = device ?? FirmwareDemo(124);
    final start = Gt1.patchOffset(0);
    d.bank[start + 349] = count;
    for (var i = 0; i < 10; i++) {
      d.bank[start + 320 + i] = i < count ? i : 0;
      if (i >= 6 && i < count) {
        d.bank.setRange(
          start + i * 32,
          start + (i + 1) * 32,
          d.bank.sublist(start, start + 32),
        );
      }
    }
    await tester.runAsync(
      () => c.connect(d, const DevicePort('demo', 'GT1', 'demo')),
    );
    expect(c.error, isNull);
    await tester.pumpWidget(ApexisApp(controller: c));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c.disconnect);
      c.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    return (c, d);
  }

  Finder button(String tooltip) =>
      find.byWidgetPredicate((w) => w is IconButton && w.tooltip == tooltip);
  Finder card(int id) => find.byKey(ValueKey('chain-unit-$id'));
  Future<void> drag(WidgetTester tester, int id, int target) async {
    await dragEffectCard(tester, id, target);
  }

  Future<void> click(WidgetTester tester, String tooltip) async {
    await tester.ensureVisible(button(tooltip));
    await tester.runAsync(() async {
      await tester.tap(button(tooltip));
      // The controller's transport subscription was created in runAsync;
      // allow its real event queue to finish before pumping UI animations.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> select(WidgetTester tester, int id) async {
    final card = find.byWidgetPredicate(
      (w) =>
          w is Semantics &&
          (w.properties.label ?? '').startsWith('UNIT ${id + 1} '),
    );
    await tester.ensureVisible(card);
    await tester.runAsync(() async {
      await tester.tap(card);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

  Future<void> tapControl(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'rejected movement leaves confirmed order intact and reports error',
    (tester) async {
      final (c, _) = await open(tester, device: RejectMovementDemo());
      final original = c.patch!.bytes.toList();
      await drag(tester, 0, 1);
      expect(c.error, contains('设备拒绝'));
      expect(c.patch!.bytes, original);
      expect(c.selectedUnit, 0);
      expect(c.ready, isTrue);
    },
  );

  testWidgets('effect UI add/replace/bypass/clear/delete and cancellation', (
    tester,
  ) async {
    final (c, _) = await open(tester);
    await click(tester, '添加效果');
    expect(find.text('添加效果'), findsOneWidget);
    await tapControl(
      tester,
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text('GATE'),
      ),
    );
    expect(c.patch!.count, 7);
    expect(c.selectedUnit, 6);
    await tapControl(tester, find.widgetWithText(OutlinedButton, '选择效果'));
    await tapControl(
      tester,
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text('COMP'),
      ),
    );
    expect(c.patch!.unit(6).type, 0x200);
    final enabled = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == '启用 COMP',
      ),
      matching: find.byType(Switch),
    );
    await tapControl(tester, enabled);
    expect(c.patch!.unit(6).enabled, isFalse);
    await tapControl(tester, enabled);
    expect(c.patch!.unit(6).enabled, isTrue);
    await tapControl(tester, find.widgetWithText(SwitchListTile, '旁路时清除效果尾音'));
    expect(c.patch!.unit(6).bytes[4], 1);
    await click(tester, '删除效果');
    await tapControl(tester, find.widgetWithText(TextButton, '取消'));
    expect(c.patch!.count, 7);
    await click(tester, '删除效果');
    await tapControl(tester, find.text('确认'));
    expect(c.patch!.count, 6);
    expect(c.selectedUnit, lessThan(6));
    expect(c.patch!.chain, [0, 1, 2, 3, 4, 5]);
    expect(c.error, isNull);
  });

  testWidgets('actual mouse drags reorder without changing UNIT data', (
    tester,
  ) async {
    final (c, d) = await open(tester);
    await select(tester, 3);
    final units = c.patch!.bytes.sublist(0, 320);
    d.requests.clear();
    await drag(tester, 3, 2);
    expect(c.patch!.chain, [0, 1, 3, 2, 4, 5]);
    expect(c.selectedUnit, 3);
    expect(c.patch!.bytes.sublist(0, 320), units);
    await drag(tester, 3, 2);
    expect(c.patch!.chain, [0, 1, 2, 3, 4, 5]);
    expect(c.selectedUnit, 3);
    expect(c.patch!.bytes.sublist(0, 320), units);
    expect(c.error, isNull);
    expect(
      d.requests.where(
        (m) => m.component == 9 && m.command == 0 && m.selector == 0x41,
      ),
      hasLength(2),
    );
  });

  testWidgets('drag first to last and back, old movement buttons removed', (
    tester,
  ) async {
    final (c, d) = await open(tester);
    d.requests.clear();
    expect(button('向前移动'), findsNothing);
    expect(button('向后移动'), findsNothing);
    await drag(tester, 0, 5);
    expect(c.patch!.chain, [1, 2, 3, 4, 5, 0]);
    expect(c.selectedUnit, 0);
    await drag(tester, 0, 1);
    expect(c.patch!.chain, [0, 1, 2, 3, 4, 5]);
    expect(c.error, isNull);
  });

  for (final count in [0, 1, 10]) {
    testWidgets('movement controls handle $count effects', (tester) async {
      final (c, _) = await open(tester, count: count);
      if (count == 0) {
        expect(button('向前移动'), findsNothing);
        expect(button('向后移动'), findsNothing);
      } else if (count == 1) {
        expect(button('向前移动'), findsNothing);
        expect(button('向后移动'), findsNothing);
        await tester.drag(card(0), const Offset(100, 0));
        await tester.pumpAndSettle();
        expect(c.patch!.chain, [0]);
      } else {
        await select(tester, 9);
        await drag(tester, 9, 8);
        expect(c.patch!.chain, [0, 1, 2, 3, 4, 5, 6, 7, 9, 8]);
        await drag(tester, 9, 8);
        expect(c.patch!.chain, List.generate(10, (i) => i));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancelled and same-position drags never write', (tester) async {
    final (c, d) = await open(tester);
    d.requests.clear();
    final gesture = await tester.startGesture(
      tester.getCenter(card(0)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.cancel();
    await tester.pumpAndSettle();
    await drag(tester, 0, 0);
    expect(c.patch!.chain, [0, 1, 2, 3, 4, 5]);
    expect(
      d.requests.where(
        (m) => m.component == 9 && m.command == 0 && m.selector == 0x41,
      ),
      isEmpty,
    );
  });

  testWidgets(
    'right-click position menu and Alt arrows replace movement buttons',
    (tester) async {
      final (c, _) = await open(tester);
      final click = await tester.startGesture(
        tester.getCenter(card(0)),
        kind: PointerDeviceKind.mouse,
        buttons: 2,
      );
      await click.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('放到第 3 位'));
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
      await tester.pumpAndSettle();
      expect(c.patch!.chain, [1, 2, 0, 3, 4, 5]);
      final ink = find.descendant(of: card(0), matching: find.byType(InkWell));
      Focus.of(tester.element(ink)).requestFocus();
      await tester.pump();
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.altLeft,
          physicalKey: PhysicalKeyboardKey.altLeft,
        );
        await tester.sendKeyEvent(
          LogicalKeyboardKey.arrowLeft,
          physicalKey: PhysicalKeyboardKey.arrowLeft,
        );
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.altLeft,
          physicalKey: PhysicalKeyboardKey.altLeft,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(c.patch!.chain, [1, 0, 2, 3, 4, 5]);
    },
  );

  testWidgets('parameter edits do not invalidate subsequent chain dragging', (
    tester,
  ) async {
    final (c, _) = await open(tester);
    await tester.runAsync(() => c.patchField(351, [75]));
    await tester.pumpAndSettle();
    await drag(tester, 0, 1);
    expect(c.patch!.chain, [1, 0, 2, 3, 4, 5]);
    expect(c.patch!.output, 75);
  });

  testWidgets(
    'external chain change cancels a stale drag without overwriting it',
    (tester) async {
      final (c, d) = await open(tester);
      d.requests.clear();
      final gesture = await tester.startGesture(
        tester.getCenter(card(0)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(180, 0));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => c.patchField(320, [2, 1, 0, 3, 4, 5, 0, 0, 0, 0]),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(c.patch!.chain, [2, 1, 0, 3, 4, 5]);
      expect(
        d.requests.where(
          (m) => m.component == 9 && m.command == 0 && m.selector == 0x41,
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('drag near viewport edge auto-scrolls through all ten effects', (
    tester,
  ) async {
    final (c, _) = await open(tester, count: 10);
    await tester.binding.setSurfaceSize(const Size(720, 1000));
    await tester.pumpAndSettle();
    final view = find.byType(ReorderableListView);
    final bounds = tester.getRect(view);
    final start = tester.getCenter(card(0));
    final edge = Offset(bounds.right - 8, start.dy);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    for (var step = 1; step <= 16; step++) {
      await gesture.moveTo(Offset.lerp(start, edge, step / 16)!);
      await tester.pump(const Duration(milliseconds: 30));
    }
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final scroll = tester.widget<ReorderableListView>(view).scrollController!;
    final position = scroll.position;
    final dropOffset = scroll.offset;
    expect(dropOffset, greaterThan(0));
    await gesture.up();
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }
    await tester.pumpAndSettle();
    expect(scroll.position, same(position));
    expect(
      scroll.offset,
      closeTo(dropOffset.clamp(0.0, scroll.position.maxScrollExtent), .01),
    );
    expect(c.patch!.chain.last, 0);
    expect(c.selectedUnit, 0);
    expect(tester.takeException(), isNull);
  });

  for (final (rejected, selected) in [
    (false, 0),
    (false, 4),
    (true, 0),
    (true, 4),
  ]) {
    testWidgets(
      'drop preserves horizontal scroll offset (rejected=$rejected, selected=$selected)',
      (tester) async {
        final (c, _) = await open(
          tester,
          count: 10,
          device: rejected ? RejectMovementDemo() : null,
        );
        await tester.binding.setSurfaceSize(const Size(720, 1000));
        if (selected != 0) await tester.runAsync(() => c.selectUnit(selected));
        await tester.pumpAndSettle();
        final view = find.byType(ReorderableListView);
        final scroll = tester
            .widget<ReorderableListView>(view)
            .scrollController!;
        scroll.jumpTo(200);
        await tester.pumpAndSettle();
        final position = scroll.position;
        final start = tester.getCenter(card(4));
        final end = tester.getCenter(card(5));
        final gesture = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        for (var step = 1; step <= 16; step++) {
          await gesture.moveTo(Offset.lerp(start, end, step / 16)!);
          await tester.pump(const Duration(milliseconds: 30));
        }
        final dropOffset = scroll.offset;
        expect(dropOffset, closeTo(200, .01));
        await gesture.up();
        for (var frame = 0; frame < 16; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          expect(
            scroll.offset,
            closeTo(dropOffset, .01),
            reason: 'drop frame $frame',
          );
          expect(scroll.position, same(position));
        }
        await tester.pumpAndSettle();
        expect(scroll.offset, closeTo(dropOffset, .01));
        expect(
          c.selectedUnit,
          selected,
        ); // Neither an off-screen nor a moved selection may pull us back.
        expect(
          c.patch!.chain,
          rejected
              ? List.generate(10, (i) => i)
              : [0, 1, 2, 3, 5, 4, 6, 7, 8, 9],
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
