# 效果移动按钮异常修复与补测

## 原因

`Patch.chain` 来自 `Uint8List.sublist`，是固定长度的副本。`EffectsPage._move` 在按钮回调中调用 `removeAt`/`insert`，改变列表长度时抛出 `UnsupportedError: Cannot remove from a fixed-length list`。异常发生在发出 MIDI 写入之前，与 GT1 固件无关。

先新增真实 Widget 点击测试，在未修复版本点击“向前移动”复现用户的原始异常。之前控制器/协议测试直接提交合法顺序，没有执行此按钮回调；先前的通信验收不能替代这项界面验收。

## 修复

- 相邻移动改为交换两个位置，不改变固定列表长度，不修改 UNIT 内容及编号。
- 增加可编辑状态、空数据、UNIT 不存在、方向及首尾范围检查。
- 继续走现有带版本校验的写入/回读流程，不在收到设备确认前修改正式数据。
- 按 UI/UX 技能的交互检查补齐按钮点击、禁用边界、错误反馈；不修改界面风格或同步宽限期。

## 自动化覆盖

`test/effect_actions_widget_test.dart` 的 7 项测试通过：

1. 设备拒绝移动时保留已确认顺序，并显示错误。
2. 通过界面添加/替换效果、旁路/启用、清尾音开关、删除取消/确认。
3. 实际前移/后移按钮、返回原顺序、选中 UNIT 不变、UNIT 数据不变。
4. 首尾按钮禁用且不发送指令，连续移动到两端再返回。
5. 空链无移动按钮。
6. 单效果不能向任一方向移动。
7. 10 个效果时末位前移/后移正确。

修复后的前 5 项移动场景（上述第 3–7 项）亦通过 `integration_test/effect_actions_profile_test.dart` 在实际 Windows Profile 构建中运行；使用模拟设备，不冒充实机结果。

最终完整回归命令 `flutter test --no-pub test local_packages/flutter_midi_command_windows/test`：136 项全部通过（包含 7 项界面补测）。`flutter analyze --no-pub` 无问题。

实机测试结束后，正常入口 `lib/main.dart` 的 Windows Profile 构建成功，输出 `build/windows/x64/runner/Profile/apexis.exe`，不再是集成测试入口。

## GT1 实机补测

- `artifacts/gt1-ui-movement-20260920/`：测试前已有 4 个效果，原测试为保护现有效果而跳过结构操作；此轮备份/恢复通过，但没有执行移动按钮，不能列为按钮实测通过。
- 针对现有链的按钮检查已加入 `hardware_write_test.dart`，显式启用 `HARDWARE_UI_MOVEMENT=true`。只交换现有链中相邻位置再还原，不增删原有算法；点击的是 `ApexisApp` 的真实按钮，而不是直接调用 `_move` 或提交 MOVE 指令。每个方向独立 READ 核验顺序，比较全部 UNIT 内容，检查选中项及边界。
- 实机执行证据目录为 `artifacts/gt1-ui-movement-existing-20260920/`。测试退出码为 0，20 个步骤通过、2 个跳过；`actualUiMovementVerified=true`、`restored=true`、`quietBankRestoredVerified=true`、`allChecksPassed=true`、`transportFailed=false`。实际按钮前移/后移与独立读回均通过，原 4 个效果及备份数据恢复核验通过。
- 两个跳过项是保护现有效果链而不增删的 `effect_structure`，以及 `RAM_save_ack`；不将跳过项计作通过。

不据此声称所有界面按钮、所有算法组合、声音质量及软关机持久化均已验收。
