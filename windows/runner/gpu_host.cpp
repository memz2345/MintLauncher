#include "gpu_host.h"

#include <dxgi1_6.h>
#include <shlwapi.h>

#include <flutter/encodable_value.h>

#include <cstdio>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace mint {

namespace {

// Windows「显示 → 图形」每应用显卡偏好的落盘位置（HMCL 的「高性能显卡」、
// PCL 的 SetGpuPreference 都写这里）。值名 = 被启动 exe 的绝对路径，值数据
// = `GpuPreference=N;`；N=0 让系统决定 / 1 节能 / 2 高性能。
// 指定到某一块具体的卡：`SpecificAdapter=<VEN&DEV&SUBSYS>;GpuPreference=1073741824;`
constexpr wchar_t kPrefsKey[] = L"Software\\Microsoft\\DirectX\\UserGpuPreferences";

std::string WideToUtf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int needed = ::WideCharToMultiByte(
      CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0,
      nullptr, nullptr);
  if (needed <= 0) return {};
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                        out.data(), needed, nullptr, nullptr);
  return out;
}

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return {};
  const int needed = ::MultiByteToWideChar(
      CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0);
  if (needed <= 0) return {};
  std::wstring out(static_cast<size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                        out.data(), needed);
  return out;
}

struct Adapter {
  std::string name;
  // DXGI 枚举顺序即系统偏好顺序（第一个 = 默认使用的卡）。
  bool preferred = false;
  // `1002&73FF&24201458`：VEN&DEV&SUBSYS，和 UserGpuPreferences 里
  // SpecificAdapter 的写法逐字符一致（大写十六进制，无 0x 前缀）。
  std::string specific;
  std::string luid;
  std::string vendor;
  uint64_t dedicated_mb = 0;
  bool is_software = false;
};

std::vector<Adapter> EnumerateAdapters() {
  std::vector<Adapter> adapters;
  IDXGIFactory1* factory = nullptr;
  if (FAILED(::CreateDXGIFactory1(__uuidof(IDXGIFactory1),
                                  reinterpret_cast<void**>(&factory))) ||
      factory == nullptr) {
    return adapters;
  }
  char vendor[32] = "other";
  for (UINT index = 0;; ++index) {
    IDXGIAdapter1* adapter = nullptr;
    if (factory->EnumAdapters1(index, &adapter) == DXGI_ERROR_NOT_FOUND) break;
    DXGI_ADAPTER_DESC1 desc = {};
    if (SUCCEEDED(adapter->GetDesc1(&desc))) {
      Adapter out;
      out.name = WideToUtf8(desc.Description);
      out.is_software = (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
      out.preferred = !out.is_software && adapters.empty();
      char id[40];
      std::snprintf(id, sizeof id, "%04X&%04X&%08X", desc.VendorId,
                    desc.DeviceId, desc.SubSysId);
      out.specific = id;
      char luid[40];
      std::snprintf(luid, sizeof luid, "%08X-%08X", desc.AdapterLuid.HighPart,
                    desc.AdapterLuid.LowPart);
      out.luid = luid;
      out.dedicated_mb = desc.DedicatedVideoMemory / (1024 * 1024);
      switch (desc.VendorId) {
        case 0x1002:
          std::snprintf(vendor, sizeof vendor, "amd");
          break;
        case 0x10DE:
          std::snprintf(vendor, sizeof vendor, "nvidia");
          break;
        case 0x8086:
          std::snprintf(vendor, sizeof vendor, "intel");
          break;
        case 0x1414:
          std::snprintf(vendor, sizeof vendor, "microsoft");
          break;
        default:
          std::snprintf(vendor, sizeof vendor, "other");
          break;
      }
      out.vendor = vendor;
      // 核显和「Microsoft 基本显示渲染器」都可能是 0 显存；只保留真正的
      // 硬件适配器（软件适配器单列，Dart 侧不显示）。
      if (!out.is_software) adapters.push_back(out);
    }
    adapter->Release();
  }
  factory->Release();
  return adapters;
}

flutter::EncodableValue AdapterToMap(const Adapter& adapter) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("name")] = flutter::EncodableValue(adapter.name);
  map[flutter::EncodableValue("specific")] =
      flutter::EncodableValue(adapter.specific);
  map[flutter::EncodableValue("luid")] = flutter::EncodableValue(adapter.luid);
  map[flutter::EncodableValue("vendor")] = flutter::EncodableValue(adapter.vendor);
  map[flutter::EncodableValue("preferred")] =
      flutter::EncodableValue(adapter.preferred);
  map[flutter::EncodableValue("dedicatedMemoryMb")] =
      flutter::EncodableValue(static_cast<int64_t>(adapter.dedicated_mb));
  return flutter::EncodableValue(map);
}

