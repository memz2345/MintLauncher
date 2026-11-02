#include "window_frame.h"

#include <commctrl.h>
#include <windowsx.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cmath>
#include <memory>
#include <string>
#include <unordered_map>

#include "window_backdrop.h"

namespace mint {

namespace {

constexpr UINT_PTR kSubclassId = 0x4D4E5446;  // 'MNTF'
constexpr UINT_PTR kViewSubclassId = 0x4D4E5456;  // 'MNTV'

using ChromeChannel =
    flutter::MethodChannel<flutter::EncodableValue>;

std::unordered_map<HWND, std::unique_ptr<ChromeChannel>> g_chrome_channels;
std::unordered_map<HWND, bool> g_maximize_hover;
// 「这次左键按下发生在最大化按钮上」：按下只通知 Dart（ripple），
// 真正的最大化 / 还原在 WM_NCLBUTTONUP 且光标仍在热区内时才执行。
std::unordered_map<HWND, bool> g_maximize_pressed;
std::unordered_map<HWND, int> g_caption_retries;

HWND RootWindow(HWND window) {
  HWND root = ::GetAncestor(window, GA_ROOT);
  return root != nullptr ? root : window;
}

void NotifyChrome(HWND window,
                  const std::string& method,
                  const flutter::EncodableValue& value) {
  HWND root = RootWindow(window);
  auto it = g_chrome_channels.find(root);
  if (it == g_chrome_channels.end() || it->second == nullptr) return;
  it->second->InvokeMethod(
      method, std::make_unique<flutter::EncodableValue>(value));
}

void UpdateMaximizeHover(HWND window, bool hovered) {
  HWND root = RootWindow(window);
  auto it = g_maximize_hover.find(root);
  const bool previous = it != g_maximize_hover.end() && it->second;
  if (previous == hovered) return;
  g_maximize_hover[root] = hovered;
  NotifyChrome(root, "maximizeHover", flutter::EncodableValue(hovered));
}

void TrackMaximizeLeave(HWND window) {
  TRACKMOUSEEVENT track = {};
  track.cbSize = sizeof(track);
  track.dwFlags = TME_LEAVE | TME_NONCLIENT;
  track.hwndTrack = RootWindow(window);
  ::TrackMouseEvent(&track);
}

void SetMaximizePressed(HWND window, bool pressed) {
  HWND root = RootWindow(window);
  if (pressed) {
    g_maximize_pressed[root] = true;
  } else {
    g_maximize_pressed.erase(root);
  }
}

bool IsMaximizePressed(HWND window) {
  HWND root = RootWindow(window);
  auto it = g_maximize_pressed.find(root);
  return it != g_maximize_pressed.end() && it->second;
}

// 按下后无论从哪条路径收场，都要给 Dart 一个 release 信号：Dart 用它在
// 最大化按钮的 InkWell 上合成 pointer up/cancel，这样水波和其余三个
// caption 按钮走的是同一套动画。activate=false 表示拖出 / 失焦取消。
void ReleaseMaximizePress(HWND window, bool activate) {
  if (!IsMaximizePressed(window)) return;
  SetMaximizePressed(window, false);
  NotifyChrome(window, "maximizeRelease",
               flutter::EncodableValue(activate));
}

// 与 Flutter 侧 `kMintCaptionHeight` / `kMintCaptionButtonWidth` 保持一致；
// 原生只用这组数字做 Win11 Snap Layouts 的命中矩形。
constexpr int kCaptionHeightDip = 44;
constexpr int kCaptionButtonWidthDip = 46;

// 最大化热区的按下：把**真实按点**（客户区 + DIP，和 Flutter 逻辑坐标同
// 尺度）一起回传。Dart 拿它在该按钮的 InkWell 上合成 pointer down，水波就
// 从鼠标位置长出来；只回传一个 bool 的话 Dart 只能钉在按钮中心，观感和
// 另外三个金刚不一致。
void NotifyMaximizeClick(HWND window, LPARAM lparam) {
  HWND root = RootWindow(window);
  flutter::EncodableMap args;
  POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  const int dpi = static_cast<int>(::GetDpiForWindow(root));
  if (dpi > 0 && ::ScreenToClient(root, &point)) {
    args[flutter::EncodableValue("x")] =
        flutter::EncodableValue(static_cast<double>(point.x) * 96.0 / dpi);
    args[flutter::EncodableValue("y")] =
        flutter::EncodableValue(static_cast<double>(point.y) * 96.0 / dpi);
  }
  NotifyChrome(root, "maximizeClick", flutter::EncodableValue(args));
}

int DipToPx(HWND window, int dip) {
  return ::MulDiv(dip, static_cast<int>(::GetDpiForWindow(window)), 96);
}

int ResizeBorder(HWND window) {
  UINT dpi = GetDpiForWindow(window);
  int frame = GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi);
  int padding = GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
  return frame + padding;
}

bool IsResizable(HWND window) {
  const LONG_PTR style = ::GetWindowLongPtr(window, GWL_STYLE);
  return (style & WS_THICKFRAME) != 0;
}

// Snap Layouts：Win11 只有从 WM_NCHITTEST 收到 HTMAXBUTTON 才会在悬停
// 最大化/还原按钮时弹出贴靠布局。三个 caption 按钮按 Flutter 侧的
// 46×44dp 固定在右上角，最大化是中间那个。
bool IsMaximizeButton(HWND window, POINT client_point) {
  HWND root = ::GetAncestor(window, GA_ROOT);
  if (root == nullptr) root = window;
  // 全屏（F11）会摘掉 WS_THICKFRAME 并隐藏自绘标题栏，此时不要再把
  // 右上角热区让给非客户区。
  if (!IsResizable(root)) return false;
  const LONG_PTR style = ::GetWindowLongPtr(root, GWL_STYLE);
  if ((style & WS_MAXIMIZEBOX) == 0) return false;
  RECT client;
  if (!::GetClientRect(root, &client)) return false;
  const int button_width = DipToPx(root, kCaptionButtonWidthDip);
  const int caption_height = DipToPx(root, kCaptionHeightDip);
  const int right = client.right - button_width;
  const int left = right - button_width;
  return client_point.x >= left && client_point.x < right &&
         client_point.y >= 0 && client_point.y < caption_height;
}

// WS_CAPTION 保留（DWM 的最小化收拢 / 最大化缩放动画只对带 caption 的
// 窗口播放），这里把整个窗口都算作客户区，系统就不再画原生标题栏，
// 视觉上与摘掉 WS_CAPTION 完全一致（VS Code / Electron 的
// titleBarStyle=hidden 就是这套）。最大化时把 client 收回到「窗口矩形 ∩
// 工作区」：正常最大化时窗口四周有 THICKFRAME 的 8px 悬出，交集恰好等于
// 工作区（与直接钉 rcWork 等价）；但万一 zoomed 状态下窗口被外力改了
// 尺寸 / 位置（NC 尺寸循环不查 IsZoomed），交集仍与可见窗口对齐，
// 客户区不会错位出画（「内容断头」）。
void CalcClientArea(HWND window, NCCALCSIZE_PARAMS* params) {
  if (!IsZoomed(window)) return;
  MONITORINFO info = {};
  info.cbSize = static_cast<DWORD>(sizeof(MONITORINFO));
  if (!::GetMonitorInfo(::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                        &info)) {
    return;
  }
  RECT& r = params->rgrc[0];
  if (r.left < info.rcWork.left) r.left = info.rcWork.left;
  if (r.top < info.rcWork.top) r.top = info.rcWork.top;
  if (r.right > info.rcWork.right) r.right = info.rcWork.right;
  if (r.bottom > info.rcWork.bottom) r.bottom = info.rcWork.bottom;
}

bool HitTest(HWND window, LPARAM lparam, LRESULT* result) {
  POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  ::ScreenToClient(window, &point);

  // Snap 热区必须在「最大化后直接返回 HTCLIENT」之前判定。
  if (IsMaximizeButton(window, point)) {
    UpdateMaximizeHover(window, true);
    TrackMaximizeLeave(window);
    *result = HTMAXBUTTON;
    return true;
  }
  UpdateMaximizeHover(window, false);

  if (!IsResizable(window) || IsZoomed(window)) {
    *result = HTCLIENT;
    return true;
  }

  RECT rect;
  if (!::GetWindowRect(window, &rect)) {
    *result = HTCLIENT;
    return true;
  }

  const int border = ResizeBorder(window);
  const int x = GET_X_LPARAM(lparam);
  const int y = GET_Y_LPARAM(lparam);
  const bool left = x >= rect.left && x < rect.left + border;
  const bool right = x < rect.right && x >= rect.right - border;
  const bool top = y >= rect.top && y < rect.top + border;
  const bool bottom = y < rect.bottom && y >= rect.bottom - border;

  if (top && left) *result = HTTOPLEFT;
  else if (top && right) *result = HTTOPRIGHT;
  else if (bottom && left) *result = HTBOTTOMLEFT;
  else if (bottom && right) *result = HTBOTTOMRIGHT;
  else if (left) *result = HTLEFT;
  else if (right) *result = HTRIGHT;
  else if (top) *result = HTTOP;
  else if (bottom) *result = HTBOTTOM;
  else *result = HTCLIENT;
  return true;
}

// 经典主题的非客户区绘制消息（未公开，Chromium 同款防御）：万一 DWM
// 走了经典绘制路径，不让它把原生 caption 画出来。
constexpr UINT WM_NCUAHDRAWCAPTION = 0x00AE;
constexpr UINT WM_NCUAHDRAWFRAME = 0x00AF;

LRESULT CALLBACK SubclassProc(HWND window,
                              UINT message,
                              WPARAM wparam,
                              LPARAM lparam,
                              UINT_PTR id,
                              DWORD_PTR ref) {
  if (id == kSubclassId) {
    LRESULT result = 0;
    if (message == WM_NCUAHDRAWCAPTION || message == WM_NCUAHDRAWFRAME) {
      return 0;
    }
    if (HandleFrameMessage(window, message, wparam, lparam, &result)) {
      return result;
    }
    if (message == WM_NCDESTROY) {
      HWND root = RootWindow(window);
      g_chrome_channels.erase(root);
      g_maximize_hover.erase(root);
      g_maximize_pressed.erase(root);
      g_caption_retries.erase(root);
      ::RemoveWindowSubclass(window, &SubclassProc, kSubclassId);
    }
  }
  return ::DefSubclassProc(window, message, wparam, lparam);
}

// FlutterView 自己的 WM_NCHITTEST：最大化按钮那一块回 HTTRANSPARENT，
// 让系统继续去问同一线程里的父窗口（自绘标题栏窗口），父窗口再回
// HTMAXBUTTON，Win11 才会把 Snap Layouts 的悬停菜单弹出来。
LRESULT CALLBACK ViewSubclassProc(HWND window,
                                  UINT message,
                                  WPARAM wparam,
                                  LPARAM lparam,
                                  UINT_PTR id,
                                  DWORD_PTR ref) {
  if (id == kViewSubclassId) {
    if (message == WM_MOUSEMOVE && IsMaximizePressed(window)) {
      // 光标进入 Flutter 客户区说明已离开最大化按钮热区（拖出再松手
      // 不应触发），这里也补一条清理路径。
      ReleaseMaximizePress(window, false);
    }
    if (message == WM_NCHITTEST) {
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ::ScreenToClient(window, &point);
      if (IsMaximizeButton(window, point)) {
        return HTTRANSPARENT;
      }
    }
    if (message == WM_NCDESTROY) {
      ::RemoveWindowSubclass(window, &ViewSubclassProc, kViewSubclassId);
    }
  }
  return ::DefSubclassProc(window, message, wparam, lparam);
}

}  // namespace

