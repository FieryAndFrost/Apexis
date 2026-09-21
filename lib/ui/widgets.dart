import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';

/// One moving selection surface, so rapid changes retarget the current position.
class SlidingSelection extends StatelessWidget {
  const SlidingSelection({
    super.key,
    required this.axis,
    required this.selected,
    required this.count,
    required this.child,
    required this.color,
    this.inset = EdgeInsets.zero,
    this.radius = 8,
  });
  final Axis axis;
  final int selected, count;
  final Widget child;
  final Color color;
  final EdgeInsets inset;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final position = axis == Axis.horizontal
        ? Offset(selected.toDouble(), 0)
        : Offset(0, selected.toDouble());
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: Align(
              alignment: Alignment.topLeft,
              child: FractionallySizedBox(
                widthFactor: axis == Axis.horizontal ? 1 / count : 1,
                heightFactor: axis == Axis.vertical ? 1 / count : 1,
                child: TweenAnimationBuilder<Offset>(
                  tween: Tween(begin: position, end: position),
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  builder: (context, offset, child) =>
                      FractionalTranslation(translation: offset, child: child),
                  child: RepaintBoundary(
                    child: Padding(
                      padding: inset,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(radius),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        RepaintBoundary(child: child),
      ],
    );
  }
}

/// Retains visited page elements without building unvisited pages. Hidden pages
/// cannot paint, tick, receive focus, or receive pointer input. The caller must
/// supply fresh widgets for the active page and invalidate on session changes.
class RetainedPageViewport extends StatefulWidget {
  const RetainedPageViewport({
    super.key,
    required this.pageId,
    required this.cacheToken,
    required this.child,
  });
  final String pageId;
  final Object cacheToken;
  final Widget child;
  @override
  State<RetainedPageViewport> createState() => _RetainedPageViewportState();
}

class _RetainedPageViewportState extends State<RetainedPageViewport> {
  final _pages = <String, Widget>{};
  @override
  void didUpdateWidget(RetainedPageViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheToken != widget.cacheToken) _pages.clear();
  }

  @override
  Widget build(BuildContext context) {
    // Only the active page receives newly constructed widgets/controller values.
    // Stable inactive children skip update/build; tight constraints permit their
    // already clean render objects to reuse layout when changing tabs.
    _pages.remove(widget.pageId);
    _pages[widget.pageId] = widget.child;
    if (_pages.length > 12) _pages.remove(_pages.keys.first);
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final entry in _pages.entries)
          Offstage(
            key: ValueKey((widget.cacheToken, entry.key)),
            offstage: entry.key != widget.pageId,
            child: TickerMode(
              enabled: entry.key == widget.pageId,
              child: ExcludeFocus(
                excluding: entry.key != widget.pageId,
                child: RepaintBoundary(child: entry.value),
              ),
            ),
          ),
      ],
    );
  }
}

/// Moves the active page surface without laying it out on each animation tick.
class DirectionalPageTransition extends StatefulWidget {
  const DirectionalPageTransition({
    super.key,
    required this.pageId,
    required this.direction,
    required this.child,
    this.enabled = true,
  });
  final String pageId;
  final Offset direction;
  final Widget child;
  final bool enabled;
  @override
  State<DirectionalPageTransition> createState() =>
      _DirectionalPageTransitionState();
}

