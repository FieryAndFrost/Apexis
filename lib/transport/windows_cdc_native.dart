import 'dart:ffi';
import 'dart:io';
import 'package:win32/win32.dart';

DynamicLibrary _load() {
  const name = 'apexis_cdc_io.dll';
  final bundled = File(
    '${File(Platform.resolvedExecutable).parent.path}/$name',
  );
  if (bundled.existsSync()) return DynamicLibrary.open(bundled.absolute.path);
  // Standalone Dart probes/Windows unit tests, built from windows/cdc_io.
  final development = File('build/cdc_io/Release/$name');
  if (development.existsSync()) {
    return DynamicLibrary.open(development.absolute.path);
  }
  throw StateError('缺少 $name；请重新构建 Windows 应用，独立测试先构建 windows/cdc_io');
}

final _library = _load();
typedef _IoNative =
    Uint32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<OVERLAPPED>);
typedef _IoDart = int Function(int, Pointer<Uint8>, int, Pointer<OVERLAPPED>);
final cdcRead = _library.lookupFunction<_IoNative, _IoDart>('apexis_cdc_read');
final cdcWrite = _library.lookupFunction<_IoNative, _IoDart>(
  'apexis_cdc_write',
);
final cdcResult = _library
    .lookupFunction<
      Uint32 Function(IntPtr, Pointer<OVERLAPPED>, Pointer<Uint32>, Int32),
      int Function(int, Pointer<OVERLAPPED>, Pointer<Uint32>, int)
    >('apexis_cdc_result');
