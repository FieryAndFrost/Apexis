import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 9),
  responseDataCallback: (data) => writeResponseData(
    data,
    testOutputFilename: 'hardware-chain-limit',
    destinationDirectory: 'build/diagnostics',
  ),
);
