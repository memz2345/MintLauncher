#include "vtouch_host.h"

#include <commctrl.h>
#include <windowsx.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace mint {

namespace {

constexpr UINT_PTR kVTouchSubclassId = 0x4D4E5454;  // 'MNTT'
constexpr UINT_PTR kTrackTimerId = 0x56544854;      // 'VTHT'
// 跟踪游戏窗口的轮询间隔。500ms 对「游戏移动 / 缩放」这种低频事件足够，
// 又不至于空转。
constexpr UINT kTrackIntervalMs = 500;

using VTouchChannel = flutter::MethodChannel<flutter::EncodableValue>;

// root HWND → 通道 / 状态。desktop_multi_window 每个子引擎都会走到
// AttachVTouchChannel，但只有虚拟触控悬浮窗会真正配置窗口。
std::unordered_map<HWND, std::unique_ptr<VTouchChannel>> g_vtouch_channels;

struct VTouchState {
  // 跟踪的游戏进程 pid（0 = 没有游戏，悬浮层铺满主屏工作区，供布局编辑）。
  DWORD track_pid = 0;
  // 解析到的游戏主窗口（每轮跟踪刷新；找不到为 null）。
  HWND game_hwnd = nullptr;
  // 连续几轮没找到游戏窗口：超过阈值自动隐藏悬浮层（游戏退出时主引擎
  // 也会发 hide，这里是兜底，避免游戏崩溃后悬浮层挂在桌面上）。
  int miss_ticks = 0;
  // 是否允许激活 / 接收键盘焦点（键位编辑对话框打开期间为 true：
  // 文本框与键位捕捉需要焦点；平时 false —— 游戏保持前台）。
  bool capture_keys = false;
  // 整窗不透明度（0..255），LWA_ALPHA。
  BYTE alpha = 255;
  // 悬浮层当前 rect（跟踪用，变了才动窗口）。
  RECT last_rect = {};
  bool has_last_rect = false;
};

std::unordered_map<HWND, VTouchState> g_vtouch_states;

VTouchState* StateOf(HWND window) {
  auto it = g_vtouch_states.find(window);
  return it == g_vtouch_states.end() ? nullptr : &it->second;
}

// ─────────────────────── 游戏窗口查找 / 跟踪 ───────────────────────

// EnumWindows 回调包：找该 pid 里「最大的一块可见顶层窗口」。Minecraft 的
// GLFW 主窗口是 java 进程里唯一的可见大窗口；java 自己偶尔弹的控制台
// （javaw 无）也不大，取面积最大的最稳。
struct EnumFindContext {
  DWORD pid;
  HWND best = nullptr;
  LONG best_area = 0;
};

BOOL CALLBACK EnumFindWindowProc(HWND hwnd, LPARAM lparam) {
  auto* ctx = reinterpret_cast<EnumFindContext*>(lparam);
  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid != ctx->pid) return TRUE;
  if (!::IsWindowVisible(hwnd)) return TRUE;
  // 有属主的窗口是对话框之类，不是主窗口。
  if (::GetWindow(hwnd, GW_OWNER) != nullptr) return TRUE;
  RECT rect = {};
  if (!::GetWindowRect(hwnd, &rect)) return TRUE;
  const LONG area = (rect.right - rect.left) * (rect.bottom - rect.top);
  if (area > ctx->best_area) {
    ctx->best_area = area;
    ctx->best = hwnd;
  }
  return TRUE;
}

// 找 pid 的主窗口；找不到返回 null。
HWND FindGameWindow(DWORD pid) {
  if (pid == 0) return nullptr;
  EnumFindContext ctx = {};
  ctx.pid = pid;
  ::EnumWindows(EnumFindWindowProc, reinterpret_cast<LPARAM>(&ctx));
  return ctx.best;
}

