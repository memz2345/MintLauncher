#include "window_backdrop.h"

#include <dwmapi.h>

#include <string>
#include <unordered_map>
#include <variant>

namespace mint {

namespace {

// ---- SetWindowCompositionAttribute（Windows 10 Aero/Acrylic） ----

enum WindowCompositionAttribute {
  kAccentPolicyAttribute = 19,
};

enum AccentState {
  kAccentDisabled = 0,
  kAccentEnableGradient = 1,
  kAccentEnableTransparentGradient = 2,
  kAccentEnableBlurBehind = 3,
  kAccentEnableAcrylicBlurBehind = 4,
};

struct AccentPolicy {
  AccentState accent_state;
  DWORD accent_flags;
  DWORD gradient_color;
  DWORD animation_id;
};

struct WindowCompositionAttributeData {
  WindowCompositionAttribute attribute;
  PVOID data;
  SIZE_T data_size;
};

using SetWindowCompositionAttributeFn =
    BOOL(WINAPI*)(HWND, WindowCompositionAttributeData*);

// ---- 未公开/较新的 DWM 属性 ----

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_NCRENDERING_POLICY
#define DWMWA_NCRENDERING_POLICY 2
#endif
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif

constexpr DWORD kDwmMicaEffect = 1029;
constexpr int kDwmBackdropAuto = 0;
constexpr int kDwmBackdropNone = 1;
constexpr int kDwmBackdropMica = 2;
constexpr int kDwmBackdropAcrylic = 3;
constexpr int kDwmBackdropTabbed = 4;
// DwmSetWindowAttribute(DWMWA_CAPTION_COLOR)：0xFFFFFFFE 关掉 DWM 画
// caption，0xFFFFFFFF 恢复系统默认。
constexpr int kDwmColorNone = -2;  // DWMWA_COLOR_NONE
constexpr int kDwmColorDefault = -1;  // DWMWA_COLOR_DEFAULT
// DWMWA_NCRENDERING_POLICY：DWMNCRP_DISABLED 让 DWM 彻底不渲染非客户区
// （含三大金刚）。backdrop（Mica/Acrylic）是 DWM 在窗口背后的合成层，
// 与 NC 渲染独立 —— 禁掉 NC 后材质照常，而原生 caption 按钮不再透在
// 自绘按钮底下（「金刚重影」的根治方案）。恢复用 DWMNCRP_USEWINDOWSTYLE。
constexpr DWORD kDwmNcrpUseWindowStyle = 1;
constexpr DWORD kDwmNcrpDisabled = 2;

// 当前开着窗口材质的窗口。ReapplyWindowChrome 只对这些窗口补 caption
// 设置，避免给普通纯色窗口乱发 DWM 属性。
std::unordered_map<HWND, bool> g_backdrop_windows;

struct OsVersionInfo {
  ULONG os_version_info_size;
  ULONG major_version;
  ULONG minor_version;
  ULONG build_number;
  ULONG platform_id;
  WCHAR csd_version[128];
};

using RtlGetVersionFn = LONG(WINAPI*)(OsVersionInfo*);

DWORD WindowsBuild() {
  static DWORD cached = 0;
  if (cached != 0) return cached;
  HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  if (ntdll != nullptr) {
    auto rtl_get_version =
        reinterpret_cast<RtlGetVersionFn>(::GetProcAddress(ntdll, "RtlGetVersion"));
    if (rtl_get_version != nullptr) {
      OsVersionInfo info = {};
      info.os_version_info_size = sizeof(info);
      if (rtl_get_version(&info) == 0) {
        cached = info.build_number;
        return cached;
      }
    }
  }
  cached = 1;
  return cached;
}

SetWindowCompositionAttributeFn CompositionAttribute() {
  static auto fn = []() -> SetWindowCompositionAttributeFn {
    HMODULE user32 = ::GetModuleHandleW(L"user32.dll");
    if (user32 == nullptr) return nullptr;
    return reinterpret_cast<SetWindowCompositionAttributeFn>(
        ::GetProcAddress(user32, "SetWindowCompositionAttribute"));
  }();
  return fn;
}

void SetAccent(HWND window, AccentState state, DWORD color) {
  auto fn = CompositionAttribute();
  if (fn == nullptr) return;
  AccentPolicy policy = {state, 2, color, 0};
  WindowCompositionAttributeData data = {
      kAccentPolicyAttribute, &policy, sizeof(policy)};
  fn(window, &data);
}

void SetDarkMode(HWND window, bool dark) {
  BOOL value = dark ? TRUE : FALSE;
  ::DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE, &value,
                          sizeof(value));
  // Windows 10 1809–1903 用的是 19 号属性，20 号从 2004 才开始。
  if (WindowsBuild() < 18985) {
    ::DwmSetWindowAttribute(window, 19, &value, sizeof(value));
  }
}

void SetRoundedCorners(HWND window) {
  if (WindowsBuild() < 22000) return;
  int preference = 2;  // DWMWCP_ROUND
  ::DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE, &preference,
                          sizeof(preference));
}

