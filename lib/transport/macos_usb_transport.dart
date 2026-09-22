import 'macos_usb_worker.dart';
import 'usb_transport.dart';
import 'usb_worker.dart';

class MacosUsbTransport extends UsbTransport {
  MacosUsbTransport({UsbWorker? worker})
    : super(worker: worker ?? UsbWorker(macosUsbWorker), kind: 'USB IOKit');
}