// 目标矩形：有游戏 → 游戏 client rect 换算成屏幕坐标（控件对准游戏画面，
// 归一化坐标语义与 Android 一致：相对游戏画面矩形）；没有游戏 → 主屏
// 工作区（布局编辑模式，也方便无游戏时对着任意窗口实测注入）。
bool TargetRect(const VTouchState& state, RECT* out) {
  if (state.game_hwnd != nullptr && ::IsWindow(state.game_hwnd)) {
    // GetClientRect 是 client 坐标，映射两个角到屏幕坐标。
    RECT r = {};
    if (!::GetClientRect(state.game_hwnd, &r)) return false;
    POINT tl = {r.left, r.top};
    POINT br = {r.right, r.bottom};
    ::ClientToScreen(state.game_hwnd, &tl);
    ::ClientToScreen(state.game_hwnd, &br);
    out->left = tl.x;
    out->top = tl.y;
    out->right = br.x;
    out->bottom = br.y;
    return out->right > out->left && out->bottom > out->top;
  }
  // 没有（或还找不到）游戏窗口：铺主屏工作区。全屏黑边时工作区可能比
  // 游戏画面大一点，可接受 —— 等窗口出现后下一轮跟踪会对齐。
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  HMONITOR monitor = state.game_hwnd != nullptr
      ? ::MonitorFromWindow(state.game_hwnd, MONITOR_DEFAULTTONEAREST)
      : ::MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  if (!::GetMonitorInfo(monitor, &info)) return false;
  *out = info.rcWork;
  return true;
}

void ApplyTrackRect(HWND window, VTouchState* state) {
  RECT rect = {};
  if (!TargetRect(*state, &rect)) return;
  // 和「实际窗口矩形」比对（不是和上次的目标矩形）：外部把窗口改了大小 /
  // 位置（别的工具、误拖拽）也能在下一轮拉回来，最多 500ms 自愈。
  RECT now = {};
  if (!::GetWindowRect(window, &now)) return;
  const bool same = now.left == rect.left && now.top == rect.top &&
      now.right == rect.right && now.bottom == rect.bottom;
  if (same) return;
  state->last_rect = rect;
  state->has_last_rect = true;
  const int w = rect.right - rect.left;
  const int h = rect.bottom - rect.top;
  ::SetWindowPos(window, HWND_TOPMOST, rect.left, rect.top, w, h,
                 SWP_NOACTIVATE);
}

// 是否应该显示悬浮层。游戏窗口最小化时收起（别让一层置顶 OSD 悬在桌面
// 上）；窗口还在（哪怕没抢到前台）就保持显示 —— 点一下悬浮键会经
// EnsureForeground 把游戏拉回前台，这正是桌面虚拟触控的用法。
// 键位编辑（capture_keys）期间始终显示：悬浮层自己要拿前台和键盘焦点。
bool ShouldShowOverlay(const VTouchState& state) {
  if (state.track_pid == 0) return true;
  if (state.capture_keys) return true;
  if (state.game_hwnd == nullptr || !::IsWindow(state.game_hwnd)) return false;
  return !::IsIconic(state.game_hwnd);
}

void TrackTick(HWND window) {
  VTouchState* state = StateOf(window);
  if (state == nullptr) return;
  if (state->track_pid != 0) {
    HWND hwnd = FindGameWindow(state->track_pid);
    if (hwnd != nullptr) {
      state->game_hwnd = hwnd;
      state->miss_ticks = 0;
      if (!ShouldShowOverlay(*state)) {
        if (::IsWindowVisible(window)) ::ShowWindow(window, SW_HIDE);
        return;
      }
      if (!::IsWindowVisible(window)) ::ShowWindow(window, SW_SHOWNOACTIVATE);
      ApplyTrackRect(window, state);
    } else if (++state->miss_ticks >= 6) {
      // 游戏 3 秒内一直找不到（退出 / 崩溃）：自己收起来。引擎常驻，
      // 下次 show 再亮出来。
      state->game_hwnd = nullptr;
      ::ShowWindow(window, SW_HIDE);
      ::KillTimer(window, kTrackTimerId);
    } else if (state->game_hwnd != nullptr &&
               !::IsWindow(state->game_hwnd)) {
      state->game_hwnd = nullptr;
    }
  } else {
    // 无游戏（布局编辑 / 实测）模式：铺一次工作区，不自动隐藏。
    state->game_hwnd = nullptr;
    if (!::IsWindowVisible(window)) ::ShowWindow(window, SW_SHOWNOACTIVATE);
    ApplyTrackRect(window, state);
  }
}

