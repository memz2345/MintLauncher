import 'dart:async';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mint/services/vtouch/vtouch_layout.dart';

/// 桌面虚拟触控悬浮窗（子窗口引擎入口）。
///
/// runner 会用同一个 main 入口启动子引擎，args 是
/// `['multi_window', windowId, '{"kind":"vtouch"}']`（见 main.dart）。
///
/// 架构（与独立日志窗口同款）：
///   · 原生侧（windows/runner/vtouch_host.cpp）把这个子窗口改造成贴在
///     游戏画面上的悬浮层：无边框 / 置顶 / 不抢焦点，并用 SetWindowRgn
///     把「命中区」裁成各控件矩形 —— 控件之外点击直接穿到游戏；
///   · 注入也走原生通道 `mint/vtouch`（SendInput 键盘 / PostMessage 鼠标）；
///   · 配置与持久化在主引擎：这里通过 `mint/vtouch_main` / `mint/vtouch_overlay`
///     两条 WindowMethodChannel 与主引擎对账，自己不碰 SharedPreferences
///     （两引擎各有一份内存缓存，互写会互相覆盖）。
const MethodChannel _native = MethodChannel('mint/vtouch');
const WindowMethodChannel _toMain = WindowMethodChannel(
  'mint/vtouch_main',
  mode: ChannelMode.unidirectional,
);
const WindowMethodChannel _fromMain = WindowMethodChannel(
  'mint/vtouch_overlay',
  mode: ChannelMode.unidirectional,
);

/// 菜单球直径 / 面板宽度（dp）。面板用固定高度，原生 region 才能算得准。
const double kBallDp = 44;
const double kPanelWidth = 300;
const double kDialogWidth = 400;
const double kDialogHeight = 470;

Future<void> runVTouchOverlay(String windowId, String argument) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VTouchOverlayApp());
}

class VTouchOverlayApp extends StatelessWidget {
  const VTouchOverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      // 悬浮层只有控件矩形可见（原生 region 裁剪），根底色无所谓。
      home: const VTouchOverlayPage(),
    );
  }
}

/// 悬浮层主页面：控件栈 + 菜单球 + 编辑面板 + 键位编辑卡。
///
/// 交互语义照搬 Android GameInputView：
///   · 摇杆推杆 → WASD 开合（对角 = 两键，死区 24%）；
///   · 按键按下 / 抬起 → key down/up（手指滑出 1.45 倍半径自动松开）；
///   · 鼠标键按下 / 抬起 → 鼠标事件；
///   · 编辑模式下控件只拖动不注入，位置存归一化坐标。
class VTouchOverlayPage extends StatefulWidget {
  const VTouchOverlayPage({super.key});

  @override
  State<VTouchOverlayPage> createState() => _VTouchOverlayPageState();
}

class _VTouchOverlayPageState extends State<VTouchOverlayPage> {
  // ── 配置（主引擎 apply 推来）──
  List<VTouchControl> _controls = [];
  double _alpha = 0.9;
  double _scale = 1.0;
  double _ballX = 0.955;
  double _ballY = 0.05;
  bool _visible = false;
  int _pid = 0;
  bool _readySent = false;
  Timer? _readyRetry;

  /// 向主引擎要配置。MissingPluginException（子引擎插件通道还没注册好）
  /// 时每 300ms 重试，直到成功。
  void _requestReady() {
    if (_readySent || !mounted) return;
    _toMain
        .invokeMethod('ready')
        .then((_) {
          _readySent = true;
        })
        .catchError((Object e) {
          debugPrint('vtouch ready failed: $e');
          _readyRetry?.cancel();
          _readyRetry = Timer(const Duration(milliseconds: 300), () {
            if (mounted) _requestReady();
          });
        });
  }

  // ── 运行时状态 ──
  bool _editMode = false;
  bool _panelOpen = false;
  String? _selectedId;

  /// 正在打开的键位编辑卡（编辑的是副本，保存才回写）。
  VTouchControl? _editing;

