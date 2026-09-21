import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../protocol/codec.dart';
import '../protocol/session.dart';
import '../transport/transport.dart';
import 'parameters.dart';
import 'view_state.dart';
export 'view_state.dart' show LinkState, DeviceAspect;

class ApexisController extends ChangeNotifier {
  ApexisController() {
    view = DeviceViewStore(_captureView());
  }
  late final DeviceViewStore view;
  ProtocolSession? session;
  DeviceTransport? transport;
  DevicePort? port;
  DeviceIdentity? identity;
  LinkState state = LinkState.disconnected;
  bool demo = false, busy = false;
  String? error;
  String? _syncError;
  String notice = '';
  Future<void> Function()? retryEdit;
  int revision = 0, selectedUnit = 0, metadataGeneration = 0;
  Uint8List globals = Uint8List(64);
  Patch? patch;
  final types = <EffectType>[];
  final resources = <ModelResource>[];
  final parameters = <ParameterInfo>[];
  final presetNames = <int, String>{};
  final presetFlags = <int, int>{};
  final patterns = <int, String>{};
  final logs = <String>[];
  int drumState = 0,
      loopState = 0,
      loopFlags = 0,
      loopPosition = 0,
      loopTotal = 0,
      loopLimit = 30000000;
  String? drumIssue;
  int loopPending = 0, loopGeneration = 0, loopCountinRemaining = 0;
  int tunerNote = 255, tunerPointer = 128, links = 0;
  bool tunerActive = false;
  double? progress;
  bool cancelTransfer = false;
  bool get ready => state == LinkState.ready;
  // Presentation is deliberately separate from protocol readiness. Fast work
  // keeps the last confirmed screen interactive; run() serializes new actions.
  static const busyFeedbackDelay = Duration(milliseconds: 500);
  bool get presentationReady =>
      _hasInteractiveView &&
      (state == LinkState.ready || state == LinkState.syncing);
  bool get showBusyFeedback => _showBusyFeedback;
  bool get editable => presentationReady && !showBusyFeedback;
  int get selected => globals[0];
  bool get factoryUserPresets => identity?.factoryUserPresets ?? false;
  bool isFactoryPreset(int id) => factoryUserPresets && id < 64;
  bool get currentFactoryPreset => isFactoryPreset(selected);
  String labelForPreset(int id) =>
      presetLabel(id, factoryUser: factoryUserPresets);
  String get persistenceNotice => factoryUserPresets
      ? '已提交到设备 RAM；软关机仅保存用户音色和全局设置，厂商试听需另存 U 区'
      : '编辑保留在设备 RAM 中，将在正常软关机时保存';
  String typeName(int id) =>
      types.where((t) => t.id == id).firstOrNull?.name ??
      'TYPE ${id.toRadixString(16).padLeft(4, '0').toUpperCase()}';
  int global16(int offset) => le16(globals, offset);
  final _assembler = RangeAssembler();
  CompletedRange? _initialGlobals;
  final _earlyNotifications = <Message>[];
  bool _accepting = false, _disposed = false;
  bool _resetConfirmed = false;
  int _epoch = 0, _requestId = 0;
  Future<void>? _notificationWork;
  StreamSubscription<Message>? _notifications;
  StreamSubscription<Object>? _faults;
  StreamSubscription<bool>? _link;
  Timer? _poll;
  Timer? _syncWatchdog;
  bool _polling = false;
  int? _activePage;
  _ParameterCache? _parameterCache;
  Future<void>? _parameterWork;
  int? _parameterWorkEpoch;
  int _parameterRefreshRequest = 0;
  bool _forceParameterRefresh = false;
  Timer? _busyFeedbackTimer;
  bool _showBusyFeedback = false, _hasInteractiveView = false;
  Future<void>? _operationWork;
  int _pendingOperations = 0;
  int _operationGeneration = 0;
  (LinkState, bool, int) _publishedProtocolState = (
    LinkState.disconnected,
    false,
    0,
  );

  void _updateBusyFeedback() {
    if (state == LinkState.disconnected || state == LinkState.connecting) {
      _hasInteractiveView = false;
    } else if (ready && !busy) {
      _hasInteractiveView = true;
    }
    final working =
        state != LinkState.disconnected &&
        (busy || !ready || _pendingOperations > 0);
    if (!working) {
      _busyFeedbackTimer?.cancel();
      _busyFeedbackTimer = null;
      _showBusyFeedback = false;
    } else if (!_showBusyFeedback && _busyFeedbackTimer == null) {
      _busyFeedbackTimer = Timer(busyFeedbackDelay, () {
        _busyFeedbackTimer = null;
        if (_disposed) return;
        _showBusyFeedback = true;
        emit();
      });
    }
  }