// ─────────────────────── 窗口样式 ───────────────────────

// 把 desktop_multi_window 建出来的普通窗口（WS_OVERLAPPEDWINDOW）改造成
// 悬浮层。幂等：show / hide 反复切换时重复调用无害。
void ApplyOverlayStyle(HWND window) {
  LONG_PTR style = ::GetWindowLongPtr(window, GWL_STYLE);
  style &= ~(WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX |
             WS_MAXIMIZEBOX | WS_OVERLAPPED);
  style |= WS_POPUP | WS_CLIPSIBLINGS | WS_CLIPCHILDREN;
  ::SetWindowLongPtr(window, GWL_STYLE, style);

  LONG_PTR ex = ::GetWindowLongPtr(window, GWL_EXSTYLE);
  ex |= WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED;
  ::SetWindowLongPtr(window, GWL_EXSTYLE, ex);
  ::SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA);

  ::SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

// ─────────────────────── 命中区（SetWindowRgn） ───────────────────────

// 由 Dart 发来的控件矩形建窗口 region。矩形是「物理像素、相对窗口左上
// 角」；shape：0=圆角方块（按钮 / 面板），1=椭圆（摇杆 / 菜单球）。
//
// 之所以用 SetWindowRgen 而不是 WM_NCHITTEST 返回 HTTRANSPARENT：后者只
// 对同线程窗口生效（Raymond Chen），透不到别的进程的游戏窗口；而 region
// 外窗口直接「不存在」，点击必然穿过（跨进程成立，也没有轮询延迟）。
// region 同时裁掉渲染 —— Flutter 的表面是不透明的，控件之外的黑底必须
// 裁掉，不能盖住游戏画面。
void ApplyRegions(HWND window, const std::vector<RECT>& rects,
                  const std::vector<int>& shapes) {
  HRGN region = nullptr;
  for (size_t i = 0; i < rects.size(); ++i) {
    const RECT& r = rects[i];
    if (r.right <= r.left || r.bottom <= r.top) continue;
    HRGN piece = nullptr;
    if (i < shapes.size() && shapes[i] == 1) {
      piece = ::CreateEllipticRgn(r.left, r.top, r.right, r.bottom);
    } else {
      // 圆角半径取短边 1/4（与 Dart 侧按钮圆角一致）；小到没意义时退圆角 4。
      const int w = r.right - r.left;
      const int h = r.bottom - r.top;
      const int rad = std::min(w, h) / 4;
      piece = ::CreateRoundRectRgn(r.left, r.top, r.right, r.bottom,
                                   std::max(rad, 4) * 2, std::max(rad, 4) * 2);
    }
    if (piece == nullptr) continue;
    if (region == nullptr) {
      region = piece;
    } else {
      ::CombineRgn(region, region, piece, RGN_OR);
      ::DeleteObject(piece);
    }
  }
  if (region == nullptr) {
    // 没有控件：整窗放行（不该发生 —— 菜单球永远在，防御一下）。
    ::SetWindowRgn(window, nullptr, TRUE);
    return;
  }
  ::SetWindowRgn(window, region, TRUE);
  // SetWindowRgn 接管了 region 的所有权，成功后不要再 DeleteObject。
}

// ─────────────────────── 输入注入 ───────────────────────

