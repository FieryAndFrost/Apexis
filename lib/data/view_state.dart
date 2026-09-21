import 'package:flutter/foundation.dart';
import 'parameters.dart';

enum LinkState { disconnected, connecting, syncing, ready }

enum DeviceAspect {
  connection,
  access,
  feedback,
  preset,
  globals,
  patch,
  effects,
  parameters,
  resources,
  patterns,
  presetNames,
  links,
  tuner,
  looper,
  drum,
}

typedef ConnectionView = ({
  LinkState phase,
  bool demo,
  String? name,
  String? kind,
  String? version,
  Object? session,
});
typedef AccessView = ({bool ready, bool busy});
typedef FeedbackView = ({
  String? error,
  String notice,
  double? progress,
  Object? retry,
});
typedef PresetView = ({int selected, int revision, String? name});
typedef TunerView = ({bool active, int note, int pointer});
typedef LooperView = ({
  int state,
  int flags,
  int position,
  int total,
  int limit,
  int pending,
  int generation,
  int countinRemaining,
});

/// Read model only. The protocol coordinator retains its working buffers; none
/// of those mutable buffers escape through this snapshot.
@immutable
class DeviceSnapshot {
  DeviceSnapshot({
    required this.connection,
    required this.access,
    required this.feedback,
    required this.preset,
    required List<int> globals,
    required List<int>? patch,
    required this.selectedUnit,
    required this.metadataGeneration,
    required List<ParameterInfo> parameters,
    required List<EffectType> types,
    required List<ModelResource> resources,
    required Map<int, String> patterns,
    required Map<int, String> presetNames,
    Map<int, int> presetFlags = const {},
    required this.links,
    required this.tuner,
    required this.looper,
    required this.drum,
    this.drumIssue,
  }) : globals = List.unmodifiable(globals),
       patch = patch == null ? null : List.unmodifiable(patch),
       parameters = List.unmodifiable(parameters),
       types = List.unmodifiable(types),
       resources = List.unmodifiable(resources),
       patterns = Map.unmodifiable(patterns),
       presetNames = Map.unmodifiable(presetNames),
       presetFlags = Map.unmodifiable(presetFlags);

  final ConnectionView connection;
  final AccessView access;
  final FeedbackView feedback;
  final PresetView preset;
  final List<int> globals;
  final List<int>? patch;
  final int selectedUnit, metadataGeneration, links, drum;
  final String? drumIssue;
  final List<ParameterInfo> parameters;
  final List<EffectType> types;
  final List<ModelResource> resources;
  final Map<int, String> patterns, presetNames;
  final Map<int, int> presetFlags;
  final TunerView tuner;
  final LooperView looper;
  bool get editable => access.ready && !access.busy;

  Object keyFor(DeviceAspect aspect) => switch (aspect) {
    DeviceAspect.connection => [connection, patch != null],
    DeviceAspect.access => access,
    DeviceAspect.feedback => feedback,
    DeviceAspect.preset => preset,
    DeviceAspect.globals => globals,
    DeviceAspect.patch => patch ?? const <int>[],
    // Parameter values are deliberately excluded from effect structure.
    DeviceAspect.effects => [
      selectedUnit,
      if (patch != null) ...[
        patch![349],
        patch!.sublist(320, 330),
        for (var i = 0; i < patch![349]; i++) ...[
          patch!.sublist(i * 32, i * 32 + 6),
          patch!.sublist(i * 32 + 30, i * 32 + 32),
        ],
      ],
      for (final t in types) (t.id, t.name, t.count, t.flags),
    ],
    DeviceAspect.parameters => [
      metadataGeneration,
      for (final p in parameters) (p.name, p.min, p.max, p.label),
    ],
    DeviceAspect.links => links,
    DeviceAspect.patterns => patterns,
    DeviceAspect.presetNames => [presetNames, presetFlags],
    DeviceAspect.resources => [
      for (final r in resources) (r.ref, r.type, r.name),
      for (final t in types) (t.id, t.name, t.count, t.flags),
    ],
    DeviceAspect.tuner => tuner,
    DeviceAspect.looper => looper,
    DeviceAspect.drum => [drum, drumIssue],
  };
}

/// Structural comparison supports immutable list/map projections as well as
/// scalar/record values. Never compare mutable buffer identities as UI state.
bool sameState(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!sameState(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && sameState(a[key], b[key]));
  }
  return a == b;
}

class _StateChannel extends ChangeNotifier {
  void publish() => notifyListeners();
}

/// Independent feature subscriptions. The complete snapshot is replaced before
/// any channel is notified, so listeners cannot observe half-published state.
class DeviceViewStore {
  DeviceViewStore(this._snapshot);
  DeviceSnapshot _snapshot;
  DeviceSnapshot get snapshot => _snapshot;
  final _channels = {
    for (final aspect in DeviceAspect.values) aspect: _StateChannel(),
  };
  Listenable channel(DeviceAspect aspect) => _channels[aspect]!;
  bool _disposed = false;

  bool publish(DeviceSnapshot next) {
    if (_disposed) return false;
    final changed = [
      for (final aspect in DeviceAspect.values)
        if (!sameState(_snapshot.keyFor(aspect), next.keyFor(aspect))) aspect,
    ];
    _snapshot = next;
    for (final aspect in changed) {
      _channels[aspect]!.publish();
    }
    return changed.isNotEmpty;
  }

  void dispose() {
    _disposed = true;
    for (final channel in _channels.values) {
      channel.dispose();
    }
  }
}
