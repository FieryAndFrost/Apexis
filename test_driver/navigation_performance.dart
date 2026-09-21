import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 3),
  responseDataCallback: (data) => writeResponseData(
    data,
    testOutputFilename:
        Platform.environment['APEXIS_PERF_LABEL'] ?? 'navigation',
    destinationDirectory: 'build/performance',
  ),
);
