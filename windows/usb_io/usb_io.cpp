// Windows-only adapter for the cross-platform GT1 vendor USB wire protocol.
// All Win32 error codes are captured here, before crossing the Dart FFI boundary.
#include <windows.h>
#include <setupapi.h>
#include <winusb.h>
#include <algorithm>
#include <cwctype>
#include <new>
#include <string>
#include <vector>

#define API extern "C" __declspec(dllexport)
static const GUID kGuid = {0xf7414ee8, 0xaf2e, 0x489c,
                          {0xa4, 0xf9, 0x16, 0x59, 0x7d, 0xb7, 0x48, 0x37}};
struct Session {
  HANDLE file = INVALID_HANDLE_VALUE;
  WINUSB_INTERFACE_HANDLE usb = nullptr;
};

static bool hardware_id(const wchar_t* value) {
  std::wstring id(value);
  std::transform(id.begin(), id.end(), id.begin(),
                 [](wchar_t ch) { return static_cast<wchar_t>(towupper(ch)); });
  const std::wstring base = L"USB\\VID_3654&PID_4E55";
  if (id.compare(0, base.size(), base) != 0) return false;
  const auto suffix = id.substr(base.size());
  if (suffix == L"&MI_03") return true;
  return suffix.size() == 15 && suffix.compare(0, 5, L"&REV_") == 0 &&
         std::all_of(suffix.begin() + 5, suffix.begin() + 9,
                     [](wchar_t ch) { return iswxdigit(ch) != 0; }) &&
         suffix.substr(9) == L"&MI_03";
}

static DWORD paths(std::vector<std::wstring>& result) {
  HDEVINFO devices = SetupDiGetClassDevsW(&kGuid, nullptr, nullptr,
                                        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
  if (devices == INVALID_HANDLE_VALUE) return GetLastError();
  DWORD error = ERROR_SUCCESS;
  for (DWORD i = 0;; ++i) {
    SP_DEVICE_INTERFACE_DATA iface{};
    iface.cbSize = sizeof(iface);
    if (!SetupDiEnumDeviceInterfaces(devices, nullptr, &kGuid, i, &iface)) {
      error = GetLastError();
      if (error == ERROR_NO_MORE_ITEMS) error = ERROR_SUCCESS;
      break;
    }
    DWORD required = 0;
    SetupDiGetDeviceInterfaceDetailW(devices, &iface, nullptr, 0, &required, nullptr);
    error = GetLastError();
    if (error != ERROR_INSUFFICIENT_BUFFER || required < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) break;
    std::vector<BYTE> memory(required);
    auto detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(memory.data());
    detail->cbSize = sizeof(*detail);
    SP_DEVINFO_DATA info{};
    info.cbSize = sizeof(info);
    if (!SetupDiGetDeviceInterfaceDetailW(devices, &iface, detail, required, nullptr, &info)) {
      error = GetLastError(); break;
    }
    wchar_t id[512]{};
    if (!SetupDiGetDeviceRegistryPropertyW(devices, &info, SPDRP_HARDWAREID, nullptr,
          reinterpret_cast<BYTE*>(id), sizeof(id) - sizeof(wchar_t), nullptr)) {
      error = GetLastError(); break;
    }
    if (hardware_id(id)) result.emplace_back(detail->DevicePath);
    error = ERROR_SUCCESS;
  }
  SetupDiDestroyDeviceInfoList(devices);
  return error;
}

API DWORD apexis_usb_scan(wchar_t* buffer, DWORD capacity, DWORD* used) {
  if (!used || (!buffer && capacity)) return ERROR_INVALID_PARAMETER;
  std::vector<std::wstring> found;
  const DWORD error = paths(found);
  if (error) return error;
  size_t length = 1;
  for (const auto& path : found) length += path.size() + 1;
  *used = static_cast<DWORD>(length);
  if (capacity < length) return ERROR_INSUFFICIENT_BUFFER;
  wchar_t* at = buffer;
  for (const auto& path : found) {
    std::copy(path.begin(), path.end(), at);
    at += path.size(); *at++ = 0;
  }
  *at = 0;
  return ERROR_SUCCESS;
}

// Never release OVERLAPPED/buffer/handle until cancellation has completed.
static DWORD complete(Session* s, OVERLAPPED* ov, BOOL started, HANDLE stop,
                      DWORD timeout, ULONG* count) {
  if (!started) {
    const DWORD error = GetLastError();
    if (error != ERROR_IO_PENDING) return error;
    HANDLE events[2] = {stop, ov->hEvent};
    const DWORD wait = stop ? WaitForMultipleObjects(2, events, FALSE, timeout)
                            : WaitForSingleObject(ov->hEvent, timeout);
    const DWORD expected = stop ? WAIT_OBJECT_0 + 1 : WAIT_OBJECT_0;
    if (wait != expected) {
      const DWORD failure = wait == WAIT_TIMEOUT ? ERROR_TIMEOUT
          : (stop && wait == WAIT_OBJECT_0 ? ERROR_OPERATION_ABORTED : GetLastError());
      CancelIoEx(s->file, ov);
      WinUsb_GetOverlappedResult(s->usb, ov, count, TRUE);
      return failure;
    }
  }
  if (!WinUsb_GetOverlappedResult(s->usb, ov, count, FALSE)) return GetLastError();
  return ERROR_SUCCESS;
}

static DWORD session_control(Session* s, USHORT active) {
  OVERLAPPED ov{};
  ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!ov.hEvent) return GetLastError();
  WINUSB_SETUP_PACKET setup{0x41, 0x30, active, 3, 0};
  ULONG count = 0;
  const BOOL started = WinUsb_ControlTransfer(s->usb, setup, nullptr, 0, nullptr, &ov);
  const DWORD result = complete(s, &ov, started, nullptr, 500, &count);
  CloseHandle(ov.hEvent);
  return result;
}

