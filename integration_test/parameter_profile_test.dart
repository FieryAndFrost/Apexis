import 'package:apexis/data/controller.dart';
import 'package:apexis/data/parameters.dart';
import 'package:apexis/transport/transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../test/support/firmware_demo.dart';

// No hardware: exercises the native AOT build, not just the JIT unit runner.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('parameter metadata cold load and cache in Windows AOT', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final c = ApexisController();
    try {
      await c.connect(
        FirmwareDemo(124),
        const DevicePort('demo', 'GT1', 'demo'),
      );
      expect(c.error, isNull);
      c.setActivePage(0);
      for (var round = 0; round < 3; round++) {
        for (var unit = 0; unit < 6; unit++) {
          await c.selectUnit(unit);
          expect(c.error, isNull);
          expect(c.parameters, isNotEmpty);
          await c.patchField(unit * 32 + 6, raw16(51 + round));
          await c.refreshParameters();
          expect(c.error, isNull);
          expect(c.parameters.first.label, '${51 + round}');
        }
      }
    } finally {
      await c.disconnect();
      c.dispose();
    }
  });
}
