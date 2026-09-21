import 'package:apexis/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Counts {
  final mounts = <String, int>{};
  final builds = <String, int>{};
  final disposals = <String, int>{};
}

class Probe extends StatefulWidget {
  const Probe(this.id, this.value, this.counts, {super.key});
  final String id;
  final int value;
  final Counts counts;
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  @override
  void initState() {
    super.initState();
    widget.counts.mounts.update(widget.id, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  void dispose() {
    widget.counts.disposals.update(widget.id, (n) => n + 1, ifAbsent: () => 1);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget.counts.builds.update(widget.id, (n) => n + 1, ifAbsent: () => 1);
    return Text('${widget.id}:${widget.value}');
  }
}

void main() {
  testWidgets('切页取消拖动草稿，迟到的结束回调不向隐藏页提交', (tester) async {
    final commits = <int>[];
    Widget view(String id) => MaterialApp(
      home: Scaffold(
        body: RetainedPageViewport(
          pageId: id,
          cacheToken: 0,
          child: id == 'A'
              ? Column(
                  children: [
                    ValueControl(
                      label: 'slider',
                      value: 50,
                      min: 0,
                      max: 100,
                      onCommit: commits.add,
                    ),
                    RotaryControl(
                      label: 'knob',
                      value: 50,
                      min: 0,
                      max: 100,
                      onCommit: commits.add,
                    ),
                  ],
                )
              : const Text('B'),
        ),
      ),
    );
    await tester.pumpWidget(view('A'));
    final slider = tester.widget<Slider>(find.byType(Slider));
    final dial = tester.widget<GestureDetector>(
      find
          .descendant(
            of: find.byType(RotaryControl),
            matching: find.byType(GestureDetector),
          )
          .first,
    );
    slider.onChanged!(75);
    dial.onVerticalDragStart!(DragStartDetails());
    dial.onVerticalDragUpdate!(
      DragUpdateDetails(
        delta: const Offset(0, -40),
        primaryDelta: -40,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pump();
    await tester.pumpWidget(view('B'));
    slider.onChangeEnd!(75);
    dial.onVerticalDragEnd!(DragEndDetails());
    await tester.pumpWidget(view('A'));
    expect(commits, isEmpty);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 50);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已访问页面复用元素，隐藏页不随活动页通知重建，返回读取新值', (tester) async {
    final counts = Counts();
    Widget view(String id, int value, {int epoch = 0}) => MaterialApp(
      home: RetainedPageViewport(
        pageId: id,
        cacheToken: epoch,
        child: Probe(id, value, counts),
      ),
    );
    await tester.pumpWidget(view('A', 1));
    expect(counts.mounts, {'A': 1});
    await tester.pumpWidget(view('B', 2));
    final buildsA = counts.builds['A'];
    expect(find.text('A:1'), findsNothing);
    expect(find.text('A:1', skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(view('B', 3));
    expect(counts.builds['A'], buildsA);
    await tester.pumpWidget(view('A', 4));
    expect(find.text('A:4'), findsOneWidget);
    expect(find.text('A:1', skipOffstage: false), findsNothing);
    expect(counts.mounts, {'A': 1, 'B': 1});
    await tester.pumpWidget(view('A', 5, epoch: 1));
    expect(counts.disposals, {'A': 1, 'B': 1});
    expect(counts.mounts, {'A': 2, 'B': 1});
    expect(find.text('B:3', skipOffstage: false), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(counts.disposals, {'A': 2, 'B': 1});
  });

  testWidgets('隐藏页面无焦点、无指针命中且关闭 ticker', (tester) async {
    final node = FocusNode();
    var taps = 0;
    Widget view(String id) => MaterialApp(
      home: Scaffold(
        body: RetainedPageViewport(
          pageId: id,
          cacheToken: 0,
          child: id == 'A'
              ? Column(
                  children: [
                    TextField(focusNode: node),
                    TextButton(
                      onPressed: () => taps++,
                      child: const Text('hidden'),
                    ),
                  ],
                )
              : const Text('B'),
        ),
      ),
    );
    await tester.pumpWidget(view('A'));
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isTrue);
    await tester.pumpWidget(view('B'));
    await tester.pump();
    expect(node.hasFocus, isFalse);
    expect(find.text('hidden').hitTestable(), findsNothing);
    final field = tester.element(find.byType(TextField, skipOffstage: false));
    expect(TickerMode.valuesOf(field).enabled, isFalse);
    expect(taps, 0);
    await tester.pumpWidget(const SizedBox());
    node.dispose();
  });
}