  void emit() {
    if (_disposed) return;
    _updateBusyFeedback();
    final changed = view.publish(_captureView());
    // Protocol waiters must observe readiness even when presentation is held
    // steady by the 500 ms grace period. UI regions still publish by slice.
    final protocolState = (state, busy, revision);
    if (changed || protocolState != _publishedProtocolState) {
      _publishedProtocolState = protocolState;
      notifyListeners();
    }
  }

  DeviceSnapshot _captureView() => DeviceSnapshot(
    connection: (
      phase: state,
      demo: demo,
      name: port?.name,
      kind: port?.kind,
      version: identity?.version,
      session: session,
    ),
    access: (ready: presentationReady, busy: showBusyFeedback),
    feedback: (
      error: error,
      notice: notice,
      progress: progress,
      retry: retryEdit,
    ),
    preset: (selected: selected, revision: revision, name: patch?.name),
    globals: globals,
    patch: patch?.bytes,
    selectedUnit: selectedUnit,
    metadataGeneration: metadataGeneration,
    parameters: parameters,
    types: types,
    resources: resources,
    patterns: patterns,
    presetNames: presetNames,
    presetFlags: presetFlags,
    links: links,
    tuner: (active: tunerActive, note: tunerNote, pointer: tunerPointer),
    looper: (
      state: loopState,
      flags: loopFlags,
      position: loopPosition,
      total: loopTotal,
      limit: loopLimit,
      pending: loopPending,
      generation: loopGeneration,
      countinRemaining: loopCountinRemaining,
    ),
    drum: drumState,
    drumIssue: drumIssue,
  );

  void log(String message) {
    logs.insert(
      0,
      '${DateTime.now().toIso8601String().substring(11, 19)}  $message',
    );
    if (logs.length > 120) logs.removeLast();
  }

  Future<void> connect(
    DeviceTransport channel,
    DevicePort target, {
    bool demonstration = false,
  }) async {
    await disconnect();
    transport = channel;
    port = target;
    demo = demonstration;
    busy = true;
    error = null;
    state = LinkState.connecting;
    emit();
    try {
      await channel.connect(target);
      session = ProtocolSession(channel);
      session!.onMatchedReply = (m) {
        if (m.component == 9 &&
            m.command == 0 &&
            m.selector == 0x42 &&
            m.error == 0 &&
            m.data.length == 7 &&
            m.data[0] == 3 &&
            (m.data[1] == 1 || m.data[1] == 2)) {
          _resetConfirmed = true;
        }
      };
      _link = channel.connected.listen((v) {
        if (!v) {
          _epoch++;
          _accepting = false;
          _assembler.reset();
          _initialGlobals = null;
          _poll?.cancel();
          _syncWatchdog?.cancel();
          parameters.clear();
          state = LinkState.disconnected;
          revision = 0;
          error = '连接已断开，请重新连接；未发送的编辑已丢弃';
          emit();
        }
      });
      _notifications = session!.notifications.listen(_queueNotification);
      _faults = session!.faults.listen((e) {
        log('接收异常：$e');
      });
      identity = DeviceIdentity((await session!.command(9, 1, 0x22)).data);
      RangeReply(await session!.command(9, 1, 0x40), capability: true);
      log('已识别 ${identity!.name} ${identity!.version}，载荷 ${channel.payload} B');
      await resync();
      await waitReady();
      await loadTypes();
      await selectUnit(demonstration ? min(3, max(0, patch!.count - 1)) : 0);
      busy = false;
      emit();
    } catch (e) {
      final message = e.toString();
      await disconnect();
      error = message;
      emit();
    }
  }

  Future<void> resync() async {
    final s = session;
    if (s == null || state == LinkState.disconnected) return;
    _epoch++;
    _accepting = false;
    _resetConfirmed = false;
    retryEdit = null;
    _earlyNotifications.clear();
    _assembler.reset();
    _initialGlobals = null;
    parameters.clear();
    metadataGeneration++;
    state = LinkState.syncing;
    emit();
    final epoch = _epoch;
    final reply = await s.command(9, 0, 0x42, [3]);
    if (epoch != _epoch) return;
    _validateControl(reply, 3);
    if (reply.data[1] != 1 && reply.data[1] != 2) {
      throw const FormatException('重新同步状态无效');
    }
    _accepting = true;
    final early = List<Message>.from(_earlyNotifications);
    _earlyNotifications.clear();
    for (final m in early) {
      _queueNotification(m);
    }
    _syncWatchdog?.cancel();
    _syncWatchdog = Timer(const Duration(seconds: 8), () {
      if (state == LinkState.syncing) {
        error = '未收齐设备当前视图，请重新同步或重新连接';
        emit();
      }
    });
  }

  void _validateControl(Message m, int action, [int? expected]) {
    if (m.data.length != 7 ||
        m.data[0] != action ||
        m.data[1] > 3 ||
        (expected != null &&
            (m.data[1] != 3 ||
                Gt1.integer(m.data, 2, 5, 0xffffffff) != expected))) {
      throw const FormatException('同步确认的状态或 revision 不匹配');
    }
  }