// SendInput 键盘：VK + scancode 一起给（GLFW 走 WM_KEYDOWN 的 VK 路径，
// DirectInput / 原始路径吃 scancode，两边都照顾到）。
void SendKey(WORD vk, bool down) {
  const UINT scan = ::MapVirtualKey(vk, MAPVK_VK_TO_VSC);
  INPUT input = {};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = vk;
  input.ki.wScan = static_cast<WORD>(scan);
  input.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
  // 扩展键（右 Ctrl/Alt、方向键、Insert 群）不带 extended 标志时部分
  // 程序会解成小键盘键，这里按规则补上。
  switch (vk) {
    case VK_RCONTROL:
    case VK_RMENU:
    case VK_INSERT:
    case VK_DELETE:
    case VK_HOME:
    case VK_END:
    case VK_PRIOR:
    case VK_NEXT:
    case VK_UP:
    case VK_DOWN:
    case VK_LEFT:
    case VK_RIGHT:
    case VK_NUMLOCK:
    case VK_DIVIDE:
    case VK_SNAPSHOT:
      input.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
      break;
    default:
      break;
  }
  ::SendInput(1, &input, sizeof(INPUT));
}

// SendInput 相对鼠标位移（视角拖动）：Raw Input 直接收增量，光标在不在
// 悬浮层上都一样。
void SendLookDelta(LONG dx, LONG dy) {
  INPUT input = {};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = MOUSEEVENTF_MOVE;
  input.mi.dx = dx;
  input.mi.dy = dy;
  ::SendInput(1, &input, sizeof(INPUT));
}

// 找光标下（目标顶层窗口内的）最深一层子窗口，鼠标消息投给它 —— 跟真实
// 点击的命中一致（mspaint 的画布、记事本的编辑区都是子窗口）。
HWND DeepChildFromPoint(HWND top_level, POINT screen_pt) {
  HWND hwnd = top_level;
  for (int depth = 0; depth < 8; ++depth) {
    POINT client_pt = screen_pt;
    ::ScreenToClient(hwnd, &client_pt);
    HWND child = ::ChildWindowFromPointEx(hwnd, client_pt,
                                          CWP_SKIPINVISIBLE |
                                              CWP_SKIPTRANSPARENT);
    if (child == nullptr || child == hwnd) break;
    hwnd = child;
  }
  return hwnd;
}

// 鼠标键注入：SendInput 的鼠标事件按光标路由，光标正悬在悬浮控件上会把
// 点击喂回悬浮层自己 —— 所以 PostMessage 直发目标窗口。wParam 按真实
// 输入的约定带上按住中的按键位。
void PostMouseButton(HWND target_hint, const std::string& button, bool down) {
  POINT pt = {};
  ::GetCursorPos(&pt);
  // 目标：优先跟踪到的游戏窗口；没有就用前台窗口（无游戏实测时点谁谁中）。
  HWND top = target_hint != nullptr && ::IsWindow(target_hint)
      ? target_hint
      : ::GetForegroundWindow();
  if (top == nullptr) return;
  HWND target = DeepChildFromPoint(top, pt);

  WPARAM wparam = 0;
  bool left_held = (::GetKeyState(VK_LBUTTON) & 0x8000) != 0;
  bool right_held = (::GetKeyState(VK_RBUTTON) & 0x8000) != 0;
  bool mid_held = (::GetKeyState(VK_MBUTTON) & 0x8000) != 0;
  if (down) {
    if (button == "left") left_held = true;
    if (button == "right") right_held = true;
    if (button == "middle") mid_held = true;
  } else {
    if (button == "left") left_held = false;
    if (button == "right") right_held = false;
    if (button == "middle") mid_held = false;
  }
  if (left_held) wparam |= MK_LBUTTON;
  if (right_held) wparam |= MK_RBUTTON;
  if (mid_held) wparam |= MK_MBUTTON;

  POINT client_pt = pt;
  ::ScreenToClient(target, &client_pt);
  LPARAM lparam = MAKELPARAM(client_pt.x, client_pt.y);
  UINT down_msg = WM_LBUTTONDOWN;
  UINT up_msg = WM_LBUTTONUP;
  if (button == "right") {
    down_msg = WM_RBUTTONDOWN;
    up_msg = WM_RBUTTONUP;
  } else if (button == "middle") {
    down_msg = WM_MBUTTONDOWN;
    up_msg = WM_MBUTTONUP;
  }
  // 双击消息不造：GLFW 只按 down/up 计数，游戏自己判连击。
  ::PostMessage(target, down ? down_msg : up_msg, wparam, lparam);
}

