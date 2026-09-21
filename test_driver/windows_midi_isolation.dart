import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 2),
  responseDataCallback: (data) => writeResponseData(
    data,
    testOutputFilename: 'windows-midi-isolation',
    destinationDirectory: 'build/diagnostics',
  ),
);