std::optional<std::string> ReadPreference(const std::wstring& exe) {
  DWORD type = 0;
  DWORD size = 0;
  LSTATUS status =
      ::SHGetValueW(HKEY_CURRENT_USER, kPrefsKey, exe.c_str(), &type, nullptr,
                    &size);
  if (status == ERROR_FILE_NOT_FOUND) return std::nullopt;
  if (status != ERROR_SUCCESS || size == 0) return std::nullopt;
  std::vector<wchar_t> buffer(size / sizeof(wchar_t) + 1, L'\0');
  status = ::SHGetValueW(HKEY_CURRENT_USER, kPrefsKey, exe.c_str(), &type,
                         buffer.data(), &size);
  if (status != ERROR_SUCCESS) return std::nullopt;
  return WideToUtf8(std::wstring(buffer.data()));
}

bool WritePreference(const std::wstring& exe, const std::wstring& data,
                     LSTATUS* out_status) {
  if (data.empty()) {
    *out_status = ::SHDeleteValueW(HKEY_CURRENT_USER, kPrefsKey, exe.c_str());
    return *out_status == ERROR_SUCCESS || *out_status == ERROR_FILE_NOT_FOUND;
  }
  *out_status = ::SHSetValueW(HKEY_CURRENT_USER, kPrefsKey, exe.c_str(), REG_SZ,
                              data.c_str(),
                              static_cast<DWORD>((data.size() + 1) *
                                                 sizeof(wchar_t)));
  return *out_status == ERROR_SUCCESS;
}

// ─────────────────────── 消息参数解析 ───────────────────────

const flutter::EncodableValue* ArgOrNull(
    const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr : &it->second;
}

std::string ArgString(const flutter::EncodableMap& args, const char* key) {
  const auto* v = ArgOrNull(args, key);
  return v != nullptr && std::holds_alternative<std::string>(*v)
      ? std::get<std::string>(*v)
      : std::string();
}

}  // namespace

void HandleGpuMethod(
    HWND hwnd,
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  (void)hwnd;
  const std::string& method = call.method_name();

  if (method == "listAdapters") {
    flutter::EncodableList list;
    for (const auto& adapter : EnumerateAdapters()) {
      list.push_back(AdapterToMap(adapter));
    }
    result->Success(flutter::EncodableValue(list));
    return;
  }

  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    result->Error("gpu", "arguments must be a map {exe, data}");
    return;
  }
  const std::string exe_value = ArgString(*args, "exe");
  if (exe_value.empty()) {
    result->Error("gpu", "missing exe argument");
    return;
  }
  const std::wstring exe_path = Utf8ToWide(exe_value);

  if (method == "getPreference") {
    const auto current = ReadPreference(exe_path);
    result->Success(current.has_value()
                        ? flutter::EncodableValue(*current)
                        : flutter::EncodableValue());
    return;
  }

  if (method == "setPreference") {
    // data 缺省 / 空串 = 删除这个 exe 的条目（回到「让 Windows 管理」）。
    const std::wstring data = Utf8ToWide(ArgString(*args, "data"));
    LSTATUS status = ERROR_SUCCESS;
    if (!WritePreference(exe_path, data, &status)) {
      result->Error("gpu", "failed to write GPU preference, LSTATUS=" + std::to_string(status));
      return;
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  result->NotImplemented();
}

}  // namespace mint