  void _queueNotification(Message m) {
    if (!_accepting) {
      if (_resetConfirmed &&
          state == LinkState.syncing &&
          _earlyNotifications.length < 512) {
        _earlyNotifications.add(m);
      }
      return;
    }
    final epoch = _epoch;
    _notificationWork = (_notificationWork ?? Future<void>.value()).then((
      _,
    ) async {
      if (epoch != _epoch || !_accepting) return;
      try {
        await _consume(m, epoch);
      } catch (e) {
        if (epoch != _epoch || state == LinkState.disconnected) return;
        log('同步重建：$e');
        error = e.toString();
        _syncError = error;
        try {
          await resync();
        } catch (next) {
          error = next.toString();
          emit();
        }
      }
    });
  }

  Future<void> _consume(Message m, int epoch) async {
    if (m.error != 0) throw DeviceError(m.error, m.data);
    final range = _assembler.add(RangeReply(m));
    if (range == null) return;
    if (range.revision == 0) throw const FormatException('revision 不能为零');
    if (state == LinkState.ready &&
        ((range.start == 0 && range.raw.length == 64) ||
            (range.start == Gt1.patchOffset(selected) &&
                range.raw.length == 374))) {
      // Some device mutations restart the entire GLOB + PATCH view without
      // an explicit subscribe response. GLOB alone cannot distinguish this
      // from a 64-byte incremental range in older handoffs; PATCH without
      // GLOB may also be the tail of a lost snapshot. Re-establish the boundary
      // with action03; never ACK a potentially incomplete two-range snapshot.
      await resync();
      return;
    }
    Uint8List nextGlobals;
    Patch nextPatch;
    if (state == LinkState.syncing) {
      if (range.start == 0 && range.raw.length == 64) {
        Gt1.check(range.raw[0], 0, 127);
        _initialGlobals = range;
        return;
      }
      final g = _initialGlobals;
      if (g == null ||
          range.revision != g.revision ||
          range.start != Gt1.patchOffset(g.raw[0]) ||
          range.raw.length != 374) {
        throw const FormatException('首次 GLOB/PATCH 地址或代次不一致');
      }
      nextGlobals = g.raw;
      nextPatch = Patch(range.raw);
    } else {
      nextGlobals = Uint8List.fromList(globals);
      final patchBytes = Uint8List.fromList(patch!.bytes);
      final patchStart = Gt1.patchOffset(selected);
      for (var i = 0; i < range.raw.length; i++) {
        final offset = range.start + i;
        if (offset < 64) nextGlobals[offset] = range.raw[i];
        if (offset >= patchStart && offset < patchStart + 374) {
          patchBytes[offset - patchStart] = range.raw[i];
        }
      }
      if (nextGlobals[0] != selected) {
        await resync();
        return;
      }
      nextPatch = Patch(patchBytes);
    }
    final ack = await session!.command(9, 0, 0x42, [
      2,
      ...Gt1.u32(range.revision),
    ]);
    _validateControl(ack, 2, range.revision);
    if (epoch != _epoch) return;
    final previousPatch = patch;
    globals = nextGlobals;
    patch = nextPatch;
    revision = range.revision;
    state = LinkState.ready;
    // Clear only a recovered notification/snapshot failure. A rejected WRITE
    // still needs its error/retry feedback; successful sync does not apply it.
    if (_syncError != null && error == _syncError) error = null;
    _syncError = null;
    _initialGlobals = null;
    _syncWatchdog?.cancel();
    presetNames[selected] = patch!.name;
    selectedUnit = selectedUnit.clamp(0, max(0, patch!.count - 1));
    if (previousPatch == null ||
        !listEquals(
          previousPatch.bytes.sublist(0, 330),
          nextPatch.bytes.sublist(0, 330),
        )) {
      retryEdit = null;
    }
    _updateParameterView();
    if (_activePage == 0 && !busy) _refreshParametersInBackground();
    emit();
  }