// 用 -1 的 MARGINS 铺 Mica 时，DWM 会把「窗口 frame」也一并铺进客户区；
// 只要窗口还带 WS_SYSMENU，它就会在最顶上再画一条原生 caption（图标、
// 标题、三大金刚），盖住 Flutter 自己画的标题栏，材质也被刷成不透明。
// DWMWA_CAPTION_COLOR = COLOR_NONE 让 DWM 不再画这条 caption，但保留
// WS_SYSMENU（右键系统菜单、Alt+Space 仍然可用）。
void SetCaptionColor(HWND window, int color) {
  ::DwmSetWindowAttribute(window, DWMWA_CAPTION_COLOR, &color, sizeof(color));
  ::DwmSetWindowAttribute(window, DWMWA_BORDER_COLOR, &color, sizeof(color));
}

// 材质模式下禁用 DWM 的非客户区渲染：原生三大金刚 / caption 一并不画。
// 窗口动画依赖的 WS_CAPTION 保留在窗口样式上，动画照常播放。
void SetNcRendering(HWND window, bool disabled) {
  const DWORD policy = disabled ? kDwmNcrpDisabled : kDwmNcrpUseWindowStyle;
  ::DwmSetWindowAttribute(
      window, DWMWA_NCRENDERING_POLICY, &policy, sizeof(policy));
}

void ExtendGlass(HWND window) {
  // 顶部不要 -1：DwmExtendFrameIntoClientArea 一旦把上边框也铺进客户区，
  // DWM 会在客户区顶部画一条原生 caption（图标 + 标题 + 三大金刚），
  // 而且 DWMWA_CAPTION_COLOR=NONE 在 Win11 某些激活时序下会被忽略。
  // 左 / 右 / 下保持 -1，Mica/Acrylic 仍从这些边铺满窗口；顶部由 Flutter
  // 自绘标题栏的半透明底色接管。
  MARGINS margins = {-1, -1, 0, -1};
  ::DwmExtendFrameIntoClientArea(window, &margins);
  // 材质模式下客户区是透明的，DWM 画在 frame 上的东西会直接透出来。
  // 窗口保留 WS_CAPTION（DWM 动画需要），这里直接禁掉 DWM 的 NC 渲染：
  // 原生三大金刚 / caption 底色从根上不存在；再把 caption / 边框颜色压成
  // NONE 兜底。最大化 / 激活之后 DWM 可能重置，由 window_frame 的
  // WM_SIZE / WM_NCACTIVATE 补设（ReapplyWindowChrome）。
  SetNcRendering(window, true);
  SetCaptionColor(window, kDwmColorNone);
}

