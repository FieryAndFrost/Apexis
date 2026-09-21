import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexis/ui/theme.dart';
import 'package:apexis/ui/widgets.dart';

void main() {
  Widget selection(Axis axis, int selected, {bool reduced = false}) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: axis == Axis.horizontal ? 300 : 100,
                height: axis == Axis.horizontal ? 60 : 180,
                child: SlidingSelection(
                  axis: axis,
                  selected: selected,
                  count: 3,
                  color: AppColors.accent,
                  child: Flex(
                    direction: axis,
                    children: List.generate(
                      3,
                      (_) => const SizedBox(width: 100, height: 60),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
  Finder getIndicator() => find.descendant(
    of: find.byType(SlidingSelection),
    matching: find.byType(DecoratedBox),
  );

  for (final axis in Axis.values) {
    testWidgets('$axis 选中背景平滑移动，快速反向不跳回起点', (tester) async {
      await tester.pumpWidget(selection(axis, 0));
      final start = tester.getTopLeft(getIndicator());
      await tester.pumpWidget(selection(axis, 2));
      expect(tester.getTopLeft(getIndicator()), start);
      await tester.pump(const Duration(milliseconds: 80));
      final midway = tester.getTopLeft(getIndicator());
      final coordinate = axis == Axis.horizontal ? midway.dx : midway.dy;
      expect(coordinate, greaterThan(0));
      expect(coordinate, lessThan(axis == Axis.horizontal ? 200 : 120));
      await tester.pumpWidget(selection(axis, 1));
      expect(tester.getTopLeft(getIndicator()), midway);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(getIndicator()),
        axis == Axis.horizontal ? const Offset(100, 0) : const Offset(0, 60),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('减少动画时选中背景直接到达目标', (tester) async {
    await tester.pumpWidget(selection(Axis.horizontal, 0, reduced: true));
    await tester.pumpWidget(selection(Axis.horizontal, 2, reduced: true));
    expect(tester.getTopLeft(getIndicator()), const Offset(200, 0));
  });

  Widget page(
    String id,
    Offset direction, {
    bool reduced = false,
    bool enabled = true,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: DirectionalPageTransition(
        enabled: enabled,
        pageId: id,
        direction: direction,
        child: Text(id),
      ),
    ),
  );
  testWidgets('关闭整页动画后立即切页且不再调度动画帧', (tester) async {
    await tester.pumpWidget(page('A', const Offset(1, 0)));
    await tester.pumpWidget(page('B', const Offset(1, 0)));
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(page('B', const Offset(1, 0), enabled: false));
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(page('C', const Offset(0, -1), enabled: false));
    expect(find.text('B'), findsNothing);
    expect(find.text('C'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DirectionalPageTransition),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );
    expect(tester.hasRunningAnimations, isFalse);
  });

  Offset offset(WidgetTester tester) => tester
      .widget<SlideTransition>(
        find.descendant(
          of: find.byType(DirectionalPageTransition),
          matching: find.byType(SlideTransition),
        ),
      )
      .position
      .value;

  testWidgets('内容按切换方向滑入，旧页面立即移除，普通重建不重启动画', (tester) async {
    await tester.pumpWidget(page('A', const Offset(1, 0)));
    expect(offset(tester), Offset.zero);
    await tester.pumpWidget(page('B', const Offset(1, 0)));
    expect(find.text('A'), findsNothing);
    expect(find.text('B'), findsOneWidget);
    expect(offset(tester).dx, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 100));
    final midway = offset(tester);
    await tester.pumpWidget(page('B', const Offset(1, 0)));
    expect(offset(tester), midway);
    await tester.pumpWidget(page('A', const Offset(-1, 0)));
    expect(offset(tester).dx, lessThan(0));
    await tester.pumpWidget(page('C', const Offset(0, 1)));
    expect(offset(tester).dy, greaterThan(0));
    await tester.pumpWidget(page('D', const Offset(0, -1)));
    expect(offset(tester).dy, lessThan(0));
    await tester.pumpAndSettle();
    expect(offset(tester), Offset.zero);
    expect(find.text('C'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内容遵循减少动画，途中开启后立即结束', (tester) async {
    await tester.pumpWidget(page('A', const Offset(1, 0)));
    await tester.pumpWidget(page('B', const Offset(1, 0)));
    await tester.pump(const Duration(milliseconds: 60));
    expect(offset(tester).dx, greaterThan(0));
    await tester.pumpWidget(page('B', const Offset(1, 0), reduced: true));
    expect(offset(tester), Offset.zero);
    await tester.pumpWidget(page('C', const Offset(0, -1), reduced: true));
    expect(offset(tester), Offset.zero);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('页面位移期间复用内容绘制，不逐帧重画复杂控件', (tester) async {
    final painter = _PaintCounter();
    var id = 0;
    late StateSetter change;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            change = setState;
            return DirectionalPageTransition(
              pageId: '$id',
              direction: const Offset(1, 0),
              child: CustomPaint(painter: painter, size: const Size(300, 200)),
            );
          },
        ),
      ),
    );
    change(() => id++);
    await tester.pump();
    final firstFrame = painter.paints;
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(painter.paints - firstFrame, 0, reason: '平移的内容应复用绘制结果，而不是每帧重画');
    await tester.pumpAndSettle();
  });
}

class _PaintCounter extends CustomPainter {
  int paints = 0;
  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.green);
  }

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}
