import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../data/controller.dart';
import '../data/parameters.dart';
import '../protocol/codec.dart';
import 'file_actions.dart';
import 'theme.dart';
import 'widgets.dart';
import 'device_region.dart';
import 'effect_chain_editor.dart';
import 'eq_curve_editor.dart';

Widget responsiveColumns(
  BuildContext context,
  List<Widget> children, {
  List<int>? flex,
  bool trailingGap = true,
}) => LayoutBuilder(
  builder: (context, box) {
    if (box.maxWidth < 760) {
      return Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1 || trailingGap)
              const SizedBox(height: 20),
          ],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 20),
          Expanded(flex: flex?[i] ?? 1, child: children[i]),
        ],
      ],
    );
  },
);
Future<bool> confirm(BuildContext context, String title, String detail) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;
Future<void> showPresets(
  BuildContext context,
  ApexisController c, {
  bool copy = false,
  bool swap = false,
}) async {
  if (swap && c.currentFactoryPreset) {
    c.error = '厂商音色不能交换，请先另存到 U 用户区';
    c.emit();
    return;
  }
  final first = c.factoryUserPresets && (copy || swap) ? 64 : 0;
  var page = first + ((max(first, c.selected) - first) ~/ 12) * 12;
  unawaited(c.loadPresetPage(page));
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialog) => ListenableBuilder(
        listenable: Listenable.merge([
          c.view.channel(DeviceAspect.presetNames),
          c.view.channel(DeviceAspect.preset),
          c.view.channel(DeviceAspect.access),
        ]),
        builder: (context, _) => AlertDialog(
          scrollable: true,
          title: Text(
            copy
                ? '保存到音色位置'
                : swap
                ? '交换预设'
                : '选择预设',
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (c.factoryUserPresets)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      copy || swap
                          ? '仅可选择 U 用户位置；软关机才持久保存。'
                          : 'F 厂商区为临时试听；保留修改请另存 U 用户区。',
                    ),
                  ),
                Row(
                  children: [
                    IconButton(
                      tooltip: '上一页',
                      onPressed: page == first || !c.editable
                          ? null
                          : () {
                              setDialog(() => page = max(first, page - 12));
                              unawaited(c.loadPresetPage(page));
                            },
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Text(
                        c.factoryUserPresets
                            ? '${c.labelForPreset(page)} — ${c.labelForPreset(min(127, page + 11))}'
                            : 'BANK ${page ~/ 4 + 1} — ${min(32, (page + 12) ~/ 4)}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    IconButton(
                      tooltip: '下一页',
                      onPressed: page + 12 >= 128 || !c.editable
                          ? null
                          : () {
                              setDialog(() => page += 12);
                              unawaited(c.loadPresetPage(page));
                            },
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                SizedBox(
                  height: 4,
                  child: c.showBusyFeedback
                      ? const LinearProgressIndicator()
                      : null,
                ),
                SizedBox(
                  height: 360,
                  child: ListView.builder(
                    itemCount: min(12, 128 - page),
                    itemBuilder: (context, i) {
                      final id = page + i;
                      return ListTile(
                        selected: id == c.selected,
                        leading: Text(
                          c.labelForPreset(id),
                          style: const TextStyle(color: AppColors.accent),
                        ),
                        title: Text(
                          c.presetNames[id] ?? '读取中…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: (c.presetFlags[id] ?? 0) & 1 != 0
                            ? Text(
                                c.isFactoryPreset(id)
                                    ? '试听已修改 · 需另存 U 区'
                                    : '未持久化 · 等待软关机',
                              )
                            : null,
                        trailing: id == c.selected
                            ? const Icon(Icons.check, size: 18)
                            : null,
                        onTap: !c.editable
                            ? null
                            : () async {
                                if (copy || swap) {
                                  if (!await confirm(
                                    context,
                                    copy
                                        ? '覆盖 ${c.labelForPreset(id)}？'
                                        : '交换这两个音色？',
                                    copy
                                        ? '目标位置将被当前音色替换。'
                                        : '当前音色与 ${c.labelForPreset(id)} 的内容将交换。',
                                  )) {
                                    return;
                                  }
                                }
                                if (!dialogContext.mounted) return;
                                Navigator.pop(dialogContext);
                                await c.action(
                                  0,
                                  copy
                                      ? 0x0a
                                      : swap
                                      ? 0x0c
                                      : 0,
                                  0,
                                  copy || swap ? [c.selected, id] : [id],
                                );
                              },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    ),
  );
}

class EffectsPage extends StatelessWidget {
  const EffectsPage({super.key, required this.c});
  final ApexisController c;
  Future<void> chooseType(BuildContext context, int unit) async {
    final type = await showDialog<EffectType>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(unit == c.patch!.count ? '添加效果' : '替换效果'),
        children: [
          for (final type in c.types)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, type),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(child: Text(type.name)),
                    if (type.flags & 2 != 0)
                      const Text(
                        'CPU1',
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (type == null) return;
    if (type.flags & 1 != 0) {
      await c.loadResources();
      if (!context.mounted) return;
      final matches = c.resources.where((r) => r.type == type.id).toList();
      if (matches.isEmpty) {
        c.error = '设备没有安装该 TYPE 的资源';
        c.emit();
        return;
      }
      final resource = await showDialog<ModelResource>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('选择已安装资源'),
          children: [
            for (final r in matches)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, r),
                child: Text(r.name),
              ),
          ],
        ),
      );
      if (resource != null) {
        await c.action(1, 0, 0x21, [
          unit,
          ...Gt1.u14(type.id),
          ...Gt1.u16(resource.ref),
        ]);
      }
    } else {
      await c.action(1, 0, 1, [unit, ...Gt1.u14(type.id)]);
    }
    await c.selectUnit(min(unit, c.patch!.count - 1));
  }

  Future<void> rename(BuildContext context) async {
    final field = TextEditingController(text: c.patch!.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('重命名音色'),
        content: TextField(
          controller: field,
          maxLength: 16,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '音色名称',
            helperText: '最多 16 个 ASCII 字符',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null) await c.rename(name);
    // Dialog 的退出动画完成前 TextField 仍可能访问 controller。
    Future<void>.delayed(const Duration(milliseconds: 400), field.dispose);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DeviceRegion(
        store: c.view,
        aspects: const [
          DeviceAspect.access,
          DeviceAspect.preset,
          DeviceAspect.connection,
        ],
        label: 'effect-toolbar',
        builder: (context) => EditorToolbar(
          hideOnCompact: true,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: c.editable ? () => rename(context) : null,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('重命名'),
              ),
              OutlinedButton.icon(
                onPressed: c.editable
                    ? () => showPresets(context, c, copy: true)
                    : null,
                icon: const Icon(Icons.save_as_outlined, size: 18),
                label: const Text('保存到'),
              ),
              TextButton(
                onPressed: c.editable && !c.currentFactoryPreset
                    ? () => showPresets(context, c, swap: true)
                    : null,
                child: Text(c.currentFactoryPreset ? '厂商区不可交换' : '交换预设'),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      DeviceRegion(
        store: c.view,
        aspects: const [DeviceAspect.effects, DeviceAspect.access],
        label: 'effect-chain',
        builder: _chain,
      ),
      const SizedBox(height: 20),
      responsiveColumns(
        context,
        [
          DeviceRegion(
            store: c.view,
            aspects: const [
              DeviceAspect.effects,
              DeviceAspect.parameters,
              DeviceAspect.access,
            ],
            label: 'effect-parameters',
            builder: _parameters,
          ),
          SectionCard(
            title: '音色控制',
            subtitle: '输入、输出与演奏速度',
            child: Column(
              children: [
                _patchControl(
                  350,
                  1,
                  (patch) => RotaryControl(
                    compact: true,
                    label: 'INPUT · 输入增益',
                    value: patch.input,
                    min: 0,
                    max: 30,
                    display: '${patch.input - 15} dB',
                    format: (v) => '${v - 15} dB',
                    onCommit: c.editable ? (v) => c.patchField(350, [v]) : null,
                  ),
                ),
                _patchControl(
                  351,
                  1,
                  (patch) => RotaryControl(
                    compact: true,
                    label: 'VOL · 输出音量',
                    value: patch.output,
                    min: 0,
                    max: 100,
                    onCommit: c.editable ? (v) => c.patchField(351, [v]) : null,
                  ),
                ),
                _patchControl(
                  372,
                  2,
                  (patch) => RotaryControl(
                    compact: true,
                    label: 'PAN · 声像',
                    value: patch.pan,
                    min: -100,
                    max: 100,
                    display: patch.pan == 0
                        ? 'C'
                        : patch.pan < 0
                        ? 'L ${-patch.pan}'
                        : 'R ${patch.pan}',
                    format: (v) => v == 0
                        ? 'C'
                        : v < 0
                        ? 'L ${-v}'
                        : 'R $v',
                    onCommit: c.editable
                        ? (v) => c.patchField(372, raw16(v))
                        : null,
                  ),
                ),
                _patchControl(
                  330,
                  2,
                  (patch) => RotaryControl(
                    compact: true,
                    label: 'BPM · 音色速度',
                    value: patch.tempo,
                    min: 40,
                    max: 240,
                    onCommit: c.editable
                        ? (v) => c.patchField(330, raw16(v))
                        : null,
                  ),
                ),
                const Divider(height: 28),
                const Text(
                  '效果参数的范围与显示值来自设备。切换算法或同步模式后将重新读取。',
                  style: TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
        ],
        flex: const [5, 3],
      ),
    ],
  );

  Widget _chain(BuildContext context) {
    final patch = c.patch!;
    return SectionCard(
      title: '效果链',
      subtitle: '信号从左向右 · ${patch.count} / 10',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (MediaQuery.sizeOf(context).width < 600 ||
              MediaQuery.sizeOf(context).height < 500)
            _presetMenu(context),
          IconButton(
            tooltip: '添加效果',
            onPressed: c.editable && patch.count < 10
                ? () => chooseType(context, patch.count)
                : null,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (patch.count == 0) return const Text('尚无效果，点击 + 添加设备支持的算法。');
          final scroll = constraints.maxWidth < patch.count * 124;
          final width = scroll
              ? 104.0
              : (constraints.maxWidth / patch.count - 12).clamp(112.0, 180.0);
          final cards = [
            for (final id in patch.chain)
              _unitCard(context, patch.unit(id), width: width),
          ];
          final preset = c.selected;
          return EffectChainEditor(
            order: patch.chain.toList(),
            selected: c.selectedUnit,
            version: (preset, c.metadataGeneration, patch.chain.join(',')),
            enabled: c.editable,
            cardWidth: width,
            children: cards,
            onCommit: (chain) async {
              if (!c.editable ||
                  c.selected != preset ||
                  !listEquals(c.patch?.chain, patch.chain)) {
                return;
              }
              await c.patchField(320, [
                ...chain,
                ...List.filled(10 - chain.length, 0),
              ]);
            },
          );
        },
      ),
    );
  }

  Widget _parameters(BuildContext context) {
    final patch = c.patch!,
        unit = patch.count > 0 ? patch.unit(c.selectedUnit) : null;
    return SectionCard(
      title: unit == null ? '效果参数' : c.typeName(unit.type),
      subtitle: unit == null
          ? null
          : 'UNIT ${unit.id + 1} · ${unit.enabled ? '已启用' : '已旁路'} · CPU${unit.processor}',
      trailing: unit == null
          ? null
          : Semantics(
              label: '启用 ${c.typeName(unit.type)}',
              child: Switch(
                value: unit.enabled,
                onChanged: c.editable
                    ? (v) => c.patchField(unit.id * 32 + 2, [v ? 1 : 0])
                    : null,
              ),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (unit != null) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: c.editable
                      ? () => chooseType(context, unit.id)
                      : null,
                  child: const Text('选择效果'),
                ),
                IconButton(
                  tooltip: '删除效果',
                  onPressed: c.editable
                      ? () async {
                          if (await confirm(
                            context,
                            '删除这个效果？',
                            '删除后设备会重新分配 UNIT 编号并更新旋钮绑定。',
                          )) {
                            await c.action(1, 0x0b, 0, [unit.id]);
                          }
                        }
                      : null,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('旁路时清除效果尾音'),
              subtitle: Text(
                c.types.any((t) => t.id == unit.type && t.flags & 4 != 0)
                    ? '关闭时保留状态；开启时清除延迟、混响等内部状态'
                    : '该算法未声明支持 CLEAR',
              ),
              value: unit.bytes[4] == 1,
              onChanged:
                  c.editable &&
                      c.types.any((t) => t.id == unit.type && t.flags & 4 != 0)
                  ? (v) => c.patchField(unit.id * 32 + 4, [v ? 1 : 0])
                  : null,
            ),
            if (c.parameters.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Text(
                      '参数描述尚未载入',
                      style: TextStyle(color: AppColors.muted),
                    ),
                    TextButton(
                      onPressed: c.ready ? () => c.selectUnit(unit.id) : null,
                      child: const Text('读取参数'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            ControlGrid(
              rotary: true,
              children: [
                for (var p = 0; p < c.parameters.length; p++)
                  DeviceRegion(
                    store: c.view,
                    aspects: const [DeviceAspect.patch, DeviceAspect.access],
                    label: 'parameter-${unit.id}-$p',
                    select: (s) => [
                      s.access,
                      s.patch?.sublist(
                        unit.id * 32 + 6 + p * 2,
                        unit.id * 32 + 8 + p * 2,
                      ),
                    ],
                    builder: (_) => RotaryControl(
                      key: ValueKey('${c.metadataGeneration}-${unit.id}-$p'),
                      label: c.parameters[p].name,
                      value: c.patch!.unit(unit.id).parameter(p),
                      min: c.parameters[p].min,
                      max: c.parameters[p].max,
                      display: c.parameters[p].label,
                      onCommit: c.editable
                          ? (v) =>
                                c.patchField(unit.id * 32 + 6 + p * 2, raw16(v))
                          : null,
                    ),
                  ),
              ],
            ),
          ] else
            const Text('添加效果后可编辑参数。'),
        ],
      ),
    );
  }

  Widget _patchControl(
    int offset,
    int length,
    Widget Function(Patch) builder,
  ) => DeviceRegion(
    store: c.view,
    aspects: const [DeviceAspect.patch, DeviceAspect.access],
    label: 'patch-$offset',
    select: (s) => [s.access, s.patch?.sublist(offset, offset + length)],
    builder: (_) => builder(c.patch!),
  );

  Widget _presetMenu(BuildContext context) => PopupMenuButton<String>(
    tooltip: '音色操作',
    enabled: c.editable,
    onSelected: (action) {
      switch (action) {
        case 'rename':
          rename(context);
        case 'copy':
          showPresets(context, c, copy: true);
        case 'swap':
          showPresets(context, c, swap: true);
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'rename', child: Text('重命名')),
      const PopupMenuItem(value: 'copy', child: Text('保存到')),
      PopupMenuItem(
        value: 'swap',
        enabled: !c.currentFactoryPreset,
        child: Text(c.currentFactoryPreset ? '厂商区不可交换' : '交换预设'),
      ),
    ],
    icon: const Icon(Icons.more_horiz),
  );

  Widget _unitCard(
    BuildContext context,
    EffectUnit unit, {
    double width = 112,
  }) => Semantics(
    selected: c.selectedUnit == unit.id,
    button: true,
    label:
        'UNIT ${unit.id + 1} ${c.typeName(unit.type)}，${unit.enabled ? '开启' : '旁路'}',
    child: SizedBox(
      width: width,
      child: Material(
        color: c.selectedUnit == unit.id ? AppColors.selected : AppColors.inset,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: c.editable ? () => c.selectUnit(unit.id) : null,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(
                color: c.selectedUnit == unit.id
                    ? AppColors.accent
                    : AppColors.controlBorder,
                width: c.selectedUnit == unit.id ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${unit.id + 1}'.padLeft(2, '0'),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.muted,
                      ),
                    ),
                    Icon(
                      unit.enabled
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 12,
                      color: unit.enabled ? AppColors.green : AppColors.muted,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    _effectIcon(c.typeName(unit.type)),
                    size: 28,
                    color: c.selectedUnit == unit.id
                        ? AppColors.accent
                        : AppColors.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  c.typeName(unit.type),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  c.selectedUnit == unit.id
                      ? '${unit.enabled ? '开启' : '旁路'} · 编辑中'
                      : unit.enabled
                      ? '开启'
                      : '旁路',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  IconData _effectIcon(String name) {
    final upper = name.toUpperCase();
    if (upper.contains('GATE')) return Icons.graphic_eq;
    if (upper.contains('COMP')) return Icons.compress;
    if (upper.contains('DRIVE') || upper.contains('DIST')) return Icons.waves;
    if (upper.contains('AMP')) return Icons.speaker_outlined;
    if (upper.contains('DELAY')) return Icons.all_inclusive;
    if (upper.contains('REVERB')) return Icons.view_in_ar_outlined;
    return Icons.tune;
  }
}

abstract class ControllerPage extends StatelessWidget {
  const ControllerPage({super.key, required this.c});
  final ApexisController c;
  Widget value(
    String name,
    int offset,
    int min,
    int max, {
    bool wide = false,
    String? display,
    String Function(int)? format,
    bool signed = false,
  }) => DeviceRegion(
    store: c.view,
    aspects: const [DeviceAspect.globals, DeviceAspect.access],
    label: 'global-$offset',
    select: (s) => [
      s.access,
      s.globals.sublist(offset, offset + (wide ? 2 : 1)),
    ],
    builder: (_) {
      final raw = wide
          ? le16(c.globals, offset, signed: signed)
          : signed
          ? c.globals[offset].toSigned(8)
          : c.globals[offset];
      return ValueControl(
        label: name,
        value: raw,
        min: min,
        max: max,
        display: format?.call(raw) ?? display,
        onCommit: c.editable
            ? (v) => c.writeField(offset, wide ? raw16(v) : [v & 255])
            : null,
      );
    },
  );

  Widget choices(String label, int offset, List<String> names) => DeviceRegion(
    store: c.view,
    aspects: const [DeviceAspect.globals, DeviceAspect.access],
    label: 'global-$offset',
    select: (s) => [s.access, s.globals[offset]],
    builder: (_) => ChoiceControl(
      label: label,
      value: c.globals[offset],
      choices: names,
      onChanged: c.editable ? (v) => c.writeField(offset, [v]) : null,
    ),
  );
  Widget toggle(String label, int offset, {String? subtitle}) => DeviceRegion(
    store: c.view,
    aspects: const [DeviceAspect.globals, DeviceAspect.access],
    label: 'global-$offset',
    select: (s) => [s.access, s.globals[offset]],
    builder: (_) => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
      value: c.globals[offset] == 1,
      onChanged: c.editable ? (v) => c.writeField(offset, [v ? 1 : 0]) : null,
    ),
  );
}

class GlobalPage extends ControllerPage {
  const GlobalPage({super.key, required super.c});
  @override
  Widget build(BuildContext context) => responsiveColumns(context, [
    SectionCard(
      title: '输出设置',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          choices('输出路由', 1, ['Normal', 'Dry', 'NoCAB']),
          const SizedBox(height: 16),
          choices('USB 录音模式', 63, ['普通', '关闭', 'Reamp', 'Dry']),
          toggle('USB 录音混入伴奏', 3),
          const Divider(height: 32),
          value('MIDI 通道', 8, 1, 16),
        ],
      ),
    ),
    SectionCard(
      title: '音量与速度',
      child: Column(
        children: [
          value('蓝牙 / 伴奏音量', 4, 0, 127),
          value('USB 录制音量', 61, 0, 100),
          value('全局 BPM', 12, 40, 240, wide: true),
          toggle('全局 BPM 同步', 16),
        ],
      ),
    ),
  ]);
}

class EqualizerPage extends ControllerPage {
  const EqualizerPage({super.key, required super.c});
  @override
  Widget build(BuildContext context) => Column(
    children: [
      DeviceRegion(
        store: c.view,
        aspects: const [
          DeviceAspect.globals,
          DeviceAspect.access,
          DeviceAspect.connection,
          DeviceAspect.preset,
          DeviceAspect.parameters,
        ],
        label: 'eq-curve',
        select: (s) => [
          s.access,
          s.connection,
          s.preset.selected,
          s.metadataGeneration,
          s.globals.sublist(32, 54),
        ],
        builder: (context) => SectionCard(
          title: '全局均衡器',
          subtitle: '4 段参数均衡 · 示意曲线，非实测频响',
          trailing: Switch(
            value: c.globals[32] == 1,
            onChanged: c.editable ? (v) => c.writeField(32, [v ? 1 : 0]) : null,
          ),
          child: Column(
            children: [
              EqCurveEditor(
                bands: List.generate(
                  4,
                  (i) => (
                    le16(c.globals, 39 + i * 4).toDouble(),
                    c.globals[38 + i * 4].toSigned(8).toDouble(),
                    c.globals[41 + i * 4] / 10,
                  ),
                ),
                enabled: c.globals[32] == 1,
                version: (c.session, c.selected, c.metadataGeneration),
                onCommit: !c.editable
                    ? null
                    : (band, frequency, gain) => c.writeField(38 + band * 4, [
                        gain & 255,
                        ...raw16(frequency),
                      ]),
              ),
              const SizedBox(height: 20),
              responsiveColumns(context, [
                value(
                  'LC · 低切',
                  34,
                  19,
                  200,
                  wide: true,
                  format: (v) => v == 19 ? '关闭' : '$v Hz',
                ),
                value(
                  'HC · 高切',
                  36,
                  4000,
                  20500,
                  wide: true,
                  format: (v) => v > 20000 ? '关闭' : '$v Hz',
                ),
              ]),
            ],
          ),
        ),
      ),
      const SizedBox(height: 20),
      LayoutBuilder(
        builder: (context, box) => Wrap(
          spacing: 16,
          runSpacing: 16,
          children: List.generate(
            4,
            (i) => SizedBox(
              width: box.maxWidth >= 900
                  ? (box.maxWidth - 48) / 4
                  : box.maxWidth >= 600
                  ? (box.maxWidth - 16) / 2
                  : box.maxWidth,
              child: SectionCard(
                title: 'P${i + 1}',
                child: Column(
                  children: [
                    value('Freq · Hz', 39 + i * 4, 20, 20000, wide: true),
                    value('Gain · dB', 38 + i * 4, -18, 18, signed: true),
                    value(
                      'Q',
                      41 + i * 4,
                      1,
                      160,
                      format: (v) => (v / 10).toStringAsFixed(1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
      DeviceRegion(
        store: c.view,
        aspects: const [DeviceAspect.access],
        label: 'eq-actions',
        builder: (context) => Wrap(
          spacing: 12,
          children: [
            OutlinedButton.icon(
              onPressed: c.editable ? () => exportEq(context, c) : null,
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('导出 EQ'),
            ),
            OutlinedButton.icon(
              onPressed: c.editable ? () => importEq(context, c) : null,
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('导入 EQ'),
            ),
          ],
        ),
      ),
    ],
  );
}

class LooperPage extends ControllerPage {
  const LooperPage({super.key, required super.c});
  @override
  Widget build(BuildContext context) => Column(
    children: [
      DeviceRegion(
        store: c.view,
        aspects: const [DeviceAspect.looper, DeviceAspect.access],
        label: 'loop-controls',
        select: (s) => [
          s.access,
          s.looper.state,
          s.looper.flags,
          s.looper.pending,
        ],
        builder: (context) => SectionCard(
          title: 'LOOPER',
          subtitle:
              '${['已停止', '播放中', '录制中'][c.loopState.clamp(0, 2)]}${c.loopFlags & 8 != 0 ? ' · 正在收尾' : ''}${c.loopFlags & 64 != 0 ? ' · 预备拍' : ''}${c.loopPending != 0 ? ' · 动作待执行 ${c.loopPending}' : ''}',
          child: Column(
            children: [
              DeviceRegion(
                store: c.view,
                aspects: const [DeviceAspect.looper],
                label: 'loop-progress',
                select: (s) => [
                  s.looper.position,
                  s.looper.total,
                  s.looper.limit,
                  s.looper.generation,
                  s.looper.countinRemaining,
                ],
                builder: (context) => Column(
                  children: [
                    Text(
                      '${(c.loopPosition / 1000000).toStringAsFixed(1)} s',
                      style: const TextStyle(
                        fontSize: 52,
                        fontWeight: FontWeight.w300,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      '总长 ${(c.loopTotal / 1000000).toStringAsFixed(1)} s · 上限 ${(c.loopLimit / 1000000).toStringAsFixed(1)} s',
                      style: const TextStyle(color: AppColors.muted),
                    ),
                    Text(
                      '运行代次 ${c.loopGeneration}${c.loopCountinRemaining > 0 ? ' · 预备拍剩余 ${(c.loopCountinRemaining / 1000000).toStringAsFixed(1)} s' : ''}',
                      style: const TextStyle(color: AppColors.muted),
                    ),
                    const SizedBox(height: 20),
                    LinearProgressIndicator(
                      value:
                          (c.loopPosition /
                                  max(
                                    1,
                                    c.loopTotal == 0
                                        ? c.loopLimit
                                        : c.loopTotal,
                                  ))
                              .clamp(0, 1),
                      minHeight: 5,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: c.editable
                        ? () => c.action(4, 0x14, 0, [], false)
                        : null,
                    icon: const Icon(Icons.fiber_manual_record),
                    label: const Text('录制'),
                  ),
                  OutlinedButton.icon(
                    onPressed: c.editable
                        ? () => c.action(
                            4,
                            c.loopState == 0 ? 0x12 : 0x13,
                            0,
                            [],
                            false,
                          )
                        : null,
                    icon: Icon(
                      c.loopState == 0 ? Icons.play_arrow : Icons.stop,
                    ),
                    label: Text(c.loopState == 0 ? '播放' : '停止'),
                  ),
                  OutlinedButton.icon(
                    onPressed: c.editable
                        ? () => c.action(4, 0x16, 0, [], false)
                        : null,
                    icon: const Icon(Icons.undo),
                    label: const Text('撤销 / 恢复'),
                  ),
                  OutlinedButton.icon(
                    onPressed: c.editable
                        ? () async {
                            if (await confirm(
                              context,
                              '清空循环录音？',
                              '这会清除设备上的当前 Looper 录音。',
                            )) {
                              await c.action(4, 0x15, 0, [], false);
                            }
                          }
                        : null,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('清空'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 20),
      responsiveColumns(context, [
        SectionCard(
          title: '录放设置',
          child: Column(
            children: [
              value('录音音量', 6, 0, 100),
              value('播放音量', 7, 0, 100),
              choices('效果链位置', 2, ['HEAD', 'TAIL']),
              choices('鼓机同步', 10, ['关闭', '启动同步', '启停同步']),
              DeviceRegion(
                store: c.view,
                aspects: const [
                  DeviceAspect.patterns,
                  DeviceAspect.globals,
                  DeviceAspect.access,
                ],
                select: (s) => [
                  s.patterns,
                  s.globals.sublist(20, 22),
                  s.access,
                ],
                builder: (context) => DropdownButtonFormField<int>(
                  key: ValueKey(c.global16(20)),
                  initialValue: c.patterns.containsKey(c.global16(20))
                      ? c.global16(20)
                      : null,
                  decoration: const InputDecoration(labelText: 'Looper 联动鼓型'),
                  isExpanded: true,
                  items: [
                    for (final p in c.patterns.entries)
                      DropdownMenuItem(value: p.key, child: Text(p.value)),
                  ],
                  onChanged: c.editable && c.patterns.isNotEmpty
                      ? (v) {
                          if (v != null) c.writeField(20, raw16(v));
                        }
                      : null,
                ),
              ),
              DeviceRegion(
                store: c.view,
                aspects: const [DeviceAspect.access],
                builder: (_) => TextButton(
                  onPressed: c.editable ? c.loadPatterns : null,
                  child: const Text('读取可用联动鼓型'),
                ),
              ),
              toggle('循环末尾停止', 9),
            ],
          ),
        ),
        SectionCard(
          title: '录制方式',
          child: Column(
            children: [
              choices('自动录音', 55, ['关闭', '一次', '持续']),
              value('触发阈值 · 灵敏度高 → 低', 56, 0, 100),
              value('小节模式 · 0 为手动', 57, 0, 16),
              choices('节拍', 58, ['4/4', '3/4', '2/4', '6/8']),
              toggle('预备拍', 59, subtitle: '手动首录的一小节预备拍'),
            ],
          ),
        ),
      ]),
    ],
  );
}

class DrumPage extends ControllerPage {
  const DrumPage({super.key, required super.c});
  @override
  Widget build(BuildContext context) => responsiveColumns(context, [
    DeviceRegion(
      store: c.view,
      aspects: const [
        DeviceAspect.drum,
        DeviceAspect.globals,
        DeviceAspect.patterns,
        DeviceAspect.access,
      ],
      label: 'drum-controls',
      select: (s) => [
        s.drum,
        s.drumIssue,
        s.access,
        s.patterns,
        s.globals.sublist(18, 20),
      ],
      builder: (context) => SectionCard(
        title: '鼓机',
        subtitle: c.drumIssue ?? (c.drumState == 0 ? '已停止 · 以设备资源为准' : '正在播放'),
        child: Column(
          children: [
            const Icon(Icons.album_outlined, size: 88, color: AppColors.accent),
            const SizedBox(height: 24),
            Text(
              c.patterns[c.global16(18)] ?? '尚未读取鼓型',
              style: const TextStyle(fontSize: 22),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: c.editable && c.drumIssue == null
                  ? () => c.action(3, c.drumState == 0 ? 3 : 4, 0, [], false)
                  : null,
              icon: Icon(c.drumState == 0 ? Icons.play_arrow : Icons.stop),
              label: Text(c.drumState == 0 ? '播放鼓机' : '停止鼓机'),
            ),
            const SizedBox(height: 24),
            DropdownButtonFormField<int>(
              initialValue: c.patterns.containsKey(c.global16(18))
                  ? c.global16(18)
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '已安装鼓型'),
              items: c.patterns.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: c.editable
                  ? (v) {
                      if (v != null) c.writeField(18, raw16(v));
                    }
                  : null,
            ),
            TextButton(
              onPressed: c.editable ? c.loadPatterns : null,
              child: const Text('刷新设备鼓型目录'),
            ),
          ],
        ),
      ),
    ),
    SectionCard(
      title: '节奏控制',
      child: Column(
        children: [
          value('鼓机音量', 5, 0, 100),
          value('鼓机 BPM', 14, 40, 240, wide: true),
          toggle('BPM 同步', 17),
          toggle('载入鼓型时采用其速度', 11),
          value('空间效果', 54, 0, 100),
        ],
      ),
    ),
  ]);
}

class TunerPage extends ControllerPage {
  const TunerPage({super.key, required super.c});
  @override
  Widget build(BuildContext context) => DeviceRegion(
    store: c.view,
    aspects: const [
      DeviceAspect.tuner,
      DeviceAspect.globals,
      DeviceAspect.access,
      DeviceAspect.connection,
    ],
    label: 'tuner-controls',
    select: (s) => [s.tuner.active, s.globals[60], s.access, s.connection.demo],
    builder: _content,
  );
  Widget _content(BuildContext context) {
    return SectionCard(
      title: '调音表',
      subtitle: c.demo
          ? '演示模式不模拟音高测量'
          : '标准音高 · A4 ${440 + c.globals[60].toSigned(8)} Hz',
      trailing: Switch(
        value: c.tunerActive,
        onChanged: c.editable ? c.setTuner : null,
      ),
      child: Column(
        children: [
          const SizedBox(height: 32),
          DeviceRegion(
            store: c.view,
            aspects: const [DeviceAspect.tuner],
            label: 'tuner-note',
            select: (s) => [
              s.tuner.active,
              s.tuner.note,
              (s.tuner.pointer - 128).abs() < 4,
            ],
            builder: (context) {
              final valid =
                  c.tunerActive && c.tunerNote >= 0 && c.tunerNote < 12;
              return Text(
                valid
                    ? [
                        'A',
                        'A♯',
                        'B',
                        'C',
                        'C♯',
                        'D',
                        'D♯',
                        'E',
                        'F',
                        'F♯',
                        'G',
                        'G♯',
                      ][c.tunerNote]
                    : '—',
                style: TextStyle(
                  fontSize: 100,
                  fontWeight: FontWeight.w300,
                  color: valid && (c.tunerPointer - 128).abs() < 4
                      ? AppColors.green
                      : AppColors.text,
                ),
              );
            },
          ),
          Text(
            c.tunerActive ? '拨动一根琴弦开始调音' : '开启调音表',
            style: const TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 40),
          DeviceRegion(
            store: c.view,
            aspects: const [DeviceAspect.tuner],
            label: 'tuner-pointer',
            builder: (context) {
              final valid =
                  c.tunerActive && c.tunerNote >= 0 && c.tunerNote < 12;
              return SizedBox(
                height: 70,
                child: LayoutBuilder(
                  builder: (context, box) => Stack(
                    children: [
                      const Positioned(
                        left: 0,
                        right: 0,
                        top: 32,
                        child: Divider(),
                      ),
                      for (var i = 0; i < 17; i++)
                        Positioned(
                          left: box.maxWidth * i / 16,
                          top: i == 8 ? 10 : 24,
                          child: Container(
                            width: 1,
                            height: i == 8 ? 44 : 16,
                            color: i == 8 ? AppColors.green : AppColors.border,
                          ),
                        ),
                      if (valid)
                        Positioned(
                          left:
                              (box.maxWidth - 20) *
                              c.tunerPointer.clamp(0, 256) /
                              256,
                          top: 0,
                          child: const Icon(
                            Icons.arrow_drop_down,
                            color: AppColors.accent,
                            size: 24,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text('偏低 ♭'), Text('准确'), Text('偏高 ♯')],
          ),
          const SizedBox(height: 24),
          ValueControl(
            label: '标准音高 A4',
            value: 440 + c.globals[60].toSigned(8),
            min: 430,
            max: 450,
            display: '${440 + c.globals[60].toSigned(8)} Hz',
            onCommit: c.editable
                ? (v) => c.writeField(60, [(v - 440) & 255])
                : null,
          ),
        ],
      ),
    );
  }
}

class ResourcesPage extends StatelessWidget {
  const ResourcesPage({super.key, required this.c});
  final ApexisController c;
  @override
  Widget build(BuildContext context) => DeviceRegion(
    store: c.view,
    aspects: const [
      DeviceAspect.resources,
      DeviceAspect.access,
      DeviceAspect.effects,
    ],
    label: 'resources',
    builder: (context) => SectionCard(
      title: '音色资源',
      subtitle: '设备已安装的模型和箱体资源',
      trailing: IconButton(
        tooltip: '刷新资源',
        onPressed: c.editable ? c.loadResources : null,
        icon: const Icon(Icons.refresh),
      ),
      child: c.resources.isEmpty
          ? const EmptyFeature(
              icon: Icons.library_music_outlined,
              title: '暂无已安装资源',
              description: '连接后从设备读取资源目录。当前协议支持选择已安装资源，尚未提供模型、IR 或鼓音源上传接口。',
            )
          : Column(
              children: [
                for (final r in c.resources)
                  ListTile(
                    leading: const Icon(Icons.speaker_outlined),
                    title: Text(r.name),
                    subtitle: Text(c.typeName(r.type)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: c.editable && c.patch!.count > 0
                        ? () async {
                            if (await confirm(
                              context,
                              '加载 ${r.name}？',
                              '将替换当前选中的 UNIT ${c.selectedUnit + 1}。',
                            )) {
                              await c.action(1, 0, 0x21, [
                                c.selectedUnit,
                                ...Gt1.u14(r.type),
                                ...Gt1.u16(r.ref),
                              ]);
                            }
                          }
                        : null,
                  ),
              ],
            ),
    ),
  );
}

class SettingsPage extends ControllerPage {
  const SettingsPage({super.key, required super.c});
  @override
  Widget build(BuildContext context) => DeviceRegion(
    store: c.view,
    aspects: const [
      DeviceAspect.connection,
      DeviceAspect.access,
      DeviceAspect.links,
    ],
    label: 'settings',
    builder: (context) => Column(
      children: [
        responsiveColumns(context, [
          SectionCard(
            title: '我的设备',
            child: Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cable, color: AppColors.accent),
                  title: Text(c.port?.name ?? 'GT1'),
                  subtitle: Text(c.demo ? '演示连接' : '${c.port?.kind} · 已连接'),
                  trailing: TextButton(
                    onPressed: c.showBusyFeedback ? null : c.disconnect,
                    child: const Text('断开'),
                  ),
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('固件版本'),
                  trailing: Text(c.identity?.version ?? '—'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('BT 音频'),
                  trailing: Text(c.links & 4 != 0 ? 'A2DP 已连接' : '未连接'),
                ),
                toggle('自动关机', 62, subtitle: '开启后，15 分钟无活动时正常软关机'),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('旋钮自定义'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: c.editable ? () => knobDialog(context, c) : null,
                ),
              ],
            ),
          ),
          SectionCard(
            title: '音色与备份',
            subtitle: '编辑与导入在正常软关机时持久化',
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.file_upload_outlined),
                  title: const Text('导出当前音色'),
                  subtitle: const Text('GT1S'),
                  onTap: c.editable && !c.demo
                      ? () => exportParameters(context, c, false)
                      : null,
                ),
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('导入音色'),
                  subtitle: const Text('覆盖当前选中的音色位置'),
                  onTap: c.editable && !c.demo
                      ? () => importParameters(context, c, false)
                      : null,
                ),
                ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: const Text('备份全部配置'),
                  subtitle: const Text('GT1B · 128 个音色与全局设置'),
                  onTap: c.editable && !c.demo
                      ? () => exportParameters(context, c, true)
                      : null,
                ),
                ListTile(
                  leading: const Icon(Icons.restore_page_outlined),
                  title: const Text('恢复配置文件'),
                  onTap: c.editable && !c.demo
                      ? () => importParameters(context, c, true)
                      : null,
                ),
                ListTile(
                  leading: const Icon(Icons.restart_alt, color: AppColors.red),
                  title: const Text('恢复出厂设置'),
                  onTap: c.editable && !c.demo
                      ? () => restoreDefaults(context, c)
                      : null,
                ),
                if (c.demo)
                  const Text(
                    '文件会话与恢复默认需连接真实设备。',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
              ],
            ),
          ),
        ], trailingGap: false),
        const SizedBox(height: 20),
        SectionCard(
          title: '应用信息',
          child: Column(
            children: [
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('语言'),
                trailing: Text('简体中文'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('帮助'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('连接与使用'),
                    content: const Text(
                      '手机：开启蓝牙，允许附近设备权限，扫描并选择效果器。\n\n电脑：通过 USB 连接，选择 MIDI 控制端点。\n\n参数同步完成后可编辑。保存回执表示修改在设备 RAM 中，正常软关机才持久化。\n\n调音器与 Looper 状态仅在对应页面打开时读取。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('知道了'),
                      ),
                    ],
                  ),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('连接诊断'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('连接诊断'),
                    content: SizedBox(
                      width: 600,
                      child: SingleChildScrollView(
                        child: SelectableText(
                          'Protocol 1 / Schema 12\nRevision ${c.revision}\n载荷 ${c.transport?.payload ?? 0} B\n\n${c.logs.join('\n')}',
                        ),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
              ),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('关于'),
                subtitle: Text(
                  'Apexis STD · Flutter\n协议依据：GT1 2026-09-14 r2\n社区、反馈服务和 OTA 尚未配置。',
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

Future<void> knobDialog(BuildContext context, ApexisController c) async {
  var knob = 0;
  var target = c.patch!.bytes[358],
      unit = c.patch!.bytes[359],
      parameter = c.patch!.bytes[360];
  var minimum = le16(c.patch!.bytes, 354, signed: true),
      maximum = le16(c.patch!.bytes, 356, signed: true);
  var enabled = c.patch!.bytes[361] == 1;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, set) => AlertDialog(
        title: const Text('旋钮自定义'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ChoiceControl(
                  label: '物理旋钮',
                  value: knob,
                  choices: const ['旋钮 1', '旋钮 2'],
                  onChanged: (v) => set(() {
                    knob = v;
                    final off = 352 + v * 10;
                    target = c.patch!.bytes[off + 6];
                    unit = c.patch!.bytes[off + 7];
                    parameter = c.patch!.bytes[off + 8];
                    minimum = le16(c.patch!.bytes, off + 2, signed: true);
                    maximum = le16(c.patch!.bytes, off + 4, signed: true);
                    enabled = c.patch!.bytes[off + 9] == 1;
                  }),
                ),
                ChoiceControl(
                  label: '控制目标',
                  value: target,
                  choices: const ['无', '输入', '输出', '效果参数'],
                  onChanged: (v) => set(() {
                    target = v;
                    minimum = 0;
                    maximum = v == 1 ? 30 : 100;
                  }),
                ),
                if (target == 3 && c.patch!.count > 0) ...[
                  DropdownButtonFormField<int>(
                    initialValue: unit.clamp(0, c.patch!.count - 1),
                    decoration: const InputDecoration(labelText: 'UNIT'),
                    items: [
                      for (final id in c.patch!.chain)
                        DropdownMenuItem(
                          value: id,
                          child: Text(
                            'UNIT ${id + 1} · ${c.typeName(c.patch!.unit(id).type)}',
                          ),
                        ),
                    ],
                    onChanged: (v) => set(() {
                      unit = v!;
                      parameter = 0;
                    }),
                  ),
                  ValueControl(
                    label: '参数编号（从 0 开始）',
                    value: parameter,
                    min: 0,
                    max: max(
                      0,
                      c.patch!.unit(unit.clamp(0, c.patch!.count - 1)).count -
                          1,
                    ),
                    onCommit: (v) => set(() => parameter = v),
                  ),
                ],
                TextFormField(
                  key: ValueKey('min-$knob-$target'),
                  initialValue: '$minimum',
                  decoration: const InputDecoration(labelText: '最小值'),
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                  ),
                  onChanged: (v) => minimum = int.tryParse(v) ?? minimum,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: ValueKey('max-$knob-$target'),
                  initialValue: '$maximum',
                  decoration: const InputDecoration(labelText: '最大值'),
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                  ),
                  onChanged: (v) => maximum = int.tryParse(v) ?? maximum,
                ),
                SwitchListTile(
                  title: const Text('启用映射'),
                  value: enabled,
                  onChanged: (v) => set(() => enabled = v),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              if (minimum > maximum ||
                  minimum < -8192 ||
                  maximum > 8191 ||
                  (target == 3 &&
                      (unit >= c.patch!.count ||
                          parameter >= c.patch!.unit(unit).count))) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请检查映射范围与 UNIT 参数')),
                );
                return;
              }
              final type = target == 3 ? c.patch!.unit(unit).type : 0;
              Navigator.pop(dialogContext);
              await c.action(8, 0, 0x20, [
                knob,
                target,
                target == 3 ? unit : 0,
                ...Gt1.u14(type),
                target == 3 ? parameter : 0,
                ...Gt1.s14(minimum),
                ...Gt1.s14(maximum),
                enabled ? 1 : 0,
              ]);
            },
            child: const Text('应用'),
          ),
        ],
      ),
    ),
  );
}