// 原生最大化 / 还原：SC_MAXIMIZE / SC_RESTORE 交给 DefWindowProc，
// DWM 自己放缩放动画（系统「动画效果」关闭时就是瞬时切换，同样原生）。
// 之前那套 220ms 的 SetWindowPos 自绘缓动已删——保留 WS_CAPTION 后
// DWM 的系统动画直接可用，不再需要补帧。
void ToggleMaximizeNative(HWND window) {
  if (window == nullptr) return;
  const WPARAM cmd = ::IsZoomed(window) ? SC_RESTORE : SC_MAXIMIZE;
  ::SendMessage(window, WM_SYSCOMMAND, cmd, 0);
}

bool HandleFrameMessage(HWND window,
                        UINT message,
                        WPARAM wparam,
                        LPARAM lparam,
                        LRESULT* result) {
  switch (message) {
    case WM_NCCALCSIZE:
      if (wparam == TRUE) {
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        CalcClientArea(window, params);
        *result = 0;
        return true;
      }
      break;
    case WM_NCHITTEST:
      // 全屏（摘掉 WS_THICKFRAME）也接管：留着 WS_CAPTION 的话，
      // DefWindowProc 会把顶部一条判成 HTCAPTION，点一下就开始拖窗口。
      return HitTest(window, lparam, result);
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK:
      // FlutterView 把最大化热区让给了顶层；这里补上点击语义，
      // 不依赖 DefWindowProc 对 HTMAXBUTTON 的默认处理。
      if (wparam == HTMAXBUTTON) {
        // 按下只给 Dart 一个信号用于 ripple / 按压态；Dart 合成 pointer
        // down 喂给 InkWell，真正的最大化动作等 release 信号后的 onTap。
        NotifyMaximizeClick(window, lparam);
        SetMaximizePressed(window, true);
        // 保证按下后移出窗口 / 按钮时能收到 WM_NCMOUSELEAVE，
        // 及时清掉按下状态。
        TrackMaximizeLeave(window);
        *result = 0;
        return true;
      }
      // 按在别处：清掉可能残留的按下状态，避免下一次松手误触发。
      ReleaseMaximizePress(window, false);
      break;
    case WM_NCLBUTTONUP:
      // 松手落在最大化按钮上，或按下发生在最大化按钮上：都走自绘路径，
      // 不让 DefWindowProc 再处理 HTMAXBUTTON。
      if (IsMaximizePressed(window) || wparam == HTMAXBUTTON) {
        // 松手时命中码偶尔不是 HTMAXBUTTON（拖动 / 命中重算），
        // 用光标位置再判一次热区；按下后已移出按钮的不再触发。
        bool on_button = wparam == HTMAXBUTTON;
        if (!on_button) {
          POINT point = {};
          if (::GetCursorPos(&point)) {
            ::ScreenToClient(RootWindow(window), &point);
            on_button = IsMaximizeButton(window, point);
          }
        }
        ReleaseMaximizePress(window, on_button);
        *result = 0;
        return true;
      }
      break;
    case WM_NCMOUSEMOVE:
      UpdateMaximizeHover(window, wparam == HTMAXBUTTON);
      if (wparam == HTMAXBUTTON) {
        TrackMaximizeLeave(window);
      } else {
        // 按住拖出按钮：取消这次点击，松手不再最大化。
        ReleaseMaximizePress(window, false);
      }
      break;
    case WM_SIZE:
      // 最大化 / 还原后 DWM 会把 caption 颜色重置回默认。材质模式下客户区
      // 是透明的，原生三大金刚就直接透在自绘按钮底下（截图里两个 ✕ 叠在
      // 一起）。这里立刻补一次，再借 caption 定时器补几次 —— DWM 通常要等
      // 缩放动画播完才落最终状态，单次补设会被它盖回去。
      if (wparam == SIZE_MAXIMIZED || wparam == SIZE_RESTORED) {
        g_caption_retries[RootWindow(window)] = 0;
        ReapplyWindowChrome(window);
        ::SetTimer(window, kBackdropCaptionTimer, 90, nullptr);
      }
      break;
    case WM_NCMOUSELEAVE:
      UpdateMaximizeHover(window, false);
      ReleaseMaximizePress(window, false);
      break;
    case WM_CAPTURECHANGED:
      // 捕获被抢走（弹窗 / 其它窗口）后这次点击不再算数。
      ReleaseMaximizePress(window, false);
      break;
    case WM_CANCELMODE:
      // 系统取消当前输入模式（弹出菜单 / 模态框等）时一并清掉。
      ReleaseMaximizePress(window, false);
      break;
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) {
        ReleaseMaximizePress(window, false);
      }
      ReapplyWindowChrome(window);
      break;
    case WM_DWMCOMPOSITIONCHANGED:
      // DWM 在激活 / 合成状态变化后可能把 caption 又画回来。材质模式下
      // 重新把 caption 颜色设成 NONE（Win11 上首帧前设置会 E_INVALIDARG）。
      ReapplyWindowChrome(window);
      break;
    case WM_NCACTIVATE:
      // DefWindowProc 的第 4 参传 -1：激活时不要重画非客户区（经典
      // caption 闪回的主路径之一，Chromium / Electron 同款处理）。
      // 之后再补一次 caption NONE 兜底。
      ReapplyWindowChrome(window);
      *result = ::DefWindowProc(window, WM_NCACTIVATE, wparam, -1);
      return true;
    case WM_TIMER:
      if (wparam == kBackdropCaptionTimer) {
        ReapplyWindowChrome(window);
        // DWM 在窗口第一次合成前会拒绝 DWMWA_CAPTION_COLOR；单次 120ms
        // 重试在“应用启动后一直不激活”的截图场景里会失败。多补几次，
        // 窗口一旦激活后面还有 WM_NCACTIVATE 兜底。
        const int attempt = ++g_caption_retries[RootWindow(window)];
        if (attempt < 6) {
          ::SetTimer(window, kBackdropCaptionTimer, 300, nullptr);
        } else {
          ::KillTimer(window, kBackdropCaptionTimer);
        }
        *result = 0;
        return true;
      }
      break;
  }
  return false;
}

