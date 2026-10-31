#ifndef RUNNER_VTOUCH_HOST_H_
#define RUNNER_VTOUCH_HOST_H_

#include <windows.h>

#include <flutter/binary_messenger.h>

namespace mint {

// 桌面虚拟触控的悬浮窗宿主（`mint/vtouch` 通道）。
//
// 桌面版 Minecraft 是独立进程的 GLFW 窗口，没法像 Android 那样把 Flutter
// 控件直接叠在游戏 View 上。这里把一个 desktop_multi_window 子窗口改造成
// 「贴在游戏画面上的悬浮层」：
//   · WS_POPUP + WS_EX_TOPMOST | TOOLWINDOW | NOACTIVATE —— 无边框、置顶、
//     不进任务栏 / Alt-Tab，并且绝不抢焦点（游戏保持前台）；
//   · SetWindowRgn 把窗口命中区裁成「各控件矩形」的并集 —— 区域外窗口
//     等于不存在，点击自然落到下面的游戏窗口（跨进程天然成立，不需要
//     WM_NCHITTEST 的 HTTRANSPARENT：那只对同线程窗口生效）。region 同时
//     裁掉渲染：Flutter 表面不透明，控件之外的黑底必须裁掉才不挡游戏，
//     所以编辑模式也保留 region（对着真实画面拖控件），只在弹出键位
//     编辑对话框需要键盘时临时允许激活（setCaptureKeys）；
//   · 按游戏 PID 跟踪游戏窗口 client rect，游戏移动 / 缩放时跟着走。
//
// 输入注入：
//   · 键盘（摇杆 WASD / 普通按键）→ SendInput，作用于当前前台窗口
//     （悬浮层不抢焦点，前台就是游戏）；
//   · 鼠标键 → SendInput 的鼠标事件按光标路由，光标正悬在悬浮控件上会把
//     点击喂回悬浮层自己，所以改走 PostMessage 直发目标窗口最深的那层
//     子窗口（GLFW 窗口过程处理投递的 WM_LBUTTONDOWN 没问题）；
//   · 视角（MOUSEEVENTF_MOVE 相对位移）→ SendInput：Raw Input 收增量，
//     PostMessage 的 WM_MOUSEMOVE 在游戏开原始输入时是无效的。
//
// 只有虚拟触控悬浮窗那个子引擎会调这条通道；日志窗口的引擎从不调用。
void AttachVTouchChannel(HWND window, flutter::BinaryMessenger* messenger);

}  // namespace mint

#endif  // RUNNER_VTOUCH_HOST_H_
