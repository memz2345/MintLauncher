#ifndef RUNNER_WINDOW_CHROME_H_
#define RUNNER_WINDOW_CHROME_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

G_BEGIN_DECLS

/// Linux 自绘标题栏支撑（与 Windows runner 的 window_frame.cpp 对齐）：
///
///  · setCustomFrame {on: bool} —— gtk_window_set_decorated 反向。摘掉
///    GTK 原生标题栏，Flutter 侧画 MintCaptionBar（拖动 / 缩放走
///    window_manager 的 startDragging / startResizing，Linux 均已实现）。
///  · getWindowIcons {fg: int} —— 从当前 GTK 图标主题取三大金刚图标
///    （window-minimize/maximize/restore/close-symbolic），按 Flutter
///    传入的前景色着色渲染成 32px PNG 回传（键与内容一一对应；主题
///    没有对应图标时该键缺省，Dart 侧回退矢量绘制）。Windows 的金刚
///    字形来自 Segoe Fluent Icons，Linux 用系统图标主题 —— 同思路：
///    都让「窗口控制按钮的长相」跟随系统。
///
/// 必须在 gtk_widget_realize 之后注册（要用到顶层窗口）。
void mint_window_chrome_register(FlView* view);

G_END_DECLS

#endif  // RUNNER_WINDOW_CHROME_H_
