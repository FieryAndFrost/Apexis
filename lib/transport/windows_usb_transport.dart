import 'usb_transport.dart';
import 'usb_worker.dart';
import 'windows_usb_worker.dart';

class WindowsUsbTransport extends UsbTransport {
  WindowsUsbTransport({UsbWorker? worker})
    : super(worker: worker ?? UsbWorker(windowsUsbWorker), kind: 'USB WinUSB');
}
