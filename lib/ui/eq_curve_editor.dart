import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';
import 'widgets.dart';

typedef EqBand = (double, double, double);

/// Local gesture preview only; confirmed values always come from the device.
class EqCurveEditor extends StatefulWidget {
  const EqCurveEditor({
    super.key,
    required this.bands,
    required this.enabled,
    required this.version,
    required this.onCommit,
  });

  final List<EqBand> bands;
  final bool enabled;
  final Object? version;
  final Future<void> Function(int band, int frequency, int gain)? onCommit;

  @override
  State<EqCurveEditor> createState() => _EqCurveEditorState();
}

class _EqCurveEditorState extends State<EqCurveEditor> {
  final _focus = FocusNode();
  int _selected = 0;
  int? _drag;
  Offset? _origin;
  EqBand? _start, _draft;
  bool _pending = false, _showPending = false, _active = true;
  Timer? _timer;
  String? _error;
  bool get _editable => _active && !_pending && widget.onCommit != null;
  List<EqBand> get _bands => [
    for (var i = 0; i < widget.bands.length; i++)
      i == _selected && _draft != null ? _draft! : widget.bands[i],
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = TickerMode.valuesOf(context).enabled;
    if (!_active && !_pending) _clearDrag();
  }

  void _clearDrag() {
    _drag = null;
    _origin = null;
    _start = null;
    _draft = null;
  }