bool ApplyCustomFrame(HWND window, HWND flutter_view) {
  if (window == nullptr) return false;
  if (!::SetWindowSubclass(window, &SubclassProc, kSubclassId, 0)) {
    return false;
  }

  // 主窗口与独立日志窗口共用：保留 WS_CAPTION（DWM 窗口动画的开关），
  // 但**摘掉 WS_SYSMENU**。
  //
  // 三大金刚按钮就是系统菜单的 UI（Raymond Chen：想去掉 Close 只能去掉
  // 系统菜单）。带 backdrop 的窗口上，DWM 会把系统菜单按钮直接画在
  // 材质层顶上——客户区透明时透在自绘按钮底下，这就是「金刚重影」。
  // 实测 DWMWA_CAPTION_COLOR=NONE / DWMNCRP_DISABLED 都压不住它；
  // 没有 WS_SYSMENU，按钮在样式层就不存在，DWM 无从画起。
  // 系统菜单由自绘标题栏右键触发原生 TrackPopupMenu（showSystemMenu）；
  // 非 Windows 平台 / 通道不可用时回退 Flutter 自绘菜单。
  // Win+D / 任务栏 / SC_MINIMIZE 等不依赖 WS_SYSMENU，照常可用。
  LONG_PTR style = ::GetWindowLongPtr(window, GWL_STYLE);
  const LONG_PTR wanted =
      (style & ~static_cast<LONG_PTR>(WS_SYSMENU)) | WS_CAPTION |
      WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
  if (wanted != style) {
    ::SetWindowLongPtr(window, GWL_STYLE, wanted);
    ::SetWindowPos(window, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                       SWP_FRAMECHANGED);
  }

  if (flutter_view != nullptr) {
    RECT rect;
    if (::GetClientRect(window, &rect)) {
      ::SetWindowPos(flutter_view, nullptr, 0, 0, rect.right, rect.bottom,
                     SWP_NOZORDER | SWP_NOACTIVATE);
    }
  }
  return true;
}

