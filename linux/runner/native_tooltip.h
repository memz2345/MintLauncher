#ifndef RUNNER_NATIVE_TOOLTIP_H_
#define RUNNER_NATIVE_TOOLTIP_H_

#include <flutter_linux/flutter_linux.h>

// mint/tooltip 方法通道：自绘标题栏的悬浮提示走 GTK 弹出层，
// 和 Android 的 PopupWindow 版 NativeTooltipHost 同一套 Dart 接口。
void mint_native_tooltip_register(FlView* view);

#endif  // RUNNER_NATIVE_TOOLTIP_H_
