import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../data/controller.dart';
import '../data/file_transfer.dart';
import '../data/parameters.dart';
import 'pages.dart' show confirm;
import 'device_region.dart';

class _TransferTarget {
  _TransferTarget(ApexisController c, {this.checkPreset = true})
    : session = c.session,
      preset = c.selected;
  final Object? session;
  final int preset;
  final bool checkPreset;
  void validate(ApexisController c) {
    if (session == null ||
        !identical(session, c.session) ||
        c.session?.isValid != true ||
        !c.ready ||
        (checkPreset && preset != c.selected)) {
      throw StateError('设备连接或目标音色已变化，操作未执行，请重新确认');
    }
  }
}

/// Shared by the transfer modal and widget tests: a commit is irreversible,
/// so cancellation is available only before that command has been sent.
class TransferProgressDialog extends StatelessWidget {
  const TransferProgressDialog({
    super.key,
    required this.title,
    required this.phase,
    required this.progress,
    required this.cancelRequested,
    required this.onCancel,
  });
  final String title;
  final TransferPhase phase;
  final double? progress;
  final bool cancelRequested;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      scrollable: true,
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: phase == TransferPhase.transferring ? progress : null,
          ),
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(switch (phase) {
              TransferPhase.committing => '正在应用到设备，请勿断电；此阶段不可取消',
              TransferPhase.closing => '正在结束会话并同步设备…',
              _ when cancelRequested => '正在取消，请稍候…',
              TransferPhase.preparing => '正在建立文件会话…',
              TransferPhase.transferring =>
                progress == null
                    ? '等待设备…'
                    : '${(progress! * 100).toStringAsFixed(0)}%',
            }),
          ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed:
              !cancelRequested &&
                  (phase == TransferPhase.preparing ||
                      phase == TransferPhase.transferring)
              ? onCancel
              : null,
          child: Text(cancelRequested ? '正在取消' : '取消'),
        ),
      ],
    ),
  );
}

Future<void> _transferDialog(
  BuildContext context,
  ApexisController c,
  Future<void> Function(FileTransfer) operation, {
  String title = '正在传输参数文件',
  _TransferTarget? target,
}) async {
  target ??= _TransferTarget(c);
  try {
    target.validate(c);
  } catch (e) {
    c.error = e.toString();
    c.emit();
    return;
  }
  c.cancelTransfer = false;
  final phase = ValueNotifier((TransferPhase.preparing, false));
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => DeviceRegion(
      store: c.view,
      aspects: const [DeviceAspect.feedback],
      label: 'transfer-progress',
      select: (s) => s.feedback.progress,
      builder: (context) => ValueListenableBuilder(
        valueListenable: phase,
        builder: (context, value, _) => TransferProgressDialog(
          title: title,
          phase: value.$1,
          progress: c.progress,
          cancelRequested: value.$2,
          onCancel: () {
            c.cancelTransfer = true;
            phase.value = (value.$1, true);
          },
        ),
      ),
    ),
  );
  final navigator = Navigator.of(context);
  unawaited(navigator.push(route));
  try {
    await c.run(() async {
      target!.validate(c);
      final session = c.session!;
      final transfer = FileTransfer(
        session,
        onPhase: (v) {
          phase.value = (v, c.cancelTransfer);
          c.log('$title: ${v.name}');
        },
        onProgress: (v) {
          c.progress = v;
          c.emit();
        },
        cancelled: () => c.cancelTransfer,
      );
      Object? failure;
      StackTrace? failureStack;
      try {
        await operation(transfer);
      } catch (e, st) {
        failure = e;
        failureStack = st;
      }
      try {
        if (identical(c.session, session) &&
            session.isValid &&
            c.state != LinkState.disconnected) {
          await c.resync();
          await c.waitReady();
        }
      } catch (e) {
        if (failure == null) rethrow;
        c.log('文件操作后同步失败（保留原始错误）: $e');
      }
      if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    });
  } finally {
    if (route.isActive) navigator.removeRoute(route);
    // Wait until the route has disposed its listeners before the notifier.
    await route.completed;
    phase.dispose();
  }
}

