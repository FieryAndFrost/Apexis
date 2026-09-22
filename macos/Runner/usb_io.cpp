// GT1 vendor USB only. Do not seize/reset/configure the composite device:
// macOS retains ownership of the USB Audio interfaces.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <atomic>
#include <cstdint>
#include <new>
#include <set>

#define USB_EXPORT extern "C" __attribute__((visibility("default"), used))

namespace {
using Interface = IOUSBInterfaceInterface300**;
constexpr uint32_t kStopped = 1;  // Private ABI, distinct from IOReturn errors.
constexpr UInt32 kReadDeadlineMs = 100;
constexpr UInt32 kWriteDeadlineMs = 500;

struct Session {
  Interface interface = nullptr;
  UInt8 input = 0, output = 0;
  bool opened = false;
  bool sessionAttempted = false;
  std::atomic<bool> stopped{false};
};

IOReturn sessionControl(Interface interface, bool online) {
  IOUSBDevRequestTO request{};
  request.bmRequestType = 0x41;
  request.bRequest = 0x30;
  request.wValue = online ? 1 : 0;
  request.wIndex = 3;
  request.noDataTimeout = kWriteDeadlineMs;
  request.completionTimeout = kWriteDeadlineMs;
  return (*interface)->ControlRequestTO(interface, 0, &request);
}

// Only called after the RX isolate has exited and all native calls returned.
void destroy(Session* session) {
  if (!session) return;
  if (session->interface) {
    if (session->opened) {
      if (session->sessionAttempted) sessionControl(session->interface, false);
      (*session->interface)->USBInterfaceClose(session->interface);
    }
    (*session->interface)->Release(session->interface);
  }
  delete session;
}

IOReturn getInterface(io_service_t service, Interface* output) {
  *output = nullptr;
  IOCFPlugInInterface** plugin = nullptr;
  SInt32 score = 0;
  auto status = IOCreatePlugInInterfaceForService(
      service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID,
      &plugin, &score);
  if (status != kIOReturnSuccess) return status;
  if (!plugin) return kIOReturnUnsupported;
  auto query = (*plugin)->QueryInterface(
      plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300),
      reinterpret_cast<LPVOID*>(output));
  IODestroyPlugInInterface(plugin);
  return query == 0 && *output ? kIOReturnSuccess : kIOReturnUnsupported;
}

bool matches(Interface interface) {
  UInt16 vendor = 0, product = 0;
  UInt8 number = 0, klass = 0, subclass = 0, protocol = 0, alternate = 0;
  return (*interface)->GetDeviceVendor(interface, &vendor) == 0 &&
      (*interface)->GetDeviceProduct(interface, &product) == 0 &&
      (*interface)->GetInterfaceNumber(interface, &number) == 0 &&
      (*interface)->GetInterfaceClass(interface, &klass) == 0 &&
      (*interface)->GetInterfaceSubClass(interface, &subclass) == 0 &&
      (*interface)->GetInterfaceProtocol(interface, &protocol) == 0 &&
      (*interface)->GetAlternateSetting(interface, &alternate) == 0 &&
      vendor == 0x3654 && product == 0x4e55 && number == 3 &&
      klass == 0xff && subclass == 0 && protocol == 1 && alternate == 0;
}

// Registry prefilter avoids creating user clients for unrelated USB hardware.
bool registryNumber(io_service_t service, CFStringRef key, int expected) {
  auto value = IORegistryEntrySearchCFProperty(
      service, kIOServicePlane, key, kCFAllocatorDefault,
      kIORegistryIterateRecursively | kIORegistryIterateParents);
  int number = -1;
  const bool equal = value && CFGetTypeID(value) == CFNumberGetTypeID() &&
      CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberIntType,
                       &number) && number == expected;
  if (value) CFRelease(value);
  return equal;
}

IOReturn endpoints(Session* session) {
  auto interface = session->interface;
  UInt8 count = 0;
  auto status = (*interface)->GetNumEndpoints(interface, &count);
  if (status != 0) return status;
  if (count != 2) return kIOReturnUnsupported;
  for (UInt8 pipe = 1; pipe <= count; ++pipe) {
    UInt8 direction = 0, number = 0, type = 0, interval = 0;
    UInt16 packet = 0;
    status = (*interface)->GetPipeProperties(
        interface, pipe, &direction, &number, &type, &packet, &interval);
    if (status != 0) return status;
    if (number != 4 || type != kUSBBulk || packet != 64)
      return kIOReturnUnsupported;
    if (direction == kUSBIn && !session->input) session->input = pipe;
    else if (direction == kUSBOut && !session->output) session->output = pipe;
    else return kIOReturnUnsupported;
  }
  return session->input && session->output ? kIOReturnSuccess
                                           : kIOReturnUnsupported;
}
}  // namespace

