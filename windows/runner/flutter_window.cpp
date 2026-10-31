#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"

#include "taskbar_progress.h"
#include "window_backdrop.h"
#include "window_frame.h"
#include "vtouch_host.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Snap Layouts 需要的子窗口命中测试重定向（见 window_frame.cpp）。
  mint::ApplyCaptionHitTest(
      GetHandle(), flutter_controller_->view()->GetNativeWindow());
  // 主窗口也走自绘框：摘掉 WS_CAPTION（否则材质模式下客户区透明时，
  // 最大化那圈 8px frame 会把原生三大金刚透出来，和自绘按钮重叠），
  // 保留 WS_THICKFRAME / MIN / MAX / SYSMENU —— DWM 的窗口动画不受影响。
  mint::ApplyCustomFrame(GetHandle(),
                         flutter_controller_->view()->GetNativeWindow());
  mint::AttachWindowChromeChannel(GetHandle(),
                                  flutter_controller_->engine()->messenger());

  // Sub-window engines created by desktop_multi_window ship without any
  // plugins. Register the generated plugin set for each new engine so
  // window_manager and friends work inside the log window too.
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    auto* view_controller =
        reinterpret_cast<flutter::FlutterViewController*>(controller);
    RegisterPlugins(view_controller->engine());

    // 子窗口（日志控制台）同样走自绘标题栏：去掉系统 caption，让
    // Flutter 侧画标题 + 系统图标的三大金刚。
    if (view_controller->view() != nullptr) {
      HWND view_hwnd = view_controller->view()->GetNativeWindow();
      HWND root = ::GetAncestor(view_hwnd, GA_ROOT);
      mint::ApplyCustomFrame(root, view_hwnd);
      mint::ApplyCaptionHitTest(root, view_hwnd);
      mint::AttachWindowChromeChannel(
          root, view_controller->engine()->messenger());
      // 虚拟触控悬浮层（`mint/vtouch` 通道）：每个子引擎各挂一份，只有
      // 悬浮层那个子引擎会调用它 —— 日志窗口的引擎从不触碰。通道里做
      // 窗口样式改造 / 命中区 / 游戏窗口跟踪 / 输入注入（见 vtouch_host）。
      mint::AttachVTouchChannel(root,
                                view_controller->engine()->messenger());
    }
  });

  // Windows taskbar progress (ITaskbarList3): install/download progress
  // and failure state.
  taskbar_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mint/taskbar",
          &flutter::StandardMethodCodec::GetInstance());
  taskbar_channel_->SetMethodCallHandler(
      [hwnd = GetHandle()](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        mint::HandleTaskbarMethod(hwnd, call, std::move(result));
      });

  // Mica / Acrylic / Tabbed / Aero window backdrop.
  backdrop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mint/backdrop",
          &flutter::StandardMethodCodec::GetInstance());
  backdrop_channel_->SetMethodCallHandler(
      [hwnd = GetHandle()](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        mint::HandleBackdropMethod(hwnd, call, std::move(result));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  taskbar_channel_ = nullptr;
  backdrop_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
