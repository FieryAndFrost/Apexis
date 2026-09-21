#define WIN32_LEAN_AND_MEAN
#include <windows.h>

// Capture last-error BEFORE crossing the Dart FFI boundary. In particular,
// ERROR_IO_PENDING is normal, not a disconnected device or failed request.
#define CDC_API extern "C" __declspec(dllexport) DWORD
CDC_API apexis_cdc_read(HANDLE handle, BYTE* data, DWORD size, OVERLAPPED* op) {
  return ReadFile(handle, data, size, nullptr, op) ? ERROR_SUCCESS : GetLastError();
}
CDC_API apexis_cdc_write(HANDLE handle, const BYTE* data, DWORD size, OVERLAPPED* op) {
  return WriteFile(handle, data, size, nullptr, op) ? ERROR_SUCCESS : GetLastError();
}
CDC_API apexis_cdc_result(HANDLE handle, OVERLAPPED* op, DWORD* count, BOOL wait) {
  return GetOverlappedResult(handle, op, count, wait) ? ERROR_SUCCESS : GetLastError();
}
