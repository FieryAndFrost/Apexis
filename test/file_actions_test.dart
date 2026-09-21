import 'dart:typed_data';
import 'package:apexis/data/controller.dart';
import 'package:apexis/data/file_transfer.dart';
import 'package:apexis/protocol/codec.dart';
import 'package:apexis/transport/transport.dart';
import 'package:apexis/ui/file_actions.dart';
import 'package:apexis/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'file_transfer_test.dart' show FileDevice, makeFile;

class FailingResetDevice extends FileDevice {
  FailingResetDevice() : super(makeFile(bank: true), bankFile: true);
  @override
  Future<void> send(Uint8List frame) async {
    final m = Message.parse(frame, response: false);
    if (m.component == 0 && m.command == 8 && m.selector == 0x36) {
      emitFrame(Gt1.frame(0, 8, 0x36, [], 1));
      return;
    }
    await super.send(frame);
  }
}

class FailingRefreshController extends ApexisController {
  bool rejectRefresh = false;
  @override
  Future<void> resync() async {
    if (rejectRefresh) throw StateError('secondary refresh failed');
    await super.resync();
  }
}

void main() {
  testWidgets(
    'commit/cleanup cannot cancel; small screens and large text fit',
    (tester) async {
      addTearDown(() async {
        tester.platformDispatcher.clearAllTestValues();
        await tester.binding.setSurfaceSize(null);
      });
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      for (final size in [
        const Size(375, 812),
        const Size(812, 375),
        const Size(1440, 900),
      ]) {
        await tester.binding.setSurfaceSize(size);
        for (final phase in TransferPhase.values) {
          var cancelled = false;
          await tester.pumpWidget(
            MaterialApp(
              theme: AppColors.theme,
              home: Scaffold(
                body: TransferProgressDialog(
                  title: '正在恢复出厂设置',
                  phase: phase,
                  progress: 0.5,
                  cancelRequested: false,
                  onCancel: () => cancelled = true,
                ),
              ),
            ),
          );
          await tester.pump();
          final button = tester.widget<TextButton>(
            find.widgetWithText(TextButton, '取消'),
          );
          final canCancel =
              phase == TransferPhase.preparing ||
              phase == TransferPhase.transferring;
          expect(button.onPressed != null, canCancel);
          if (canCancel) {
            await tester.tap(find.text('取消'));
            expect(cancelled, isTrue);
          }
          expect(tester.takeException(), isNull, reason: '$size $phase');
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  Future<void> mountReset(WidgetTester tester, ApexisController c) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppColors.theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => restoreDefaults(context, c),
              child: const Text('测试恢复'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('测试恢复'));
    await tester.pumpAndSettle();
  }

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 40));
      if (find.byType(AlertDialog).evaluate().isEmpty) return;
    }
    fail('Transfer dialog failed to close');
  }

  testWidgets(
    'reset failure remains visible when subsequent refresh also fails',
    (tester) async {
      final c = FailingRefreshController();
      final device = FailingResetDevice();
      await tester.runAsync(
        () => c.connect(device, const DevicePort('file', 'GT1', '演示')),
      );
      expect(c.error, isNull);
      c.rejectRefresh = true;
      await mountReset(tester, c);
      await tester.tap(find.text('确认'));
      await drain(tester);
      expect(c.error, contains('00/08/36'));
      expect(c.error, isNot(contains('secondary refresh failed')));
      expect(c.logs.join(), contains('secondary refresh failed'));
      expect(device.committed, isFalse);
      expect(device.ended, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c.disconnect);
      c.dispose();
    },
  );

  testWidgets('reconnect during confirmation never resets the new connection', (
    tester,
  ) async {
    final c = ApexisController();
    final oldDevice = FailingResetDevice(), newDevice = FailingResetDevice();
    await tester.runAsync(
      () => c.connect(oldDevice, const DevicePort('old', 'GT1', '演示')),
    );
    await mountReset(tester, c);
    await tester.runAsync(() async {
      await c.disconnect();
      await c.connect(newDevice, const DevicePort('new', 'GT1', '演示'));
    });
    await tester.tap(find.text('确认'));
    await drain(tester);
    expect(c.error, contains('操作未执行'));
    expect(oldDevice.begins, 0);
    expect(newDevice.begins, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(c.disconnect);
    c.dispose();
  });
}
