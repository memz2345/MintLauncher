#ifndef RUNNER_WINDOW_EFFECTS_H_
#define RUNNER_WINDOW_EFFECTS_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

G_BEGIN_DECLS

/// 窗口模糊的前置条件：合成器在跑且有 RGBA 可视区时，把顶层窗口换成
/// 可透明绘制（app_paintable + RGBA visual + 透明 draw 回调），并把
/// FlView 底色调成 #00000000，Flutter 视图的透明区域才能透出系统模糊。
/// 没有合成器（Xvfb / 无混成 X11）时什么都不做，窗口保持不透明黑底。
///
/// 必须在 gtk_widget_realize 之前调用（visual 要在 realize 前设置）。
void mint_backdrop_configure_window(GtkWindow* window, FlView* view);

/// 注册 `mint/backdrop` 方法通道，接口与 Windows runner 的
/// window_backdrop.cpp 对齐：
///   getCapabilities → {supported, blur, de, session}
///   setBackdrop {mode, dark, tint} → {applied, fallback}
///   reset / hideCaption → 无操作成功
///
/// Linux 的模糊实现（系统接口，与 Windows 走 DWM 同思路）：
///   · X11（含 XWayland）+ KWin → `_KDE_NET_WM_BLUR_BEHIND_REGION`
///   · Wayland + KWin 6.3+      → ext_background_effect_v1（标准协议）
///   · Wayland + 老 KWin/Plasma → org_kde_kwin_blur（KDE 私有协议）
/// GNOME / 其它合成器没有公开的按窗口模糊接口，能力探测会如实返回。
void mint_backdrop_register(FlView* view);

G_END_DECLS

#endif  // RUNNER_WINDOW_EFFECTS_H_