USB_EXPORT uint32_t apexis_macos_usb_scan(uint64_t* ids, uint32_t capacity,
                                         uint32_t* count) {
  if (!ids || !count || capacity == 0) return kIOReturnBadArgument;
  *count = 0;
  // IOUSBHostFamily exposes compatibility user clients on modern macOS.
  // Deduplicate if both legacy and host matching yield the same service.
  std::set<uint64_t> seen;
  for (const char* klass : {kIOUSBInterfaceClassName, "IOUSBHostInterface"}) {
    auto matching = IOServiceMatching(klass);
    if (!matching) return kIOReturnNoMemory;
    io_iterator_t iterator = IO_OBJECT_NULL;
    auto status = IOServiceGetMatchingServices(kIOMasterPortDefault, matching,
                                               &iterator);
    if (status != 0) return status;
    while (auto service = IOIteratorNext(iterator)) {
      uint64_t id = 0;
      if (registryNumber(service, CFSTR("idVendor"), 0x3654) &&
          registryNumber(service, CFSTR("idProduct"), 0x4e55) &&
          registryNumber(service, CFSTR("bInterfaceNumber"), 3) &&
          IORegistryEntryGetRegistryEntryID(service, &id) == 0 &&
          seen.insert(id).second) {
        Interface interface = nullptr;
        const auto result = getInterface(service, &interface);
        if (result != 0) {
          IOObjectRelease(service);
          IOObjectRelease(iterator);
          return result;  // Surface sandbox/user-client errors, not empty scan.
        }
        const bool match = matches(interface);
        (*interface)->Release(interface);
        if (match) {
          if (*count == capacity) {
            IOObjectRelease(service);
            IOObjectRelease(iterator);
            return kIOReturnNoSpace;
          }
          ids[(*count)++] = id;
        }
      }
      IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
  }
  return 0;
}

USB_EXPORT uint32_t apexis_macos_usb_open(uint64_t id, void** output) {
  if (!output || !id) return kIOReturnBadArgument;
  *output = nullptr;
  auto matching = IORegistryEntryIDMatching(id);
  if (!matching) return kIOReturnNoMemory;
  auto service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
  if (!service) return kIOReturnNoDevice;
  auto session = new (std::nothrow) Session;
  if (!session) { IOObjectRelease(service); return kIOReturnNoMemory; }
  auto status = getInterface(service, &session->interface);
  IOObjectRelease(service);
  if (status == 0 && !matches(session->interface)) status = kIOReturnUnsupported;
  if (status == 0) {
    // Exclusive only to interface 03. Never USBInterfaceOpenSeize.
    status = (*session->interface)->USBInterfaceOpen(session->interface);
    session->opened = status == 0;
  }
  if (status == 0) status = endpoints(session);
  if (status == 0) {
    session->sessionAttempted = true;
    status = sessionControl(session->interface, false);
  }
  if (status == 0) status = sessionControl(session->interface, true);
  if (status != 0) { destroy(session); return status; }
  *output = session;
  return 0;
}

USB_EXPORT uint32_t apexis_macos_usb_read(void* handle, uint8_t* buffer,
                                         uint32_t capacity, uint32_t* count) {
  if (!handle || !buffer || !count || capacity != 64) return kIOReturnBadArgument;
  auto session = static_cast<Session*>(handle);
  *count = 0;
  if (session->stopped.load()) return kStopped;
  UInt32 size = capacity;
  // One packet: no waiting to aggregate multiple packets into a full buffer.
  // The deadline bounds idle shutdown; available data returns immediately.
  auto status = (*session->interface)->ReadPipeTO(
      session->interface, session->input, buffer, &size,
      kReadDeadlineMs, kReadDeadlineMs);
  if (session->stopped.load()) return kStopped;
  if (status == kIOUSBTransactionTimeout || status == kIOReturnTimeout) return 0;
  if (status != 0) return status;
  if (size > capacity) return kIOReturnOverrun;
  *count = size;
  return 0;
}

USB_EXPORT uint32_t apexis_macos_usb_write(void* handle, const uint8_t* buffer,
                                          uint32_t size) {
  if (!handle || !buffer || !size || size > 244) return kIOReturnBadArgument;
  auto session = static_cast<Session*>(handle);
  if (session->stopped.load()) return kStopped;
  // WritePipeTO reports status, not transferred length. Any error is fatal:
  // a prefix might already have reached the target, so never replay a write.
  return (*session->interface)->WritePipeTO(
      session->interface, session->output, const_cast<uint8_t*>(buffer), size,
      kWriteDeadlineMs, kWriteDeadlineMs);
}

USB_EXPORT void apexis_macos_usb_stop(void* handle) {
  if (handle) static_cast<Session*>(handle)->stopped.store(true);
}

USB_EXPORT void apexis_macos_usb_close(void* handle) {
  destroy(static_cast<Session*>(handle));
}