void ResetSystemBackdrop(HWND window) {
  const DWORD build = WindowsBuild();
  if (build >= 22000) {
    BOOL disabled = FALSE;
    ::DwmSetWindowAttribute(window, kDwmMicaEffect, &disabled,
                            sizeof(disabled));
  }
  if (build >= 22621) {
    int none = kDwmBackdropNone;
    ::DwmSetWindowAttribute(window, DWMWA_SYSTEMBACKDROP_TYPE, &none,
                            sizeof(none));
  }
  MARGINS margins = {0, 0, 0, 0};
  ::DwmExtendFrameIntoClientArea(window, &margins);
  // 回到纯色窗口：恢复 NC 渲染（DWMNCRP_DISABLED 只该在材质模式用），
  // caption 颜色回默认。
  SetNcRendering(window, false);
  SetCaptionColor(window, kDwmColorDefault);
}

// DWM 的 GradientColor 是 0xAABBGGRR。
DWORD AccentColor(int argb, DWORD alpha) {
  const BYTE a = static_cast<BYTE>(alpha);
  const BYTE r = static_cast<BYTE>((argb >> 16) & 0xFF);
  const BYTE g = static_cast<BYTE>((argb >> 8) & 0xFF);
  const BYTE b = static_cast<BYTE>(argb & 0xFF);
  return (static_cast<DWORD>(a) << 24) | (static_cast<DWORD>(b) << 16) |
         (static_cast<DWORD>(g) << 8) | static_cast<DWORD>(r);
}

const flutter::EncodableValue* FindArg(const flutter::EncodableMap* args,
                                      const char* key) {
  if (args == nullptr) return nullptr;
  auto it = args->find(flutter::EncodableValue(key));
  return it == args->end() ? nullptr : &it->second;
}

std::string StringArg(const flutter::EncodableMap* args, const char* key,
                      const std::string& fallback) {
  const auto* value = FindArg(args, key);
  if (value == nullptr) return fallback;
  if (const auto* text = std::get_if<std::string>(value)) return *text;
  return fallback;
}

bool BoolArg(const flutter::EncodableMap* args, const char* key, bool fallback) {
  const auto* value = FindArg(args, key);
  if (value == nullptr) return fallback;
  if (const auto* boolean = std::get_if<bool>(value)) return *boolean;
  return fallback;
}

int IntArg(const flutter::EncodableMap* args, const char* key, int fallback) {
  const auto* value = FindArg(args, key);
  if (value == nullptr) return fallback;
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  if (const auto* number64 = std::get_if<int64_t>(value)) {
    return static_cast<int>(*number64);
  }
  return fallback;
}