static void release(Session* s) {
  if (s->usb) WinUsb_Free(s->usb);
  if (s->file != INVALID_HANDLE_VALUE) CloseHandle(s->file);
  delete s;
}

API DWORD apexis_usb_open(const wchar_t* path, Session** output) {
  if (!path || !output) return ERROR_INVALID_PARAMETER;
  *output = nullptr;
  std::vector<std::wstring> found;
  DWORD error = paths(found);
  if (error) return error;
  if (std::find(found.begin(), found.end(), path) == found.end()) return ERROR_DEVICE_NOT_CONNECTED;
  auto s = new (std::nothrow) Session;
  if (!s) return ERROR_NOT_ENOUGH_MEMORY;
  // Exclusive access to THIS interface only, never the audio/composite parent.
  s->file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                        OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
  if (s->file == INVALID_HANDLE_VALUE) { error = GetLastError(); release(s); return error; }
  if (!WinUsb_Initialize(s->file, &s->usb)) { error = GetLastError(); release(s); return error; }
  USB_DEVICE_DESCRIPTOR device{};
  ULONG length = 0;
  USB_INTERFACE_DESCRIPTOR iface{};
  if (!WinUsb_GetDescriptor(s->usb, USB_DEVICE_DESCRIPTOR_TYPE, 0, 0,
                           reinterpret_cast<PUCHAR>(&device), sizeof(device), &length) ||
      !WinUsb_QueryInterfaceSettings(s->usb, 0, &iface)) {
    error = GetLastError(); release(s); return error;
  }
  if (length != sizeof(device) || device.idVendor != 0x3654 || device.idProduct != 0x4e55 ||
      iface.bInterfaceNumber != 3 || iface.bInterfaceClass != 0xff ||
      iface.bInterfaceSubClass != 0 || iface.bInterfaceProtocol != 1 || iface.bNumEndpoints != 2) {
    release(s); return ERROR_INVALID_DATA;
  }
  bool input = false, output_pipe = false;
  for (UCHAR i = 0; i < 2; ++i) {
    WINUSB_PIPE_INFORMATION pipe{};
    if (!WinUsb_QueryPipe(s->usb, 0, i, &pipe)) { error = GetLastError(); release(s); return error; }
    if (pipe.PipeType != UsbdPipeTypeBulk || pipe.MaximumPacketSize != 64) {
      release(s); return ERROR_INVALID_DATA;
    }
    input |= pipe.PipeId == 0x84;
    output_pipe |= pipe.PipeId == 0x04;
  }
  if (!input || !output_pipe) { release(s); return ERROR_INVALID_DATA; }
  ULONG timeout = 250;
  if (!WinUsb_SetPipePolicy(s->usb, 0x04, PIPE_TRANSFER_TIMEOUT, sizeof(timeout), &timeout)) {
    error = GetLastError(); release(s); return error;
  }
  // Explicit session fence replaces DTR; host drains old IN packets before commands.
  error = session_control(s, 1);
  if (error) { release(s); return error; }
  *output = s;
  return ERROR_SUCCESS;
}

API DWORD apexis_usb_read(Session* s, BYTE* buffer, ULONG size, ULONG* count, HANDLE stop) {
  if (!s || !buffer || size != 64 || !count || !stop) return ERROR_INVALID_PARAMETER;
  *count = 0;
  if (WaitForSingleObject(stop, 0) == WAIT_OBJECT_0) return ERROR_OPERATION_ABORTED;
  OVERLAPPED ov{};
  ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!ov.hEvent) return GetLastError();
  const BOOL started = WinUsb_ReadPipe(s->usb, 0x84, buffer, size, nullptr, &ov);
  const DWORD result = complete(s, &ov, started, stop, INFINITE, count);
  CloseHandle(ov.hEvent);
  return result;
}

API DWORD apexis_usb_write(Session* s, BYTE* buffer, ULONG size) {
  if (!s || !buffer || !size || size > 244) return ERROR_INVALID_PARAMETER;
  OVERLAPPED ov{};
  ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!ov.hEvent) return GetLastError();
  ULONG count = 0;
  const BOOL started = WinUsb_WritePipe(s->usb, 0x04, buffer, size, nullptr, &ov);
  DWORD result = complete(s, &ov, started, nullptr, 500, &count);
  CloseHandle(ov.hEvent);
  // A partial write may have executed: NEVER replay a non-idempotent command.
  if (!result && count != size) result = ERROR_WRITE_FAULT;
  return result;
}

// Owner must have joined the RX isolate and completed all writes first.
API void apexis_usb_close(Session* s) {
  if (!s) return;
  (void)session_control(s, 0);
  release(s);
}