// 跨进程抢前台的经典手法（AttachThreadInput 蹭前台线程的输入队列）。
// SetForegroundWindow 有前台锁：调用进程不持有前台时会被系统静默拒绝，
// attach 一下就绕开了（很多「窗口置顶」工具同款，无副作用）。
void ForceForeground(HWND hwnd);

// 尽力把游戏窗口拉回前台。悬浮层从不抢焦点，但用户切到启动器改设置后
// 直接按悬浮键，SendInput 会打进启动器 —— 注入前发现前台不是游戏就把
// 游戏拉回来。点击悬浮层的进程刚收到输入，通常拥有前台权限。
void EnsureForeground(HWND game_hwnd) {
  if (game_hwnd == nullptr || !::IsWindow(game_hwnd)) return;
  if (::GetForegroundWindow() == game_hwnd) return;
  ForceForeground(game_hwnd);
}

// 跨进程抢前台的经典手法（AttachThreadInput 蹭前台线程的输入队列）。
// SetForegroundWindow 有前台锁：调用进程不持有前台时会被系统静默拒绝，
// attach 一下就绕开了（很多「窗口置顶」工具同款，无副作用）。
void ForceForeground(HWND hwnd) {
  if (hwnd == nullptr || !::IsWindow(hwnd)) return;
  if (::GetForegroundWindow() == hwnd) return;
  DWORD fore_pid = 0;
  const DWORD fore_thread =
      ::GetWindowThreadProcessId(::GetForegroundWindow(), &fore_pid);
  const DWORD cur_thread = ::GetCurrentThreadId();
  const bool attached = fore_thread != 0 && fore_thread != cur_thread &&
      ::AttachThreadInput(cur_thread, fore_thread, TRUE);
  ::BringWindowToTop(hwnd);
  ::SetForegroundWindow(hwnd);
  if (attached) {
    ::AttachThreadInput(cur_thread, fore_thread, FALSE);
  }
}

// ─────────────────────── 消息参数解析 ───────────────────────

const flutter::EncodableValue* ArgOrNull(
    const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr : &it->second;
}

bool ArgBool(const flutter::EncodableMap& args, const char* key,
             bool fallback = false) {
  const auto* v = ArgOrNull(args, key);
  return v != nullptr && std::holds_alternative<bool>(*v)
      ? std::get<bool>(*v)
      : fallback;
}

int ArgInt(const flutter::EncodableMap& args, const char* key, int fallback) {
  const auto* v = ArgOrNull(args, key);
  if (v == nullptr) return fallback;
  if (auto* n = std::get_if<int32_t>(v)) return *n;
  if (auto* n = std::get_if<int64_t>(v)) return static_cast<int>(*n);
  return fallback;
}

double ArgDouble(const flutter::EncodableMap& args, const char* key,
                 double fallback) {
  const auto* v = ArgOrNull(args, key);
  if (v == nullptr) return fallback;
  if (auto* n = std::get_if<double>(v)) return *n;
  if (auto* n = std::get_if<int32_t>(v)) return static_cast<double>(*n);
  if (auto* n = std::get_if<int64_t>(v)) return static_cast<double>(*n);
  return fallback;
}

std::string ArgString(const flutter::EncodableMap& args, const char* key,
                      const std::string& fallback = "") {
  const auto* v = ArgOrNull(args, key);
  return v != nullptr && std::holds_alternative<std::string>(*v)
      ? std::get<std::string>(*v)
      : fallback;
}

