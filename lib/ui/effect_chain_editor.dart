import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';

/// Local drag preview only; the controller remains the confirmed device state.
class EffectChainEditor extends StatefulWidget {
  const EffectChainEditor({
    super.key,
    required this.order,
    required this.selected,
    required this.version,
    required this.enabled,
    required this.cardWidth,
    required this.children,
    required this.onCommit,
  });
  final List<int> order;
  final int selected;
  final Object version;
  final bool enabled;
  final double cardWidth;
  final List<Widget> children;
  final Future<void> Function(List<int>) onCommit;

  @override
  State<EffectChainEditor> createState() => _EffectChainEditorState();
}

class _EffectChainEditorState extends State<EffectChainEditor> {
  final _scroll = ScrollController();
  List<int>? _draft, _dragOrder;
  Object? _dragVersion;
  int? _dragFrom;
  int _listGeneration = 0;
  bool _pending = false;
  bool _reveal = true;
  double _width = 0;
  bool get _enabled => widget.enabled && !_pending && widget.order.length > 1;

  @override
  void didUpdateWidget(EffectChainEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.version != widget.version ||
        !listEquals(oldWidget.order, widget.order) ||
        !widget.enabled) {
      // Recreate the native list only to cancel an invalid active drag.
      // Re-keying it on every ACK discards its ScrollPosition (including
      // unsaved offsets produced by edge auto-scroll) and jumps to zero.
      if (_dragOrder != null) _listGeneration++;
      _dragOrder = null;
      _draft = null;
    }
    // Reordering is not navigation: keep the viewport where the user dropped
    // the card, even when the selected UNIT is elsewhere in the chain.
    if (oldWidget.selected != widget.selected ||
        oldWidget.order.length != widget.order.length ||
        oldWidget.cardWidth != widget.cardWidth) {
      _reveal = true;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _place(int id, int target) async {
    if (!_enabled || target < 0 || target >= widget.order.length) return;
    final next = widget.order.toList(); // Growable: never mutate Patch.chain.
    final from = next.indexOf(id);
    if (from < 0 || from == target) return;
    next.insert(target, next.removeAt(from));
    setState(() {
      _pending = true;
      _draft = next;
    });
    try {
      await widget.onCommit(next);
    } finally {
      if (mounted) {
        setState(() {
          _pending = false;
          _draft = null;
        });
      }
    }
  }

  Future<void> _menu(int id, Offset position) async {
    if (!_enabled) return;
    final version = widget.version;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final target = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        for (var i = 0; i < widget.order.length; i++)
          PopupMenuItem(
            value: i,
            enabled: widget.order[i] != id,
            child: Text('放到第 ${i + 1} 位'),
          ),
      ],
    );
    if (mounted && target != null && widget.version == version) {
      await _place(id, target);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final order = _draft ?? widget.order;
      final extent = widget.cardWidth + 12;
      if (_width != box.maxWidth) {
        _width = box.maxWidth;
        _reveal = true;
      }
      if (_reveal && _dragOrder == null && !_pending) {
        _reveal = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients || _dragOrder != null || _pending) {
            return;
          }
          final index = widget.order.indexOf(widget.selected);
          _scroll.jumpTo(
            (index * extent - (_width - widget.cardWidth) / 2).clamp(
              0.0,
              _scroll.position.maxScrollExtent,
            ),
          );
        });
      }
      final scaler = MediaQuery.textScalerOf(context);
      double textHeight(String text, double size, {bool singleLine = false}) {
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium!.copyWith(fontSize: size),
          ),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: singleLine ? 1 : null,
        )..layout(maxWidth: widget.cardWidth - 20);
        final height = painter.height;
        painter.dispose();
        return height;
      }

      final height =
          82 +
          textHeight('10', 12, singleLine: true) +
          textHeight('TYPE', 14, singleLine: true) +
          textHeight('开启 · 编辑中', 12);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: height,
            child: Scrollbar(
              controller: _scroll,
              child: ReorderableListView(
                key: ValueKey(_listGeneration),
                scrollController: _scroll,
                scrollDirection: Axis.horizontal,
                primary: false,
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.only(bottom: 8),
                itemExtent: extent,
                onReorderStart: (index) {
                  _dragFrom = index;
                  _dragOrder = widget.order.toList();
                  _dragVersion = widget.version;
                },
                onReorderEnd: (index) {
                  if (index == _dragFrom || index == (_dragFrom ?? -2) + 1) {
                    _dragOrder = null;
                  }
                },
                onReorder: (from, to) {
                  final original = _dragOrder ?? widget.order;
                  final staleDrag =
                      _dragOrder != null && _dragVersion != widget.version;
                  _dragOrder = null;
                  if (!_enabled ||
                      staleDrag ||
                      !listEquals(original, widget.order)) {
                    return;
                  }
                  if (to > from) to--;
                  _place(original[from], to);
                },
                proxyDecorator: (child, index, animation) => Material(
                  color: Colors.transparent,
                  elevation: 8,
                  borderRadius: BorderRadius.circular(12),
                  child: child,
                ),
                children: [
                  for (var i = 0; i < order.length; i++)
                    Padding(
                      key: ValueKey('chain-unit-${order[i]}'),
                      padding: const EdgeInsets.only(right: 12),
                      child: Focus(
                        onKeyEvent: (_, event) {
                          if (!_enabled ||
                              event is! KeyDownEvent ||
                              !HardwareKeyboard.instance.isAltPressed) {
                            return KeyEventResult.ignored;
                          }
                          final delta =
                              event.logicalKey == LogicalKeyboardKey.arrowLeft
                              ? -1
                              : event.logicalKey ==
                                    LogicalKeyboardKey.arrowRight
                              ? 1
                              : 0;
                          if (delta == 0) return KeyEventResult.ignored;
                          _place(order[i], i + delta);
                          return KeyEventResult.handled;
                        },
                        child: GestureDetector(
                          onSecondaryTapDown: !_enabled
                              ? null
                              : (details) =>
                                    _menu(order[i], details.globalPosition),
                          child: MouseRegion(
                            cursor: _enabled
                                ? SystemMouseCursors.grab
                                : MouseCursor.defer,
                            child: _ChainDragStart(
                              onCancel: () => _dragOrder = null,
                              index: i,
                              enabled: _enabled,
                              child: widget
                                  .children[widget.order.indexOf(order[i])],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '拖拽卡片排序 · 右键选择位置 · Alt + ← / →',
            style: TextStyle(fontSize: 12, color: AppColors.muted),
          ),
        ],
      );
    },
  );
}

class _ChainDragStart extends StatelessWidget {
  const _ChainDragStart({
    required this.index,
    required this.enabled,
    required this.child,
    required this.onCancel,
  });
  final int index;
  final bool enabled;
  final Widget child;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) => Listener(
    onPointerCancel: (_) => onCancel(),
    onPointerDown: !enabled
        ? null
        : (event) {
            if (event.buttons != kPrimaryButton) return;
            SliverReorderableList.of(context).startItemDragReorder(
              index: index,
              event: event,
              recognizer:
                  (event.kind == PointerDeviceKind.touch
                        ? DelayedMultiDragGestureRecognizer()
                        : ImmediateMultiDragGestureRecognizer())
                    ..gestureSettings = MediaQuery.maybeGestureSettingsOf(
                      context,
                    ),
            );
          },
    child: child,
  );
}