  @override
  void didUpdateWidget(EqCurveEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_pending &&
        (oldWidget.version != widget.version ||
            oldWidget.enabled != widget.enabled ||
            !listEquals(oldWidget.bands, widget.bands) ||
            widget.onCommit == null)) {
      _clearDrag();
    }
  }

  Offset _position(EqBand band, Size plot) => Offset(
    log(band.$1.clamp(20, 20000) / 20) / log(1000) * plot.width,
    (20 - band.$2.clamp(-18, 18)) / 40 * plot.height,
  );

  void _move(Offset global, Size plot) {
    if (!_editable || _drag == null || _start == null || _origin == null) {
      return;
    }
    final p = _position(_start!, plot) + global - _origin!;
    final hz = (20 * pow(1000, (p.dx / plot.width).clamp(0, 1))).round().clamp(
      20,
      20000,
    );
    final gain = (20 - p.dy / plot.height * 40).round().clamp(-18, 18);
    setState(() => _draft = (hz.toDouble(), gain.toDouble(), _start!.$3));
  }

  Future<void> _commit() async {
    if (!_editable || _draft == null) return;
    final band = _selected, value = _draft!, original = widget.bands[band];
    final callback = widget.onCommit!;
    _drag = null;
    _origin = null;
    _start = null;
    if (value.$1 == original.$1 && value.$2 == original.$2) {
      setState(_clearDrag);
      return;
    }
    setState(() {
      _pending = true;
      _error = null;
    });
    _timer = Timer(const Duration(milliseconds: 500), () {
      if (mounted && _pending) setState(() => _showPending = true);
    });
    try {
      await callback(band, value.$1.round(), value.$2.round());
    } catch (_) {
      if (mounted) setState(() => _error = '提交失败，请重试');
    } finally {
      _timer?.cancel();
      if (mounted) {
        setState(() {
          _pending = _showPending = false;
          _clearDrag();
        });
      }
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && _drag != null) {
      setState(_clearDrag);
      return KeyEventResult.handled;
    }
    if (!_editable || _drag != null) return KeyEventResult.ignored;
    final b = widget.bands[_selected];
    final key = event.logicalKey;
    var hz = b.$1, gain = b.$2;
    if (key == LogicalKeyboardKey.arrowUp) {
      gain = (gain + 1).clamp(-18, 18);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      gain = (gain - 1).clamp(-18, 18);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      hz = (hz * pow(1000, .01)).round().clamp(20, 20000).toDouble();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      hz = (hz / pow(1000, .01)).round().clamp(20, 20000).toDouble();
    } else {
      return KeyEventResult.ignored;
    }
    _draft = (hz, gain, b.$3);
    unawaited(_commit());
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bands = _bands, selected = bands[_selected];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Focus(
          focusNode: _focus,
          onKeyEvent: _key,
          onFocusChange: (_) => setState(() {}),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.inset,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _focus.hasFocus ? AppColors.accent : AppColors.border,
              ),
            ),
            child: SizedBox(
              key: const ValueKey('eq-plot'),
              height: 200,
              child: LayoutBuilder(
                builder: (context, box) {
                  final plot = Size(max(1, box.maxWidth - 48), 152);
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: EqPainter(bands, widget.enabled),
                            ),
                          ),
                        ),
                      ),
                      // Selected handle is on top; P1–P4 selectors resolve overlaps.
                      for (final i in [
                        for (var n = 0; n < bands.length; n++)
                          if (n != _selected) n,
                        _selected,
                      ])
                        Positioned(
                          key: ValueKey('eq-position-$i'),
                          left: _position(bands[i], plot).dx,
                          top: _position(bands[i], plot).dy,
                          width: 48,
                          height: 48,
                          child: Semantics(
                            label: 'P${i + 1} 均衡频段',
                            value:
                                '${bands[i].$1.round()} Hz，${bands[i].$2.round()} dB',
                            selected: i == _selected,
                            enabled: _editable,
                            child: MouseRegion(
                              cursor: _editable
                                  ? SystemMouseCursors.move
                                  : SystemMouseCursors.basic,
                              child: Listener(
                                behavior: HitTestBehavior.opaque,
                                onPointerCancel: (_) {
                                  // An accepted pan can end on pointer cancel.
                                  // Clear the draft before the recognizer runs.
                                  if (!_pending) setState(_clearDrag);
                                },
                                child: GestureDetector(
                                  key: ValueKey('eq-handle-$i'),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _editable
                                      ? () {
                                          _focus.requestFocus();
                                          setState(() => _selected = i);
                                        }
                                      : null,
                                  onPanDown: !_editable
                                      ? null
                                      : (d) {
                                          _focus.requestFocus();
                                          setState(() {
                                            _selected = i;
                                            _drag = i;
                                            _origin = d.globalPosition;
                                            _start = widget.bands[i];
                                            _draft = _start;
                                            _error = null;
                                          });
                                        },
                                  onPanStart: !_editable
                                      ? null
                                      : (d) => _move(d.globalPosition, plot),
                                  onPanUpdate: !_editable
                                      ? null
                                      : (d) => _move(d.globalPosition, plot),
                                  onPanEnd: !_editable
                                      ? null
                                      : (_) => unawaited(_commit()),
                                  onPanCancel: () {
                                    if (!_pending) setState(_clearDrag);
                                  },
                                  child: Center(
                                    child: Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: widget.onCommit == null
                                            ? AppColors.disabled
                                            : i == _selected
                                            ? AppColors.accent
                                            : AppColors.surface,
                                        border: Border.all(
                                          color: AppColors.accent,
                                          width: 2,
                                        ),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        '${i + 1}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color:
                                              i == _selected ||
                                                  widget.onCommit == null
                                              ? AppColors.onAccent
                                              : AppColors.text,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: LayoutBuilder(
            builder: (context, box) {
              final fullAxis =
                  box.maxWidth >=
                  MediaQuery.textScalerOf(context).scale(14) * 18;
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('20'),
                  if (fullAxis) ...[const Text('200'), const Text('2k')],
                  const Text('20k Hz'),
                ],
              );
            },
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (var i = 0; i < bands.length; i++)
              ChoiceChip(
                label: Text('P${i + 1}'),
                selected: _selected == i,
                onSelected: _pending || _drag != null
                    ? null
                    : (_) {
                        _focus.requestFocus();
                        setState(() => _selected = i);
                      },
              ),
          ],
        ),
        Text(
          'P${_selected + 1} · ${selected.$1.round()} Hz · ${selected.$2.round()} dB · Q ${selected.$3.toStringAsFixed(1)}${_showPending ? ' · 提交中' : ''}',
          style: const TextStyle(color: AppColors.accent),
          key: const ValueKey('eq-readout'),
        ),
        Text(
          _error ?? '左右调频率，上下调增益；松手生效。点位表示单段参数。',
          style: TextStyle(
            fontSize: 12,
            color: _error == null ? AppColors.muted : AppColors.red,
          ),
        ),
      ],
    );
  }
}
