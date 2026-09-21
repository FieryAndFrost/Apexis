import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 6),
  responseDataCallback: (data) => writeResponseData(
    data,
    testOutputFilename: 'hardware-backup',
    destinationDirectory: 'build/diagnostics',
  ),
);
