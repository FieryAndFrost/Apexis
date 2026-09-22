import 'dart:ffi';
import 'dart:io';

DynamicLibrary _load() {
  if (!Platform.isMacOS) throw UnsupportedError('IOKit 仅适用于 macOS');
  final process = DynamicLibrary.process();
  if (process.providesSymbol('apexis_macos_usb_scan')) return process;
  // Standalone read-only probes may load the separately built test library.
  final development = File('build/macos_usb/libapexis_macos_usb.dylib');
  if (development.existsSync()) {
    return DynamicLibrary.open(development.absolute.path);
  }
  throw StateError('缺少 macOS USB 原生接口，请重新构建 macOS 应用');
}

final _library = _load();
final macUsbScan = _library
    .lookupFunction<
      Uint32 Function(Pointer<Uint64>, Uint32, Pointer<Uint32>),
      int Function(Pointer<Uint64>, int, Pointer<Uint32>)
    >('apexis_macos_usb_scan');
final macUsbOpen = _library
    .lookupFunction<
      Uint32 Function(Uint64, Pointer<Pointer<Void>>),
      int Function(int, Pointer<Pointer<Void>>)
    >('apexis_macos_usb_open');
final macUsbRead = _library
    .lookupFunction<
      Uint32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint32>),
      int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>)
    >('apexis_macos_usb_read');
final macUsbWrite = _library
    .lookupFunction<
      Uint32 Function(Pointer<Void>, Pointer<Uint8>, Uint32),
      int Function(Pointer<Void>, Pointer<Uint8>, int)
    >('apexis_macos_usb_write');
final macUsbStop = _library
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'apexis_macos_usb_stop',
    );
final macUsbClose = _library
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'apexis_macos_usb_close',
    );

String macUsbError(int error) =>
    'IOKit 0x${error.toRadixString(16).padLeft(8, '0')}';
