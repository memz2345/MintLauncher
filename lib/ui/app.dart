import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/liquid_glass_bar_service.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/services/test_hooks.dart';
import 'package:mint/services/theme_fonts.dart';
import 'package:mint/services/theme_package.dart';
import 'package:mint/services/volume_bar_service.dart';
import 'package:mint/services/window_backdrop.dart';
import 'package:mint/src/app_dynamic_color.dart';
import 'package:mint/src/enums.dart';
import 'package:mint/src/system_font.dart';
import 'package:mint/ui/fluent/fluent_home_shell.dart';
import 'package:mint/ui/miuix/miuix_material_bridge.dart';
import 'package:mint/ui/miuix/miuix_home_shell.dart';
import 'package:mint/ui/mint_icons.dart';
import 'package:mint/ui/window_chrome.dart';
import 'package:mint/ui/widgets/back_stack_menu.dart';
import 'package:mint/widgets/edge_scroll_haptic.dart';
import 'package:mint/widgets/global_shortcuts.dart';
import 'package:mint/widgets/mdui_ripple.dart'
    show mintSplashColor, mintSplashFactory, mintUsesMduiRipple;
import 'package:mint/widgets/mint_scroll_behavior.dart';
import 'package:mint/ui/widgets/theme_volume_bar.dart';
import 'package:mint/widgets/miuix/miuix_overscroll.dart';
import 'package:mint/widgets/xiaomi_freeform_media_query.dart';

import 'app_theme.dart';
import 'home_shell.dart';
import 'pages/about_page.dart';
import 'pages/common.dart' show MintGlobalSnack;
import 'pages/download_hub_page.dart';
import 'pages/download_manager_page.dart';
import 'pages/game_install_page.dart';
import 'pages/loader_install_page.dart';
import 'pages/modpack_import_flow.dart';
import 'pages/settings_page.dart' show SettingsPage;
import 'pages/theme_package_page.dart';
import 'pages/shared_actions.dart' show activeVersionId, launchVersion;
import 'pages/vanilla_versions_page.dart';
import 'pages/version_manager_page.dart';
import 'pages/version_settings_page.dart';
import 'package:mint/services/launcher/modloader.dart';
import 'widgets/crash_report_dialog.dart';

/// 回归用：启动后自动切到指定游戏目录并启动某个版本。
/// 例：`--dart-define=MINT_TEST_GAME_DIR=H:\pcl2test
/// --dart-define=MINT_TEST_LAUNCH_VERSION=1.11.2`（正常构建不受影响）。
const _kTestGameDir = String.fromEnvironment('MINT_TEST_GAME_DIR');
const _kTestLaunchVersion = String.fromEnvironment('MINT_TEST_LAUNCH_VERSION');

/// 根组件：MaterialApp + 动态取色/种子色主题。
///
/// 界面风格（[UiStyle]）在这里分流：Material 3 走动态取色/种子色那一套；
/// HyperOS 由 MiuixThemeController 解析配色，再经 [materialSchemeFromMiuix]
/// 搭桥喂给 ThemeData，让还没迁到 miuix 的内容配色不打架。
/// （架构照搬 local2api 的 ui/app.dart，去掉用不到的托盘/应用锁/l10n。）
class MintApp extends StatefulWidget {
  const MintApp({super.key, required this.settings, required this.controller});

  final SettingsService settings;
  final LauncherController controller;

  @override
  State<MintApp> createState() => _MintAppState();
}

class _MintAppState extends State<MintApp> with WidgetsBindingObserver {
  /// 系统的深/浅色（didChangePlatformBrightness 同步刷新）。
  Brightness _systemBrightness = Brightness.light;

