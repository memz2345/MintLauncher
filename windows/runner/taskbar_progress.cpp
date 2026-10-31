#include "taskbar_progress.h"

#include <shobjidl.h>

#include <algorithm>
#include <string>

namespace mint {

namespace {

// One COM object per process is enough. Released at process exit (the
// runner keeps it for the whole lifetime, same as stock Win32 apps).
ITaskbarList3* g_taskbar = nullptr;

ITaskbarList3* Taskbar() {
  if (g_taskbar != nullptr) {
    return g_taskbar;
  }
  // The Flutter runner may not have initialized COM yet. If the apartment
  // mode differs the call fails and taskbar progress stays unavailable;
  // everything else keeps working.
  CoInitializeEx(nullptr,
                 COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  ITaskbarList3* taskbar = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&taskbar));
  if (FAILED(hr)) {
    return nullptr;
  }
  // The taskbar may register later than the window; HrInit re-syncs.
  taskbar->HrInit();
  g_taskbar = taskbar;
  return g_taskbar;
}

void ClearProgress(HWND hwnd) {
  if (auto* taskbar = Taskbar()) {
    taskbar->SetProgressState(hwnd, TBPF_NOPROGRESS);
  }
}

void HandleSetProgress(HWND hwnd, double value) {
  auto* taskbar = Taskbar();
  if (taskbar == nullptr) return;
  value = std::clamp(value, 0.0, 1.0);
  taskbar->SetProgressState(hwnd, TBPF_NORMAL);
  // SetProgressValue takes integer completed/total; 1e4 steps are plenty
  // for the taskbar overlay rendering.
  taskbar->SetProgressValue(hwnd,
                            static_cast<ULONGLONG>(value * 10000.0), 10000);
}

void HandleSetState(HWND hwnd, const std::string& state) {
  if (state == "none") {
    ClearProgress(hwnd);
    return;
  }
  auto* taskbar = Taskbar();
  if (taskbar == nullptr) return;
  if (state == "normal") {
    taskbar->SetProgressState(hwnd, TBPF_NORMAL);
  } else if (state == "indeterminate") {
    taskbar->SetProgressState(hwnd, TBPF_INDETERMINATE);
  } else if (state == "paused") {
    taskbar->SetProgressState(hwnd, TBPF_PAUSED);
  } else if (state == "error") {
    taskbar->SetProgressState(hwnd, TBPF_ERROR);
  }
}

const flutter::EncodableValue* FindArg(
    const flutter::EncodableMap* args, const char* key) {
  if (args == nullptr) return nullptr;
  auto it = args->find(flutter::EncodableValue(key));
  return it == args->end() ? nullptr : &it->second;
}

}  // namespace

void HandleTaskbarMethod(
    HWND window,
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  if (method == "setProgress") {
    if (const auto* value = FindArg(args, "value")) {
      if (const auto* d = std::get_if<double>(value)) {
        HandleSetProgress(window, *d);
      } else if (const auto* i = std::get_if<int32_t>(value)) {
        HandleSetProgress(window, static_cast<double>(*i));
      }
    }
    result->Success();
    return;
  }
  if (method == "setState") {
    if (const auto* value = FindArg(args, "state")) {
      if (const auto* state = std::get_if<std::string>(value)) {
        HandleSetState(window, *state);
      }
    }
    result->Success();
    return;
  }
  if (method == "clear") {
    ClearProgress(window);
    result->Success();
    return;
  }
  result->NotImplemented();
}

}  // namespace mint
