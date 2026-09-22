// Exercise the actual adapter's overlapped completion/cancellation with real
// Windows named pipes. Only the three WinUSB I/O entry points are substituted;
// this does NOT claim to test USB enumeration or the physical GT1 controller.
#include <windows.h>
#include <winusb.h>
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <thread>

static bool partial_write = false;
static bool fail_write = false;
static std::atomic<bool> read_submitted{false};
static BOOL __stdcall test_read(WINUSB_INTERFACE_HANDLE h, UCHAR pipe, PUCHAR b,
                               ULONG size, PULONG count, LPOVERLAPPED ov) {
  if (pipe != 0x84) std::abort();
  const BOOL result = ReadFile(h, b, size, count, ov);
  const DWORD error = GetLastError();
  read_submitted.store(true);
  SetLastError(error);
  return result;
}
static BOOL __stdcall test_write(WINUSB_INTERFACE_HANDLE h, UCHAR pipe, PUCHAR b,
                                ULONG size, PULONG count, LPOVERLAPPED ov) {
  if (pipe != 0x04) std::abort();
  if (fail_write) { SetLastError(ERROR_DEVICE_NOT_CONNECTED); return FALSE; }
  return WriteFile(h, b, partial_write ? size - 1 : size, count, ov);
}
static BOOL __stdcall test_result(WINUSB_INTERFACE_HANDLE h, LPOVERLAPPED ov,
                                 LPDWORD count, BOOL wait) {
  return GetOverlappedResult(h, ov, count, wait);
}
#define WinUsb_ReadPipe test_read
#define WinUsb_WritePipe test_write
#define WinUsb_GetOverlappedResult test_result
#include "usb_io.cpp"

#define CHECK(x) do { if (!(x)) { std::cerr << "FAIL line " << __LINE__ << ": " << #x << '\n'; std::abort(); } } while (0)

struct Pipe {
  HANDLE server;
  HANDLE stop;
  Session session;
  Pipe() {
    static unsigned sequence = 0;
    const auto name = L"\\\\.\\pipe\\apexis-usb-test-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(++sequence);
    server = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 4096, 4096, 0, nullptr);
    CHECK(server != INVALID_HANDLE_VALUE);
    session.file = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                               OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    CHECK(session.file != INVALID_HANDLE_VALUE);
    session.usb = session.file;
    stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    CHECK(stop != nullptr);
  }
  ~Pipe() {
    CloseHandle(session.file);
    CloseHandle(stop);
    if (server != INVALID_HANDLE_VALUE) CloseHandle(server);
  }
};

int main() {
  CHECK(hardware_id(L"USB\\VID_3654&PID_4E55&MI_03"));
  CHECK(hardware_id(L"usb\\vid_3654&pid_4e55&rev_0200&mi_03"));
  CHECK(!hardware_id(L"USB\\VID_3654&PID_4B55&MI_03"));
  CHECK(!hardware_id(L"USB\\VID_3654&PID_79B8&MI_03"));
  CHECK(!hardware_id(L"USB\\VID_3654&PID_4E55&MI_00"));
  CHECK(!hardware_id(L"USB\\VID_3654&PID_4E55&MI_030"));
  CHECK(!hardware_id(L"USB\\VID_3654&PID_4E55&REV_ZZZZ&MI_03"));
  for (unsigned cycle = 0; cycle < 30; ++cycle) {
    Pipe p;
    BYTE buffer[64]{}; ULONG count = 0; DWORD result = 0;
    std::thread reading([&] { result = apexis_usb_read(&p.session, buffer, 64, &count, p.stop); });
    const BYTE input[] = {0xf0, 1, 0xf7}; DWORD sent = 0;
    CHECK(WriteFile(p.server, input, sizeof(input), &sent, nullptr));
    reading.join();
    CHECK(result == ERROR_SUCCESS && count == 3 && buffer[0] == 0xf0 && buffer[2] == 0xf7);
    read_submitted.store(false);
    std::thread idle([&] { result = apexis_usb_read(&p.session, buffer, 64, &count, p.stop); });
    const auto deadline = GetTickCount64() + 1000;
    while (!read_submitted.load() && GetTickCount64() < deadline) std::this_thread::yield();
    CHECK(read_submitted.load()); // Ensure cancellation reaches real pending I/O.
    SetEvent(p.stop);
    idle.join();
    CHECK(result == ERROR_OPERATION_ABORTED);
  }
  {
    Pipe p;
    BYTE data[] = {0xf0, 2, 0xf7};
    CHECK(apexis_usb_write(&p.session, data, 3) == ERROR_SUCCESS);
    partial_write = true;
    CHECK(apexis_usb_write(&p.session, data, 3) == ERROR_WRITE_FAULT);
    partial_write = false; fail_write = true;
    CHECK(apexis_usb_write(&p.session, data, 3) == ERROR_DEVICE_NOT_CONNECTED);
    fail_write = false;
    CHECK(apexis_usb_write(&p.session, data, 0) == ERROR_INVALID_PARAMETER);
    CHECK(apexis_usb_write(&p.session, data, 245) == ERROR_INVALID_PARAMETER);
  }
  {
    Pipe p;
    BYTE buffer[64]{}; ULONG count = 0; DWORD result = 0;
    std::thread reading([&] { result = apexis_usb_read(&p.session, buffer, 64, &count, p.stop); });
    CloseHandle(p.server); p.server = INVALID_HANDLE_VALUE;
    reading.join();
    CHECK(result == ERROR_BROKEN_PIPE || result == ERROR_PIPE_NOT_CONNECTED);
  }
  std::cout << "PASS WinUSB adapter: whitelist, pending/buffered RX, cancellation x30, partial/error TX, peer removal\n";
}