Future<void> exportParameters(
  BuildContext context,
  ApexisController c,
  bool bank,
) async {
  final target = _TransferTarget(c, checkPreset: !bank);
  Uint8List? result;
  await _transferDialog(context, c, (transfer) async {
    result = await transfer.transfer(bank: bank, preset: target.preset);
  }, target: target);
  if (result == null) return;
  try {
    final path = await FilePicker.saveFile(
      dialogTitle: '保存参数文件',
      fileName: bank
          ? 'Apexis-backup.gt1b'
          : '${c.labelForPreset(target.preset)}.gt1s',
      bytes: result,
      type: FileType.custom,
      allowedExtensions: [bank ? 'gt1b' : 'gt1s'],
    );
    if (path != null) {
      c.notice = '参数文件已导出';
      c.emit();
    }
  } catch (e) {
    c.error = e.toString();
    c.emit();
  }
}

Future<void> importParameters(
  BuildContext context,
  ApexisController c,
  bool bank,
) async {
  final target = _TransferTarget(c, checkPreset: !bank);
  try {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [bank ? 'gt1b' : 'gt1s'],
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    PresetFile.validate(bytes, bank: bank);
    if (!context.mounted ||
        !await confirm(
          context,
          bank ? '恢复全部配置？' : '覆盖 ${c.labelForPreset(target.preset)}？',
          (bank
                  ? '文件将替换全部 128 个音色和全局设置。建议先备份当前配置。'
                  : '将用文件内容替换当前音色，确认后上传并提交到设备 RAM。') +
              (c.factoryUserPresets
                  ? '\n厂商位置仅供本次开机试听，不覆盖厂商原始 Flash；需另存 U 区才能保留。'
                  : ''),
        )) {
      return;
    }
    if (!context.mounted) return;
    await _transferDialog(context, c, (transfer) async {
      await transfer.transfer(bank: bank, preset: target.preset, input: bytes);
      c.notice = c.persistenceNotice;
    }, target: target);
  } catch (e) {
    c.error = e.toString();
    c.emit();
  }
}

Future<void> restoreDefaults(BuildContext context, ApexisController c) async {
  final target = _TransferTarget(c, checkPreset: false);
  if (!await confirm(context, '恢复出厂设置？', '将替换设备的全局设置和全部音色。建议先导出 GT1B 备份。')) {
    return;
  }
  if (!context.mounted) return;
  await _transferDialog(
    context,
    c,
    (t) async {
      await t.restoreDefaults();
      c.notice = '已恢复默认参数；${c.persistenceNotice}';
    },
    title: '正在恢复出厂设置',
    target: target,
  );
}

Future<void> exportEq(BuildContext context, ApexisController c) async {
  final bytes = Uint8List.fromList(
    utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'format': 'Apexis-EQ',
        'version': 1,
        'schema': 12,
        'raw': c.globals.sublist(32, 54),
      }),
    ),
  );
  try {
    await FilePicker.saveFile(
      dialogTitle: '导出 EQ',
      fileName: 'Apexis-EQ.json',
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
  } catch (e) {
    c.error = e.toString();
    c.emit();
  }
}

Future<void> importEq(BuildContext context, ApexisController c) async {
  final target = _TransferTarget(c, checkPreset: false);
  try {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null) return;
    final json = jsonDecode(utf8.decode(result.files.single.bytes!));
    if (json is! Map ||
        json['format'] != 'Apexis-EQ' ||
        json['version'] != 1 ||
        json['schema'] != 12 ||
        json['raw'] is! List) {
      throw const FormatException('EQ 文件格式不匹配');
    }
    final data = (json['raw'] as List).cast<int>();
    if (data.length != 22 ||
        data.any((v) => v < 0 || v > 255) ||
        data[0] > 1 ||
        data[1] != 0 ||
        le16(data, 2) < 19 ||
        le16(data, 2) > 200 ||
        le16(data, 4) < 4000 ||
        le16(data, 4) > 20500) {
      throw const FormatException('EQ 参数越界');
    }
    for (var i = 0; i < 4; i++) {
      final at = 6 + i * 4;
      if (data[at].toSigned(8) < -18 ||
          data[at].toSigned(8) > 18 ||
          le16(data, at + 1) < 20 ||
          le16(data, at + 1) > 20000 ||
          data[at + 3] < 1 ||
          data[at + 3] > 160) {
        throw const FormatException('EQ 频段参数无效');
      }
    }
    if (!context.mounted ||
        !await confirm(context, '应用 EQ 文件？', '将替换当前全局均衡器设置。')) {
      return;
    }
    target.validate(c);
    await c.writeField(32, data);
  } catch (e) {
    c.error = e.toString();
    c.emit();
  }
}
