import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 3),
  responseDataCallback: (data) => writeResponseData(
    data,
    testOutputFilename: 'gt1-cdc-readonly-20260921',
    destinationDirectory: 'artifacts',
  ),
);