class _DirectionalPageTransitionState extends State<DirectionalPageTransition>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: 1,
  );
  late final progress = CurvedAnimation(
    parent: controller,
    curve: Curves.easeOutCubic,
  );
  int _transition = 0;
  @override
  void didUpdateWidget(DirectionalPageTransition old) {
    super.didUpdateWidget(old);
    controller.duration = const Duration(milliseconds: 240);
    if (!widget.enabled) {
      _transition++;
      controller.value = 1;
    } else if (old.pageId != widget.pageId) {
      final transition = ++_transition;
      if (MediaQuery.disableAnimationsOf(context)) {
        controller.value = 1;
      } else {
        controller.value = 0;
        // Lay out/raster the new page once before starting the motion clock.
        // Expensive first-frame work must not consume the visible animation.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              transition == _transition &&
              widget.enabled &&
              !MediaQuery.disableAnimationsOf(context)) {
            controller.forward();
          }
        });
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.enabled || MediaQuery.disableAnimationsOf(context)) {
      _transition++;
      controller.value = 1;
    }
  }

  @override
  void dispose() {
    progress.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !widget.enabled
      ? RepaintBoundary(child: widget.child)
      : ClipRect(
          child: SlideTransition(
            position: Tween<Offset>(
              begin: widget.direction * .06,
              end: Offset.zero,
            ).animate(progress),
            child: RepaintBoundary(child: widget.child),
          ),
        );
}

class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.child,
    this.hideOnCompact = false,
  });
  final Widget child;
  final bool hideOnCompact;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (hideOnCompact &&
          (MediaQuery.sizeOf(context).width < 600 ||
              MediaQuery.sizeOf(context).height < 500)) {
        return const SizedBox.shrink();
      }
      if (constraints.maxWidth < 800 ||
          MediaQuery.textScalerOf(context).scale(14) > 19) {
        return child;
      }
      return Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '声音工作台',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                Text(
                  'SIGNAL & TONE',
                  style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.5,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          child,
        ],
      );
    },
  );
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      gradient: AppColors.panelGradient,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.border),
      boxShadow: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 16,
          offset: Offset(0, 6),
        ),
      ],
    ),
    child: Padding(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

class ValueControl extends StatefulWidget {
  const ValueControl({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onCommit,
    this.display,
  });
  final String label;
  final String? display;
  final int value, min, max;
  final FutureOr<void> Function(int)? onCommit;
  @override
  State<ValueControl> createState() => _ValueControlState();
}

/// Block duplicate writes immediately, but avoid flashing a disabled appearance
/// for a normal short device round-trip. Timers never outlive their control.
mixin _DelayedCommitFeedback<T extends StatefulWidget> on State<T> {
  bool pending = false;
  bool showPending = false;
  Timer? _pendingTimer;

  void beginPending() {
    setState(() => pending = true);
    _pendingTimer?.cancel();
    _pendingTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted && pending) setState(() => showPending = true);
    });
  }

  void endPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    pending = false;
    showPending = false;
  }

  @override
  void dispose() {
    _pendingTimer?.cancel();
    super.dispose();
  }
}

ButtonStyle? _pendingStepStyle(bool preserveAppearance) => preserveAppearance
    ? IconButton.styleFrom(disabledForegroundColor: AppColors.text)
    : null;

