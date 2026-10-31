#ifndef RUNNER_WINDOW_FRAME_H_
#define RUNNER_WINDOW_FRAME_H_

#include <windows.h>

#include <flutter/binary_messenger.h>

namespace mint {

/// 切换最大化 / 还原（Snap 热区点击和 Dart 标题栏共用）。
/// 直接走 SC_MAXIMIZE / SC_RESTORE，动画由 DWM 原生播放
/// （窗口保留 WS_CAPTION，最小化 / 最大化 / 还原的系统动画都在）。
void ToggleMaximizeNative(HWND window);

// Removes the native caption (client area covers the whole window) while
// keeping WS_CAPTION + WS_THICKFRAME: DWM keeps its shadow / rounded corners
// and — crucially — plays the native minimize / maximize / restore animations
// (VS Code / Electron `titleBarStyle: hidden` use the same configuration).
//
// The Flutter side draws its own 44px caption bar and calls
// window_manager.startDragging() from it. This helper is shared by the main
// runner window and desktop_multi_window sub-windows (the log console).
bool HandleFrameMessage(HWND window,
                        UINT message,
                        WPARAM wparam,
                        LPARAM lparam,
                        LRESULT* result);

// Subclasses a window created by desktop_multi_window and forces the Flutter
// view to fill the new client area.
bool ApplyCustomFrame(HWND window, HWND flutter_view);

// 给自绘标题栏的窗口挂上 `mint/window_chrome` 通道。
//
// 最大化按钮的热区让给了非客户区（Snap Layouts），FlutterView 收不到
// 鼠标 move；原生在 WM_NCHITTEST / WM_NCMOUSEMOVE 里把 hover 状态回传，
// 按下只回传一个信号用于 ripple，实际最大化在松手（WM_NCLBUTTONUP）时
// 由原生执行。
//
// 主窗口和 desktop_multi_window 的日志窗口各有一条同名的 Per-engine 通道。
void AttachWindowChromeChannel(HWND window,
                               flutter::BinaryMessenger* messenger);

// 让 Flutter 子窗口把「最大化按钮」那一小块让给顶层的非客户区命中测试。
//
// Win11 的 Snap Layouts 只在窗口的 WM_NCHITTEST 返回 HTMAXBUTTON 时弹出；
// 但鼠标其实停在铺满客户区的 FlutterView（另一个 HWND）上，顶层收不到
// 这个点。子窗口在该矩形内回 HTTRANSPARENT，系统就会继续问父窗口，父窗口
// 再回 HTMAXBUTTON —— 贴靠布局的悬停判定就通了。按下 / 松手也由父窗口
// 按 WM_NCLBUTTONDOWN / WM_NCLBUTTONUP 处理（见 window_frame.cpp）。
bool ApplyCaptionHitTest(HWND window, HWND flutter_view);

}  // namespace mint

#endif  // RUNNER_WINDOW_FRAME_H_