  Future<void> waitReady({int? atLeastRevision}) async {
    if (ready && (atLeastRevision == null || revision >= atLeastRevision)) {
      return;
    }
    final done = Completer<void>();
    void listener() {
      if (state == LinkState.disconnected) {
        if (!done.isCompleted) done.completeError(StateError('连接已断开'));
      } else if (ready &&
          (atLeastRevision == null || revision >= atLeastRevision)) {
        if (!done.isCompleted) done.complete();
      }
    }

    addListener(listener);
    try {
      listener();
      await done.future.timeout(const Duration(seconds: 8));
    } finally {
      removeListener(listener);
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (_disposed || !editable || session == null) return;
    if (_pendingOperations >= 16) {
      notice = '待处理操作较多，请等待设备完成';
      emit();
      return;
    }
    final previous = _operationWork;
    final done = Completer<void>();
    _operationWork = done.future;
    final expectedSession = session, expectedEpoch = _epoch;
    final expectedPreset = selected;
    final expectedMetadata = metadataGeneration;
    final expectedStructure = _editStructure;
    final generation = _operationGeneration;
    _pendingOperations++;
    try {
      if (previous != null) await previous;
      if (_disposed ||
          !identical(session, expectedSession) ||
          state == LinkState.disconnected) {
        return;
      }
      if (!ready) await waitReady();
      if (_disposed ||
          !identical(session, expectedSession) ||
          expectedEpoch != _epoch ||
          expectedPreset != selected ||
          expectedMetadata != metadataGeneration ||
          !listEquals(expectedStructure, _editStructure) ||
          !ready) {
        if (!_disposed && identical(session, expectedSession)) {
          notice = '设备视图已变化，已取消等待中的操作，请重新操作';
          emit();
        }
        return;
      }
      await _runOperation(action);
    } catch (e) {
      if (!_disposed && identical(session, expectedSession)) {
        error = e.toString();
      }
    } finally {
      if (generation == _operationGeneration) _pendingOperations--;
      if (identical(_operationWork, done.future)) _operationWork = null;
      done.complete();
      emit();
    }
  }

  // UNIT indices can be reused after an external structural edit, even on a
  // page with no parameter metadata loaded. Never redirect a queued command.
  List<int>? get _editStructure {
    final p = patch;
    if (p == null) return null;
    return [
      p.count,
      ...p.chain,
      for (var i = 0; i < p.count; i++) ...[
        p.unit(i).type,
        p.unit(i).processor,
        p.unit(i).count,
        p.unit(i).model,
      ],
    ];
  }

  Future<void> _runOperation(Future<void> Function() action) async {
    final expectedSession = session;
    busy = true;
    error = null;
    emit();
    try {
      await action();
    } catch (e) {
      if (_disposed || !identical(session, expectedSession)) return;
      error = e.toString();
      log(error!);
      if (e is DeviceError && (e.code == 8 || e.code == 9)) {
        try {
          await resync();
          await waitReady();
        } catch (_) {
          /* 保留原始错误 */
        }
      }
    } finally {
      if (!_disposed && identical(session, expectedSession)) {
        busy = false;
        progress = null;
        emit();
        if (ready && _activePage == 0) _refreshParametersInBackground();
      }
    }
  }

  Future<void> writeField(int offset, List<int> raw) => run(() async {
    retryEdit = null;
    final epoch = _epoch;
    final rev = revision, id = _requestId = _requestId % 16383 + 1;
    final frameBudget = min(244, 8 * transport!.payload);
    var maxRaw = 191;
    while (25 + maxRaw + (maxRaw + 6) ~/ 7 > frameBudget) {
      maxRaw--;
    }
    RangeReply? finalReply;
    for (var at = 0; at < raw.length; at += maxRaw) {
      final chunk = raw.sublist(at, min(at + maxRaw, raw.length));
      final frame = Gt1.write(rev, id, offset, raw.length, at, chunk);
      late RangeReply reply;
      for (var attempt = 0; ; attempt++) {
        try {
          reply = RangeReply(await session!.request(frame));
          break;
        } on DeviceError catch (e) {
          if (e.code != 7) rethrow;
          if (attempt >= 2) {
            if (at > 0) {
              try {
                await session!.command(9, 7, 0x41, Gt1.u14(id));
              } catch (_) {
                /* 取消仅适用于本端未完成事务 */
              }
            }
            final retained = List<int>.from(raw);
            retryEdit = () async {
              if (epoch != _epoch) return;
              await writeField(offset, retained);
            };
            rethrow;
          }
          await Future<void>.delayed(
            Duration(milliseconds: 150 * (1 << attempt)),
          );
          if (epoch != _epoch) throw StateError('设备视图已变化，旧编辑已取消');
        }
      }
      if (reply.requestId != id ||
          reply.offset != offset ||
          reply.total != raw.length ||
          reply.filled != at + chunk.length) {
        throw const FormatException('WRITE 事务回执不匹配');
      }
      final last = at + chunk.length == raw.length;
      if ((!last && reply.state != 0) ||
          (last && reply.state != 1 && reply.state != 2)) {
        throw StateError('设备未提交参数');
      }
      finalReply = reply;
    }
    if (finalReply!.state == 2) notice = '参数已提交，但设备恢复声音失败，请检查设备';
    // 同值写不产生通知；仅使用设备回读，绝不把请求当作正式值。
    if (finalReply.revision == revision &&
        finalReply.raw.length == raw.length) {
      _applyReadback(offset, finalReply.raw);
    } else {
      try {
        await waitReady(
          atLeastRevision: finalReply.revision,
        ).timeout(const Duration(seconds: 2));
      } on TimeoutException {
        await resync();
        await waitReady();
      }
    }
    if (finalReply.state == 2) {
      await resync();
      await waitReady();
    }
    // Descriptions are not part of the WRITE transaction. Schema changes have
    // already hidden obsolete controls; labels can finish after editing unlocks.
  });
  void _applyReadback(int offset, Uint8List raw) {
    if (offset < 64) {
      globals = Uint8List.fromList(globals)
        ..setRange(offset, offset + raw.length, raw);
    } else if (offset >= Gt1.patchOffset(selected) &&
        offset + raw.length <= Gt1.patchOffset(selected) + 374) {
      final bytes = Uint8List.fromList(patch!.bytes);
      final start = offset - Gt1.patchOffset(selected);
      bytes.setRange(start, start + raw.length, raw);
      patch = Patch(bytes);
    }
    _updateParameterView();
    emit();
  }

  Future<void> patchField(int offset, List<int> raw) =>
      writeField(Gt1.patchOffset(selected, offset), raw);
  Future<void> action(
    int c,
    int op,
    int s, [
    List<int> data = const [],
    bool sync = true,
  ]) => run(() async {
    if (c == 0 && s == 0 && factoryUserPresets) {
      if (op == 0x0a && data.length == 2 && isFactoryPreset(data[1])) {
        throw StateError('另存目标必须是 U 用户区，不能覆盖厂商位置');
      }
      if (op == 0x0c && data.length == 2 && data.any(isFactoryPreset)) {
        throw StateError('只能交换两个 U 用户音色');
      }
    }
    try {
      await session!.command(c, op, s, data);
    } on DeviceError catch (e) {
      if (c == 1 && op == 0x0b && e.code == 1 && listEquals(e.data, [1])) {
        notice = '效果已删除，但设备恢复声音失败';
      } else {
        rethrow;
      }
    }
    if (sync) {
      await resync();
      await waitReady();
      await refreshParameters();
    } else {
      await pollNow();
    }
  });
  Future<void> save() => run(() async {
    if (currentFactoryPreset) {
      throw StateError('厂商音色修改仅供本次开机试听，请使用“保存到”另存 U 用户区');
    }
    final d = (await session!.command(0, 8, 0)).data;
    if (!listEquals(d, [1])) throw const FormatException('保存状态未知');
    notice = persistenceNotice;
  });
  Future<void> rename(String name) async {
    if (name.length > 16 || name.codeUnits.any((v) => v < 32 || v > 126)) {
      error = '名称需为最多 16 个 ASCII 字符';
      emit();
      return;
    }
    final bytes = Uint8List(17)..setRange(0, name.length, ascii.encode(name));
    await patchField(332, bytes);
  }

  Future<void> loadTypes() async {
    final s = session!;
    final count = Gt1.integer((await s.command(1, 1, 0x22)).data, 0, 2);
    types.clear();
    for (var i = 0; i < count; i++) {
      final d = (await s.command(1, 1, 0x22, Gt1.u14(i))).data;
      if (d.length < 7 || Gt1.integer(d, 0, 2) != i) {
        throw const FormatException('TYPE 目录无效');
      }
      types.add(
        EffectType(
          Gt1.integer(d, 2, 2),
          ascii.decode(d.sublist(7)),
          d[5],
          d[6],
        ),
      );
    }
    emit();
  }

  Future<void> loadResources() => run(() async {
    final count = Gt1.integer(
      (await session!.command(1, 1, 0x20)).data,
      0,
      3,
      65535,
    );
    resources.clear();
    for (var i = 0; i < count; i++) {
      final d = (await session!.command(1, 1, 0x20, Gt1.u16(i))).data;
      if (d.length < 10 || Gt1.integer(d, 0, 3) != i) {
        throw const FormatException('资源目录无效');
      }
      resources.add(
        ModelResource(
          Gt1.integer(d, 3, 3, 65535),
          Gt1.integer(d, 6, 2),
          ascii.decode(d.sublist(10)),
        ),
      );
    }
  });
  Future<void> selectUnit(int id) async {
    selectedUnit = id;
    parameters.clear();
    metadataGeneration++;
    emit();
    try {
      await refreshParameters(force: true);
    } catch (e) {
      error = e.toString();
      emit();
    }
  }

  void _refreshParametersInBackground() {
    final epoch = _epoch;
    unawaited(
      refreshParameters().catchError((Object e) {
        if (epoch != _epoch || _disposed) return;
        error = e.toString();
        emit();
      }),
    );
  }

  // GT1 0.2.124's effect_registry only varies schema with Mode/Sync; model
  // names/counts additionally depend on model_ref. Unknown firmware keeps the
  // conservative path, rather than guessing dependencies from TYPE numbers.
  bool get _knownParameterDependencies =>
      demo ||
      (identity?.major == 0 &&
          identity?.minor == 2 &&
          identity?.patchVersion == 124);

  bool _sameParameterSchema(_ParameterCache cache, EffectUnit unit) {
    if (cache.epoch != _epoch ||
        cache.preset != selected ||
        cache.unit.id != unit.id ||
        cache.unit.type != unit.type ||
        cache.unit.model != unit.model ||
        cache.unit.count != unit.count) {
      return false;
    }
    for (var p = 0; p < unit.count; p++) {
      if (cache.unit.parameter(p) == unit.parameter(p)) continue;
      if (!_knownParameterDependencies || p >= cache.info.length) return false;
      final name = cache.info[p].name.trim().toLowerCase();
      if (name == 'mode' || name == 'sync') return false;
    }
    return true;
  }

  void _updateParameterView() {
    final cache = _parameterCache;
    if (patch == null ||
        patch!.count == 0 ||
        cache == null ||
        !_sameParameterSchema(cache, patch!.unit(selectedUnit))) {
      if (parameters.isNotEmpty) {
        parameters.clear();
        metadataGeneration++;
      }
      _parameterCache = null;
      return;
    }
    final unit = patch!.unit(selectedUnit);
    parameters
      ..clear()
      ..addAll([
        for (var p = 0; p < cache.info.length; p++)
          ParameterInfo(
            cache.info[p].name,
            cache.info[p].min,
            cache.info[p].max,
            cache.unit.parameter(p) == unit.parameter(p)
                ? cache.info[p].label
                : '${unit.parameter(p)}',
          ),
      ]);
  }

  Future<void> refreshParameters({bool force = false}) {
    _parameterRefreshRequest++;
    _forceParameterRefresh |= force;
    if (_parameterWork != null && _parameterWorkEpoch == _epoch) {
      return _parameterWork!;
    }
    final epoch = _epoch;
    _parameterWorkEpoch = epoch;
    late final Future<void> work;
    work =
        (() async {
          // A changed selection or incoming device edit cancels stale results and
          // restarts from the latest confirmed snapshot, never from requested values.
          while (epoch == _epoch) {
            final request = _parameterRefreshRequest;
            final forced = _forceParameterRefresh;
            _forceParameterRefresh = false;
            final generation = metadataGeneration;
            try {
              final done = await _loadParameterView(force: forced);
              if (done && request == _parameterRefreshRequest) break;
              // Preserve explicit reads across stale results (e.g. selection).
              _forceParameterRefresh |= forced;
            } catch (_) {
              if (epoch != _epoch) break;
              if (generation == metadataGeneration) rethrow;
              _forceParameterRefresh |= forced;
            }
          }
        })().whenComplete(() {
          if (identical(_parameterWork, work)) _parameterWork = null;
        });
    _parameterWork = work;
    return work;
  }

  Future<bool> _loadParameterView({required bool force}) async {
    if (!force && _activePage != 0) return true;
    if (!ready || patch == null || patch!.count == 0) return true;
    final epoch = _epoch,
        generation = metadataGeneration,
        unit = patch!.unit(selectedUnit);
    final preset = selected, s = session!;
    final notifications = _notificationWork;
    bool current() =>
        epoch == _epoch &&
        ready &&
        (force || _activePage == 0) &&
        generation == metadataGeneration &&
        identical(notifications, _notificationWork) &&
        selected == preset &&
        selectedUnit == unit.id &&
        patch!.count > unit.id &&
        listEquals(patch!.unit(unit.id).bytes, unit.bytes);
    // Keep cache validity in the nullable value itself. In Windows AOT the
    // separate `reuse` boolean across the await below allowed a null cache
    // dereference in the inlined EffectUnit.parameter path (Debug was fine).
    final candidate = _parameterCache;
    final cache = candidate != null && _sameParameterSchema(candidate, unit)
        ? candidate
        : null;
    final address = [unit.id, ...Gt1.u14(unit.type)];
    final visible = cache != null
        ? [...address, cache.info.length]
        : (await s.command(2, 1, 0x20, address)).data;
    if (!current()) return false;
    if (visible.length != 4 ||
        visible[0] != unit.id ||
        Gt1.integer(visible, 1, 2) != unit.type ||
        visible[3] > unit.count) {
      throw const FormatException('可见参数数无效');
    }
    final result = <ParameterInfo>[];
    final labelSupported = <bool>[];
    for (var p = 0; p < visible[3]; p++) {
      final query = [...address, p];
      if (cache != null && cache.unit.parameter(p) == unit.parameter(p)) {
        result.add(cache.info[p]);
        labelSupported.add(cache.labelSupported[p]);
        continue;
      }
      late final String name;
      late final int minimum, maximum;
      if (cache != null) {
        name = cache.info[p].name;
        minimum = cache.info[p].min;
        maximum = cache.info[p].max;
      } else {
        final description = (await s.command(2, 1, 0x22, query)).data;
        if (!current()) return false;
        final range = (await s.command(2, 1, 0x23, query)).data;
        if (!current()) return false;
        if (description.length < 4 ||
            range.length != 9 ||
            !listEquals(description.sublist(0, 4), query) ||
            !listEquals(range.sublist(0, 4), query)) {
          throw const FormatException('参数描述不匹配');
        }
        name = ascii.decode(description.sublist(4)).replaceAll('\n', ' ');
        minimum = Gt1.signed14(range, 5);
        maximum = Gt1.signed14(range, 7);
      }
      var label = '${unit.parameter(p)}';
      var supported = cache == null || cache.labelSupported[p];
      try {
        if (supported) {
          final d = (await s.command(2, 1, 0x21, query)).data;
          if (!current()) return false;
          if (d.length < 4 || !listEquals(d.sublist(0, 4), query)) {
            throw const FormatException('参数标签不匹配');
          }
          label = ascii.decode(d.sublist(4));
        }
      } on DeviceError catch (e) {
        if (e.code != 6) rethrow;
        supported = false;
      }
      if (!current()) return false;
      labelSupported.add(supported);
      result.add(ParameterInfo(name, minimum, maximum, label));
    }
    // New notifications invalidate the captured view even before their ACK
    // completes. Do not join the notification coordinator from a UI refresh.
    if (current()) {
      _parameterCache = _ParameterCache(
        epoch,
        preset,
        unit,
        result,
        labelSupported,
      );
      parameters
        ..clear()
        ..addAll(result);
      emit();
      return true;
    }
    return false;
  }

  Future<void> loadPresetPage(int start) => run(() async {
    for (var at = start; at < min(start + 12, 128); at += 3) {
      final d = (await session!.command(0, 1, 0x23, [
        at,
        min(3, 128 - at),
      ])).data;
      if (d.length < 4 || d[0] != 1 || d[1] != at || d[2] < 1 || d[2] > 3) {
        throw const FormatException('预设目录无效');
      }
      var p = 4;
      for (var i = 0; i < d[2]; i++) {
        if (p + 2 > d.length || p + 2 + d[p + 1] > d.length) {
          throw const FormatException('预设名称被截断');
        }
        final n = d[p + 1];
        presetFlags[at + i] = d[p];
        presetNames[at + i] = ascii.decode(d.sublist(p + 2, p + 2 + n));
        p += 2 + n;
      }
    }
  });
  Future<void> loadPatterns() => run(() async {
    drumIssue = null;
    late Uint8List d;
    try {
      d = (await session!.command(3, 1, 0x20)).data;
    } on DeviceError catch (e) {
      if ([1, 5, 6].contains(e.code)) {
        drumIssue = '设备鼓机尚不可用，请检查固件版本、鼓机初始化及已安装资源';
      }
      rethrow;
    }
    if (d.length != 6 || d[0] != 1) throw const FormatException('鼓机目录无效');
    final next = <int, String>{};
    for (var source = 0; source < 2; source++) {
      final count = Gt1.integer(d, source == 0 ? 1 : 3, 2);
      for (var i = 0; i < count; i++) {
        final id = (source << 12) | i;
        final item = (await session!.command(3, 1, 0x20, Gt1.u14(id))).data;
        if (item.length < 7 || item.length != 7 + item[6] * 2) {
          throw const FormatException('鼓型名称无效');
        }
        final raw = <int>[];
        for (var p = 7; p < item.length; p += 2) {
          raw.add(
            (Gt1.check(item[p], 0, 15) << 4) | Gt1.check(item[p + 1], 0, 15),
          );
        }
        next[id] = utf8.decode(raw, allowMalformed: true);
      }
    }
    patterns
      ..clear()
      ..addAll(next);
  });
  void setActivePage(int? page) {
    _activePage = page;
    _poll?.cancel();
    if (page != 3 && page != 4 && page != 5) return;
    _poll = Timer.periodic(Duration(milliseconds: page == 5 ? 100 : 200), (_) {
      if (ready && !busy && !_polling && !(page == 4 && drumIssue != null)) {
        unawaited(
          pollNow().catchError((Object e) {
            error = e.toString();
            emit();
          }),
        );
      }
    });
  }

  /// Only this read-only snapshot may be polled again after an explicit
  /// rejection. GT1 0.2.124 maps its backend's transient -2 (audio/worker
  /// updating the snapshot) to error 1, as well as genuine unavailability.
  /// Limit retries; never retry timeouts or musical commands such as UNDO.
  Future<Uint8List> readLooperProgress() async {
    final currentSession = session, epoch = _epoch;
    if (currentSession == null) throw StateError('设备尚未连接');
    final legacyBusy =
        identity?.major == 0 &&
        identity?.minor == 2 &&
        identity?.patchVersion == 124;
    for (var attempt = 0; ; attempt++) {
      if (epoch != _epoch ||
          !identical(session, currentSession) ||
          !currentSession.isValid) {
        throw StateError('Looper 查询会话已变化');
      }
      try {
        return (await currentSession.command(4, 1, 0x21)).data;
      } on DeviceError catch (e) {
        if (attempt >= 3 ||
            e.data.isNotEmpty ||
            !(e.code == 7 || (legacyBusy && e.code == 1))) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 30 * (attempt + 1)));
      }
    }
  }

  Future<void> pollNow() async {
    if (!ready || _polling) return;
    final page = _activePage, epoch = _epoch, currentSession = session!;
    if (page != 3 && page != 4 && !(page == 5 && tunerActive)) return;
    bool current() =>
        epoch == _epoch &&
        identical(session, currentSession) &&
        _activePage == page &&
        ready;
    _polling = true;
    try {
      if (page == 3) {
        final d = await readLooperProgress();
        if (!current()) return;
        if (d.length != 24 || d[0] != 1) {
          throw const FormatException('Looper 进度无效');
        }
        var remaining = 0;
        if (d[2] & 64 != 0) {
          final cue = (await currentSession.command(4, 1, 0x24)).data;
          if (!current()) return;
          if (cue.length != 7 || cue[0] != 1) {
            throw const FormatException('Looper 预备拍倒计时无效');
          }
          remaining = Gt1.integer(cue, 2, 5, 0xffffffff);
        }
        loopState = d[1];
        loopFlags = d[2];
        loopPending = d[3];
        loopGeneration = Gt1.integer(d, 4, 5, 0xffffffff);
        loopPosition = Gt1.integer(d, 9, 5, 0xffffffff);
        loopTotal = Gt1.integer(d, 14, 5, 0xffffffff);
        loopLimit = Gt1.integer(d, 19, 5, 0xffffffff);
        loopCountinRemaining = remaining;
      } else if (page == 4) {
        late Uint8List d;
        try {
          d = (await currentSession.command(3, 1, 0)).data;
        } on DeviceError catch (e) {
          if (current() && [1, 5, 6].contains(e.code)) {
            drumIssue = '设备鼓机尚不可用，请检查固件版本、鼓机初始化及已安装资源';
            emit();
          }
          rethrow;
        }
        if (!current()) return;
        if (d.length != 7) throw const FormatException('鼓机状态无效');
        drumState = d[0];
        drumIssue = null;
      } else if (page == 5 && tunerActive) {
        final d = (await currentSession.command(5, 1, 0)).data;
        if (!current() || !tunerActive) return;
        if (d.length != 6) throw const FormatException('调音数据无效');
        tunerNote = Gt1.integer(d, 2, 2);
        tunerPointer = Gt1.integer(d, 4, 2);
      }
      emit();
    } catch (_) {
      // Late failures from a previous page/session must not overwrite the
      // current screen's connection/error state.
      if (current()) rethrow;
    } finally {
      _polling = false;
    }
  }

  Future<void> setTuner(bool enabled) => run(() async {
    await session!.command(5, enabled ? 3 : 4, 0);
    final d = (await session!.command(9, 1, 0)).data;
    if (d.length != 4) throw const FormatException('设备模式无效');
    tunerActive = d[0] == 4;
    tunerNote = 255;
  });
  Future<void> readLinks() => run(() async {
    final d = (await session!.command(9, 1, 0x20)).data;
    if (d.length != 2 || d[0] != 1) throw const FormatException('连接状态无效');
    links = d[1];
  });
  Future<void> disconnect() async {
    _operationGeneration++;
    _operationWork = null;
    _pendingOperations = 0;
    _busyFeedbackTimer?.cancel();
    _busyFeedbackTimer = null;
    _showBusyFeedback = false;
    _hasInteractiveView = false;
    state = LinkState.disconnected;
    emit();
    retryEdit = null;
    _parameterCache = null;
    _epoch++;
    _accepting = false;
    _earlyNotifications.clear();
    _assembler.reset();
    _initialGlobals = null;
    _poll?.cancel();
    _syncWatchdog?.cancel();
    await _notifications?.cancel();
    await _faults?.cancel();
    await _link?.cancel();
    await session?.dispose();
    session = null;
    await transport?.dispose();
    transport = null;
    state = LinkState.disconnected;
    revision = 0;
    patch = null;
    identity = null;
    globals = Uint8List(64);
    types.clear();
    resources.clear();
    parameters.clear();
    presetNames.clear();
    presetFlags.clear();
    patterns.clear();
    drumIssue = null;
    drumState = loopState = loopFlags = loopPending = loopGeneration = 0;
    loopPosition = loopTotal = loopCountinRemaining = 0;
    loopLimit = 30000000;
    tunerActive = false;
    busy = false;
    emit();
  }

  @override
  void dispose() {
    _disposed = true;
    _busyFeedbackTimer?.cancel();
    view.dispose();
    unawaited(disconnect());
    super.dispose();
  }
}

class _ParameterCache {
  _ParameterCache(
    this.epoch,
    this.preset,
    this.unit,
    this.info,
    this.labelSupported,
  );
  final int epoch, preset;
  final EffectUnit unit;
  final List<ParameterInfo> info;
  final List<bool> labelSupported;
}