class _ValueControlState extends State<ValueControl>
    with _DelayedCommitFeedback<ValueControl> {
  double? draft;
  bool _pageActive = true;
  bool get enabled => _pageActive && !pending && widget.onCommit != null;
  bool get preserveAppearance =>
      _pageActive && pending && !showPending && widget.onCommit != null;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageActive = TickerMode.valuesOf(context).enabled;
    if (!_pageActive) draft = null;
  }

  void commit(int value) async {
    if (!mounted || !enabled) return;
    final callback = widget.onCommit!;
    setState(() => draft = value.clamp(widget.min, widget.max).toDouble());
    try {
      final result = callback(draft!.round());
      if (result is Future<void>) {
        beginPending();
        await result;
      }
    } finally {
      if (mounted) {
        setState(() {
          endPending();
          draft = null;
        });
      }
    }
  }

  @override
  void didUpdateWidget(ValueControl old) {
    super.didUpdateWidget(old);
    if ((!pending && (old.value != widget.value || !enabled)) ||
        old.min != widget.min ||
        old.max != widget.max) {
      draft = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = (draft ?? widget.value.toDouble()).clamp(
      widget.min.toDouble(),
      widget.max.toDouble(),
    );
    final sliderTheme = SliderTheme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        color: AppColors.inset,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.selected,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      draft == null
                          ? (widget.display ?? '${widget.value}')
                          : '${value.round()}${showPending ? ' …' : ''}',
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontFeatures: [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                tooltip: '减小 ${widget.label}',
                style: _pendingStepStyle(
                  preserveAppearance && value > widget.min,
                ),
                onPressed: !enabled || value <= widget.min
                    ? null
                    : () => commit(value.round() - 1),
                icon: const Icon(Icons.remove, size: 18),
              ),
              Expanded(
                child: SliderTheme(
                  data: preserveAppearance
                      ? sliderTheme.copyWith(
                          disabledActiveTrackColor:
                              sliderTheme.activeTrackColor,
                          disabledInactiveTrackColor:
                              sliderTheme.inactiveTrackColor,
                          disabledThumbColor: sliderTheme.thumbColor,
                          disabledActiveTickMarkColor:
                              sliderTheme.activeTickMarkColor,
                          disabledInactiveTickMarkColor:
                              sliderTheme.inactiveTickMarkColor,
                        )
                      : sliderTheme,
                  child: Slider(
                    label: '${value.round()}',
                    semanticFormatterCallback: (v) =>
                        '${widget.label} ${v.round()}',
                    value: value,
                    min: widget.min.toDouble(),
                    max: max(widget.min + 1, widget.max).toDouble(),
                    divisions: max(1, widget.max - widget.min),
                    onChanged: !enabled
                        ? null
                        : (v) {
                            if (_pageActive) setState(() => draft = v);
                          },
                    onChangeEnd: !enabled
                        ? null
                        : (v) {
                            commit(v.round());
                          },
                  ),
                ),
              ),
              IconButton(
                tooltip: '增大 ${widget.label}',
                style: _pendingStepStyle(
                  preserveAppearance && value < widget.max,
                ),
                onPressed: !enabled || value >= widget.max
                    ? null
                    : () => commit(value.round() + 1),
                icon: const Icon(Icons.add, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Drag up to increase, down to decrease; scroll the page outside the dial.
/// Device writes are committed only on release (or an explicit step / entry).
class RotaryControl extends StatefulWidget {
  const RotaryControl({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onCommit,
    this.display,
    this.format,
    this.compact = false,
  });
  final String label;
  final String? display;
  final int value, min, max;
  final FutureOr<void> Function(int)? onCommit;
  final String Function(int)? format;
  final bool compact;

  @override
  State<RotaryControl> createState() => _RotaryControlState();
}

class _RotaryControlState extends State<RotaryControl>
    with _DelayedCommitFeedback<RotaryControl> {
  double? draft;
  bool focused = false;
  bool _pageActive = true;
  bool get enabled =>
      _pageActive &&
      !pending &&
      widget.onCommit != null &&
      widget.max > widget.min;
  bool get visuallyEnabled =>
      _pageActive &&
      !showPending &&
      widget.onCommit != null &&
      widget.max > widget.min;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageActive = TickerMode.valuesOf(context).enabled;
    if (!_pageActive) draft = null;
  }

  int get value => (draft ?? widget.value.toDouble())
      .clamp(widget.min.toDouble(), max(widget.min, widget.max).toDouble())
      .round();
  String get valueDisplay =>
      widget.format?.call(value) ??
      (draft == null ? widget.display : null) ??
      '$value';
  String get display => showPending ? '$valueDisplay …' : valueDisplay;

  @override
  void didUpdateWidget(RotaryControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!pending && (oldWidget.value != widget.value || !enabled)) ||
        oldWidget.min != widget.min ||
        oldWidget.max != widget.max) {
      draft = null;
    }
  }

  void commit(int next) async {
    if (!mounted || !enabled) return;
    final callback = widget.onCommit!;
    setState(() => draft = next.clamp(widget.min, widget.max).toDouble());
    try {
      final result = callback(value);
      if (result is Future<void>) {
        beginPending();
        await result;
      }
    } finally {
      if (mounted) {
        setState(() {
          endPending();
          draft = null;
        });
      }
    }
  }

  Future<void> enterValue() async {
    final field = TextEditingController(text: '$value');
    String? error;
    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          void submit() {
            final parsed = int.tryParse(field.text.trim());
            if (parsed == null || parsed < widget.min || parsed > widget.max) {
              update(() => error = '请输入 ${widget.min}～${widget.max} 的整数');
              return;
            }
            Navigator.pop(context, parsed);
          }

          return AlertDialog(
            scrollable: true,
            title: Text(widget.label),
            content: TextField(
              controller: field,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                labelText: '参数值',
                helperText: '设备原始值 ${widget.min}～${widget.max}',
                errorText: error,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('确定')),
            ],
          );
        },
      ),
    );
    // The exit transition still owns the TextField for a short time.
    Future<void>.delayed(const Duration(milliseconds: 400), field.dispose);
    if (mounted && result != null) commit(result);
  }

  @override
  Widget build(BuildContext context) {
    final dial = Focus(
      onFocusChange: (v) => setState(() => focused = v),
      canRequestFocus: visuallyEnabled,
      onKeyEvent: (node, event) {
        if (!enabled || (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowRight ||
            key == LogicalKeyboardKey.arrowUp) {
          commit(value + 1);
        } else if (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowDown) {
          commit(value - 1);
        } else if (key == LogicalKeyboardKey.home) {
          commit(widget.min);
        } else if (key == LogicalKeyboardKey.end) {
          commit(widget.max);
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: Semantics(
        label: widget.label,
        value: display,
        hint: pending ? '等待设备确认' : '向上拖动增大，向下拖动减小，也可使用加减按钮或点击数值输入',
        enabled: enabled,
        increasedValue: enabled && value < widget.max ? '${value + 1}' : null,
        decreasedValue: enabled && value > widget.min ? '${value - 1}' : null,
        onIncrease: enabled && value < widget.max
            ? () => commit(value + 1)
            : null,
        onDecrease: enabled && value > widget.min
            ? () => commit(value - 1)
            : null,
        child: MouseRegion(
          cursor: visuallyEnabled
              ? SystemMouseCursors.resizeUpDown
              : SystemMouseCursors.basic,
          child: Listener(
            onPointerCancel: (_) => setState(() => draft = null),
            child: GestureDetector(
              key: ValueKey('dial-${widget.label}'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: !enabled
                  ? null
                  : (_) => setState(() => draft = value.toDouble()),
              onVerticalDragUpdate: !enabled
                  ? null
                  : (details) => setState(() {
                      draft =
                          ((draft ?? value.toDouble()) -
                                  details.delta.dy *
                                      (widget.max - widget.min) /
                                      200)
                              .clamp(
                                widget.min.toDouble(),
                                widget.max.toDouble(),
                              );
                    }),
              onVerticalDragEnd: !enabled
                  ? null
                  : (_) {
                      if (draft != null) commit(value);
                    },
              onVerticalDragCancel: () => setState(() => draft = null),
              child: SizedBox.square(
                dimension: widget.compact ? 76 : 100,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: DialPainter(
                      fraction: widget.max <= widget.min
                          ? 0
                          : (value - widget.min) / (widget.max - widget.min),
                      enabled: visuallyEnabled,
                      focused: focused,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final readout = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '减小 ${widget.label}',
          style: _pendingStepStyle(
            pending && visuallyEnabled && value > widget.min,
          ),
          onPressed: enabled && value > widget.min
              ? () => commit(value - 1)
              : null,
          icon: const Icon(Icons.remove, size: 16),
        ),
        Flexible(
          child: Tooltip(
            message: '输入 ${widget.label}',
            child: TextButton(
              onPressed: enabled ? enterValue : null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 2),
              ),
              child: Text(
                display,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: widget.compact ? 18 : 22,
                  color: visuallyEnabled ? AppColors.text : AppColors.disabled,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: '增大 ${widget.label}',
          style: _pendingStepStyle(
            pending && visuallyEnabled && value < widget.max,
          ),
          onPressed: enabled && value < widget.max
              ? () => commit(value + 1)
              : null,
          icon: const Icon(Icons.add, size: 16),
        ),
      ],
    );
    final label = Text(
      widget.label,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: visuallyEnabled ? AppColors.text : AppColors.disabled,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    );
    return widget.compact
        ? Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.inset,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: LayoutBuilder(
              builder: (context, box) {
                if (box.maxWidth < 230 ||
                    MediaQuery.textScalerOf(context).scale(14) > 19) {
                  return Column(children: [label, dial, readout]);
                }
                return Row(
                  children: [
                    dial,
                    const SizedBox(width: 8),
                    Expanded(child: Column(children: [label, readout])),
                  ],
                );
              },
            ),
          )
        : Column(children: [label, const SizedBox(height: 8), dial, readout]);
  }
}

class DialPainter extends CustomPainter {
  const DialPainter({
    required this.fraction,
    required this.enabled,
    required this.focused,
  });
  final double fraction;
  final bool enabled, focused;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide * .39;
    const start = 3 * pi / 4, sweep = 3 * pi / 2;
    final ring = Rect.fromCircle(center: center, radius: radius);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(ring, start, sweep, false, arc..color = AppColors.track);
    canvas.drawArc(
      ring,
      start,
      sweep * fraction,
      false,
      arc..color = enabled ? AppColors.accent : AppColors.disabled,
    );
    for (var i = 0; i <= 10; i++) {
      final a = start + sweep * i / 10;
      final direction = Offset(cos(a), sin(a));
      canvas.drawLine(
        center + direction * (radius + 5),
        center + direction * (radius + 8),
        Paint()
          ..color = AppColors.controlBorder
          ..strokeWidth = 1,
      );
    }
    final body = Rect.fromCircle(center: center, radius: radius - 7);
    canvas.drawCircle(
      center + const Offset(0, 3),
      radius - 4,
      Paint()
        ..color = AppColors.knobDark
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(
      center,
      radius - 6,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.knobLight, AppColors.knobDark],
        ).createShader(body),
    );
    canvas.drawCircle(
      center,
      radius - 9,
      Paint()
        ..shader = const SweepGradient(
          colors: [
            AppColors.surface,
            AppColors.card,
            AppColors.knobLight,
            AppColors.surface,
            AppColors.card,
            AppColors.surface,
          ],
        ).createShader(body),
    );
    final a = start + sweep * fraction;
    final direction = Offset(cos(a), sin(a));
    canvas.drawLine(
      center + direction * (radius * .49),
      center + direction * (radius - 11),
      Paint()
        ..color = enabled ? AppColors.text : AppColors.disabled
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    if (focused) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
        Paint()
          ..color = AppColors.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(DialPainter old) =>
      old.fraction != fraction ||
      old.enabled != enabled ||
      old.focused != focused;
}

class ChoiceControl extends StatelessWidget {
  const ChoiceControl({
    super.key,
    required this.label,
    required this.value,
    required this.choices,
    required this.onChanged,
  });
  final String label;
  final int value;
  final List<String> choices;
  final ValueChanged<int>? onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(
            choices.length,
            (i) => ChoiceChip(
              label: Text(choices[i]),
              selected: value == i,
              onSelected: onChanged == null ? null : (_) => onChanged!(i),
              showCheckmark: true,
              selectedColor: AppColors.selected,
              side: BorderSide(
                color: value == i ? AppColors.accent : AppColors.controlBorder,
                width: value == i ? 1.5 : 1,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Only uses two columns when both the available width and text scale allow it.
class ControlGrid extends StatelessWidget {
  const ControlGrid({super.key, required this.children, this.rotary = false});
  final List<Widget> children;
  final bool rotary;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = rotary
          ? (MediaQuery.textScalerOf(context).scale(14) > 19
                ? (constraints.maxWidth >= 520 ? 2 : 1)
                : constraints.maxWidth >= 480
                ? 3
                : constraints.maxWidth >= 300
                ? 2
                : 1)
          : constraints.maxWidth >= 500 &&
                MediaQuery.textScalerOf(context).scale(14) <= 19
          ? 2
          : 1;
      return Wrap(
        spacing: 12,
        runSpacing: rotary ? 16 : 0,
        children: [
          for (final child in children)
            SizedBox(
              width: (constraints.maxWidth - (columns - 1) * 12) / columns,
              child: child,
            ),
        ],
      );
    },
  );
}

/// Keep the selected unit visible after selection, reorder and viewport resize.
class EffectChainViewport extends StatefulWidget {
  const EffectChainViewport({
    super.key,
    required this.children,
    required this.selected,
  });
  final List<Widget> children;
  final int selected;
  @override
  State<EffectChainViewport> createState() => _EffectChainViewportState();
}

class _EffectChainViewportState extends State<EffectChainViewport> {
  final controller = ScrollController();
  double width = 0;
  bool reveal = true;
  @override
  void didUpdateWidget(EffectChainViewport old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected ||
        old.children.length != widget.children.length) {
      reveal = true;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (box.maxWidth != width) {
        width = box.maxWidth;
        reveal = true;
      }
      if (reveal) {
        reveal = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !controller.hasClients) return;
          final target = (widget.selected * 128 - (width - 104) / 2).clamp(
            0.0,
            controller.position.maxScrollExtent,
          );
          controller.jumpTo(target);
        });
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            controller: controller,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < widget.children.length; i++) ...[
                  if (i > 0)
                    const SizedBox(
                      width: 24,
                      child: Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: AppColors.muted,
                      ),
                    ),
                  widget.children[i],
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '← 左右滑动浏览效果 →',
            style: TextStyle(fontSize: 12, color: AppColors.muted),
          ),
        ],
      );
    },
  );
}

class StatusTag extends StatelessWidget {
  const StatusTag({
    super.key,
    required this.label,
    this.color = AppColors.green,
    this.icon = Icons.check_circle_outline,
  });
  final String label;
  final Color color;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: AppColors.inset,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(child: Icon(icon, size: 16, color: color)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

class EmptyFeature extends StatelessWidget {
  const EmptyFeature({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });
  final IconData icon;
  final String title, description;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(icon, size: 48, color: AppColors.accent),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, height: 1.7),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    ),
  );
}

class EqPainter extends CustomPainter {
  EqPainter(this.bands, this.enabled);
  final List<(double, double, double)> bands;
  final bool enabled;
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = AppColors.border
      ..strokeWidth = 0.5;
    for (var y = 0; y <= 4; y++) {
      canvas.drawLine(
        Offset(0, size.height * y / 4),
        Offset(size.width, size.height * y / 4),
        grid,
      );
    }
    for (var x = 0; x <= 6; x++) {
      canvas.drawLine(
        Offset(size.width * x / 6, 0),
        Offset(size.width * x / 6, size.height),
        grid,
      );
    }
    final path = Path();
    for (var x = 0; x <= size.width; x++) {
      final freq = 20 * pow(1000, x / size.width);
      var db = 0.0;
      // 仅为参数示意曲线；非设备 DSP 实测频响。
      if (enabled) {
        for (final band in bands) {
          final delta = log(freq / band.$1) / ln2;
          db += band.$2 * exp(-pow(delta, 2) * max(0.4, band.$3));
        }
      }
      final y = size.height / 2 - db.clamp(-20, 20) / 40 * size.height;
      if (x == 0) {
        path.moveTo(x.toDouble(), y);
      } else {
        path.lineTo(x.toDouble(), y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = enabled ? AppColors.accent : AppColors.muted
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(EqPainter old) => true;
}
