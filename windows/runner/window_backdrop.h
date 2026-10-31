#ifndef RUNNER_WINDOW_BACKDROP_H_
#define RUNNER_WINDOW_BACKDROP_H_

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace mint {

/// 原生 caption 被 DwmExtendFrameIntoClientArea 画出来时的延迟重试定时器。
constexpr UINT_PTR kBackdropCaptionTimer = 0x4D4E5443;  // 'MNTC'

// `mint/backdrop` platform channel.
//
// 把 WinUI 的 SystemBackdrop 搬到 Flutter：
//   · Windows 11 22621+：DWM SYSTEMBACKDROP_TYPE（Mica / Acrylic / Tabbed）
//   · Windows 11 22000：未公开的 MICA_EFFECT
//   · Windows 10 1809+：SetWindowCompositionAttribute（Acrylic / Aero）
//
// Flutter 视图本身支持 alpha，窗口透明由 Dart 侧
// `windowManager.setBackgroundColor(Colors.transparent)` 打开。
void HandleBackdropMethod(
    HWND window,
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

// 材质模式下 DwmExtendFrameIntoClientArea(-1) 会带出原生 caption。
// Win11 首帧前 DwmSetWindowAttribute(DWMWA_CAPTION_COLOR, NONE) 可能返回
// E_INVALIDARG，所以 Show()/激活/合成状态变化时都再补一次。
void ReapplyWindowChrome(HWND window);

}  // namespace mint

#endif  // RUNNER_WINDOW_BACKDROP_H_