// rects: [[l, t, r, b], ...]，shapes: [0|1, ...]（可与 rects 等长或缺省）。
void ParseRegions(const flutter::EncodableMap& args, std::vector<RECT>* rects,
                  std::vector<int>* shapes) {
  const auto* list = ArgOrNull(args, "rects");
  if (list == nullptr || !std::holds_alternative<flutter::EncodableList>(*list)) {
    return;
  }
  for (const auto& item : std::get<flutter::EncodableList>(*list)) {
    if (!std::holds_alternative<flutter::EncodableList>(item)) continue;
    const auto& quad = std::get<flutter::EncodableList>(item);
    if (quad.size() < 4) continue;
    auto num = [&quad](size_t i) -> int {
      const auto& v = quad[i];
      if (auto* n = std::get_if<int32_t>(&v)) return *n;
      if (auto* n = std::get_if<int64_t>(&v)) return static_cast<int>(*n);
      if (auto* n = std::get_if<double>(&v)) return static_cast<int>(*n);
      return 0;
    };
    rects->push_back(RECT{num(0), num(1), num(2), num(3)});
  }
  const auto* shape_list = ArgOrNull(args, "shapes");
  if (shape_list != nullptr &&
      std::holds_alternative<flutter::EncodableList>(*shape_list)) {
    for (const auto& item : std::get<flutter::EncodableList>(*shape_list)) {
      if (auto* n = std::get_if<int32_t>(&item)) {
        shapes->push_back(*n);
      } else if (auto* n64 = std::get_if<int64_t>(&item)) {
        shapes->push_back(static_cast<int>(*n64));
      }
    }
  }
}

// ─────────────────────── 通道处理 ───────────────────────

