import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

DynamicLibrary _load() {
  const name = 'apexis_usb_io.dll';
  final bundled = File(
    '${File(Platform.resolvedExecutable).parent.path}/$name',
  );
  if (bundled.existsSync()) return DynamicLibrary.open(bundled.absolute.path);
  final development = File('build/usb_io/Release/$name');
  if (development.existsSync()) {
    return DynamicLibrary.open(development.absolute.path);
  }
  throw StateError('缺少 $name；请重新构建 Windows 应用，独立测试先构建 windows/usb_io');
}

final _library = _load();
final usbScan = _library
    .lookupFunction<
      Uint32 Function(Pointer<Utf16>, Uint32, Pointer<Uint32>),
      int Function(Pointer<Utf16>, int, Pointer<Uint32>)
    >('apexis_usb_scan');
final usbOpen = _library
    .lookupFunction<
      Uint32 Function(Pointer<Utf16>, Pointer<Pointer<Void>>),
      int Function(Pointer<Utf16>, Pointer<Pointer<Void>>)
    >('apexis_usb_open');
final usbRead = _library
    .lookupFunction<
      Uint32 Function(
        Pointer<Void>,
        Pointer<Uint8>,
        Uint32,
        Pointer<Uint32>,
        IntPtr,
      ),
      int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>, int)
    >('apexis_usb_read');
final usbWrite = _library
    .lookupFunction<
      Uint32 Function(Pointer<Void>, Pointer<Uint8>, Uint32),
      int Function(Pointer<Void>, Pointer<Uint8>, int)
    >('apexis_usb_write');
final usbClose = _library
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'apexis_usb_close',
    );
