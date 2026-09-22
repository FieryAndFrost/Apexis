import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 3),
  responseDataCallback: (data) => writeResponseData(
    data,
    testOutputFilename: 'gt1-winusb-readonly',
    destinationDirectory: 'artifacts',
  ),
);
