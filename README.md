# Mint Launcher

实验性多平台 Minecraft 启动器（Flutter）。**当前进度：Windows 端离线启动已跑通**（端到端实测 1.20.4 下载 → 启动 → 主菜单）；**Android x86_64 模拟器已实测 1.7.10 下载 → 主菜单 → 创建世界 → 进入游戏**；**Android arm64 真机（vivo V2403A / Android 16）已实测 1.7.10 / 1.15.2 点击进「选择世界」、a1.0.15（GL4ES）进主菜单并点开选世界、游戏内悬浮窗正常**。

[![CI](https://github.com/memz2345/MintLauncher/actions/workflows/ci.yml/badge.svg)](https://github.com/memz2345/MintLauncher/actions/workflows/ci.yml)

## CI（GitHub Actions，`.github/workflows/ci.yml`）

- **Linux 兼容测试（ubuntu-latest）**：analyze → 174 项单测 → `flutter build linux` →
  多段冒烟 —— ① **Xvfb**（纯 X11、软渲染 Impeller GLES，进程存活 20s+ + 截图）；
  ② **多场景截图巡游**（同一个 bundle 用环境变量钩子反复拉起：首页 / 下载中心 /
  设置 / 版本管理 / Fluent 风格 / 深色主题各截一张）；③ **weston headless**
  （`GDK_BACKEND=wayland` 走 Wayland 路径，无 KDE 模糊协议时能力探测如实降级）；
  ④ **KWin 模糊探针**（Xvfb 里跑真 `kwin_x11`，`MINT_TEST_BACKDROP` 启动即应用材质，
  `xprop` 验证窗口上真的出现 `_KDE_NET_WM_BLUR_BEHIND_REGION(CARDINAL) = 0`）。
  产物（全场景截图 + 应用 / 合成器日志）上传到 Actions artifact `linux-smoke`，
  构建产物上传为 `linux-bundle`。
- **Linux 游戏启动实测（独立 job）**：Xvfb + `LIBGL_ALWAYS_SOFTWARE=1 /
  GALLIUM_DRIVER=llvmpipe`（即「CPU 软件渲染」后端在 Linux 的实现路径）下跑
  `dart run tool/e2e_launch_test.dart 1.20.4` —— 清单 → 安装（库 / 客户端 /
  资源 / natives）→ 缺 Java 自动下载 Mojang Linux 运行时 → 起游戏进程 →
  观察 90 秒；通过标准 = 日志出现 `LWJGL Version` 且无主类异常。
  `MINT_E2E_MIRROR=official` 直连官方源（海外机器更快）。
- **Windows 构建与测试**、**Android Debug APK 编译检查** 同跑，防跨平台回归。

## 平台

| 平台 | 状态 | 启动方案 |
|---|---|---|
| Windows | ✅ 可用 | 普通 Java 进程（参考 HMCL） |
| macOS / Linux | 🧪 CI 兼容测试 | 同 Windows 逻辑；GitHub Actions（ubuntu）上构建 + Xvfb / weston headless / KWin 模糊探针持续冒烟（见 `.github/workflows/ci.yml`） |
| Android | 🧪 实验 | FCL 运行时（JRE8/JRE17 + LWJGL3/lwjglx + GL4ES），x86_64 模拟器与 arm64 真机均已跑通 1.7.10，targetSdk 37 |

## 界面（布局参考 FCL，标题栏移植自 local2api）

- **三套界面风格**：miuix（HyperOS）/ Material 3 Expressive / **Fluent（fluent_ui）**，
  设置里一键切换，路由栈不动。Fluent 走 Win11 风格侧栏（48 ↔ 220 可折叠）
  + FluentIcons + 4/6/8 圆角的形状语言，Material 叶子由 FluentTheme 桥接配色。
  - **Fluent 侧栏可折叠**：`FluentCollapsibleSideBar` —— 顶部汉堡按钮原位展开/收起，
    宽度 220ms `easeOutCubic`，状态落盘 `mint.fluentPaneExpanded`；折叠态只留 48dp
    图标栏，选中项左侧 3×16 accent 指示条（WinUI NavigationView 同款），
    **指示条带滑入 / 淡入动画**（AnimatedSwitcher，220ms easeOutCubic）。
    fluent 自带 `NavigationPane(compact)` 是**浮层**且展开状态藏在私有 State 里，
    没法持久化，所以宽屏自绘、窄屏继续走 `PaneDisplayMode.top`。
  - **卡面语言**：侧栏是一块浮起的 **8px 圆角卡片**（离窗口边缘 6px、1px card
    stroke、卡底色），照 QwenTtsMic 的 WinUI `CardStyle`（CornerRadius 8 +
    CardBackgroundFillColorDefault + CardStrokeColorDefault）抄的；不再用分隔线。

- **主页**：FCL 式布局 —— 左侧已安装版本列表，右侧常驻账户 / 当前版本 / 大号启动按钮面板；
  账户、版本管理、版本设置、内容管理全部是独立页面（不再用弹窗堆功能）。
- **标题栏**：
  - miuix：`MiuixTopAppBar` + `MiuixExitUntilCollapsedScrollBehavior` + 毛玻璃，
    滚轮 / 触控滚动时大标题收成居中小标题并钉住（local2api `MiuixBlurTopBar` 同款）。
  - Material：`ExpressiveSliverAppBar` 同款大标题折叠，滚动后收成毛玻璃工具栏。
  - 二级页用返回 + 小标题栏；日志页使用紧凑栏，不占大标题空间。
- **自绘窗口标题栏（Windows）**：真的摘掉 `WS_CAPTION`（不只是 `WM_NCCALCSIZE`），
  DWM 阴影/圆角/缩放保留；Flutter 画 44px 标题栏 —— 根页面是 Mint 徽标 + 应用名，
  二级小标题页把 **back / 标题 / 顶栏操作**托管到标题栏（HMCL 式），只显示一个主标题，
  页面内不再重复一条栏。back 与右上角三大金刚同宽同高、贴各自窗口边缘。
  三大金刚用 Segoe Fluent Icons（Windows 10 回退 MDL2）系统字形，颜色跟主题；
  四个按钮（返回 + 三大金刚）都有 90ms hover state layer 和 **按下水波**：
  最小化 / 关闭走 InkWell；最大化按钮在原生热区里，Flutter 收不到指针事件，
  由原生按下信号在按钮 Stack 里自绘扩散圆（Material 手动种 InkRipple 在
  当前树上实测画不出来），按下即见、松手才最大化。关闭按钮
  hover 仍变 Windows 红。支持拖动、双击最大化/还原、右键系统菜单、贴边缩放。
- **自绘窗口标题栏（Linux，2026-10-31 起）**：同一套 Flutter 44px 标题栏。
  `main.dart` 在窗口 show 之前调 `LinuxWindowChrome.ensureCustomFrame()` →
  runner（`linux/runner/window_chrome.cc`）`gtk_window_set_decorated(FALSE)`
  摘掉 GTK 原生装饰（不闪原生标题栏）；拖动 / 贴边缩放直接用 window_manager
  的 Linux 实现（`gtk_window_begin_move_drag` / `begin_resize_drag`）。
  **三大金刚图标 = 当前 GTK 图标主题的 `window-*-symbolic`**（Adwaita /
  Breeze / Yaru 都带）：Dart 把前景色传给 runner，`gtk_icon_info_load_symbolic`
  按 fg 着色渲染成 32px PNG 回传，Flutter 按 16dp 画 —— 换系统主题图标
  也跟着换皮，和 Windows 用 Segoe 系统字形是同一个思路；主题没有这组
  图标时回退 Material 矢量。悬停态 / 按下 ripple / 双击最大化 / 右键
  （Linux 走 Flutter 自绘菜单，没有 Windows 那套 GetSystemMenu）全部
  与 Windows 一致；日志子窗口在 Linux 保留 GTK 原生装饰（chrome 通道
  只注册在主窗口引擎上，避免双标题栏）。
  Win11 悬停最大化按钮会弹出 Snap Layouts（FlutterView 把该热区让给顶层
  `WM_NCHITTEST` 并返回 `HTMAXBUTTON`），该按钮的 hover / 点击由原生
  `mint/window_chrome` 回传给 Flutter，所以和另外两个金刚表现一致。
  **最大化也是松手才动作**：`WM_NCLBUTTONDOWN` 只回传按下信号种 ripple，
  真正的最大化 / 还原在 `WM_NCLBUTTONUP` 且光标仍在热区内时才执行，
  不会按下瞬间就把窗口顶上去、看不见水波。
  **窗口动画全部原生**：客户区由 `WM_NCCALCSIZE` 铺满整窗，`WS_CAPTION`
  在 `ApplyCustomFrame` 里摘掉（VS Code / Electron `titleBarStyle=hidden` 同款方案），
  DWM 的最小化收拢、最大化 / 还原缩放动画照常播放（实测抓帧确认有缩放中间帧）。
  早期那套 220ms 的 SetWindowPos 自绘动画已删除。
  - **叠影修复（材质模式）**：窗口材质开启后客户区是透明的，只要还留着
    `WS_CAPTION`/非客户区渲染，DWM 就会把**原生三大金刚**画在那圈 frame 上，
    透在自绘按钮底下 —— 最大化时最明显（截图里两个 ✕ 叠一起）。现在主窗口
    也走 `ApplyCustomFrame` 摘掉 caption，并在 `WM_SIZE` / `WM_NCACTIVATE`
    后补设 `DWMWA_CAPTION_COLOR=NONE` 兜底。
  - **返回箭头跟风格走**：`MintBackIcon` —— fluent 用 `FluentIcons.chrome_back`、
    miuix 用 `MiuixIcons.extended.byName('back')` 矢量图标、Material 用
    `Icons.arrow_back`；页面内顶栏与窗口标题栏共用同一份。`MintIcon` 支持
    `fluentSize`：Segoe Fluent 字形留白小，fluent 侧统一按 0.70 缩放
    （22 → 15.4），否则 22 的 `chrome_back` 比标题还壮。
  - **标题栏下载按钮**：位置在最小化左侧，**只在有下载任务时出现**
    （图标外圈是总进度环，点进下载管理页）；空闲时完全消失，不占位。
    页面托管的顶栏操作统一进 44×44 的动作槽 + 整条栏 `ClipRect`，
    修掉 M3 `IconButton` 48dp 最小约束上下溢出压住正文的问题。
- **PCL2 动效**：`PclHoverSurface` 照 `MyListItem` 移植 —— 悬浮底板 0.75→1
  缩放 + 淡入（120ms），离开 180ms 淡出后硬重置；按下整行 0.98。
  下载版本列表、加载器列表、版本管理左侧目录 / 右侧版本行都已接入。
  `MintCollapsibleCard` 照 `MyCard` 移植：90ms 阴影 / 标题色悬浮反馈，
  内容高度 240ms 缓动收放，箭头 250ms 旋转；**折叠状态按卡持久化**
  （`mint.card.<key>`，重进页面保持上次状态），**卡头点击带水波**
  （InkWell，Windows 下是 mdui 涟漪）。
- **mdui 涟漪（Windows / macOS / Linux）**：`lib/widgets/mdui_ripple.dart`
  照 mdui v1 源码（`mdui@1.0.2` npm 包 dist/css + src/components/ripple）逐项
  还原的 `InteractiveInkFeature` —— **直径 = max(元素对角线, 48px)**；按下时
  wave 锚在按下点、**1400ms ease 一边放大一边滑到元素中心**（v1 的
  `translate3d(-x + w/2, -y + h/2, 0)` 就是做这件事，最终是「居中 + 对角线
  直径」的整圆，必然盖满整行）；松手先 `.fill`（300ms，opacity → 0.35，
  同时把未完成的扩散快速落位），再 `.out`（600ms，opacity → 0），
  没有 v2 式的快速 cancel。颜色统一 M3 按压态档位（`mintSplashColor`：
  浅色黑 10% / 深色白 10%，mdui v1 深色的 0.3 白太浓会盖内容；
  各组件一律走这个函数，不要手写 splash alpha）。挂进
  `ThemeData.splashFactory`（`mintSplashFactory`），InkWell / Material 全局
  生效；窗口标题栏的原生点击热区手动种 `MduiInkRipple`。移动端
  （Android / iOS）保持 Flutter 原生 InkRipple。
- **虚拟触控悬浮层（Windows，设置 → 虚拟触控）**：照 Android OSD 做一套
  桌面版 —— 悬浮球 + 可自定义摇杆 / 按键（同一份布局 JSON，默认键位名
  E / ESC / SHIFT / SPACE / LMB / RMB…，旧中文标签按 id 自动迁移）。实现是
  `desktop_multi_window` 子窗口：原生 `vtouch_host.cpp` 把它改成
  `WS_POPUP | TOPMOST | TOOLWINDOW | NOACTIVATE`，每 500ms 按游戏 PID
  跟踪游戏窗口 client rect，并用 `SetWindowRgn` 把命中区裁成各控件矩形 ——
  控件之外点击直接穿到游戏。启用 + 自动显示时游戏启动就唤起，游戏退出 /
  最小化自动收起；键盘走 SendInput、鼠标键 PostMessage 直发游戏窗口。
  **踩坑**：隐藏启动的子窗口里，`desktop_multi_window` 的插件通道是原生
  在窗口创建之后才注册的，Dart 侧第一次 `ready` / `setMethodCallHandler`
  / `apply` 都会撞 `MissingPluginException` 或 `CHANNEL_UNREGISTERED` ——
  `vtouch_overlay.dart` 的 ready / fromMain / apply 三处都有 300ms 重试，
  别把重试删了（删了表现就是「悬浮层永远不出现」）。
- **弹窗三风格**：`MintStyleDialogShell` / `mintDialogActions` /
  `MintStyleTextField`（common.dart）—— 同一套业务弹窗按界面风格分流：
  miuix → 28px 圆角 HyperOS 卡 + MiuixButton/MiuixTextField；fluent →
  Win11 ContentDialog 观感（8px 圆角 + FluentTheme 资源色 + fluent
  Button/FilledButton/TextBox/fluent.ListTile）；Material → AlertDialog /
  SimpleDialog / TextField。确认 / 文本 / 输入类弹窗保留；设置页里所有**
  带选项**的弹窗改成共用母页 `MintChoicePage`（`pushMintChoicePage`）——
  推入独立页面、卡片列表 + 当前项打勾，选中 pop 回值，业务代码不变。
- **下载 / 设置是独立页面**：底部导航 / 侧栏的三个入口（首页 / 下载 / 设置）
  里只有首页是常驻 tab；下载点 `openDownloadHub()`、设置点 `openSettings()`
  推入带返回的二级页（HMCL 式），页面顶栏不再挂副标题。
  窄屏底栏换成 **local2api FloatingBottomBar 同款悬浮胶囊**（InstallerX 移植）：
  毛玻璃胶囊 + 主色 15% 指示器，可横向拖动跟手切换、松手吸附；从下载 /
  设置返回时底栏重建、指示器归位首页。
- **设置页（HMCL 式左类右内容）**：不再是一级 tab；底部导航 / 侧栏的
  「设置」改为 `openSettings()` 推入新页面。页面用 `MintPageScaffold`
  小标题 + 左侧大类卡（启动 / 网络 / 外观 / 快捷键 / 关于）与右侧内容区；
  窄屏大类改成横向胶囊。设置页里每个带选项的项都进入共用的
  `MintChoicePage`（同一个母页，内容不同）。
- **窗口动画回归修复（WS_CAPTION）**：材质叠影那轮把 `WS_CAPTION` 摘掉了，
  结果 DWM 的最小化收拢 / 最大化还原动画跟着消失（动画依赖 caption）。
  现在 `ApplyCustomFrame` **恢复并钉住 WS_CAPTION、摘掉 WS_SYSMENU**：
  三大金刚按钮本质是系统菜单的 UI，没有 WS_SYSMENU 它们在样式层就不存在
  （Raymond Chen：想去掉 Close 只能去掉系统菜单）——带 backdrop 的窗口
  DWM 会把系统菜单按钮画在材质层上，`DWMWA_CAPTION_COLOR=NONE` 与
  `DWMNCRP_DISABLED` 都压不住，唯独样式层消失才根治（「金刚重影」终版
  方案）。动画照常播放（SC_MINIMIZE/MAXIMIZE 靠 MINIMIZEBOX/MAXIMIZEBOX，
  两个位保留）；自绘标题栏右键改为调用**原生系统菜单**（`GetSystemMenu` +
  `TrackPopupMenu`，还原/移动/大小/最小化/最大化/关闭与 Alt+F4 提示都由
  Windows 提供），通道不可用时才回退 Flutter 自绘菜单；
  `WM_NCCALCSIZE` 整窗客户区 + `WM_NCACTIVATE` lParam=-1 +
  `WM_NCUAHDRAWCAPTION/FRAME` 吞掉继续做防御。关闭材质时
  `ResetSystemBackdrop` 会把 NC 渲染恢复回 `USEWINDOWSTYLE`。
- **双风格**：MiuixThemeController 在根部分流，`UiStyle` 决定渲染 miuix（HyperOS）还是 Material 3 的叶子；
  MaterialApp/Navigator 不重建，换风格路由栈不动（InstallerX 同款架构）。
- **换风格要「原地换肤」**：`MintUiStyle.current` 是静态变量，读它的 widget 不登记依赖；
  页面又把 `miuix: Boolean` 当**构造参数快照**在推入时求值一次 —— 于是已入栈的页面
  还是旧风格（Android 上表现为「改了一版」，得退出重进）。现在根上挂
  `MintStyleScope`（InheritedWidget，`lib/ui/mint_icons.dart`），渲染决策一律
  `mintMiuixOf(context, widget.miuix)` / `mintFluentOf(context)`：有 scope 时以它为准
  并登记依赖（风格一变整栈一起重绘），只有在**没有 scope** 的场合（widget 单测直接
  pump 一个页面、挂在 MaterialApp 之外的浮层）才退回构造参数。
- **Material 顶栏 = 浮在内容上的渐变模糊栏**（local2api 同款）：二级页小标题栏
  不再占布局空间，改成 `Stack` 浮层 + 内容 `top` 让出栏高，底下垫满强度
  `MintProgressiveBand(maxSigma 12, tintAlphaTop 0.75, intensity 1)`，内容滚到栏下
  是渐渐糊掉而不是撞硬边；标题 16/w600。门槛 `progressiveTopBar` **且**
  `ImageFilter.isShaderFilterSupported`（渐进模糊是 `ImageFilter.shader` 实现的，
  软渲染上会退化甚至不生效，那种情况直接回实心栏）。
- **页面转场**：`ios_push_transition.dart` 全套照搬 —— MiuixNavSettleCurve、旧页视差 + alpha 衰减、
  圆角落位收直、预测式返回跟手。
- **miuix 越界滚动**：整体位移 + Folme 弹簧回位（MiuixOverscrollBehavior）。
- **动态取色**：dynamic_color → 同时喂 M3 种子与 miuix keyColor；miuix→Material 色桥保证两套不打架。
- **拉伸热区（Windows）**：`MintWindowResizeFrame` 在窗口四边画 5px 透明
  热区接管拖拽（自绘窗口后 Flutter 子窗口吃掉原生 WM_NCHITTEST），
  拖动时调 `windowManager.startResizing`。**最大化 / 全屏时热区整体收掉**
  （`startResizing` 走 NC 尺寸循环、不查 IsZoomed，最大化还能拉伸会把
  客户区拉错位，内容「断头」）——热区收掉 + `onPanStart` 双保险；原生
  `CalcClientArea` 同时加固成「窗口矩形 ∩ 工作区」，就算被外力拉伸，
  客户区仍与可见窗口对齐，不会错位出画。
- **滚动条策略**（`MintScrollbarBehavior`，三套风格共用）：Material 默认给
  每个滚动体包 Scrollbar，浮动大标题页的内容从毛玻璃标题下滑过时滚动条
  会跟着探进标题里 —— 通过 `MintFloatingTitleScope` 标记浮动标题页，
  这些页面的纵向滚动条直接不画（滚轮 / 键盘照常，local2api 同款观感）；
  其余滚动体照常 hover 出滚动条。
- **主页（2026-10-25 改版）**：右侧一列信息 —— **离线账户列表**（点名字切换、
  底部进账户管理）+ **版本管理**一条（副标题显示当前启动版本）+ 右下角
  **启动游戏 FAB**（准备中变「取消启动」带进度环，运行中变红色「结束」；
  Windows 下按本进程 PID 定向 `taskkill /T /F` 杀整棵进程树 —— javapath 的
  `java.exe` 只是 Oracle 启动器 wrapper，真正的 JVM 是它的子进程，只杀
  wrapper 会留下孤儿游戏窗口；始终只动 Mint 拉起的 PID，绝不按进程名扫
  别的启动器实例。用户主动结束不算崩溃，不弹崩溃分析）。
  不再区分横竖屏，中间完全留空只露页面背景 / 窗口材质；顶部不显示大标题
  与 Mint 徽标。**版本管理页点击版本 = 选中并回主页**（PCL 版本选择同款）；
  管理操作（启动 / 设置 / 重命名 / 删除）走行内按钮与右键菜单，不弹页。
- **页面背景**（`lib/ui/widgets/page_background.dart`，G:\192\local2api 的
  `PageBackground` 同款移植）：所有页面壳（`MintPageScaffold` 两套风格）的
  Stack 最底层铺一块画布 + 可选自定义图片（`Image.file` + `BoxFit.cover`，
  支持整体不透明度 0~100% 与 0~24 高斯模糊，按屏幕分辨率限解码尺寸）。
  设置 → 外观 →「页面背景图」开关 / 换图 / 滑块。没启用图片时一个像素都不
  多画（观感与从前一致）；启用后页面内容与标题栏浮在同一张图上，
  透明层不再互相叠出脏色。背景图路径 / 开关 / 滑块值都落盘
  `launcher_config`（`pageBackground*` 键）。
- **云雾前景**（`lib/widgets/mint_cloud_foreground.dart` +
  `shaders/cloud_foreground.frag`）：主页之上飘动的白色液态云雾，视觉参考
  Kimi（月之暗面）K3.1 Pro 博客页头（<https://www.kimi.ai/blog/kimi-k3-1-pro>，
  页头那几层 PNG 素材有版权不能入库，观感程序化复现）：
  - **shader 思路**：5 阶 fbm + 两层 domain warping（IQ 配方）拧出大理石
    漩涡等高线，再叠 `sin(v)` 等值线刻纹随时间慢滑 —— 对应 Kimi layer-1
    的「柔雾里藏纹」；云的形状来自双层 blob 密度场（远层大而慢、近层小
    而快 = 视差），云团水平 `fract` 回绕永不飘出画面，四边羽化 + 上半屏
    偏置保证它是氛围不是主角。
  - **性能**：shader 先光栅到 1/2 边长的离屏图（`Picture.toImageSync`，
    GPU 侧）再线性放大（片元开销 ~1/4）；Ticker 按 30fps 量化；页签切走
    （PageView 保活但不上屏）时「没画就不推进时间」，完全不烧 GPU；
    `TickerMode` 关闭时 Ticker 直接不响。
  - **可读性**：整层 `IgnorePointer` 不挡交互；实际透明度按深浅主题打折 +
    硬上限封顶（深 0.34 / 浅 0.55，出厂默认算出来约 0.23 / 0.34），
    绝不盖内容（mdui_ripple 的前车之鉴）。
  - 设置 → 外观 →「云雾前景」开关 + 不透明度 / 云团密度滑杆；值落盘
    `launcher_config`（`cloudForeground` / `cloudOpacity` / `cloudDensity`
    键）。shader 加载失败时安静地不画（纯装饰）；复用方式见 widget 头注释
    （任意 Stack 里 `Positioned.fill(IgnorePointer(MintCloudForeground(...)))`，
    参数化 blob 密度 / 漂移速度 / 透明度 / 上半屏偏置 / 种子）。
- 布局：≥768px 桌面侧栏（首页 / 下载 / 设置三个入口），窄屏悬浮胶囊底栏；
  下载 / 设置推入独立页面，返回后停在首页。Ctrl+1…3 仍可直接打开对应页面。
- **下拉刷新**：Material 走 local2api 的 `M3EPullToRefresh`（顶栏下浮出 M3E
  形变指示器，内容原位）；miuix 走 `MiuixPullToRefresh`（指示圈 + 文案把页面
  元素整体下推）。原版 / 加载器 / OptiFine / Modrinth 搜索 / 版本管理都接好了；
  **顶栏刷新按钮与手势下拉共用同一个加载方法**——手动刷新时指示器同样出现
  （`MintRefreshController.refresh()`，local2api 的同款接线）。可滚动体统一用
  `AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics())`。
- **下载页点击动画**：版本行 / 加载器行保留 PCL2 悬浮缩放，Material 风格下
  点击叠一层 Flutter 原生 InkRipple（`PclHoverSurface(ripple: true)`，非自绘）；
  miuix 风格保持自己的按压遮罩。
- **窗口材质（Windows 10+）**：云母 Mica / 亚克力 Acrylic / 标签页 Tabbed / Aero，
  由 runner 原生调用 DWM（Windows 11 22621+ 用 `SYSTEMBACKDROP_TYPE`，22000 用
  `MICA_EFFECT`，Windows 10 用 `SetWindowCompositionAttribute`）。窗口透明 + Flutter
  半透明页面，设置里可调玻璃底色不透明度；关闭后回到纯色窗口。
  材质模式下自绘标题栏保持完全透明。**不要**把 DWM frame 向顶部延伸（margins
  用 `{-1,-1,0,-1}`）：上边框一旦铺进客户区，DWM 会在客户区顶部画一条原生 caption；
  `DWMWA_CAPTION_COLOR=NONE` 在 Win11 的部分激活时序下会被忽略。顶部交给 Flutter
  的半透明标题栏；首帧前后 / 获得焦点时还会补设 caption NONE 兜底。
  `--dart-define=MINT_WINDOW_EFFECT=off|mica|acrylic|tabbed|aero` 可强制某一种，
  `MINT_BACKDROP_CLEAR=true` 去掉 Flutter 侧底色（诊断用）。
- **窗口材质（Linux，2026-10-31 起）**：与 Windows 同思路 —— 用**系统提供的
  模糊接口**（`linux/runner/window_effects.cc`，通道同为 `mint/backdrop`）：
  - X11（含 XWayland）+ KWin → `_KDE_NET_WM_BLUR_BEHIND_REGION` 原子；
    KWin 读到 0 / 1 个 cardinal 即整窗模糊（kwin `updateBlurRegion` 同款），
    不用跟着 DPI / 窗口尺寸重算矩形；
  - Wayland + KWin 6.3+ → `ext_background_effect_v1`（wayland-protocols 标准
    协议，NULL region = 移除、双缓冲随 surface commit 生效）；
  - Wayland + 老 KWin / Plasma 5 → `org_kde_kwin_blur`（KDE 私有协议）；
    两份协议 XML 在仓库里（`linux/runner/protocols/`），由 wayland-scanner
    构建期生成代码，缺 scanner / libwayland-client 的环境自动降级纯 X11；
  - 整窗模糊提交**超大矩形**（KWindowSystem `installBlur` 同款），窗口
    改尺寸不用重新提交；
  - 前置条件：有混成器时把顶层窗口换成 RGBA 可视区 + `app_paintable` +
    透明 draw 回调 + FlView 底 `#00000000`（flutter-acrylic 同款姿势），
    无混成（Xvfb / 关闭混成）保持黑色不透明底；
  - GNOME / Mutter 等没有公开的按窗口模糊接口 → 能力探测如实返回不可用，
    设置页显示「当前桌面环境没有公开的窗口模糊接口」；四种 Windows 模式在
    Linux 上收敛成「关闭 / 窗口模糊（系统）」两项（都落到 KWin 的同一实现，
    存的仍是 acrylic 档）；`--dart-define=MINT_TEST_BACKDROP=acrylic|mica…`
    启动即应用（CI 的 KWin 探针用 xprop 验证原子真的设置上）。
- **鼠标 / 键盘**：Esc、鼠标侧键、Alt+← 返回；F11 全屏；Ctrl+1…3 切换一级页；
  Ctrl+F 搜索；Ctrl+M 版本管理；F5 刷新；版本列表 ↑↓ 选择、Enter 启动、
  F2 重命名、Delete 删除。**启动准备阶段按 Esc / 启动窗口「取消」中断启动**
  （取消会传播到下载器，.part 分片直接作废）。设置页底部有快捷键一览。
- **到顶 / 底轻震**：移植 local2api `EdgeScrollHaptic` —— fling 撞到列表边界轻震，
  250ms 冷却；主应用可在设置里关，独立日志窗口默认开启。
- **独立日志窗口**：自绘标题栏（关闭/最小化/最大化在右上）；顶栏只剩四张
  local2api 风格级别卡（全部 / Info / 警告 / 错误，实时计数）和最右侧「自动滚动」
  switch。游戏日志按级别分成 4 个 PageView 页面，支持左右滑动，切页动画与主页
  `kPageTransitionDuration/kPageTransitionCurve` 一致；启动器日志仍在下方分隔栏。
  **游戏退出后约 1 秒自动收起日志窗口**（期间重新启动新游戏则保留）；子窗口
  引擎常驻，下次启动游戏时清空上一会话内容再显示，不需要重启启动器就刷新
  日志（`clear` 会同时把批量推送定时器置空，否则新会话日志永远不推送）。
- **关于页 = 反编译「我的设备」页**（2026-10-30 重排，`about_page.dart`）：
  把 MIUI 设置（`设置_15.apk`，jadx 反编译）的「我的设备」页搬了进来 ——
  - **两段式缩放动画**：`MintMyDeviceAnimation` 逐行对照反编译的
    `MyDeviceAnimationController.startAnimation` 移植 —— 滚动时标题块先按
    stage1 缩到 0.9 并淡出（`1 - (actionBarPadding/logoPadding)·stage1`），
    滚过 logoPadding 后 logo（主题字标 / M 徽标）再按 stage2 缩放淡出，
    pivot 都取自身中心；收起态小标题在 stage2 打满时钉进顶栏
    （反编译里是二值显示）。几何比例（`my_device_os_logo_area_height` /
    `my_device_logo_bottom` / `my_device_logo_height`）映射成
    88 / 128 / 104 三档行程；
  - **一整块大卡**：主题描述 + 主题 / 作者 / 设计师 / 版本 / 资源 / 壁纸 /
    主题包来源 + 高级设置行全部收进同一张卡（系统「我的设备」页下面那块
    信息大卡的同构），行间是 mint 分隔线；
  - 背景解析顺序：预览器指定给「关于」的图 > 主题声明的设置窗口背景 >
    全局自定义 / 主题壁纸。
- **竖屏「更多」页**（`more_page.dart`）：底栏第三项就是这页（与首页 /
  下载同级的常驻 tab，2026-10-30 起**不再 push**），三个列表项 —— 设置 /
  主题设置（MIUI）/ **下载器**（下载器点了切到下载一级分页，**不是新页面**）。
- **底部弹窗背景图**（`mintSheetBackgroundPathOf`）：miuix / Material /
  Fluent 共用的底部动作单（`showMintActionSheet`）现在铺「弹窗声明的背景」
  —— 预览器指定给「底部弹窗」的图 → 主题**弹窗级**声明（mtz 里弹出的拨号
  面板自带一张弹窗背景 `dialerpad_background`，浅蓝芙宁娜那张，比整屏
  window_bg 更对味，按明暗取对应声明）→ 退回主题声明的设置窗口背景。
  图按 cover + 贴底对齐（角色立绘通常在底部），顶部一道同色渐变压出手柄 /
  标题可读性。
- **关于页顶栏与其他页对位**：返回键换成与其他二级页**同组件同几何**
  （miuix → `MiuixSmallTopAppBar`，Material → 同规格 56 小栏），展开态
  只有返回键浮在页头上；滚动时叠一条渐进模糊带（强度 = stage1 渐入），
  完全折叠后栏中央渐显「关于」—— MIUI 关于页收起时 actionBar 带模糊
  渐入的同款行为。**底部留白 = 半个视口**：关于页内容不满一屏，没有这段
  行程就滚不出两段式收起（stage1+stage2 要 232px），收起态小标题永远
  出不来。
- **对话框 controller 的 dispose 时机（重要踩坑）**：`showDialog` 返回时
  退场动画**还在播**，外面立刻 `controller.dispose()` 会在动画 tick 重建
  仍在树里的 TextField 时对已 dispose 的 controller `addListener`
  （`debugAssertNotDisposed`）→ build 期红屏 + 文本度量乱掉来一个
  99731px 的 RenderFlex 溢出。输入类对话框一律用 **StatefulWidget 持有
  controller**（State.dispose 在路由完全结束后才跑）——
  `showMintInputDialog`、下载其他文件的 URL 对话框已改，新代码照这个写。
  另：部分 ROM / 模拟器镜像吞 logcat，`main.dart` 把 Flutter 异常同步落
  到数据目录 `flutter_error.log`（`run-as dev.mint.mint` 直接读）。
- **「更多」是常驻 tab**：与首页 / 下载同级（PageView 第 2 页，窄屏底栏 /
  宽屏侧栏 / Ctrl+3 一致），不再 push 新页面；页内「下载器」直接发 tab
  切换请求。「更多」没有专属按页背景（scope 空键 = 回落全局 / 主题壁纸）。
- **下载页任务区**：「下载管理」+「导入整合包」两行（窄屏卡片 / 宽屏左栏）；
  「下载其他文件」合并进 FAB —— 右下角 ＋ 直接进入下载流程：**Android 用
  公共下载目录 `/sdcard/Download/Mint`**（应用已声明
  MANAGE_EXTERNAL_STORAGE，FCL 同款，建不出目录回落应用数据目录），
  桌面端弹系统目录选择器（默认定位上次用的目录并记忆）。miuix 风格下
  FAB 用 `MiuixFloatingActionButton`（HyperOS 同款圆钮）。

## MIUI 主题包（.mtz，完整还原）

设置 → 外观 → **MIUI 主题包**（独立页面）：导入 `.mtz` 后按主题**声明的模块**
逐项还原，而不是只换一张壁纸。

- **解析**（`lib/services/theme_package.dart`，archive 解包 + xml 解析）：
  - `description.xml`：标题 / 作者 / 设计师 / `version` / `uiVersion` / 描述；
  - `wallpaper/`：桌面 + 锁屏壁纸（`default_wallpaper` / `default_lock_wallpaper`）；
  - **全模块背景图**（`backgrounds/`，assetsVersion 3 新增）：每个应用模块声明的
    整屏 / 页面背景（`window_bg` 家族 + `dialerpad_background`（拨号盘浅蓝芙宁娜
    那张）/ `conversation_bg` 等）按「模块 + 资源名 + 明暗」去重收集（同名资源
    多 dpi 只留最清晰的），背景预览器 / 按页背景 / 弹窗背景都用这份列表；
    **.9.png 的引导边**（mtz 里是没被 aapt 编译的源图，四周一圈黑线 + 透明角）
    由 `services/nine_patch.dart` 在主 isolate 裁掉 1px 缓存成 `*_9crop.png`
    （导入 / 补解完成后统一跑，没裁完先按原图展示）；
  - 各模块 zip 里的 `theme_values.xml`（含 `nightmode/`）：颜色 / 字符串合并成
    `colors` / `strings`（这个主题 341 条颜色、15 个模块）；
  - `icons`：按包名的应用图标（80 个，详情页按包名预览）；
  - `boots/bootanimation.zip`：解到 `<主题>/bootanimation/`（desc.txt + partN）；
  - `fonts`（若有）：ttf/otf 提取为 `font.<ext>`；
  - `preview/`：主题预览图；结果写 `theme.json` 缓存，重进不重新解包。
- **生效方式**（设置 → 外观 → MIUI 主题包 → 应用主题）：
  - **壁纸** → 所有页面的 `PageBackground`（`themeUseWallpaper`；用户自己选的
    背景图优先。主题壁纸默认 62% 不透明度 + 6px 模糊，保证正文可读）；
  - **主色** → 从 `miuix_color_blue_light_primary_default` /
    `design_default_color_primary` 等标准名里挑，否则取最鲜艳的声明色；
    同时喂 miuix `keyColor` 与 Material / Fluent 的种子色（`themeUseAccent`）；
  - **字体** → 启动时 `FontLoader` 注册成 `MintThemeFont`，Material 的
    `TextTheme` 与 miuix 全套 `MiuixTextStyles` 都套上（切字体需重启应用）；
  - **开机动画** → Android 启动游戏时，`GameLoadingOverlay` 播
    `boots/bootanimation.zip`（`BootAnimation.kt`：支持 `c`/`p` 分段、fps、
    pause、循环最后一组），游戏出第一帧自动收起；解析失败退回原加载层。
- **Android 文件选择**：DocumentsUI 会按 MIME 把不认识的 `.mtz` 置灰，
  所以 Android 端 `file_selector` 用 `*/*` 放开过滤；选中的 `content://`
  先 `XFile.saveTo` 落到缓存临时文件再解包（用户反馈「能选但导入没反应」
  的根因就是解包跑在主 isolate 上、78MB 的包把界面卡死了）。
- **导入不卡界面**：`extractMintTheme()` 是纯函数，整个解包/校验/解压丢进
  `Isolate.run`；主 isolate 只显示进度卡、收结果后 `notifyListeners`。
  sha1 分块计算，避免整读 78MB 占内存。
- **回归钩子**：`--dart-define=MINT_TEST_IMPORT_THEME=<mtz 绝对路径>` 启动时
  自动导入并应用（真机把包 push 到
  `/sdcard/Android/data/dev.mint.mint/files/`）；`MINT_TEST_APPLY_THEME=true`
  应用第一个已导入主题；`MINT_TEST_PAGE=theme` 直接落到主题页。
- **单测**：`test/theme_package_test.dart` 用真实 `1.mtz` 断言标题 / 主色
  (#FF60C0FD) / 80 个图标 / 壁纸 / 开机动画 / 颜色条数与缓存重载。
- **背景图预览器**（`theme_background_preview_page.dart`，主题页 →「背景图」）：
  主题包里所有「应用声明背景」按左右滑动整屏铺开（PageView + 双指缩放，
  底部缩略图条可跳页）—— 桌面 / 锁屏壁纸 + 各模块的 `window_bg` /
  `dialerpad_background` / `conversation_bg` 等（浅色、夜间分开计）。
  任意一张都能通过「设为 …」chip 指定到启动器的某个页面：**首页 / 下载 /
  下载管理 / 设置 / 主题 / 关于 / 底部弹窗**（再点一次取消）。按页背景落盘
  `launcher_config` 的 `pageBackgroundAssignments`（页键 → 图路径），
  `PageBackground` 解析顺序 = 按页指定 > 全局自定义背景图 > 主题壁纸
  （`MintPageBackgroundScope` 挂在页面壳 / 首页外壳上，窄屏壳按当前 tab
  切换 home/download 两把钥匙）。已指定的图在缩略图上带蓝点亮标记，
  当前页头显示「已用于 …」。

## 版本管理（多游戏目录）

「版本」页右上角的文件夹图标，或主页「管理版本」/ Ctrl+M 会推入独立的版本管理页
（HMCL「实例管理」/ FCL 版本列表布局）：

- **侧边选项卡片（可折叠）**：版本管理的「游戏目录」、版本设置的「分类」共用
  `MintCollapsiblePane` —— 圆角卡面（fluent 8 / miuix·Material 20）+ 头部一行
  标题（页面动作按钮也在这一行）+ 折叠按钮；展开 ↔ 56dp 图标栏，220ms 收放，
  收起后只剩图标 + tooltip，状态按 `mint.pane.<key>` 各自落盘。
  默认都**展开**（`defaultExpanded: true`），页面自己的 `storageKey` 互相独立。
  窄屏改成和其他页面一致的单列页面：游戏目录卡 +「已安装版本」区块 + 搜索 /
  筛选 + 版本卡片；「更多」操作从底部动作单弹出（欠阻尼弹簧曲线，不再是居中对话框）。

- **左侧**：游戏目录列表（可添加、切换、移除，移除不删磁盘文件；每个目录各自记住选中版本）。
- **右侧**：当前目录的版本号列表，支持搜索、加载器筛选（全部 / Fabric / Forge / NeoForge / 其他）、
  启动 / 运行中停止、版本设置、管理内容、打开目录、重命名 / 复制 / 删除，
  以及 **「安装加载器 / OptiFine」**（HMCL 同款：对已安装的版本补装
  Fabric / Forge / NeoForge / Quilt / OptiFine，生成继承原版本的新版本，
  装完自动选中 —— 下载页不再放加载器入口，统一从这里补装。点击后推入
  **独立的「安装加载器」页**：只列该 MC 版本可用的加载器与构建，
  选好后 FAB 先返回上一级、安装转后台，不再叠两个连续弹窗）和
  **「导出整合包」**（反编译 PCL2 2.14 `PageInstanceExport` 后对齐实现，
  详见下文「整合包导出」；**OptiFine 因许可证不再分发，跳过并在包内
  「安装说明.txt」注明**；进度走后台任务）。
- **版本设置**照 PCL2 `PageInstance` 改成左右两栏：左侧版本信息 + 概览 / 启动 / 高级，
  右侧是当前分类的内容；概览里汇总内存 / Java / 游戏目录 / 模组数并给管理内容入口，
  窄屏自动换成顶部分段选择。
- 版本设置按「游戏目录 + 版本 id」分键，同名版本在不同目录里互不影响。

### 整合包导出（反编译 PCL2 2.14 `PageInstanceExport` 对齐实现）

入口：版本管理 → 右键菜单「导出整合包」（`modpack_export_flow.dart` 的三风格弹窗）。
反编译确认 PCL2 2.14.0 的导出**只有 Modrinth 一种格式**（zip 根放
`modrinth.index.json` + `overrides/`，扩展名 .mrpack；没有 CurseForge manifest 导出），
Mint 对齐这一行为并保留旧版 CurseForge 格式作为兼容选项：

- **格式选择**：默认 Modrinth（.mrpack，PCL2 2.14+ 同款、体积更小、生态更好）；
  可切回 CurseForge 兼容 .zip（manifest.json + overrides/）。两种格式都带包内
  「安装说明.txt」。
- **导出内容勾选**（PCL2 `ExportOption` 同思路，顺序即规则优先级）：游戏本体设置
  （options.txt / configureddefaults / OptiFine 设置）、游戏本体个人信息（默认不勾）、
  模组（mods / coremods / lib，自动避开 .disabled / .old）、已禁用的 Mod（默认不勾）、
  整合包重要数据（kubejs / openloader / scripts / datapacks / patchouli_books 等社区
  整合包常见目录，PCL2 收录的规则原文逐条对应）、Mod 设置（config / defaultconfigs，
  自动避开 JEI 世界数据、spark 会话、Essential 账号缓存等隐私内容）、TaCZ 枪包、
  沉浸画 / 地图 / JEI / EMI / 帕秋莉个人信息（默认不勾）、资源包 / 光影包
  （**按世界 / 单包生成子项，可单独反选**）、光影包设置（shaderpacks/*.txt）、截图
  （默认不勾）、导出的结构（schematics）、录像回放（默认不勾）、单人游戏存档
  （按世界生成子项）、Licence 文件、服务器列表（servers.dat）。
  模组类选项只在可安装模组的版本出现，光影包在模组或 OptiFine 版本出现
  （PCL2 RequireModLoader / RequireModLoaderOrOptiFine 门控）。
- **收集模型**：不再用固定目录白名单，而是 PCL2 的规则引擎 —— 递归扫游戏主目录，
  每个文件按「选项规则 + 默认排除（\*.log / \*.dat_old / hmclversion.cfg / log4j2.xml /
  session.lock 等），靠后的行覆盖靠前的、`!` 反选」决定收不收；`assets` / `versions` /
  `libraries` 只在主目录根部跳过，`.git` / `.fabric` / avatar-cache 等缓存目录无条件
  跳过。版本隔离时 `versions/<id>/` 里的版本 jar / json 不命中任何包含规则，自然不进包。
- **联网匹配（仅 Modrinth 格式，可关）**：mods / 资源包 / 光影包 / 数据包里的
  jar/zip/rar 按 sha1 到 Modrinth `POST /v2/version_files` 批量反查（PCL2 同款接口），
  查到的文件**不打包**、只把下载直链写进 `modrinth.index.json`（sha1 + sha512 + fileSize），
  包体大幅缩小；查不到的（小众 / 自制 Mod）原样进 overrides。联网失败自动回退为
  全部直接打包并在完成提示里注明。
- **依赖写法**：Modrinth index 的 dependencies 写 minecraft + forge /
  fabric-loader / neoforge（quilt-loader 是 Mint 对 PCL2 的补充，PCL2 2.14 漏写 quilt）；
  CurseForge manifest 写 modLoaders id（`forge-47.2.0` / `fabric-0.16.9` …）。
  OptiFine 两种格式都不打包（许可证 + PCL2 页面提示「受 Modrinth 整合包规范限制，
  导出的整合包中不会包含 OptiFine」）。

## 下载与安装

- **下载与安装**（下载中心照 PCL2 `PageDownload` 结构重排）：
  - **后台下载 + 下载管理页**（参考 PCL2 `PageDownload` / `NetTask` 那套任务队列）：
    - `DownloadCenter`（`lib/services/download_center.dart`）是全局任务队列：每条任务有
      标题 / 当前文件 / 字节进度 / 文件计数 / 速度 / 剩余时间 / 状态（下载中 / 已完成 /
      失败 / 已取消），100ms 节流通知，最多留 30 条历史。
    - `Downloader` 接一条任务当进度出口（`task:` 参数）：`runBatch` 铺总量、
      `_downloadOne` 每读一个 chunk 就 `addBytes`，本文件写完 `fileDone`。
    - `LauncherController` 的安装 / 加载器 / JRE / Modrinth 下载都会自动开任务；
      `VersionInstaller` 的粗粒度进度通过 `task.setPhase()` 覆盖字节进度
      （解压、校验阶段字节数不涨，但阶段在推进）。
    - **安装默认转后台**：点「开始安装」后立刻离开配置页，不再自动进安装进度页；
      进度只看标题栏下载按钮 / 下载管理页，完成后短提示并自动选中新版本。
    - 下载管理页（`DownloadManagerPage`）：顶部总进度 / 总速度 / 全部取消，
      下面按「正在下载 / 已完成」分组，单条可取消或删记录，一键清空历史。
      入口两处：标题栏下载按钮、下载中心顶部的「下载管理」行。
    - **下载器直达 + 红点**（2026-10-30）：下载中心（首页壳的下载分页）
      顶部新增「任务」区 —— 宽屏在左栏最上、窄屏在卡片列表最上：
      「下载管理」行（有进行中任务时图标挂红色计数角标 / 窄屏行尾红点）
      与「导入整合包」行；窄屏底栏的「下载」tab 在有任务时同样挂红点
      （Flutter 悬浮胶囊 `FloatingBottomBarItem.badge` 与 Android 原生玻璃栏
      `LiquidGlassBarTab.badge`（Kotlin 侧 Compose 画点）两条链路都接了
      `DownloadCenter.hasActive`）。
    - **下载其他文件**（`download_other_flow.dart`，入口 = 下载页右下角 ＋
      FAB）：Android 直接用公共下载目录 `/sdcard/Download/Mint`（建不出
      回落应用数据目录，不弹 SAF）；桌面端系统目录选择器（默认记住上次
      的选择 `otherDownloadDir`，其次游戏目录）→ 输入 URL（可选改文件名，
      默认取 URL basename）→ DownloadCenter 后台任务。先探 Content-Length
      当进度分母，探不到按字节累计；完成 / 失败都走全局 snackbar。
    - 截图钩子：`--dart-define=MINT_TEST_DOWNLOAD=1|2` 塞假任务；
      `--dart-define=MINT_TEST_PAGE=downloads` 直接落到下载管理页。
    - 回归钩子：`--dart-define=MINT_TEST_INSTALL=1.20.4` 启动 2 秒后自动跑一次安装
      （验证任务队列 + 下载器接线，不弹安装页）。
      `--dart-define=MINT_TEST_GAME_DIR=<目录>
      --dart-define=MINT_TEST_LAUNCH_VERSION=1.11.2` 启动后自动切游戏目录并拉起游戏
      （PCL / Mint 目录互通实测用）；`MINT_TEST_PAGE=download|loader_install`
      直接落到下载中心 / 补装加载器页。
  - **下载中心双栏布局（PCL2 式）**：从底栏 / 侧栏的「下载」入口推入独立页面
    （与设置页同款二级页，带返回）。≥840px 时左侧是分类列表，右侧直接内嵌
    社区资源浏览器；窄屏退回卡片列表。**2026-10 精简**：游戏组只留
    **Minecraft 原版**（加载器 / OptiFine 改在版本管理里对已装版本补装，
    HMCL 同款流程），下载管理入口只在标题栏下载按钮；右下角常驻 **＋ FAB**
    导入本地整合包（等价于把 .zip / .mrpack 拖进窗口）。
    **页面不再放解释性文案**：分类描述、窄屏副标题、底部指南、空状态长句
    全部移除，只保留版本数 / 已安装 / 发布日这类状态信息。
    社区资源五类：模组 / 整合包 / 数据包 / 资源包 / 光影，
    结果卡片带下载量 / 收藏数图标；下载游戏页的版本行（含已安装）和
    窄屏下载卡片右侧都有下载图标，已安装游戏卡额外带勾选状态。
  - **社区资源浏览器（Modrinth）**：打开即拉**热门列表**（无关键词按下载量
    排序，`index=downloads`），搜索框输入关键词后按相关度；结果收进
    **和下载游戏页同款的大折叠卡**（`MintCollapsibleCard`），行右侧是下载
    入口，卡片带 **分类 tag**（Modrinth display_categories，带中文映射），
    点 tag 清空关键词按该分类继续搜。**分页**改成上一页 / 下一页（API
    `total_hits` 算总页数），不再「加载更多」；**每个类型在内存里缓存
    搜索词 / 页码 / 结果 / 滚动位置**（不落盘），切 tab 回来不重新请求，
    只有改搜索条件、下拉刷新或点搜索才重新拉。
    **版本筛选**：搜索框下的版本 chip 打开**版本清单选择器**（全部 MC 版本
    newest 在前 + 本地搜索 + 手输任意版本 + 全部版本 / 当前版本快捷项），
    **默认「全部版本」不预填**当前版本，详情页版本列表跟随同一筛选。
    **详情页顶卡点击直接打开 Modrinth 网页**（url_launcher）。
    **安装完成后的 toast 带「打开文件夹」动作**——按资源类型直达该版本
    对应目录（整合包则是 versions/<版本名>）。
    独立浏览器页顶部有类型 chips 可切换五类（PCL2 左侧类别的窄屏形态）。
    **没有已安装版本也能浏览与下载**（安装时自选目标文件夹，默认游戏根目录
    的对应子目录）。
    **详情页也显示 tag**（ActionChip），点击推一个「无关键词 + 该分类过滤」
    的搜索页继续浏览。
  - **社区资源下载先选文件夹**：点安装先弹系统文件夹选择器
    （`file_selector`），默认定位到该版本对应的目录
    （隔离则 `versions/<id>/<mods|resourcepacks|shaderpacks|datapacks>`，
    否则共享根同名子目录）；确认后下载走 DownloadCenter 后台任务。
    **Android 的 data 目录例外**：游戏在 `Android/data` / 应用内部
    `filesDir` 时系统文件应用选不进来，改为提示后直接装到当前版本目录
    （仍可手动选一个可见文件夹），不再弹 SAF。
  - **整合包（.mrpack）安装**：选游戏目录（默认当前目录）→ 输入版本名 →
    下载 mrpack → 解析 `modrinth.index.json` → 解压 `overrides/` →
    下载 index 声明的文件（跳过 `env.client=unsupported`）→ 安装
    MC 本体 + 依赖加载器 → 写一个继承加载器的 pack json 并**强制版本隔离**
    （mods / config 全在 `versions/<版本名>/` 下），装完自动选中新版本。
  - **本地整合包导入（拖入安装，PCL2 / HMCL 同款）**：
    `lib/services/launcher/modpack_importer.dart` 识别五种格式——
    **Modrinth .mrpack / CurseForge / MultiMC(Prism) / HMCL / 普通 zip**；
    两个入口：**把 .zip / .mrpack 拖进窗口任意位置**（`app.dart` 的
    `_ModpackDropZone` 全窗口 DropTarget，拖入时盖「松开导入整合包」提示层）
    或 下载页 → 任务 → 「导入整合包」。识别后弹确认框（格式 / 大小 /
    加载器 / MC 版本，普通 zip 识别不出版本时手填），导入走
    DownloadCenter 后台任务：解压覆盖文件（client-overrides 覆盖 overrides）→
    下载清单文件（CurseForge 走官方 API（设置 → 网络填 key），
    没配 key 用 edge.forgecdn.net CDN 直链按 fileID 兜底）→ 装 MC 本体 +
    加载器 → 继承 pack json + 强制版本隔离。
  - **一键安装页**（HMCL / FCL 的「安装游戏」流程）：先选 Minecraft 版本，
    随后并发预取**该版本可用的加载器**（PCL2 规则：Forge 只对正式版、
    Fabric / Quilt 1.14+、NeoForge 1.20.2+，且构建列表非空才显示；
    OptiFine 有对应 MC 版本构建才出现），不可用的加载器直接不显示，
    不再列禁用原因；再单选加载器（选中项带 × 取消）+ 可选 OptiFine 叠加，
    右下角 **FAB「安装 …」**一次装完。页面不再放大段解释文案。
  - **补装加载器独立页**（HMCL 下载加载器页同思路，`loader_install_page.dart`）：
    版本管理菜单「安装加载器 / OptiFine」推入独立页面，顶部是目标版本，
    下面只列该 MC 版本可用的加载器（含 OptiFine），选中后同页展示可滚动
    构建列表（默认推荐 / 最新）；FAB 点击先返回上一级，安装转后台
    （进度见标题栏），完成后自动选中新版本。
  - 原版版本列表按「正式版 / 快照 / 远古版」各收成一张可折叠大卡片，分组与
    行图标用方块：**草方块 / 命令方块 / 原石**（HMCL 同款，脚本生成于
    `tool/gen_block_icons.py`）；行说明只显示本地时区的发布日期和时间
    （例如 `2026-09-15 19:23`）。加载器 / OptiFine 版本同样收成可折叠卡片。
  - Fabric / Quilt 页面与模组搜索页会提示另装 **Fabric API**，并提供直达入口。

- **崩溃 / 错误分析器**（HMCL `CrashReportAnalyzer` + PCL2 报错字典的精简版，
  `lib/services/crash_analyzer.dart`）：
  - 30+ 条规则按序匹配（内存 / Java 版本 / 模块系统 / Forge 与 Fabric 模组
    加载 / Mixin / OpenGL 与显卡 / 文件权限与占用 / 磁盘 / zip 损坏 /
    类冲突 / 会话 / 崩溃报告特征），命中给出「原因 + 建议 + 命中行」；
  - Windows 退出码语义表（0xC0000005 访问违例、0xC0000135 缺 DLL、
    0xC00000FD 栈溢出等）兜底；
  - 游戏异常退出时自动分析，结果同时挂主页崩溃卡（含命中行 evidence）与
    日志页横幅；
  - 日志页顶栏「导入日志分析」：选一个 `.log/.txt/.json` 崩溃报告跑分析器，
    独立对话框展示结果；没有匹配时照实说，不硬编原因。

## Android（实验，x86_64 模拟器已验证 1.7.10 / 1.16.5 / 1.20.4 / 1.21.4 进主菜单）

- **运行时来源**：复用 FoldCraftLauncher **1.3.4.3** 的 launcher dex、
  原生库（含 MobileGlues / SimpleFPEWrapper）、JRE8/JRE17/JRE21、
  LWJGL 3.3.3 / **3.4.1**（26.3 需要）、GL4ES/ANGLE 原生库（x86_64 与
  arm64-v8a 两套）；Mint 只负责 Flutter UI、下载安装和启动参数。JRE25 不随包，
  在「设置 → 运行环境」里按需下载。FCL 组件按 **GPL-3.0** 分发，来源与许可证见
  `android/app/src/main/assets/fcl/NOTICE.txt`。arm64 资源从 FCL 官方
  `FCL-release-1.3.4.3-arm64-v8a.apk` / `-all.apk` 提取：
  `lib/arm64-v8a/*.so` → `jniLibs/arm64-v8a`、`assets/app_runtime/java/jre8/...`、
  `jre17`/`jre21` 资源、`lwjgl/3.3.3` 与 `lwjgl/3.4.1` 的 jar + natives。
- **JRE 选择 = 版本要求的 Java 大版本**：`app` 的 `abiFilters` 为 `arm64-v8a + x86_64`，
  `FclRuntime.availableJavaMajors` 按 APK 里**实际存在**的 `jre*/bin-<abi>.tar.xz`
  决定可用档位（8/17/21/25，两套 ABI 都已打包），再照 FCL
  `JavaManager.findExactOrNextGreater` 取「正好或更高」的第一档：1.12.x → JRE8、
  1.17–1.20.4 → JRE17、1.20.5+/1.21.x → JRE21。版本 JSON 没写 `javaVersion`
  时由 `GameVersion.requiredJavaMajor` 按版本号兜底推断。
  **Android 16 (SDK 36) arm64 上 JRE8 8u442 会在 HOSTED 初始化时崩**
  （`assembler_aarch64.hpp:237 Field too big for insn`，`-Xint` 也崩），所以那种
  机器上 JRE8 直接判为不可用，1.7.10 也跟着走 JRE17，并加
  `-XX:-UseCompressedOops -XX:-UseCompressedClassPointers -XX:+UseSerialGC`。
  实在凑不出要求的 JRE 时**明确报错**（`需要 Java N，当前运行时只有 M`），
  不再悄悄用低版本 JRE 让游戏 `UnsupportedClassVersionError`。
- **1.13+ 的结构化参数**（照 FCL `DefaultLauncher` + `CacioJavaArgs` 移植）：
  `arguments.jvm` / `arguments.game` 走 `lib/services/launcher/arguments.dart` 的
  `ArgumentExpander`（桌面与 Android 共用，Android 按 `os.name=Linux` 求值规则，
  否则 JSON 里所有 `os:{name:"linux"}` 的参数块会整段丢掉）；补齐
  `classpath_separator` / `file_separator` / `library_directory` / `primary_jar` /
  `resolution_*` / `path` 等变量，`has_custom_resolution` 置 true 让 `--width/--height`
  由我们的渲染尺寸决定。`${natives_directory}` / `${gl_lib_name}` /
  `${egl_lib_name}` **故意留原样**，由 FCL 的 `rebaseArgs` 换成当前渲染器的真实
  .so 路径；`-Dio.netty.native.workdir` / `-Djna.tmpdir` /
  `-Dorg.lwjgl.system.SharedLibraryExtractPath` 改指可写 cacheDir（FCL 同款），
  否则 LWJGL 往只读目录解 .so 直接起不来。Java 9+ 追加主类包的
  `--add-exports`，AWT 挂 caciocavallo（JRE8 用 `caciocavallo`、JRE17+ 用
  `caciocavallo17` + `-javaagent:cacio-agent.jar` + `--add-opens/--add-exports`），
  否则 1.13+ 取 `Toolkit` 就 `HeadlessException`。LWJGL 目录按版本声明取
  3.3.3 / 3.4.1（`GameVersion.lwjglVersion` 取链上最高声明），
  1.13+ 另外打开 `nativeSetUseInputStackQueue`（FCL 按 `arguments.isPresent()` 传）。
- **Manifest 必须关闭 native 指针 tagging**：`android:allowNativeHeapPointerTagging="false"`
  （FCL 官方 APK 同款）。不关时 JRE17 报 `Pointer tag ... was truncated` 直接
  abort，JRE8 也会在 AArch64 汇编器处崩——这是 Android 16 真机启动失败的关键。
- **数据目录**：Android 端游戏目录放在应用内部 `filesDir/MintLauncher/minecraft`
  （通过 `mint/fcl` 的 `dataDir` 方法与启动时短重试获取；实测 vivo Android 16
  对应用进程访问自己的外部 `Android/data/<pkg>` 也返回 EACCES，内部存储最稳）。
  插件注册在 `MainActivity.configureFlutterEngine` 里显式补一次
  `GeneratedPluginRegistrant`，规避个别构建组合下 `shared_preferences`
  的 `MissingPluginException`。
- **链路**：Flutter 安装 → `android_launch.dart` 构建 JVM/classpath/game 参数 →
  MethodChannel `mint/fcl` → Kotlin `FclRuntime`（InMemoryDexClassLoader 加载 dex、
  解压 JRE/LWJGL）→ `FCLauncher` → `GameActivity`（渲染分辨率可调的 SurfaceView
  + 触摸控制）。
- **游戏窗口（拖窗口）+ 渲染分辨率**：`game_display.json` 里两组独立字段。
  - `windowWidth` / `windowHeight` = 画面在屏幕上占的矩形（屏幕宽/高百分比，
    35%~100%），**即时生效**：只重排 SurfaceView 布局，不重建 GL surface，
    拉小后四周是黑边（预期效果），OSD 按键层跟着一起缩；
  - `mode` / `ratio` = GL 缓冲实际像素（高度固定 720，宽度按比例：
    16:9 → 1280、4:3 → 960、21:9 → 1680），同时写进 `--width/--height` 与
    `options.txt`。
  拖角标时两者联动（`setWindow` 把矩形宽高比换算成 `ratio`），所以缓冲比例
  始终等于画面矩形比例 —— compositor 永远只做等比缩放，任何模式下都不拉伸；
  比例触到 4:3~21:9 的上下限时，多出来的收窄退化成黑边。运行中改分辨率走
  FCL 的实时链路（`holder.setFixedSize` + `CallbackBridge.sendUpdateWindowSize`
  + `pushEventWindow`），游戏按新 framebuffer 重新布局，不用重启；滑杆/拖动
  过程中只重排矩形，松手那一刻才换缓冲（避免每帧重分配）。入口：游戏内
  悬浮球 → 功能 → 游戏窗口 / 渲染分辨率，以及设置 → 游戏窗口 / 渲染分辨率。
- **启动加载层**：跳到 `GameActivity` 时先盖一层独立 Dialog 窗口（Compose
  `ContainedLoadingIndicator`，M3E 形变加载动画 + 版本名），FCL 的 FPS 计数器
  出现第一帧后淡出。
- **游戏内菜单 = 真玻璃（Kimi 3.1.5 的 LiquidGlass 观感）**：
  `compose/GlassPanel.kt`。Compose 的 `Modifier.blur` 只能糊自己这一层，糊不到
  身后的游戏画面，所以浮层打开期间用 **`PixelCopy` 低频（120ms ≈ 8fps）抓游戏
  SurfaceView**（双缓冲 + 降采样到 ≤720px 宽），面板把自己身后那一块按窗口坐标
  摆回去再模糊裁圆角 —— 注意**只抓 SurfaceView 不抓整窗**，整窗截图会把浮层
  自己拍进去，玻璃里就出现「玻璃套玻璃」的递归糊。边缘高光用 Kimi 同款 AGSL
  （圆角矩形 SDF 梯度 · 光向，`pow(|dot(grad, light)|, falloff)`），并且用
  `1 - smoothstep(0, rimWidth, -sd)` 把它**限制在靠边一条 rim**：整块铺会把
  面板内部画成一堆 X 形亮带（实测踩过）。Android 13 以下没有 AGSL → 退回
  自上而下的亮边；抓不到画面 → 退回半透明深色卡。`MintPanel` / `MintGroup`
  全部换成这套，`MintPanel` 颜色常量改名 `MintSheet`（与组合函数同名会撞）。
  SDK 36 起 `RuntimeShader.setFloat2/setFloat4` 改名成 `setFloatUniform`，
  而 31~35 只有旧名 —— 按 arity 反射挑可用的那个。
- **触摸**：菜单点击/绝对指针；左下 FCL 风格摇杆 = WASD、右侧拖动 = 视角。  OSD 按键直接用键位名（E / ESC / SHIFT / SPACE / Q / T / TAB / F5 / 1 /
  LMB / RMB），不再写中文；按键层在背包、聊天等 GUI 里保持可见可点
  （例如按 E 关背包），打开 Mint 菜单时自动收起。退出走确认框并结束进程
  （FCL 的 exit hook 与 JVM 同进程，无法只结束游戏线程）。
- **返回键 / 背包点击（2026-10-31，AVD 实测 1.11.2）**：游戏中（含背包、
  聊天、选世界）按 Android 返回键默认发 ESC，不再直接回启动器；加载页
  仍保留返回脱身，回启动器走悬浮球菜单。菜单态点击照 FCL TouchPad
  的 CLICK 模式：先推指针位置，延迟 33ms 再投递 LMB，松手后补释放 ——
  同帧投递会让游戏拿上一帧坐标判定，表现就是背包物品点不动。
- **输入链路修复（2026-10-29，arm64 真机实测）**：
  - **鼠标判定不能按位与**：`SOURCE_MOUSE_RELATIVE`(0x40002) 里含
    `SOURCE_CLASS_POINTER`(0x2)，所有触摸屏（0x1002）都带这一位 —— 以前
    `sources and MOUSE_MASK != 0` 会把**所有手指触摸**当成鼠标事件交给
    `GameHardwareInput`，结果「光标能动、鼠标键不触发、悬浮球也收不到事件」。
    现在统一用 `PhysicalInputWatcher.isMouseSource()`（完整 source 相等判断）。
  - **假键鼠设备**：vivo 的屏下指纹（`vivo_ts_fp` / `vivo_fp`）在系统里上报
    `KEYBOARD|MOUSE` + `ALPHABETIC`，会让 OSD 误判「外接键鼠」直接收起。
    现在鼠标设备还要求 `keyboardType == NONE` + 真实 X/Y 位移轴，键盘要求
    真的有字母键（`hasKeys(A, Z, SPACE)`）。
  - **诊断日志**：真机 logcat 对整个应用进程是吞掉的，输入事件改写到
    `/sdcard/Android/data/dev.mint.mint/files/logs/mint-input.log`（`InputDebug`）。
    同目录的 `input_queue` 文件（内容 `0`/`1`）可临时覆盖 GLFW 输入队列开关。
  - **远古版强制 GL4ES**：VirGL/Zink 跑 alpha/beta（AWT + LWJGL2）只会清出
    灰屏（100+ FPS 但没画面）；按 `needsLegacyAwt` 固定 `gl4es` 后
    a1.0.15 直接进主菜单，点击也正常（Dart 与 Kotlin 两侧都做了兜底）。
- **体验微调（搬自 FCL main 分支行为，GPL-3.0 已标注）**：设置落盘
  `filesDir/game_tweaks.json`（启动器设置页与游戏内菜单共用，改动经广播
  `ACTION_TWEAKS` 立刻生效）——
  - **转视角灵敏度**（FCL `MenuSetting.mouseSensitivity` 对应物）：捕获指针后
    拖动转视角的倍率，设置页滑杆 + 游戏内菜单「控制 → 视角」；
  - **陀螺仪转视角**（FCL `Gyroscope.java` 同思路：滑动窗口平均 + 死区 +
    屏幕旋转自适应 + 双轴独立反转与灵敏度）：无传感器的设备自动禁用入口；
  - **最高屏幕刷新率**（FCL `JVMActivity.applyMaxRefreshRatePolicy` 同思路）：
    在同分辨率档位里挑最高刷新率，避免高刷屏被系统限在 60Hz；
  - **游戏内内存叠层**（FCL `showMemory` 对应物）：FPS 下面叠一行 JVM 堆用量；
  - **游戏内文字输入**（FCL `TouchCharInput` 简化版）：游戏内菜单「功能 →
    输入文字」，系统 IME 编辑整串后逐字符 sendChar + 回车注入（聊天/命令）。
- **Android JVM / 游戏参数**：版本设置里的「额外 JVM 参数 / 追加游戏参数」
  （FCL `VersionSetting.javaArgs/minecraftArgs` 对应物）同样作用于 Android
  启动；用户 `-Xmx` 排在内置参数之后可直接覆盖内存上限。
- **当前限制**：打包 **arm64-v8a + x86_64**；x86_64 模拟器已验证 1.7.10 / 1.16.5 /
  1.20.4 / 1.21.4 原版进主菜单（GL4ES 下 FPS 约 15~30，取决于 GPU / 渲染器），
  arm64 真机（Android 16）此前只验证过 1.7.10，高版本待复测；
  Forge / Fabric 等加载器在 Android 上尚未验证（官方安装器要跑子进程，
  Android 起不了 `Process.run(java)`，需要改走 profile JSON 直写）。
  26.x 快照一类声明 LWJGL ≥3.4.1 的版本，运行时目录已支持归一到 3.4.1，
  但 3.4.1 那套 jar/natives 还没打进 APK；armeabi-v7a 未打包。
- **冒烟钩子**：`--dart-define=MINT_TEST_ANDROID_LAUNCH=1.7.10` 启动后台自动拉起。

## 启动器核心（lib/services/launcher/）

- **下载记账（治「幽灵下载」）**：一次安装要跑 5~10 批下载（库 → 客户端 →
  log4j → natives → 解析 assetIndex 才知道有 1.5 万个资源 → 加载器再补一批），
  以前每批都 `plan()` **覆盖**分母，UI 就在每批开始时显示 100%；失败的文件又和
  成功的一样 `doneFiles++`，`complete()` 无条件打绿勾。现在：
  `DownloadTask.addPlan()` **累加**总量（`plan()` 只给第一条用）、
  `fileFailed()` 单独计 `failedFiles` 且 `complete()` 有失败就落成 `failed`、
  `setPhase()` 只许前进（阶段切换不再把条往回拉）、重试的分片字节用
  `undoBytes()` 回滚（否则 doneBytes 超总被 clamp 成 100%）；
  `runBatch` 返回 `BatchResult(total/downloaded/failed)`，`VersionInstaller`
  汇总后抛 `InstallIncompleteException`，安装页与下载中心再也不会「没下完却已完成」。
  完整性判定也不再只看「文件在不在」：`fetchFile` 在 sha1 未知时按 `size` 判定，
  客户端 jar 大小不符就重下，资源索引会重新解析校验，natives jar 缺失/解不开
  写日志而不是静默跳过；classpath 构建缺库不再悄悄剔除，Android 启动前
  `_repairAndroidLibraries` 会按 JSON 补一轮，补不上才带着缺项启动并在日志点名；
  Android 运行时的 JRE/LWJGL/caciocavallo/jna 解包改成 `.mint-ready` marker 门控
  （半截产物不再被当成已就绪），并挂一条真正的下载任务显示进度。
- **downloader.dart**：并发下载 + SHA1 校验 + 重试 + 每次尝试独立 `.part` 分片；BMCLAPI 域名映射  （piston-meta/piston-data/libraries/resources → bmclapi2.bangbang93.com，
  Forge 的 files./maven.minecraftforge.net 与 maven.neoforged.net → 镜像 /maven），
  auto = 镜像优先官方兜底；清单类请求（getString）同样带重试。
  **源健康熔断（PCL2 SourceFail 同思路）**：按「主机 + 第一段路径」统计失败率，
  连接层失败立刻换下一个候选（不再对坏源重试 3 次），窗口 ≥8 次且失败率 ≥60%
  冷却 45 秒 —— 修掉 BMCLAPI 资源 CDN 坏节点导致上千个小文件每个都先撞坏源的问题
  （实测 1000 个小资源 22s → 3.5s）。IPv4-first 连接工厂改为逐地址尝试，
  修掉 Dart 3.12 下把 `List<InternetAddress>` 传给 `SecureSocket.startConnect`
  的类型崩溃（此前所有 HTTPS 请求都失败/重试）。
  Forge / NeoForge 版本列表优先走 BMCLAPI 专用接口（`/forge/minecraft/<mc>`、
  `/neoforge/list/<mc>`），官方元数据兜底 —— 修复两者偶尔拉取不到的问题。
- **launch_builder.dart（Forge 主 jar 规则）**：Forge/NeoForge 1.17+
  （BootstrapLauncher）的版本**主 jar 不上溯继承链**（PCL2 `McLibListGet`
  同款）—— 本体是 libraries 里的补丁 client jar，原版 jar 进 classpath
  会撞模块（`ResolutionException: _1._20._1 and minecraft export …`）。
- **download_task.dart**：后台任务的数据模型（**纯 Dart，不依赖 Flutter**）——
  downloader.dart 因此能被 `dart run` 的无头工具直接编译；Flutter 侧的队列 /
  ChangeNotifier 节流在 download_center.dart（re-export 本文件，旧 import 不变）。
- **manifest.dart / version_model.dart**：version_manifest_v2；版本 JSON 解析、rules 求值（os/arch/features，"x86" 特指 32 位）、inheritsFrom 父子合并（按完整 maven 坐标去重）。
- **version_installer.dart**：客户端 jar / 依赖库 / log4j 配置 / 资源索引 + 资源对象（hash 分桶）/ natives 解压。
- **modloader.dart**：Fabric / Quilt（profile json + 继承链）与 Forge / NeoForge（官方 installer --installClient 无头安装；**全新目录会先写空
  `launcher_profiles.json`**——官方安装器要求目标目录已有官方启动器档案，
  HMCL 同款兜底）。
- **optifine.dart**：原生 Patcher 补丁 + LaunchWrapper 版本 json（原版基
  本体）；**Forge / NeoForge 基本体走官方共存路线**——OptiFine jar 直接
  作为 Forge mod 放进别名版本的隔离 mods/（1.17+ 官方姿势，不覆盖
  BootstrapLauncher 引导链），版本目录里有 mods 也会触发自动版本隔离。
- **modrinth.dart**：搜索 / 版本列表 / 下载，按版本 id 推断 MC 版本与加载器过滤。
- **modpack_importer.dart**：本地整合包识别 + 解压（Modrinth / CurseForge /
  MultiMC / HMCL / 普通 zip 五种格式，见「下载与安装」）。
- **modpack_exporter.dart**：整合包导出（Modrinth .mrpack / CurseForge .zip 双格式，
  PCL2 2.14 `PageInstanceExport` 规则模型对齐 + 联网匹配 Modrinth 资源，
  见「版本管理 → 整合包导出」；规则引擎与收集规则有单测覆盖）。
- **java_runtime.dart**：系统 Java 探测 + Mojang 官方 java-runtime 清单下载
  （按版本 JSON 的 `javaVersion.component` 选组件，SHA-1 逐文件校验）+ Adoptium
  Temurin 兜底。**启动时缺 Java 自动安装**（设置可关）：先按 `javaMajor` 挑
  现有 Java，没有就装对应大版本运行时，Mojang 失败回退 Adoptium。
- **account.dart**：离线账户，UUID = md5("OfflinePlayer:name") + v3/variant 位修补；外置登录走 authlib-injector。
- **launch_builder.dart**：1.13+ `arguments{jvm,game}` 规则展开 + `${}` 替换；<1.13 `minecraftArguments` 兼容；
  追加 GC 预设 / 自定义 JVM·游戏参数 / 环境变量 / 自动连服参数；
  **强制图形后端**：CPU 软件渲染挂 mesa-loader javaagent（HMCL 同款
  LLVMpipe），OpenGL / Vulkan 走 26.2+ 的 `--graphicsBackend`。
- **launcher_controller.dart**：安装 → Java → 内存 →（CPU 后端的 Mesa）→
  启动前命令 → 构建命令 → Process.start → stdout/stderr 泵进日志页；
  **整条链路可中断**——`cancelLaunch()` 把取消传播到所有挂着的下载器，
  每阶段之间 `_throwIfCancelled()` 快速失败；进程优先级（PowerShell）与
  启动器可见性（保持 / 最小化 / 关闭）在起进程后应用。

## 启动选项（照 PCL2 反编译搬运 + HMCL 补充）

PCL2 的设置 → 启动 / 高级选项按 `E:\Plain Craft Launcher 2.exe` 的
ilspycmd 反编译源码（`PageSetupLaunch.cs`，VB.NET → C#）逐项搬运，
HMCL 的图形后端 / 运行时思路补充（`lib/src/enums.dart` + 设置页「启动 /
启动高级」两节，全部支持每版本覆盖）：

| 选项 | 来源 | 说明 |
|---|---|---|
| 版本隔离 | PCL2 `LaunchArgumentIndieV2` | 五档：关闭 / 有加载器的版本 / 老版本与快照 / 老版本、快照与有加载器的版本 / 全部隔离；**版本目录下有 mods（含文件）或 saves（含子目录）的版本无论选哪档都自动隔离**（PCL2 `PathIndie` 同款优先级），单版本可在版本设置里强制开 / 关 |
| 内存 AUTO / 手工 | PCL2 `GetRam` | AUTO 按「可用物理内存 + mods 数」档位公式（0.5/1.5/2.7/4.5GB 上浮）；滑块**不设人为上限**（≥ 物理内存，至少 32GB，可输精确值），上方实时条每 2 秒刷「总 / 已用 / 可用」 |
| 游戏窗口 | PCL2 `LaunchArgumentWindowType` + HMCL | 默认 854×480 / **与启动器窗口大小相同**（取启动器当前逻辑像素尺寸）/ 自定义宽高 / 全屏 |
| 启动器可见性 | PCL2 `LaunchArgumentVisible` | 保持打开（弹独立日志窗口）/ 最小化 / 关闭 |
| 进程优先级 | PCL2 `LaunchArgumentPriority` | 高 / 中 / 低（Windows 生效） |
| JVM / 游戏参数 | PCL2 `TextAdvanceJvm/Game` | 一行一个，追加到版本 JSON 参数之后 |
| 启动前命令 | PCL2 `LaunchAdvanceRun` | `cmd /c` 在游戏主目录执行，支持 `{verpath}/{verindie}/{java}/{version}` 占位符，可选等待结束 |
| GC 预设 | PCL2 `LaunchAdvanceGC` | 自动 / 调优 G1 / 标准 G1 / ZGC / 分代 ZGC |
| 强制图形后端 | HMCL | 自动 / OpenGL / Vulkan / **CPU 软件渲染**（Windows 下载 mesa-loader-windows 26.0.4，约 48MB，`-javaagent:...=llvmpipe`） |
| 文件校验 | PCL2 `VersionAdvanceAssetsV2` | 全局开关 + **每版本「不校验」**：已有文件直接信任只补缺失 |
| 自动装 Java | HMCL | 启动时按 `javaVersion.majorVersion` 挑 / 下载（见 java_runtime） |
| 环境变量 / 自动连服 | PCL2 / HMCL | `KEY=VALUE` 一行一个；`--server host:port` 启动直连 |

## 运行

```bash
flutter run -d windows          # 开发
flutter build windows --release # 产物 build/windows/x64/runner/Release/mint.exe
flutter test                    # 单测（整合包识别 / 布局 / 标题栏 / 下拉刷新…）

# Linux（依赖 clang cmake ninja pkg-config libgtk-3-dev libwayland-dev）
flutter build linux --release   # 产物 build/linux/x64/release/bundle/mint
bash tool/ci/smoke_x11.sh build/linux/x64/release/bundle/mint build/smoke/x11
bash tool/ci/smoke_wayland.sh build/linux/x64/release/bundle/mint build/smoke/wayland
bash tool/ci/kwin_blur_probe.sh build/linux/x64/release/bundle/mint build/smoke/kwin

# 不开 GUI 的端到端冒烟（清单→安装→Java→启动→观察 90 秒）
dart run tool/e2e_launch_test.dart 1.20.4

# 加载器组合矩阵：fabric+API / fabric+OF+API / forge / forge+OF，
# 装到指定目录并逐个启动观察 75 秒，报告写 <目录>/matrix-report.md
dart run tool/e2e_loader_matrix.dart H:\mctest 1.20.1

# 截图 / 回归钩子（只影响本次运行，不写设置）
flutter build windows --release \
  --dart-define=MINT_TEST_TAB=2 \
  --dart-define=MINT_UI_STYLE=material \
  --dart-define=MINT_THEME_MODE=light
```

游戏目录默认 `%APPDATA%\MintLauncher\minecraft`，可在设置里改。下载源可选
自动/BMCLAPI/官方；**下载线程数可调**（1-256，设置 → 网络）。**总进度按
文件数计**（PCL2 同款，标题栏圆圈同源）；下载管理页在最后一个任务完成后
自动返回上一级。**多语言**：当前内置简体中文（Material/Cupertino/Fluent
组件文案一并本地化），可锁定「界面语言」；**启动游戏时默认把游戏内语言
写为简体中文**（options.txt，可关）。

## 已知边界（实验阶段）

- 正版（Microsoft OAuth）登录未做；外置登录仅验证服务器连通性与注入器下载。
- 模组更新检查未做；CurseForge 整合包清单走官方 API（要 key）或 CDN 直链
  兜底，个别文件下载失败会记日志跳过、不阻断导入。
- 老版本（<1.6 虚拟资源）只做了基本兼容。
- Android：arm64-v8a / x86_64 双 ABI，JRE8/17/21 随包、JRE25 按需下载；
  1.7.10 / 1.15.2 / 1.16.5 / 1.20.4 / 1.21.4 已在 AVD 验证，1.15.2 / 26.3
  已在 vivo V2403A 真机验证。
- **26.3 的实验渲染后端**：26.3 换成 RenderPearl + SDL3，GL4ES/Krypton 的 EGL
  不完整。Mint 会自动切 Zink（系统 Vulkan 驱动），能进主菜单、原生分辨率
  60fps，但 Adreno 上文字/贴图仍有花屏；这是 26.3 新渲染路径与当前驱动/
  MobileGlues 的限制，不是启动器崩溃。要完整体验 26.3 请等 FCL/Mesa 更新。
- 正版登录、模组更新检查、CurseForge API key 等桌面端限制同上。

## 2026-10-30 Android 启动链 / 渲染 / 运行时这一轮

真机：vivo V2403A（SM8650 / Adreno 750 / 2800×1260 / Android 16）。

- **SplashScreen**：接入 AndroidX `core-splashscreen`，`LaunchTheme` 父主题
  `Theme.SplashScreen`，品牌 M 徽标（`drawable/mint_splash_logo.xml` + 深浅色
  背景）；`MainActivity` 用 keep-on-screen 条件挂到 Dart 首帧的 `mint/fcl ready`
  才收，8 秒兜底。桌面端不受影响。
- **Java 17+ 启动**：
  - FCL 运行时升级到 **1.3.4.3**（dex + libpojavexec/libjsound + MobileGlues /
    SimpleFPEWrapper），补 **LWJGL 3.4.1**（26.3 声明 3.4.3，按 FCL 规则归一到
    3.4.1）；`lwjglDirName` 现在按版本号 ≥3.4.1 映射，不再只认死 `3.4.1`。
  - JRE25 不随包：`JreDownloader` 用 HTTP Range 从 FCL 发布的 APK 里只取
    `jre25/bin-<abi>.tar.xz` / `universal.tar.xz` / `version`（不整包下载），
    再交给 FCL `RuntimeUtils.uncompressTarXZ` + `patchJava` + `.mint-ready`。
  - 新增「设置 → 运行环境 / 更多 → 运行环境」：Java 8/17/21/25 状态
    （随包 / 已安装 / 需下载 / 此机型不可用）+ 下载进度 + 版本对照；
    启动时缺 Java 会在同一个任务里自动下载（`autoInstallJava`）。
  - 修 `-Djna.boot.library.path`：原来指向 APK lib 目录但没有 libjnidispatch，
    oshi/JNA 在崩溃报告里二次抛错，把真正的启动异常吞掉；现在指到
    `app_runtime/jna/<版本>/natives/<abi>`。Java 19+ 补
    `-Dstdout/stderr.encoding=UTF-8`；加 `-XX:ErrorFile` / HeapDump。
- **26.3（RenderPearl / SDL3）**：
  - 26.3+ 传 `sdl3=true`，`GameActivity` 在 `execute` 前调
    `SdlBridge.prepareSurface(...)`，并在分辨率变化/重建 Surface 时
    `syncResolution`；不注册的话 SDL 隐藏窗口报 `Could not fetch native window`。
  - 渲染器加 MobileGlues / SimpleFPEWrapper；GL4ES/Krypton/VirGL 的
    `maxGameVersion` 按 FCL `displayMaxMCver` 设上限，26.3 自动回落 **Zink**。
    Zink 会以系统 Vulkan 驱动初始化（`FCLConfig.setUseVKDriverSystem(true)`），
    游戏实际走 Vulkan 后端（日志：`Using graphics backend Vulkan, using drivers:
    1.3.128 Qualcomm ...`）。
  - 实测 26.3 能进主菜单、原生 2800×1260、60fps；但 Adreno 上文字/贴图有花屏，
    MobileGlues 会在着色器编译阶段失败。属于 26.3 实验渲染路径的上游限制。
- **横竖屏 tab**：`HomePagerLayoutKeeper` 在窄/宽布局切换的下一帧把
  `PageController` 拉回 `HomeNavState.index`，三个壳（Material / miuix / Fluent）
  都接入；实测下载页竖屏 → 横屏（侧栏壳）→ 竖屏，tab 始终保持。
- **MIUI 小窗**：移植 `sanitizeXiaomiFreeformPadding`（flutter#161086），
  `app.dart` builder 在异常 inset 时包一层 MediaQuery，正常值原样直通。
- **渲染分辨率 = 屏幕原生**：`AndroidDisplaySettings` / `GameDisplaySettings`
  的 100% 从「720p 基准」改为「屏幕原生高度」。1.5K 设备 100% = 2800×1260，
  75% = 2102×946，50% = 1400×630；旧的 `resolutionScale`（相对 720p）在原生
  `load()` 里按 `scale * 720 / screenHeight` 等价迁移并写 `scaleBase:screen`，
  用户看到的画面尺寸不会突变。实机验证 1.15.2 GL4ES 在 2102×946 下 60fps，
  26.3 Zink 在 2800×1260 下 60fps。
- **回归**：`flutter test` 173 例全过；`./gradlew :app:compileDebugKotlin` 通过；
  真机重新安装后测过 Splash、运行环境下载 JRE25、横竖屏 tab、1.15.2 启动、
  26.3 启动。

## 2026-10-31 26.3 竖屏拉伸 / 26.2 黑屏 / 更多页进程管理 / 设置单页

对照 FCL（SdlBridge / JVMActivity / SDLSurface 源码）定的两处渲染修复，
外加三个体验项。

- **26.3 竖屏拉伸（根因修复）**：SDL 建窗口时会按窗口宽高请求方向
  （`SDLActivity.setOrientation`：宽<高 → `SENSOR_PORTRAIT`，直接调
  `activity.setRequestedOrientation`）。Mint 的 GameActivity 没拦，Activity 被
  SDL 转成竖屏，游戏整个竖排（Mojang 标志横躺）—— 这就是「26.3 是竖屏拉伸、
  不是横屏」的根因。照 FCL `JVMActivity` 的兜底 override
  `setRequestedOrientation` 一律锁 `SENSOR_LANDSCAPE`（GameActivity.kt）。
  旧的 `sdlSyncHandler` 轮询补同步保留，注释改成新解释。
- **26.2 黑屏有声（buffer 一致性）**：FCL 用 `TextureView.setDefaultBufferSize`
  维持「Surface buffer == SDL 窗口 == GLFW 窗口」三边一致；Mint 的 sdl3 路径
  在 `applyDisplay` 里跳过了 `holder.setFixedSize`，运行中改分辨率后
  ANativeWindow buffer 与 RenderPearl 的 swapchain extent 对不上，表现为
  「游戏在跑、有声音、画面全黑」。`applyDisplay` 现在对 sdl3 也 `setFixedSize`
  —— 之前担心的「旋转后 buffer 竖排」已经由方向锁根除（SDL 再也转不动
  Activity），固定缓冲是安全的。26.1 及更早版本本来就走这条路径，一并受益。
- **更多 → 游戏进程管理（Android）**：新增「游戏进程」卡 —— 状态（pid 文件 +
  /proc 复核）、「跳转到游戏画面」（`game.foreground`：
  `REORDER_TO_FRONT` 把 singleTask 的游戏 task 提回前台，进程活着但 Activity
  被销毁的极端情况凭 `restoreToFront` 标记静默退出、不误报启动参数缺失）、
  「强制结束游戏进程」（`game.forceStop`：跳过先广播后杀的两段式，直接
  SIGKILL）。解决「卡在游戏里回不来 / 退不出」。
- **设置页竖屏单页化**：取消窄屏的横向分类胶囊（旧 tab 选择），所有设置按
  启动 → 启动高级 → 虚拟触控（桌面）→ 网络 → 外观 → 快捷键 → 关于 在一个
  ListView 里铺开；宽屏保留 HMCL 式左侧大类。单页 = 单滚动体，miuix 大标题
  折叠与顶栏渐变模糊带照常工作（顺带就是「设置页顶栏渐变模糊」）。
- **版本管理顶栏渐变模糊**：双栏/卡片布局不是整页滚动体，miuix 大标题折叠
  没有滚动体记账、渐变带永远出不来 —— `MintPageScaffold` 新增 `pinBar`，
  钉住小标题栏（不升级大标题），`_MiuixSmallBar` / `_MaterialSmallBar` 的
  渐进模糊带常驻，内容从栏下滚过即被糊住。
- **AVD 验证（l2api36 / API 36 x86_64）**：26.2 下载 → 启动（自动装 JRE25、
  GL4ES 不支持 26.2 自动回落、手动改 MobileGlues + 强制 OpenGL 后端后
  RenderPearl-GL 正常初始化）；Mojang 加载画面**正常显示**（模拟器 Vulkan
  能力不全走不了 Vulkan 后端，软渲染进主菜单较慢），画面等比 letterbox
  无拉伸，GameActivity 全程横屏 —— 方向锁与 buffer 不变式均按预期工作。