bool ApplyCaptionHitTest(HWND window, HWND flutter_view) {
  if (window == nullptr || flutter_view == nullptr) return false;
  return ::SetWindowSubclass(flutter_view, &ViewSubclassProc, kViewSubclassId,
                             reinterpret_cast<DWORD_PTR>(window)) != FALSE;
}

void AttachWindowChromeChannel(HWND window,
                               flutter::BinaryMessenger* messenger) {
  if (window == nullptr || messenger == nullptr) return;
  HWND root = RootWindow(window);
  if (g_chrome_channels.find(root) != g_chrome_channels.end()) return;
  auto channel = std::make_unique<ChromeChannel>(
      messenger, "mint/window_chrome",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [root](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "toggleMaximize") {
          ToggleMaximizeNative(root);
          result->Success();
          return;
        }
        if (call.method_name() == "showSystemMenu") {
          // 自绘标题栏右键 → Windows 原生系统菜单。菜单项文案 / 图标 /
          // Alt+F4 提示都由系统提供；这里只按最大化状态灰置还原 / 大小。
          HMENU menu = ::GetSystemMenu(root, FALSE);
          if (menu == nullptr) {
            result->Error("no_system_menu",
                          "window has no native system menu");
            return;
          }
          const bool zoomed = ::IsZoomed(root) != FALSE;
          ::EnableMenuItem(menu, SC_RESTORE,
                           MF_BYCOMMAND |
                               (zoomed ? MF_ENABLED : MF_GRAYED));
          ::EnableMenuItem(menu, SC_MAXIMIZE,
                           MF_BYCOMMAND |
                               (zoomed ? MF_GRAYED : MF_ENABLED));
          ::EnableMenuItem(menu, SC_SIZE,
                           MF_BYCOMMAND |
                               (zoomed ? MF_GRAYED : MF_ENABLED));
          POINT pt = {};
          ::GetCursorPos(&pt);
          // TrackPopupMenu 需要窗口在前台，否则点外面菜单不会收。
          ::SetForegroundWindow(root);
          const UINT command = ::TrackPopupMenu(
              menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, pt.x,
              pt.y, 0, root, nullptr);
          ::PostMessage(root, WM_NULL, 0, 0);
          if (command != 0) {
            ::PostMessage(root, WM_SYSCOMMAND, command, 0);
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  g_chrome_channels[root] = std::move(channel);
}

}  // namespace mint