  /// 全局导航（鼠标侧键 / Esc / 快捷键返回用）。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _systemBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    WindowBackdrop.instance.addListener(_onBackdropChanged);
    widget.controller.addListener(_onControllerChanged);
    // 只有真正画了自绘标题栏时才让二级页把标题/back/操作托管上来。
    // Linux 也启用：GTK 原生装饰在 main 里提前摘掉（LinuxWindowChrome）。
    MintWindowChrome.instance.enabled = Platform.isWindows || Platform.isLinux;
    // 回归钩子：自动套用第一个已导入的 MIUI 主题（截图 / 冒烟用）。
    const testApplyTheme = bool.fromEnvironment('MINT_TEST_APPLY_THEME');
    if (testApplyTheme) {
      final theme = MintThemeLibrary.instance.themes.firstOrNull;
      if (theme != null) {
        widget.settings.applyThemePackage(
          theme.id,
          hasWallpaper: theme.wallpaper.isNotEmpty,
          hasAccent: theme.accent != null,
          hasFont: theme.fontFile.isNotEmpty,
          hasBootAnimation: theme.bootAnimationDir.isNotEmpty,
        );
      }
    }
    // 截图/回归钩子：优先沙盒配置（iOS simctl 的环境变量不进场），
    // 其次 dart-define，桌面 CI 再用同名环境变量。
    final testPage = MintTestHooks.page.isNotEmpty
        ? MintTestHooks.page
        : (const String.fromEnvironment('MINT_TEST_PAGE').isNotEmpty
              ? const String.fromEnvironment('MINT_TEST_PAGE')
              : (Platform.environment['MINT_TEST_PAGE'] ?? ''));
    if (testPage.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openTestPage(testPage),
      );
    }
    if (MintTestHooks.showBackMenu) {
      // 等二级页推入 / 首帧稳定后再弹，截图时菜单已经展开。
      Future<void>.delayed(const Duration(seconds: 3), () {
        // Navigator 自己的 context 不是 Navigator 的后代，Navigator.of()
        // 找不到它；用 Overlay 的 context（在 Navigator 里面）。
        final navContext = _navigatorKey.currentState?.overlay?.context;
        if (!mounted || navContext == null) return;
        showMintBackStackMenu(
          navContext,
          anchor: Offset(24, MediaQuery.paddingOf(navContext).top + 28),
        ).catchError((Object e, StackTrace st) {
          debugPrint('back menu hook failed: $e\n$st');
        });
      });
    }
    if (_kTestLaunchVersion.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runLaunchHook());
    }
  }

  Future<void> _runLaunchHook() async {
    if (_kTestGameDir.isNotEmpty) {
      await widget.controller.switchGameDir(_kTestGameDir);
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    // 必须用 Navigator 里的 context：MintApp 的 context 在 MaterialApp 之上，
    // showDialog 拿不到 MaterialLocalizations。
    final navContext = _navigatorKey.currentContext;
    if (!mounted || navContext == null) return;
    await launchVersion(
      navContext,
      widget.controller,
      widget.settings,
      versionId: _kTestLaunchVersion,
    );
  }

  /// 截图 / 回归钩子：直接落到某个二级页（不改设置、正常构建无影响）。
  void _openTestPage(String page) {
    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    final id = activeVersionId(widget.controller, widget.settings);
    final miuix = widget.settings.uiStyle.isMiuix;
    final route = switch (page) {
      'version_settings' when id != null => MaterialPageRoute<void>(
        builder: (_) => VersionSettingsPage(miuix: miuix, versionId: id),
      ),
      'version_manager' => MaterialPageRoute<void>(
        builder: (_) => VersionManagerPage(miuix: miuix),
      ),
      'vanilla' => MaterialPageRoute<void>(
        builder: (_) => VanillaVersionsPage(miuix: miuix),
      ),
      'downloads' => MaterialPageRoute<void>(
        builder: (_) => DownloadManagerPage(miuix: miuix),
      ),
      'download' => MaterialPageRoute<void>(
        builder: (_) => DownloadHubPage(miuix: miuix),
      ),
      'settings' => MaterialPageRoute<void>(
        builder: (_) => SettingsPage(miuix: miuix),
      ),
      'about' => MaterialPageRoute<void>(
        builder: (_) => MintAboutPage(miuix: miuix),
      ),
      'theme' => MaterialPageRoute<void>(
        builder: (_) => MintThemePage(miuix: miuix),
      ),
      'loader' => MaterialPageRoute<void>(
        builder: (_) =>
            GameInstallPage(miuix: miuix, initialLoader: ModLoader.fabric),
      ),
      'loader_install' when id != null => MaterialPageRoute<void>(
        builder: (_) => LoaderInstallPage(miuix: miuix, versionId: id),
      ),
      _ => null,
    };
    if (route != null) nav.push(route);
  }

  void _onBackdropChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (brightness == _systemBrightness) return;
    // 「跟随系统」时这一下就是主题模式变了：miuix 的配色是单份（明或暗），
    // 不重算的话 MaterialApp 的 themeMode 会停在上一次那份上。
    setState(() => _systemBrightness = brightness);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Android：游戏跑在 :game 独立进程里，启动器回前台时对一次状态 ——
    // 用户在游戏里退出、或从后台被系统杀掉，按钮都要跟着变回「启动游戏」。
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      widget.controller.syncAndroidGameState();
    }
    if (state == AppLifecycleState.resumed) _maybeShowCrashReport();
  }

  bool _crashDialogOpen = false;

  void _onControllerChanged() {
    final report = widget.controller.pendingCrash;
    if (report == null) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeShowCrashReport(),
    );
  }

  /// 崩溃 / 启动失败：像 FCL 一样弹日志页（完整日志 + 复制）。
  Future<void> _maybeShowCrashReport() async {
    if (!mounted || _crashDialogOpen) return;
    final report = widget.controller.pendingCrash;
    if (report == null) return;
    final navContext = _navigatorKey.currentContext;
    if (navContext == null) return;
    _crashDialogOpen = true;
    widget.controller.dismissCrashReport();
    try {
      await showCrashReportDialog(
        navContext,
        report: report,
        miuix: widget.settings.uiStyle.isMiuix,
      );
    } finally {
      _crashDialogOpen = false;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    WindowBackdrop.instance.removeListener(_onBackdropChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool _volumeHudOn = false;

  /// 「主题音量条」开关 + 当前有没有主题 → 要不要接系统的音量广播（Android）。
  /// 关掉时原生会反注册广播，不留监听。
  void _syncVolumeBarHud(SettingsService settings, MintTheme? theme) {
    final on =
        Platform.isAndroid && settings.volumeUseThemeBar && theme != null;
    if (on == _volumeHudOn) return;
    _volumeHudOn = on;
    MintVolumeBar.setListening(on);
  }

  @override
  Widget build(BuildContext context) {
    return AppDynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return Consumer<SettingsService>(
          builder: (context, settings, child) {
            // 两支必须**同形**（外面 MiuixThemeController、里面 MaterialApp）：
            // 换风格只换叶子渲染哪一套，MaterialApp/Navigator 不重建，
            // 路由栈不动 —— local2api 那条「切风格不回首页」的关键设计。
            final dark = switch (settings.themeMode) {
              ThemeMode.light => false,
              ThemeMode.dark => true,
              ThemeMode.system => _systemBrightness == Brightness.dark,
            };

            // miuix 的动态取色：dynamic_color 插件拿到的系统取色直接喂
            // keyColor（非空时走同步 HCT 计算）。Android 侧 getCorePalette
            // 可用；桌面侧 getAccentColor。都没拿到时用种子色兜底。
            final systemScheme = settings.useDynamicColor
                ? (dark ? darkDynamic : lightDynamic)
                : null;
            // MIUI 主题包的主色优先于系统取色 / 种子色（主题「完整还原」）。
            final themePackage = MintThemeLibrary.instance.byId(
              settings.activeThemeId,
            );
            // 叶子组件（返回箭头 / 滚动条）直接读它，免得层层传。
            MintThemeLibrary.instance.activeTheme = themePackage;
            _syncVolumeBarHud(settings, themePackage);
            final themeAccent = settings.themeUseAccent
                ? themePackage?.accent
                : null;
            final miuixKeyColor =
                themeAccent ?? systemScheme?.primary ?? settings.themeSeedColor;

            // 供页面 State 里的 showMintSnack 兜底（页面作用域在 Scaffold 内，
            // State 的 context 取不到）。
            MintGlobalSnack.miuix = settings.uiStyle.isMiuix;
            // 叶子组件的图标风格（返回箭头 / 下载图标）。
            MintUiStyle.current = settings.uiStyle;

            return MiuixThemeController(
              colorSchemeMode: settings.useDynamicColor
                  ? miuixColorSchemeModeOf(themeMode: settings.themeMode)
                  : miuixDefaultColorSchemeModeOf(
                      themeMode: settings.themeMode,
                    ),
              keyColor: settings.useDynamicColor ? miuixKeyColor : null,
              paletteStyle: miuixPaletteStyleOf(FlexSchemeVariant.tonalSpot),
              fontWeightAdjustment: miuixFontWeightAdjustmentOf(
                settings.fontWeight,
              ),
              textStyles: ThemeFonts.family == null
                  ? null
                  : _miuixTextStylesWithFont(ThemeFonts.family!),
              isDark: dark,
              child: Builder(
                builder: (context) => MintStyleScope(
                  // 挂在 Navigator 之上：已入栈的页面在 build 里读风格就会
                  // 登记依赖，换风格时一起重绘（不清栈、不用重进页面）。
                  style: settings.uiStyle,
                  child: switch (settings.uiStyle) {
                    UiStyle.miuix => _buildMiuixApp(context, settings, dark),
                    UiStyle.fluent => _buildFluentApp(
                      context,
                      settings,
                      lightDynamic,
                      darkDynamic,
                      dark,
                    ),
                    UiStyle.materialExpressive => _buildMaterialApp(
                      context,
                      settings,
                      lightDynamic,
                      darkDynamic,
                      dark,
                    ),
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---- Material 3 ----

  Widget _buildMaterialApp(
    BuildContext context,
    SettingsService settings,
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
    bool dark,
  ) {
    final useDynamic =
        settings.useDynamicColor && lightDynamic != null && darkDynamic != null;

    final seed = _themeSeed(settings);
    final lightScheme = useDynamic
        ? lightDynamic
        : ColorScheme.fromSeed(seedColor: seed);
    final darkScheme = useDynamic
        ? darkDynamic
        : ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);

    _applyBackdrop(settings, dark, (dark ? darkScheme : lightScheme).surface);

    return _materialApp(
      theme: _theme(
        AppTheme.light(cornerRadius: settings.cornerRadius),
        lightScheme,
        settings.fontWeight,
      ),
      darkTheme: _theme(
        AppTheme.dark(cornerRadius: settings.cornerRadius),
        settings.isPureBlackMode ? _pureBlack(darkScheme) : darkScheme,
        settings.fontWeight,
      ),
      themeMode: settings.themeMode,
      scrollBehavior: const MintScrollbarBehavior(),
    );
  }

  // ---- 小米 HyperOS ----

  Widget _buildMiuixApp(
    BuildContext context,
    SettingsService settings,
    bool dark,
  ) {
    final miuix = MiuixTheme.of(context);
    var scheme = materialSchemeFromMiuix(miuix.colors, miuix.brightness);
    if (dark && settings.isPureBlackMode) scheme = _pureBlack(scheme);

    _applyBackdrop(settings, dark, miuix.colors.surface);

    final base = dark
        ? AppTheme.dark(cornerRadius: settings.cornerRadius)
        : AppTheme.light(cornerRadius: settings.cornerRadius);
    // 输入装饰归零：AppTheme 的 filled/fillColor 会漏进 MiuixTextField 内层的
    // Material TextField，在 miuix 自己的底色上再糊一层灰。
    final theme = _theme(
      base,
      scheme,
      settings.fontWeight,
    ).copyWith(inputDecorationTheme: kMiuixNeutralInputDecoration);

    return _materialApp(
      theme: theme,
      darkTheme: theme,
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      scrollBehavior: const MiuixOverscrollBehavior(),
    );
  }

  // ---- Windows 11 Fluent ----

  /// Fluent 风格：页面叶子仍是 Material 组件，但配色由
  /// [fluent.FluentThemeData] 桥过来（accent = 种子色/动态取色），
  /// 形状换成 Fluent 的 4/6/8 圆角；壳换成 fluent_ui 的 NavigationView。
  Widget _buildFluentApp(
    BuildContext context,
    SettingsService settings,
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
    bool dark,
  ) {
    final useDynamic =
        settings.useDynamicColor && lightDynamic != null && darkDynamic != null;
    final scheme = useDynamic
        ? (dark ? darkDynamic : lightDynamic)
        : ColorScheme.fromSeed(
            seedColor: _themeSeed(settings),
            brightness: dark ? Brightness.dark : Brightness.light,
          );

    _applyBackdrop(settings, dark, scheme.surface);

    final base = dark
        ? AppTheme.dark(cornerRadius: settings.cornerRadius)
        : AppTheme.light(cornerRadius: settings.cornerRadius);
    // Fluent 的形状语言：小圆角、方一些的按钮 / 输入框 / 卡片。
    final theme = _theme(base, scheme, settings.fontWeight).copyWith(
      cardTheme: base.cardTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );

    return _materialApp(
      theme: theme,
      darkTheme: theme,
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      scrollBehavior: const MintScrollbarBehavior(),
      fluentTheme: _fluentTheme(scheme, dark),
    );
  }

  fluent.FluentThemeData _fluentTheme(ColorScheme scheme, bool dark) {
    final accent = scheme.primary;
    return fluent.FluentThemeData(
      brightness: dark ? Brightness.dark : Brightness.light,
      fontFamily: kSystemFontFamily,
      accentColor: fluent.AccentColor.swatch({
        'normal': accent,
        'light': accent.withValues(alpha: 0.9),
        'lighter': accent.withValues(alpha: 0.8),
        'lightest': accent.withValues(alpha: 0.7),
        'dark': accent.withValues(alpha: 0.9),
        'darker': accent.withValues(alpha: 0.8),
        'darkest': accent.withValues(alpha: 0.7),
      }),
      // NavigationView 的 body 背景取这里；置透明由壳的 Material 容器铺底。
      scaffoldBackgroundColor: const Color(0x00000000),
      navigationPaneTheme: const fluent.NavigationPaneThemeData(
        backgroundColor: Color(0x00000000),
      ),
    );
  }

  /// Material / Fluent 的种子色：主题主色 > 用户种子色。
  Color _themeSeed(SettingsService settings) {
    final theme = MintThemeLibrary.instance.byId(settings.activeThemeId);
    if (settings.themeUseAccent && theme?.accent != null) return theme!.accent!;
    return settings.themeSeedColor;
  }

  /// 把主题字体套到 miuix 的全套 textStyles 上。
  MiuixTextStyles _miuixTextStylesWithFont(String family) {
    final base = defaultTextStyles();
    TextStyle f(TextStyle style) => style.copyWith(fontFamily: family);
    return base.copy(
      main: f(base.main),
      paragraph: f(base.paragraph),
      body1: f(base.body1),
      body2: f(base.body2),
      button: f(base.button),
      footnote1: f(base.footnote1),
      footnote2: f(base.footnote2),
      headline1: f(base.headline1),
      headline2: f(base.headline2),
      subtitle: f(base.subtitle),
      title1: f(base.title1),
      title2: f(base.title2),
      title3: f(base.title3),
      title4: f(base.title4),
    );
  }

  // ---- 公共 ----

  ThemeData _theme(ThemeData base, ColorScheme scheme, double fontWeight) {
    // copyWith(textTheme:) 是整体替换，裸 TextStyle（无 color）会丢掉
    // ThemeData 上色管线的结果。正确做法：在已解析的 TextTheme 上只改字重。
    var textTheme = _applyWeight(base.textTheme, fontWeight);
    var primaryTextTheme = base.primaryTextTheme;
    final family = ThemeFonts.family;
    if (family != null) {
      textTheme = textTheme.apply(fontFamily: family);
      primaryTextTheme = primaryTextTheme.apply(fontFamily: family);
    }
    var themed = base.copyWith(
      colorScheme: scheme,
      textTheme: textTheme,
      primaryTextTheme: primaryTextTheme,
    );
    // MIUI 主题声明的控件颜色直接套到 Material 叶子：滚动条拇指、复选框 /
    // 单选框选中态、滑块与进度、弹窗底色。miuix 自己的开关/按钮在各自
    // 组件里处理，这里兜住还没迁到 miuix 的 Material 控件。
    final themeControls = MintThemeLibrary.instance.activeTheme;
    if (themeControls != null) {
      final scrollbar = themeControls.scrollbarColor;
      if (scrollbar != null) {
        themed = themed.copyWith(
          scrollbarTheme: ScrollbarThemeData(
            thumbColor: WidgetStatePropertyAll(scrollbar),
          ),
        );
      }
      final checkbox = themeControls.checkboxColor;
      if (checkbox != null) {
        themed = themed.copyWith(
          checkboxTheme: CheckboxThemeData(
            fillColor: WidgetStateProperty.resolveWith(
              (states) =>
                  states.contains(WidgetState.selected) ? checkbox : null,
            ),
          ),
        );
      }
      final radio = themeControls.radioColor;
      if (radio != null) {
        themed = themed.copyWith(
          radioTheme: RadioThemeData(
            fillColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected) ? radio : null,
            ),
          ),
        );
      }
      final seekbar = themeControls.seekbarColor;
      if (seekbar != null) {
        themed = themed.copyWith(
          sliderTheme: themed.sliderTheme.copyWith(
            activeTrackColor: seekbar,
            thumbColor: seekbar,
          ),
          progressIndicatorTheme: themed.progressIndicatorTheme.copyWith(
            color: seekbar,
          ),
        );
      }
      final dialog = themeControls.dialogColor;
      if (dialog != null) {
        themed = themed.copyWith(
          dialogTheme: themed.dialogTheme.copyWith(
            backgroundColor: Color.alphaBlend(dialog, scheme.surface),
          ),
        );
      }
    }
    // 桌面三平台：点击涟漪换成 mdui v1 的实现（1400ms 缓扩散 + 300/600ms
    // 消散，见 widgets/mdui_ripple.dart）。Android / iOS 保持 Flutter 原生
    // InkRipple —— 触摸反馈跟系统走，别为了风格牺牲手感。
    if (!mintUsesMduiRipple) return themed;
    return themed.copyWith(
      splashFactory: mintSplashFactory,
      splashColor: mintSplashColor(scheme.brightness),
    );
  }

  static TextTheme _applyWeight(TextTheme t, double fontWeight) {
    FontWeight w() {
      if (fontWeight <= 100) return FontWeight.w100;
      if (fontWeight <= 200) return FontWeight.w200;
      if (fontWeight <= 300) return FontWeight.w300;
      if (fontWeight <= 400) return FontWeight.w400;
      if (fontWeight <= 500) return FontWeight.w500;
      if (fontWeight <= 600) return FontWeight.w600;
      if (fontWeight <= 700) return FontWeight.w700;
      if (fontWeight <= 800) return FontWeight.w800;
      return FontWeight.w900;
    }

    final weight = w();
    return t.copyWith(
      bodyLarge: t.bodyLarge?.copyWith(fontWeight: weight),
      bodyMedium: t.bodyMedium?.copyWith(fontWeight: weight),
      bodySmall: t.bodySmall?.copyWith(fontWeight: weight),
      titleLarge: t.titleLarge?.copyWith(fontWeight: weight),
      titleMedium: t.titleMedium?.copyWith(fontWeight: weight),
      titleSmall: t.titleSmall?.copyWith(fontWeight: weight),
      labelLarge: t.labelLarge?.copyWith(fontWeight: weight),
      labelMedium: t.labelMedium?.copyWith(fontWeight: weight),
      labelSmall: t.labelSmall?.copyWith(fontWeight: weight),
    );
  }

  static ColorScheme _pureBlack(ColorScheme scheme) => scheme.copyWith(
    surface: Colors.black,
    surfaceDim: Colors.black,
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: Colors.black,
    surfaceContainer: Colors.black,
    surfaceContainerHigh: Colors.black,
    surfaceContainerHighest: const Color(0xFF1C1C1E),
    surfaceTint: Colors.transparent,
  );

  Widget _materialApp({
    required ThemeData theme,
    required ThemeData darkTheme,
    required ThemeMode themeMode,
    ScrollBehavior? scrollBehavior,
    fluent.FluentThemeData? fluentTheme,
  }) {
    // 多语言：当前内置 zh-CN（界面文案即简体中文），声明 supported 后
    // Material/Fluent 组件自身的本地化（日期、工具提示等）也走中文。
    // Android 13+ 的 per-app 语言由 AppLocaleBridge 同步到系统设置。
    final code = widget.settings.uiLocale;
    final parts = code.split('-');
    final locale = code.isEmpty
        ? null
        : Locale(parts.first, parts.length > 1 ? parts[1] : null);
    return MaterialApp(
      title: 'Mint Launcher',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      navigatorObservers: [
        MintWindowChrome.instance.observer,
        liquidGlassBarRouteObserver,
      ],
      theme: theme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      scrollBehavior: scrollBehavior,
      locale: locale,
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      // 多语言 delegates：Material/Cupertino/Widgets 全局文案（zh-CN）+
      // fluent_ui 的组件（NavigationView / Flyout / ContentDialog…）——
      // 正常由 FluentApp 提供，我们挂在 MaterialApp 下面就要自己补，
      // 否则整个壳在构建期直接抛「No FluentLocalizations found」。
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        fluent.FluentLocalizations.delegate,
      ],
      // 根部强制系统字体 + 禁装饰继承：miuix 组件里裸 TextStyle 的文本
      // （侧栏标签等）实测拿不到 ThemeData.fontFamily，落到 Segoe UI 的
      // CJK 回退 —— 字体很怪还带下划线。
      builder: (context, child) {
        Widget page = child!;
        if (MintGlobalSnack.miuix) {
          page = Stack(
            children: [
              page,
              Positioned.fill(
                child: MiuixSnackbarHost(state: MintGlobalSnack.host),
              ),
            ],
          );
        }
        if (widget.settings.edgeScrollHaptic) {
          page = EdgeScrollHaptic(child: page);
        }
        // Fluent 风格：把 FluentTheme 挂到 Navigator 之上，所有路由里的
        // fluent_ui 组件（NavigationView 等）都能取到主题。
        if (fluentTheme != null) {
          page = fluent.FluentTheme(data: fluentTheme, child: page);
        }

        Widget content = Column(
          children: [
            MintWindowTitleBar(navigatorKey: _navigatorKey),
            Expanded(child: page),
          ],
        );
        // 标题栏右键菜单的宿主层（标题栏在 Navigator 之外，showMenu
        // 无处安放；自建 Overlay 让菜单盖在所有内容之上）。
        content = MintCaptionMenuHost(child: content);

        // 整合包拖入（桌面端）：全窗口 DropTarget，松开 .zip/.mrpack
        // 直接进导入流程（PCL2「拖入安装」同款）。
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          content = _ModpackDropZone(child: content);
        }

        // 窗口材质：DWM 材质在窗口后面，Flutter 视图大面积透明；
        // 这里垫一层主题色，保证壁纸再花正文也能读。
        if (WindowBackdrop.instance.isActive) {
          final scheme = Theme.of(context).colorScheme;
          final dark = scheme.brightness == Brightness.dark;
          final tint = WindowBackdrop.instance.tintFor(
            WindowBackdrop.instance.appliedMode,
            widget.settings.backdropTint,
            dark,
          );
          content = Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: scheme.surface.withValues(alpha: tint),
                ),
              ),
              content,
            ],
          );
        }
        // 应用内音量条：按音量键时盖一层主题的音量柱（IgnorePointer，不挡交互）。
        if (_volumeHudOn) {
          content = Stack(
            children: [
              content,
              const Positioned.fill(child: ThemeVolumeBar()),
            ],
          );
        }
        if (MintWindowChrome.instance.enabled) {
          content = MintWindowResizeFrame(child: content);
        }
        Widget result = DefaultTextStyle(
          style: Theme.of(
            context,
          ).textTheme.bodyMedium!.copyWith(decoration: TextDecoration.none),
          child: GlobalShortcutHost(
            navigatorKey: _navigatorKey,
            controller: widget.controller,
            child: content,
          ),
        );
        // 小米 HyperOS 小窗（freeform）下 MediaQuery.padding 会返回离谱值
        // （flutter#161086），SafeArea 会把整页往下挤。没异常时 helper 原样
        // 返回同一个实例，这里就不额外包一层。
        final rawMedia = MediaQuery.of(context);
        final safeMedia = sanitizeXiaomiFreeformPadding(rawMedia);
        if (!identical(safeMedia, rawMedia)) {
          result = MediaQuery(data: safeMedia, child: result);
        }
        return result;
      },
      home: _StyledHome(
        material: MaterialHomeShell(controller: widget.controller),
        miuix: MiuixHomeShell(controller: widget.controller),
        fluent: FluentHomeShell(controller: widget.controller),
      ),
    );
  }

  void _applyBackdrop(SettingsService settings, bool dark, Color surface) {
    WindowBackdrop.instance.apply(
      mode: settings.windowEffect,
      dark: dark,
      surfaceColor: surface,
    );
  }
}

