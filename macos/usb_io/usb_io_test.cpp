// Runs on macOS without GT1: calls the production adapter with a fake IOKit
// interface vtable. This is NOT a test of real enumeration/USB transfers.
#include "../Runner/usb_io.cpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>

#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); std::abort(); } } while (0)

static UInt16 vid = 0x3654, pid = 0x4e55, packetSize = 64;
static UInt8 interfaceNumber = 3, endpointCount = 2;
static IOReturn readStatus = 0, writeStatus = 0;
static int reads = 0, writes = 0, controls = 0, closes = 0, releases = 0;
static bool duplicateInput = false;

int main() {
  IOUSBInterfaceInterface300 table{};
  table.GetDeviceVendor = [](void*, UInt16* v) -> IOReturn { *v = vid; return 0; };
  table.GetDeviceProduct = [](void*, UInt16* v) -> IOReturn { *v = pid; return 0; };
  table.GetInterfaceNumber = [](void*, UInt8* v) -> IOReturn { *v = interfaceNumber; return 0; };
  table.GetInterfaceClass = [](void*, UInt8* v) -> IOReturn { *v = 0xff; return 0; };
  table.GetInterfaceSubClass = [](void*, UInt8* v) -> IOReturn { *v = 0; return 0; };
  table.GetInterfaceProtocol = [](void*, UInt8* v) -> IOReturn { *v = 1; return 0; };
  table.GetAlternateSetting = [](void*, UInt8* v) -> IOReturn { *v = 0; return 0; };
  table.GetNumEndpoints = [](void*, UInt8* v) -> IOReturn { *v = endpointCount; return 0; };
  table.GetPipeProperties = [](void*, UInt8 pipe, UInt8* direction, UInt8* number,
                              UInt8* type, UInt16* packet, UInt8* interval) -> IOReturn {
    *direction = (pipe == 1 || duplicateInput) ? kUSBIn : kUSBOut;
    *number = 4; *type = kUSBBulk; *packet = packetSize; *interval = 0;
    return 0;
  };
  table.ControlRequestTO = [](void*, UInt8 pipe, IOUSBDevRequestTO* request) -> IOReturn {
    CHECK(pipe == 0 && request->bmRequestType == 0x41 && request->bRequest == 0x30);
    CHECK(request->wIndex == 3 && request->wLength == 0 && request->wValue <= 1);
    CHECK(request->noDataTimeout == 500 && request->completionTimeout == 500);
    ++controls; return 0;
  };
  table.ReadPipeTO = [](void*, UInt8 pipe, void* buffer, UInt32* size,
                        UInt32 idle, UInt32 deadline) -> IOReturn {
    CHECK(pipe == 1 && *size == 64 && idle == 100 && deadline == 100);
    ++reads;
    if (readStatus) return readStatus;
    const uint8_t frame[] = {0xf0, 1, 0xf7};
    std::memcpy(buffer, frame, sizeof(frame)); *size = sizeof(frame); return 0;
  };
  table.WritePipeTO = [](void*, UInt8 pipe, void*, UInt32 size,
                         UInt32 idle, UInt32 deadline) -> IOReturn {
    CHECK(pipe == 2 && size <= 244 && idle == 500 && deadline == 500);
    ++writes; return writeStatus;
  };
  table.USBInterfaceClose = [](void*) -> IOReturn { ++closes; return 0; };
  table.Release = [](void*) -> ULONG { ++releases; return 0; };
  auto pointer = &table;
  CHECK(matches(&pointer));
  vid = 0x1234; CHECK(!matches(&pointer)); vid = 0x3654;
  pid = 0x4e54; CHECK(!matches(&pointer)); pid = 0x4e55;
  interfaceNumber = 0; CHECK(!matches(&pointer)); interfaceNumber = 3;
  Session session;
  session.interface = &pointer;
  CHECK(endpoints(&session) == 0 && session.input == 1 && session.output == 2);
  session.input = session.output = 0;
  duplicateInput = true; CHECK(endpoints(&session) != 0); duplicateInput = false;
  session.input = session.output = 0;
  packetSize = 512; CHECK(endpoints(&session) != 0); packetSize = 64;
  endpointCount = 3; CHECK(endpoints(&session) != 0); endpointCount = 2;
  CHECK(endpoints(&session) == 0);
  CHECK(sessionControl(&pointer, false) == 0 && sessionControl(&pointer, true) == 0);
  uint8_t buffer[244]{}; uint32_t count = 0;
  CHECK(apexis_macos_usb_read(&session, buffer, 64, &count) == 0);
  CHECK(count == 3 && buffer[0] == 0xf0 && buffer[2] == 0xf7);
  readStatus = kIOUSBTransactionTimeout;
  CHECK(apexis_macos_usb_read(&session, buffer, 64, &count) == 0 && count == 0);
  readStatus = kIOReturnNoDevice;
  CHECK(apexis_macos_usb_read(&session, buffer, 64, &count) == static_cast<uint32_t>(kIOReturnNoDevice));
  CHECK(apexis_macos_usb_write(&session, buffer, 244) == 0 && writes == 1);
  writeStatus = kIOReturnTimeout;
  CHECK(apexis_macos_usb_write(&session, buffer, 3) == static_cast<uint32_t>(kIOReturnTimeout));
  CHECK(writes == 2); // No replay after potentially partial transmission.
  CHECK(apexis_macos_usb_write(&session, buffer, 245) != 0 && writes == 2);
  CHECK(apexis_macos_usb_write(&session, buffer, 0) != 0 && writes == 2);
  apexis_macos_usb_stop(&session);
  CHECK(apexis_macos_usb_read(&session, buffer, 64, &count) == kStopped && reads == 3);
  CHECK(apexis_macos_usb_write(&session, buffer, 3) == kStopped && writes == 2);
  auto owned = new Session;
  owned->interface = &pointer; owned->opened = true; owned->sessionAttempted = true;
  apexis_macos_usb_close(owned);
  CHECK(controls == 3 && closes == 1 && releases == 1);
  apexis_macos_usb_close(nullptr);
  std::puts("macOS USB contract tests passed (mock IOKit, no hardware)");
}