void HandleVTouchMethod(HWND window,
                        VTouchState* state,
                        const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                            result) {
  const auto& method = call.method_name();
  flutter::EncodableMap args;
  if (call.arguments() != nullptr) {
    if (auto* map = std::get_if<flutter::EncodableMap>(call.arguments())) {
      args = *map;
    }
  }

  if (method == "configure") {
    // 幂等改造窗口样式（popup / topmost / noactivate / layered）。
    ApplyOverlayStyle(window);
    state->alpha = static_cast<BYTE>(
        std::max(0, std::min(255, ArgInt(args, "alpha", 255))));
    ::SetLayeredWindowAttributes(window, 0, state->alpha, LWA_ALPHA);
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "show") {
    ApplyOverlayStyle(window);
    state->has_last_rect = false;  // show 时强制对一次位置。
    ::SetTimer(window, kTrackTimerId, kTrackIntervalMs, nullptr);
    // 悬浮层绝不接收焦点。desktop_multi_window 建窗口时对 FlutterView
    // 调过 SetFocus（SetChildContent），这一下会把悬浮层顶层推成本线程的
    // 活动窗口 —— show 之后必须把前台还回去：有游戏还游戏，没游戏还给
    // show 之前的前台（谁都不该因为悬浮层出现而失焦）。
    HWND prev_foreground = ::GetForegroundWindow();
    ::ShowWindow(window, SW_SHOWNOACTIVATE);
    // TrackTick 决定是否留下：游戏不在前台 / 最小化时同一轮就收起，
    // 无游戏编辑模式则铺工作区。
    TrackTick(window);
    if (!state->capture_keys) {
      if (state->game_hwnd != nullptr && ::IsWindow(state->game_hwnd)) {
        ForceForeground(state->game_hwnd);
      } else if (prev_foreground != nullptr && prev_foreground != window) {
        ForceForeground(prev_foreground);
      }
      // 建窗口时 desktop_multi_window 的 SetChildContent 曾 SetFocus 到
      // 悬浮层的 FlutterView —— 若焦点还挂在悬浮层自己身上，摘掉。
      GUITHREADINFO gti = {};
      gti.cbSize = sizeof(gti);
      if (::GetGUIThreadInfo(::GetCurrentThreadId(), &gti) &&
          (gti.hwndFocus == window || ::IsChild(window, gti.hwndFocus))) {
        ::SetFocus(nullptr);
      }
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "hide") {
    ::KillTimer(window, kTrackTimerId);
    ::ShowWindow(window, SW_HIDE);
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "setTrackPid") {
    state->track_pid = static_cast<DWORD>(ArgInt(args, "pid", 0));
    state->game_hwnd = FindGameWindow(state->track_pid);
    state->miss_ticks = 0;
    state->has_last_rect = false;
    if (::IsWindowVisible(window)) {
      TrackTick(window);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "setCaptureKeys") {
    state->capture_keys = ArgBool(args, "enabled");
    LONG_PTR ex = ::GetWindowLongPtr(window, GWL_EXSTYLE);
    if (state->capture_keys) {
      // 键位编辑对话框：允许激活并接住焦点（文本框 / 键位捕捉）。
      ex &= ~static_cast<LONG_PTR>(WS_EX_NOACTIVATE);
      ::SetWindowLongPtr(window, GWL_EXSTYLE, ex);
      ::SetForegroundWindow(window);
      ::SetFocus(window);
    } else {
      ex |= WS_EX_NOACTIVATE;
      ::SetWindowLongPtr(window, GWL_EXSTYLE, ex);
      // 焦点还给游戏（编辑完继续操作）。
      EnsureForeground(state->game_hwnd);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "setRegions") {
    std::vector<RECT> rects;
    std::vector<int> shapes;
    ParseRegions(args, &rects, &shapes);
    ApplyRegions(window, rects, shapes);
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "setAlpha") {
    state->alpha = static_cast<BYTE>(
        std::max(0, std::min(255, ArgInt(args, "alpha", 255))));
    ::SetLayeredWindowAttributes(window, 0, state->alpha, LWA_ALPHA);
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "injectKey") {
    // 编辑态的护栏在 Dart 侧（悬浮窗只有非编辑态才会发注入调用）。
    if (!state->capture_keys) {
      EnsureForeground(state->game_hwnd);
      SendKey(static_cast<WORD>(ArgInt(args, "vk", 0)),
              ArgBool(args, "down"));
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "injectMouse") {
    if (!state->capture_keys) {
      PostMouseButton(state->game_hwnd, ArgString(args, "button", "left"),
                      ArgBool(args, "down"));
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "injectLook") {
    if (!state->capture_keys) {
      SendLookDelta(
          static_cast<LONG>(ArgDouble(args, "dx", 0)),
          static_cast<LONG>(ArgDouble(args, "dy", 0)));
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  result->NotImplemented();
}

LRESULT CALLBACK VTouchSubclassProc(HWND window,
                                    UINT message,
                                    WPARAM wparam,
                                    LPARAM lparam,
                                    UINT_PTR id,
                                    DWORD_PTR ref) {
  if (id == kVTouchSubclassId) {
    switch (message) {
      case WM_MOUSEACTIVATE: {
        // 点击悬浮层绝不激活它自己 —— 前台 / 焦点保持给游戏，SendInput
        // 才能一直打进游戏。键位编辑对话框期间放行。
        VTouchState* state = StateOf(window);
        if (state != nullptr && !state->capture_keys) {
          return MA_NOACTIVATE;
        }
        break;
      }
      case WM_TIMER:
        if (wparam == kTrackTimerId) {
          TrackTick(window);
          return 0;
        }
        break;
      case WM_NCDESTROY: {
        g_vtouch_channels.erase(window);
        g_vtouch_states.erase(window);
        ::RemoveWindowSubclass(window, &VTouchSubclassProc, kVTouchSubclassId);
        break;
      }
      default:
        break;
    }
  }
  return ::DefSubclassProc(window, message, wparam, lparam);
}

}  // namespace

void AttachVTouchChannel(HWND window, flutter::BinaryMessenger* messenger) {
  if (window == nullptr || messenger == nullptr) return;
  if (g_vtouch_channels.find(window) != g_vtouch_channels.end()) return;
  if (!::SetWindowSubclass(window, &VTouchSubclassProc, kVTouchSubclassId, 0)) {
    return;
  }
  auto channel = std::make_unique<VTouchChannel>(
      messenger, "mint/vtouch",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [window](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) {
        VTouchState* state = StateOf(window);
        if (state == nullptr) {
          result->NotImplemented();
          return;
        }
        HandleVTouchMethod(window, state, call, std::move(result));
      });
  g_vtouch_channels[window] = std::move(channel);
  g_vtouch_states[window] = VTouchState{};
}

}  // namespace mint