/// 首页：三套 shell 在**同一个位置**换，类型恒定，路由栈不动。
/// 对应 InstallerX「引擎只决定叶子渲染哪一套，导航容器根本不受影响」的写法。
class _StyledHome extends StatelessWidget {
  const _StyledHome({
    required this.material,
    required this.miuix,
    required this.fluent,
  });

  final Widget material;
  final Widget miuix;
  final Widget fluent;

  @override
  Widget build(BuildContext context) {
    final style = context.select<SettingsService, UiStyle>((s) => s.uiStyle);
    return switch (style) {
      UiStyle.miuix => miuix,
      UiStyle.fluent => fluent,
      UiStyle.materialExpressive => material,
    };
  }
}

/// 全窗口整合包拖入层：拖文件进窗口时盖一层「松开导入整合包」提示，
/// 松开的 .zip / .mrpack 走 [startModpackImportFlow]。
class _ModpackDropZone extends StatefulWidget {
  const _ModpackDropZone({required this.child});

  final Widget child;

  @override
  State<_ModpackDropZone> createState() => _ModpackDropZoneState();
}

class _ModpackDropZoneState extends State<_ModpackDropZone> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) {
        if (_dragging) setState(() => _dragging = false);
      },
      onDragDone: (details) {
        setState(() => _dragging = false);
        String? pack;
        for (final f in details.files) {
          if (isModpackFileName(f.name)) {
            pack = f.path;
            break;
          }
        }
        if (pack == null || pack.isEmpty) return;
        startModpackImportFlow(context, path: pack);
      },
      child: Stack(
        children: [
          widget.child,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.42),
                  child: Center(
                    child: Card(
                      elevation: 8,
                      color: cs.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 30,
                          vertical: 24,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.archive_outlined,
                              size: 42,
                              color: cs.primary,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '松开导入整合包',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '支持 Modrinth .mrpack / CurseForge / MultiMC / HMCL .zip',
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