  // ── 输入状态（Android GameInputView 同款）──
  int? _stickPointer;
  Offset _knob = Offset.zero;
  final Map<int, VTouchControl> _held = {};
  final Set<int> _pressedKeys = {};
  final Set<int> _downMouse = {};

  final FocusNode _captureFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _registerFromMain();
  }

  bool _fromMainRegistered = false;
  Timer? _fromMainRetry;

  /// 注册「主引擎 → 悬浮窗」的 apply / hide 处理。
  ///
  /// 子引擎的插件通道也是原生在窗口创建之后才注册的，initState 里第一次
  /// 注册可能直接抛 CHANNEL_UNREGISTERED / MissingPluginException；
  /// 不重试的话主引擎永远推不进来（表现就是悬浮层一直不出现）。
  void _registerFromMain() {
    if (_fromMainRegistered || !mounted) return;
    _fromMain
        .setMethodCallHandler(_onMainCall)
        .then((_) {
          _fromMainRegistered = true;
        })
        .catchError((Object e) {
          debugPrint('vtouch fromMain register failed: $e');
          _fromMainRetry?.cancel();
          _fromMainRetry = Timer(const Duration(milliseconds: 300), () {
            if (mounted) _registerFromMain();
          });
        });
  }

  @override
  void dispose() {
    _releaseEverything();
    _readyRetry?.cancel();
    _fromMainRetry?.cancel();
    _captureFocus.dispose();
    super.dispose();
  }

  // ───────────────────── 主引擎消息 ─────────────────────

  Future<dynamic> _onMainCall(MethodCall call) async {
    switch (call.method) {
      case 'apply':
        final args =
            (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
        final layout = <VTouchControl>[
          if (args['layout'] is List)
            for (final item in (args['layout'] as List))
              if (item is Map)
                VTouchControl.fromJson(item.cast<String, dynamic>()),
        ];
        if (!mounted) return true;
        setState(() {
          _pid = (args['pid'] as num?)?.toInt() ?? 0;
          _visible = (args['visible'] as bool?) ?? false;
          if (args['alpha'] is num) _alpha = (args['alpha'] as num).toDouble();
          if (args['scale'] is num) _scale = (args['scale'] as num).toDouble();
          if (args['ballX'] is num) _ballX = (args['ballX'] as num).toDouble();
          if (args['ballY'] is num) _ballY = (args['ballY'] as num).toDouble();
          if (layout.isNotEmpty) _controls = layout;
        });
        _releaseEverything();
        _closePanelIfInvisible();
        // 原生窗口随配置同步（幂等）。
        unawaited(_syncNativeWindow());
        return true;
      case 'hide':
        if (!mounted) return true;
        setState(() => _visible = false);
        _releaseEverything();
        _closePanelIfInvisible();
        unawaited(_syncNativeWindow());
        return true;
    }
    return null;
  }

  /// 配置收起 / 隐藏时把面板与编辑态一起收掉，别让下一轮 apply 回来时
  /// 界面还停在上次的状态里。
  void _closePanelIfInvisible() {
    if (_visible) return;
    _panelOpen = false;
    _editing = null;
    _labelController?.dispose();
    _labelController = null;
    _selectedId = null;
    if (_editMode) {
      _editMode = false;
      unawaited(_native.invokeMethod('setCaptureKeys', {'enabled': false}));
    }
  }

  /// 把显隐 / pid / 透明度同步给原生窗口。幂等，apply 与本地改动都走这里。
  Future<void> _syncNativeWindow() async {
    try {
      await _native.invokeMethod('configure', {
        'alpha': (_alpha * 255).round().clamp(0, 255),
      });
      await _native.invokeMethod('setTrackPid', {'pid': _pid});
      await _native.invokeMethod(_visible ? 'show' : 'hide');
    } catch (e) {
      debugPrint('vtouch native sync failed: $e');
    }
    _scheduleRegions();
  }

  // ───────────────────── region（命中区）同步 ─────────────────────

  bool _regionsPending = false;

  /// 帧渲染后把各控件的物理像素矩形发给原生（SetWindowRgn）。控件之外
  /// 区域窗口直接不存在，点击穿透到游戏 —— 所以每次布局 / 显隐变化后
  /// 都要重推一次。
  void _scheduleRegions() {
    if (_regionsPending) return;
    _regionsPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _regionsPending = false;
      if (!mounted) return;
      _pushRegions();
    });
  }

  void _pushRegions() {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final rects = <List<double>>[];
    final shapes = <int>[];

    void addRect(Offset center, double w, double h, int shape) {
      rects.add([
        (center.dx - w / 2) * dpr,
        (center.dy - h / 2) * dpr,
        (center.dx + w / 2) * dpr,
        (center.dy + h / 2) * dpr,
      ]);
      shapes.add(shape);
    }

    for (final c in _controls) {
      final side = _controlSide(c);
      addRect(
        Offset(c.nx * size.width, c.ny * size.height),
        c.isJoystick ? side : side + 2,
        c.isJoystick ? side : side + 2,
        c.isJoystick ? 1 : 0,
      );
    }
    addRect(
      Offset(_ballX * size.width, _ballY * size.height),
      kBallDp + 4,
      kBallDp + 4,
      1,
    );
    if (_panelOpen) {
      final h = math.min(560.0, size.height - 80);
      rects.add([
        (size.width - 12 - kPanelWidth) * dpr,
        64 * dpr,
        (size.width - 12) * dpr,
        (64 + h) * dpr,
      ]);
      shapes.add(0);
    }
    if (_editing != null) {
      addRect(
        Offset(size.width / 2, size.height / 2),
        kDialogWidth + 8,
        kDialogHeight + 8,
        0,
      );
    }
    _native
        .invokeMethod('setRegions', {'rects': rects, 'shapes': shapes})
        .catchError((Object e) {
          debugPrint('vtouch setRegions failed: $e');
          return <String, Object?>{};
        });
  }

  // ───────────────────── 持久化（回主引擎） ─────────────────────

  Future<void> _saveAll() async {
    try {
      await _toMain.invokeMethod('save', {
        'layout': [for (final c in _controls) c.toJson()],
        'alpha': _alpha,
        'scale': _scale,
        'ballX': _ballX,
        'ballY': _ballY,
      });
    } catch (e) {
      debugPrint('vtouch save failed: $e');
    }
  }

  // ───────────────────── 输入注入 ─────────────────────

  /// 面板开着 / 编辑中不注入（面板里点滑杆不该往游戏里敲键）。
  bool get _canInject => _visible && !_editMode && !_panelOpen;

  Future<void> _sendKey(int glfw, bool down) async {
    final vk = glfwToVk(glfw);
    debugPrint('vtouch: sendKey glfw=$glfw vk=$vk down=$down');
    if (vk <= 0) return;
    try {
      await _native.invokeMethod('injectKey', {'vk': vk, 'down': down});
    } catch (e) {
      debugPrint('injectKey failed: $e');
    }
  }

  /// 键开合去重（Android setKey 同款）：状态没变就不重发。
  void _setKey(int glfw, bool down) {
    if (glfw <= 0) return;
    if (down == _pressedKeys.contains(glfw)) return;
    if (down) {
      if (!_canInject) return;
      _pressedKeys.add(glfw);
    } else {
      _pressedKeys.remove(glfw);
    }
    unawaited(_sendKey(glfw, down));
  }

  void _setMouse(int button, bool down) {
    if (button < 0) return;
    if (down == _downMouse.contains(button)) return;
    if (down) {
      if (!_canInject) return;
      _downMouse.add(button);
    } else {
      _downMouse.remove(button);
    }
    _native
        .invokeMethod('injectMouse', {'button': button, 'down': down})
        .catchError((Object e) {
          debugPrint('injectMouse failed: $e');
          return <String, Object?>{};
        });
  }

  /// 界面切换 / 收起时清掉全部按住状态，避免 W / 空格 / 鼠标键卡住
  /// （Android releaseEverything 同款）。
  void _releaseEverything() {
    _stickPointer = null;
    for (final k in _pressedKeys.toList()) {
      _pressedKeys.remove(k);
      unawaited(_sendKey(k, false));
    }
    for (final m in _downMouse.toList()) {
      _downMouse.remove(m);
      _native.invokeMethod('injectMouse', {'button': m, 'down': false});
    }
    _held.clear();
    if (mounted) setState(() => _knob = Offset.zero);
  }

  // ───────────────────── 控件几何 ─────────────────────

  /// 摇杆直径 / 按键边长（逻辑像素，dp × 全局缩放）。
  double _controlSide(VTouchControl c) => math.max(36.0, c.sizeDp * _scale);

  VTouchControl? _joystick() {
    for (final c in _controls) {
      if (c.isJoystick) return c;
    }
    return null;
  }

  // ───────────────────── 摇杆 ─────────────────────

  void _updateJoystick(Offset pos, Size size) {
    final stick = _joystick();
    if (stick == null) return;
    final center = Offset(stick.nx * size.width, stick.ny * size.height);
    final r = _controlSide(stick) / 2;
    var d = pos - center;
    if (d.distance > r) {
      d = Offset.fromDirection(d.direction, r);
    }
    setState(() => _knob = d);
    final keys = joystickKeysFor(d.dx, d.dy, r);
    _setKey(87, keys.w);
    _setKey(65, keys.a);
    _setKey(83, keys.s);
    _setKey(68, keys.d);
  }

  // ───────────────────── 编辑模式 ─────────────────────

  void _toggleEditMode(bool value) {
    setState(() {
      _editMode = value;
      if (value) _selectedId = null;
    });
    _releaseEverything();
    if (!value) unawaited(_saveAll());
    _scheduleRegions();
  }

  void _moveControl(VTouchControl c, Offset pos, Size size) {
    setState(() {
      c.nx = (pos.dx / size.width).clamp(0.02, 0.98);
      c.ny = (pos.dy / size.height).clamp(0.02, 0.98);
    });
    _scheduleRegions();
  }

  void _addButton() {
    var n = _controls.length + 1;
    String id;
    do {
      id = 'btn$n';
      n++;
    } while (_controls.any((c) => c.id == id));
    final control = VTouchControl(id: id, label: 'KEY', nx: 0.5, ny: 0.5);
    setState(() {
      _controls.add(control);
      _selectedId = id;
    });
    unawaited(_saveAll());
    _scheduleRegions();
    _openBinding(control);
  }

  void _resetLayout() {
    setState(() {
      _controls = vtouchDefaults();
      _scale = 1.0;
      _alpha = 0.9;
      _selectedId = null;
      _editing = null;
    });
    _releaseEverything();
    unawaited(_saveAll());
    unawaited(_syncNativeWindow());
  }

  void _togglePanel() {
    setState(() => _panelOpen = !_panelOpen);
    _releaseEverything();
    _scheduleRegions();
  }

  void _hideOverlay() {
    _releaseEverything();
    setState(() {
      _visible = false;
      _panelOpen = false;
      _editing = null;
    });
    unawaited(_native.invokeMethod('hide'));
    unawaited(_toMain.invokeMethod('hide'));
  }

  // ───────────────────── 键位编辑卡 ─────────────────────

  /// 标签输入的 controller：编辑卡打开时创建，关闭时销毁（避免 build 里
  /// 反复重建导致光标跳动）。
  TextEditingController? _labelController;

  /// 打开编辑卡：窗口临时允许激活（文本框 / 键位捕捉要键盘焦点），关卡时
  /// 还给游戏。region 里会加上对话框矩形，黑底不会突然铺满全屏。
  Future<void> _openBinding(VTouchControl c) async {
    setState(() {
      _editing = c.copy();
      _labelController?.dispose();
      _labelController = TextEditingController(text: _editing!.label);
    });
    _releaseEverything();
    _scheduleRegions();
    try {
      await _native.invokeMethod('setCaptureKeys', {'enabled': true});
    } catch (_) {}
    _captureFocus.requestFocus();
  }

  Future<void> _closeBinding({bool save = false}) async {
    final editing = _editing;
    setState(() {
      _editing = null;
      _labelController?.dispose();
      _labelController = null;
    });
    if (save && editing != null) {
      final original = _controls.where((c) => c.id == editing.id).firstOrNull;
      if (original != null) {
        original
          ..label = editing.label
          ..keyCode = editing.keyCode
          ..mouseButton = editing.mouseButton
          ..sizeDp = editing.sizeDp;
      }
      unawaited(_saveAll());
    }
    _scheduleRegions();
    try {
      await _native.invokeMethod('setCaptureKeys', {'enabled': false});
    } catch (_) {}
  }

  void _deleteControl(String id) {
    setState(() {
      _controls.removeWhere((c) => c.id == id);
      _editing = null;
      _labelController?.dispose();
      _labelController = null;
      _selectedId = null;
    });
    _releaseEverything();
    unawaited(_saveAll());
    _scheduleRegions();
    unawaited(_native.invokeMethod('setCaptureKeys', {'enabled': false}));
  }

  // ───────────────────── build ─────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // 首帧就绪后向主引擎要配置（主引擎 apply → syncNativeWindow）。
    //
    // 注意：子引擎的插件通道（desktop_multi_window）是原生在窗口创建
    // **之后**才注册的（隐藏启动的子窗口尤其容易撞上），第一次 invoke
    // 可能拿到 MissingPluginException。这里持续重试直到成功，否则主引擎
    // 永远收不到 ready，就不会推配置，悬浮层一直不可见。
    if (!_readySent) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _requestReady());
    }
    if (!_fromMainRegistered) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _registerFromMain());
    }
    _scheduleRegions();

    return KeyboardListener(
      focusNode: _captureFocus,
      onKeyEvent: _onKeyEvent,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 控件（最底层）。
          for (final c in _controls) _buildControl(context, c, size),
          // 菜单球（盖在控件上：重叠时优先菜单，与 Android 一致）。
          _buildBall(size),
          // 编辑面板。
          if (_panelOpen) _buildPanel(context, size),
          // 键位编辑卡（最上层）。
          if (_editing != null) _buildBindingCard(context),
        ],
      ),
    );
  }

  void _onKeyEvent(KeyEvent event) {
    // 键位捕捉只在「绑定输入框」持焦时生效：标签 TextField 输入时事件会
    // 冒泡经过这里，不能把打字当成改键。
    if (_editing == null || !_captureFocus.hasFocus) return;
    if (event is KeyDownEvent) {
      final glfw = glfwFromKeyLabel(event.logicalKey.keyLabel);
      if (glfw > 0) setState(() => _editing?.keyCode = glfw);
    }
  }

  // ───────────────────── 控件 ─────────────────────

  Widget _buildControl(BuildContext context, VTouchControl c, Size size) {
    final side = _controlSide(c);
    final center = Offset(c.nx * size.width, c.ny * size.height);
    final left = center.dx - side / 2;
    final top = center.dy - side / 2;

    Widget visual;
    if (c.isJoystick) {
      visual = Stack(
        alignment: Alignment.center,
        children: [
          _JoystickPaint(
            side: side,
            knob: _stickPointer != null ? _knob : Offset.zero,
          ),
          if (_editMode)
            Text(
              c.label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      );
    } else {
      final pressed = _isPressed(c);
      visual = Container(
        width: side,
        height: side,
        decoration: BoxDecoration(
          // 与 Android GameInputView 同一档：正常黑 30%、按下提亮到白 46%。
          color: pressed
              ? Colors.white.withValues(alpha: 0.46)
              : Colors.black.withValues(alpha: 0.30),
          borderRadius: BorderRadius.circular(side * 0.22),
          border: Border.all(
            color: _editMode && _selectedId == c.id
                ? const Color(0xFF7EB6FF)
                : Colors.white.withValues(alpha: pressed ? 0.80 : 0.47),
            width: _editMode && _selectedId == c.id ? 2 : 1.4,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          c.label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.92),
            fontSize: c.label.length <= 2
                ? 13
                : (c.label.length == 3
                      ? 11.5
                      : (c.label.length == 4 ? 10.5 : 9.2)),
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    if (_editMode) {
      // 编辑模式：拖动改归一化位置，点按选中；不注入。
      return Positioned(
        key: ValueKey('vtouch-${c.id}'),
        left: left,
        top: top,
        width: side,
        height: side,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _selectedId = c.id),
          onPanStart: (d) => setState(() => _selectedId = c.id),
          onPanUpdate: (d) =>
              _moveControl(c, center + d.delta, MediaQuery.sizeOf(context)),
          child: visual,
        ),
      );
    }

    return Positioned(
      key: ValueKey('vtouch-${c.id}'),
      left: left,
      top: top,
      width: side,
      height: side,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _onControlDown(c, e, size),
        onPointerMove: (e) => _onControlMove(c, e, size),
        onPointerUp: (e) => _onControlUp(c, e),
        onPointerCancel: (e) => _onControlUp(c, e),
        child: visual,
      ),
    );
  }

  bool _isPressed(VTouchControl c) {
    if (c.isJoystick) return _stickPointer != null;
    if (_held.containsValue(c)) return true;
    if (c.isMouse) return _downMouse.contains(c.mouseButton);
    return c.keyCode != 0 && _pressedKeys.contains(c.keyCode);
  }

  void _onControlDown(VTouchControl c, PointerDownEvent e, Size size) {
    debugPrint(
      'vtouch: down ${c.id} key=${c.keyCode} mouse=${c.mouseButton} '
      'canInject=$_canInject local=${e.localPosition} size=$size dpr=${MediaQuery.devicePixelRatioOf(context)}',
    );
    if (!_canInject) return;
    if (c.isJoystick) {
      if (_stickPointer == null) {
        _stickPointer = e.pointer;
        _updateJoystick(e.localPosition, size);
      }
      return;
    }
    // 同一个键可能被两个指针按到：先到先得。
    if (_held.values.any((h) => h.id == c.id)) return;
    _held[e.pointer] = c;
    if (c.isMouse) {
      _setMouse(c.mouseButton, true);
    } else {
      _setKey(c.keyCode, true);
    }
    setState(() {});
  }

  void _onControlMove(VTouchControl c, PointerMoveEvent e, Size size) {
    if (c.isJoystick) {
      if (_stickPointer == e.pointer) _updateJoystick(e.localPosition, size);
      return;
    }
    final held = _held[e.pointer];
    if (held == null || held.id != c.id) return;
    // 手指 / 鼠标滑出 1.45 倍半径：松开（跟 FCL 一致）。
    // localPosition 是控件盒子内的坐标，加回盒子左上角得到窗口坐标。
    final global = e.localPosition + Offset(leftOf(c, size), topOf(c, size));
    final center = Offset(c.nx * size.width, c.ny * size.height);
    final radius = _controlSide(c) / 2;
    if ((global - center).distance > radius * 1.45) {
      _releaseHeld(e.pointer);
      setState(() {});
    }
  }

  double leftOf(VTouchControl c, Size size) =>
      c.nx * size.width - _controlSide(c) / 2;

  double topOf(VTouchControl c, Size size) =>
      c.ny * size.height - _controlSide(c) / 2;

  void _onControlUp(VTouchControl c, PointerEvent e) {
    if (c.isJoystick && _stickPointer == e.pointer) {
      _stickPointer = null;
      setState(() => _knob = Offset.zero);
      _setKey(87, false);
      _setKey(65, false);
      _setKey(83, false);
      _setKey(68, false);
      return;
    }
    _releaseHeld(e.pointer);
    setState(() {});
  }

  void _releaseHeld(int pointer) {
    final c = _held.remove(pointer);
    if (c == null) return;
    if (c.isMouse) {
      _setMouse(c.mouseButton, false);
    } else {
      _setKey(c.keyCode, false);
    }
  }

  // ───────────────────── 菜单球 ─────────────────────

  Widget _buildBall(Size size) {
    return Positioned(
      left: _ballX * size.width - (kBallDp + 4) / 2,
      top: _ballY * size.height - (kBallDp + 4) / 2,
      width: kBallDp + 4,
      height: kBallDp + 4,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _togglePanel,
        onPanUpdate: (d) {
          setState(() {
            _ballX = ((_ballX * size.width + d.delta.dx) / size.width).clamp(
              0.05,
              0.95,
            );
            _ballY = ((_ballY * size.height + d.delta.dy) / size.height).clamp(
              0.04,
              0.96,
            );
          });
          _scheduleRegions();
        },
        onPanEnd: (d) => unawaited(_saveAll()),
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _panelOpen
                ? Colors.white.withValues(alpha: 0.30)
                : Colors.black.withValues(alpha: 0.55),
            border: Border.all(color: Colors.white.withValues(alpha: 0.65)),
          ),
          child: Icon(
            _panelOpen ? Icons.close : Icons.sports_esports,
            size: 22,
            color: Colors.white.withValues(alpha: 0.92),
          ),
        ),
      ),
    );
  }

  // ───────────────────── 编辑面板 ─────────────────────

  Widget _buildPanel(BuildContext context, Size size) {
    final h = math.min(560.0, size.height - 80);
    return Positioned(
      right: 12,
      top: 64,
      width: kPanelWidth,
      height: h,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF00F1015),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '虚拟触控',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: '收起面板',
                    onPressed: _togglePanel,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.12)),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  SwitchListTile(
                    value: _editMode,
                    onChanged: _toggleEditMode,
                    title: const Text('编辑按键位置'),
                    subtitle: const Text(
                      '开启后拖动按键，点悬浮球收起面板',
                      style: TextStyle(fontSize: 12),
                    ),
                    dense: true,
                  ),
                  ListTile(
                    dense: true,
                    title: Text('按键大小 ${(_scale * 100).round()}%'),
                    subtitle: Slider(
                      value: _scale,
                      min: 0.7,
                      max: 1.6,
                      onChanged: (v) {
                        setState(() => _scale = v);
                        _scheduleRegions();
                      },
                      onChangeEnd: (v) => unawaited(_saveAll()),
                    ),
                  ),
                  ListTile(
                    dense: true,
                    title: Text('不透明度 ${(_alpha * 100).round()}%'),
                    subtitle: Slider(
                      value: _alpha,
                      min: 0.25,
                      max: 1.0,
                      onChanged: (v) {
                        setState(() => _alpha = v);
                        unawaited(
                          _native.invokeMethod('configure', {
                            'alpha': (v * 255).round().clamp(0, 255),
                          }),
                        );
                      },
                      onChangeEnd: (v) => unawaited(_saveAll()),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _addButton,
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('添加按键'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _resetLayout,
                            icon: const Icon(Icons.restart_alt, size: 18),
                            label: const Text('重置'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      '按键（点按改键位 / 标签）',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  for (final c in _controls)
                    ListTile(
                      dense: true,
                      selected: _selectedId == c.id,
                      onTap: () {
                        setState(() => _selectedId = c.id);
                        _openBinding(c);
                      },
                      title: Text(c.label),
                      subtitle: Text(
                        '${c.isJoystick
                            ? '摇杆'
                            : c.isMouse
                            ? mouseLabel(c.mouseButton)
                            : glfwKeyLabel(c.keyCode)} · '
                        '${c.sizeDp.round()}dp · (${(c.nx * 100).round()}, ${(c.ny * 100).round()})',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      trailing: Icon(switch (c.kind) {
                        VTouchKind.joystick => Icons.gamepad_outlined,
                        VTouchKind.mouse => Icons.mouse_outlined,
                        VTouchKind.button => Icons.keyboard_outlined,
                      }, size: 18),
                    ),
                  const Divider(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: OutlinedButton.icon(
                      onPressed: _hideOverlay,
                      icon: const Icon(Icons.visibility_off_outlined, size: 18),
                      label: const Text('收起悬浮层'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────── 键位编辑卡 ─────────────────────

  Widget _buildBindingCard(BuildContext context) {
    final c = _editing!;
    final isMouse = c.isMouse;
    final isStick = c.isJoystick;
    return Center(
      child: Container(
        width: kDialogWidth,
        height: kDialogHeight,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xF40F1015),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('编辑「${c.id}」', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              isStick ? '摇杆固定映射 WASD，可改标签与大小' : '设置标签与触发时注入的按键',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _labelController,
              onChanged: (v) => c.label = v,
              decoration: const InputDecoration(
                labelText: '标签',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 14),
            if (!isStick) ...[
              if (isMouse)
                // 鼠标键：左 / 右 / 中。
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('左键')),
                    ButtonSegment(value: 1, label: Text('右键')),
                    ButtonSegment(value: 2, label: Text('中键')),
                  ],
                  selected: {c.mouseButton.clamp(0, 2)},
                  onSelectionChanged: (s) =>
                      setState(() => c.mouseButton = s.first),
                )
              else ...[
                // 键盘键：点输入框捕捉下一次按键，或点快捷芯片。
                InkWell(
                  onTap: _captureFocus.requestFocus,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.keyboard, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '绑定：${glfwKeyLabel(c.keyCode)}（点击后按一个键）',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (label, glfw) in const [
                      ('Space', 32),
                      ('E', 69),
                      ('Q', 81),
                      ('T', 84),
                      ('F5', 294),
                      ('Tab', 258),
                      ('Shift', 340),
                      ('Ctrl', 341),
                      ('Esc', 256),
                      ('1', 49),
                      ('2', 50),
                      ('3', 51),
                    ])
                      ActionChip(
                        label: Text(
                          label,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () => setState(() => c.keyCode = glfw),
                      ),
                  ],
                ),
              ],
            ],
            const SizedBox(height: 14),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('大小 ${c.sizeDp.round()}dp'),
              subtitle: Slider(
                value: c.sizeDp.clamp(36, 200),
                min: 36,
                max: 200,
                onChanged: (v) => setState(() => c.sizeDp = v),
              ),
            ),
            const Spacer(),
            Row(
              children: [
                TextButton(
                  onPressed: () => _deleteControl(c.id),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                  ),
                  child: const Text('删除'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => unawaited(_closeBinding()),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => unawaited(_closeBinding(save: true)),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 摇杆绘制：透明感底盘 + 推杆（Android GameInputView 的 FCL 风格）。
class _JoystickPaint extends StatelessWidget {
  const _JoystickPaint({required this.side, required this.knob});

  final double side;
  final Offset knob;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(side),
      painter: _JoystickPainter(knob: knob),
    );
  }
}

class _JoystickPainter extends CustomPainter {
  const _JoystickPainter({required this.knob});

  final Offset knob;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final base = Paint()
      ..color = Colors.black.withValues(alpha: 0.22)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.47)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawCircle(center, r, base);
    canvas.drawCircle(center, r, stroke);
    // 中心小点：回中位置有参照（Android 同款）。
    final dot = Paint()..color = Colors.white.withValues(alpha: 0.27);
    canvas.drawCircle(center, r * 0.055, dot);
    final knobR = r * 0.30;
    final knobPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.23)
      ..style = PaintingStyle.fill;
    final knobStroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.68)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawCircle(center + knob, knobR, knobPaint);
    canvas.drawCircle(center + knob, knobR, knobStroke);
  }

  @override
  bool shouldRepaint(_JoystickPainter oldDelegate) => oldDelegate.knob != knob;
}
