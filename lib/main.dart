import 'package:flutter/material.dart';
import 'ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ApexisApp(autoDemo: bool.fromEnvironment('DEMO')));
}