flutter::EncodableMap Capabilities() {
  const DWORD build = WindowsBuild();
  return flutter::EncodableMap{
      {flutter::EncodableValue("supported"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("build"), flutter::EncodableValue(static_cast<int>(build))},
      {flutter::EncodableValue("windows11"), flutter::EncodableValue(build >= 22000)},
      {flutter::EncodableValue("mica"), flutter::EncodableValue(build >= 22000)},
      // Win10 1809 起有 SetWindowCompositionAttribute 亚克力；
      // Win11 22000 起也有系统级 Mica 可用。
      {flutter::EncodableValue("acrylic"), flutter::EncodableValue(build >= 17763)},
      {flutter::EncodableValue("tabbed"), flutter::EncodableValue(build >= 22621)},
      {flutter::EncodableValue("aero"), flutter::EncodableValue(build >= 10240)},
  };
}

// 返回实际生效的模式（不支持的会降级）。
std::string ApplyBackdrop(HWND window, const std::string& mode, bool dark,
                          int tint) {
  const DWORD build = WindowsBuild();
  SetDarkMode(window, dark);
  SetRoundedCorners(window);

  if (mode == "off") {
    SetAccent(window, kAccentDisabled, 0);
    ResetSystemBackdrop(window);
    return "off";
  }

  // 先清掉上一种材质，避免 Mica 与 accent 叠在一起。
  SetAccent(window, kAccentDisabled, 0);

  if (mode == "mica" && build >= 22621) {
    ResetSystemBackdrop(window);
    ExtendGlass(window);
    int backdrop = kDwmBackdropMica;
    ::DwmSetWindowAttribute(window, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop,
                            sizeof(backdrop));
    return "mica";
  }

  if (mode == "mica" && build >= 22000) {
    ResetSystemBackdrop(window);
    ExtendGlass(window);
    BOOL enabled = TRUE;
    ::DwmSetWindowAttribute(window, kDwmMicaEffect, &enabled, sizeof(enabled));
    return "mica";
  }

  if (mode == "tabbed" && build >= 22621) {
    ResetSystemBackdrop(window);
    ExtendGlass(window);
    int backdrop = kDwmBackdropTabbed;
    ::DwmSetWindowAttribute(window, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop,
                            sizeof(backdrop));
    return "tabbed";
  }

  if (mode == "acrylic" && build >= 22621) {
    ResetSystemBackdrop(window);
    ExtendGlass(window);
    int backdrop = kDwmBackdropAcrylic;
    ::DwmSetWindowAttribute(window, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop,
                            sizeof(backdrop));
    return "acrylic";
  }

  // Windows 10（以及 Win11 22000 的 Acrylic/Tabbed 降级）：
  // 走 SetWindowCompositionAttribute。Dart 侧再叠一层主题底色，
  // 所以这里只给 0x40 的底，避免整窗发灰。
  ResetSystemBackdrop(window);
  ExtendGlass(window);
  const DWORD accent = AccentColor(tint, 0x40);
  if (mode == "aero") {
    SetAccent(window, kAccentEnableBlurBehind, accent);
    return "aero";
  }
  if (build >= 17763) {
    SetAccent(window, kAccentEnableAcrylicBlurBehind, accent);
    return "acrylic";
  }
  SetAccent(window, kAccentEnableBlurBehind, accent);
  return "aero";
}

}  // namespace

void ReapplyWindowChrome(HWND window) {
  if (window == nullptr) return;
  auto it = g_backdrop_windows.find(window);
  if (it == g_backdrop_windows.end() || !it->second) return;
  // 只补属性，不重复 DwmExtendFrame（那会触发一次合成闪烁）：
  // NC 渲染继续禁着 + caption 颜色压成 NONE（DWM 在最大化 / 激活后
  // 可能把两者重置回去）。
  SetNcRendering(window, true);
  SetCaptionColor(window, kDwmColorNone);
}

void HandleBackdropMethod(
    HWND window,
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "getCapabilities") {
    result->Success(flutter::EncodableValue(Capabilities()));
    return;
  }
  if (method == "setBackdrop") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    const std::string mode = StringArg(args, "mode", "off");
    const bool dark = BoolArg(args, "dark", false);
    const int tint = IntArg(args, "tint", 0xFFF7F7F7);
    const std::string applied = ApplyBackdrop(window, mode, dark, tint);
    const bool active = applied != "off";
    g_backdrop_windows[window] = active;
    if (active) {
      // 首帧前 DWM 还没进入合成状态，caption 颜色设置可能被拒绝；
      // 120ms 后再补一次（WM_TIMER 由 window_frame.cpp 接管）。
      ::SetTimer(window, kBackdropCaptionTimer, 120, nullptr);
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("applied"),
         flutter::EncodableValue(applied)},
        {flutter::EncodableValue("fallback"),
         flutter::EncodableValue(applied != mode)},
    }));
    return;
  }
  if (method == "hideCaption") {
    // Dart 侧在首帧后 / 窗口获得焦点时再补一刀。DWM 在某些激活
    // 时序下会把 caption 重新画出来，原生 timer 偶发赶不上。
    auto it = g_backdrop_windows.find(window);
    if (it != g_backdrop_windows.end() && it->second) {
      SetCaptionColor(window, kDwmColorNone);
    }
    result->Success();
    return;
  }
  if (method == "reset") {
    SetAccent(window, kAccentDisabled, 0);
    ResetSystemBackdrop(window);
    g_backdrop_windows[window] = false;
    ::KillTimer(window, kBackdropCaptionTimer);
    result->Success();
    return;
  }
  result->NotImplemented();
}

}  // namespace mint
