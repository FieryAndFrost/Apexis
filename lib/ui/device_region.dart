import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../data/view_state.dart';

/// Feature-level subscription, with optional field projection. Offstage cached
/// pages unsubscribe and catch up from the latest snapshot before reappearing.
class DeviceRegion extends StatefulWidget {
  const DeviceRegion({
    super.key,
    required this.store,
    required this.aspects,
    required this.builder,
    this.select,
    this.label = '',
  });
  final DeviceViewStore store;
  final List<DeviceAspect> aspects;
  final Object? Function(DeviceSnapshot)? select;
  final WidgetBuilder builder;
  final String label;
  @visibleForTesting
  static void Function(String label)? onBuild;
  @override
  State<DeviceRegion> createState() => _DeviceRegionState();
}

class _DeviceRegionState extends State<DeviceRegion> {
  final _subscriptions = <Listenable>[];
  ValueListenable<TickerModeData>? _visibility;
  Object? _selected;
  bool _active = true;
  Object? _selection() => widget.select != null
      ? widget.select!(widget.store.snapshot)
      : [
          for (final aspect in widget.aspects)
            widget.store.snapshot.keyFor(aspect),
        ];

  void _detach() {
    for (final source in _subscriptions) {
      source.removeListener(_changed);
    }
    _subscriptions.clear();
  }

  void _attach() {
    if (!_active || _subscriptions.isNotEmpty) return;
    for (final aspect in widget.aspects.toSet()) {
      final source = widget.store.channel(aspect);
      source.addListener(_changed);
      _subscriptions.add(source);
    }
  }

  void _changed() {
    if (!mounted || !_active) return;
    final next = _selection();
    if (!sameState(_selected, next)) {
      setState(() => _selected = next);
    }
  }

  void _visibilityChanged() {
    final next = _visibility!.value.enabled;
    if (next == _active) return;
    _active = next;
    if (_active) {
      _attach();
      _changed();
    } else {
      _detach();
    }
  }

  @override
  void initState() {
    super.initState();
    _selected = _selection();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visibility = TickerMode.getValuesNotifier(context);
    if (!identical(visibility, _visibility)) {
      _visibility?.removeListener(_visibilityChanged);
      _visibility = visibility..addListener(_visibilityChanged);
    }
    _active = visibility.value.enabled;
    _detach();
    _attach();
  }

  @override
  void didUpdateWidget(DeviceRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store ||
        !listEquals(oldWidget.aspects, widget.aspects)) {
      _detach();
      _attach();
    }
    _selected = _selection();
  }

  @override
  void dispose() {
    _detach();
    _visibility?.removeListener(_visibilityChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _selected = _selection();
    DeviceRegion.onBuild?.call(widget.label);
    return widget.builder(context);
  }
}
