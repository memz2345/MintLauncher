import 'dart:math' as math;

/// 桌面虚拟触控的布局模型。
///
/// 字段名与 Android 侧 `ControlLayout.kt` 的 ControlButton JSON 完全一致
/// （id / label / key / mouse / nx / ny / size / kind），key 用 **GLFW 键码**
/// —— 两平台的布局 JSON 可以直接互拷。桌面端注入时经 [glfwToVk] 翻成
/// Windows 虚拟键。
///
/// 坐标是 0..1 归一化（相对**游戏画面矩形**），换分辨率 / 换窗口大小布局
/// 不跑位；size 是 dp（乘全局 scale），与 Android 语义一致。
class VTouchControl {
  VTouchControl({
    required this.id,
    required this.label,
    this.keyCode = 0,
    this.mouseButton = -1,
    required this.nx,
    required this.ny,
    this.sizeDp = 52,
    this.kind = VTouchKind.button,
  });

  /// 稳定 id（重命名 / 改键不换 id，编辑面板按它定位）。
  final String id;
  String label;

  /// GLFW 键码（0 = 无键绑定）。W=87 A=65 S=83 D=68 Space=32 ESC=256…
  int keyCode;

  /// 鼠标键：0=左 1=右 2=中，-1 = 非 MOUSE 元件。
  int mouseButton;

  /// 归一化中心点（0..1，相对游戏画面矩形）。
  double nx, ny;

  /// 边长（BUTTON/MOUSE）或直径（JOYSTICK），dp。
  double sizeDp;

  VTouchKind kind;

  bool get isJoystick => kind == VTouchKind.joystick;
  bool get isMouse => kind == VTouchKind.mouse;

  VTouchControl copy() => VTouchControl(
    id: id,
    label: label,
    keyCode: keyCode,
    mouseButton: mouseButton,
    nx: nx,
    ny: ny,
    sizeDp: sizeDp,
    kind: kind,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'key': keyCode,
    'mouse': mouseButton,
    'nx': nx,
    'ny': ny,
    'size': sizeDp,
    'kind': kind.id,
  };

  factory VTouchControl.fromJson(Map<String, Object?> json) => VTouchControl(
    id: (json['id'] as String?) ?? '',
    label: (json['label'] as String?) ?? '',
    keyCode: (json['key'] as num?)?.toInt() ?? 0,
    mouseButton: (json['mouse'] as num?)?.toInt() ?? -1,
    nx: (json['nx'] as num?)?.toDouble() ?? 0.5,
    ny: (json['ny'] as num?)?.toDouble() ?? 0.5,
    sizeDp: (json['size'] as num?)?.toDouble() ?? 52,
    kind: VTouchKindX.fromId(json['kind'] as String?),
  );
}

/// 控件类型（与 Android ControlKind 对齐）。
enum VTouchKind {
  /// 虚拟摇杆：位移 → WASD 开合（对角 = 两键）。
  joystick('JOYSTICK'),

  /// 普通按键：按下 / 抬起发键盘事件。
  button('BUTTON'),

  /// 鼠标键：按下 / 抬起发鼠标事件（攻击 / 使用）。
  mouse('MOUSE');

  const VTouchKind(this.id);

  final String id;
}

class VTouchKindX {
  VTouchKindX._();

  static VTouchKind fromId(String? id) => VTouchKind.values.firstWhere(
    (k) => k.id == id,
    orElse: () => VTouchKind.button,
  );
}

/// 默认布局：照搬 FCL「手机横屏」习惯（与 Android ControlLayout.defaults()
/// 同一套 id 与坐标），左下摇杆、右下动作键、右上功能键。
///
/// 标签用**键位名**（E / ESC / SHIFT / SPACE…），不用中文；摇杆的 "WASD"
/// 只在编辑态显示，正常游戏里 FCL 风格不写文字。
List<VTouchControl> vtouchDefaults() => [
  // 左下：移动摇杆
  VTouchControl(
    id: 'stick',
    label: 'WASD',
    nx: 0.13,
    ny: 0.74,
    sizeDp: 148,
    kind: VTouchKind.joystick,
  ),
  // 右下：动作
  VTouchControl(
    id: 'jump',
    label: 'SPACE',
    keyCode: 32,
    nx: 0.88,
    ny: 0.80,
    sizeDp: 66,
  ),
  VTouchControl(
    id: 'sneak',
    label: 'SHIFT',
    keyCode: 340,
    nx: 0.74,
    ny: 0.88,
    sizeDp: 52,
  ),
  VTouchControl(
    id: 'sprint',
    label: 'CTRL',
    keyCode: 341,
    nx: 0.74,
    ny: 0.70,
    sizeDp: 52,
  ),
  VTouchControl(
    id: 'attack',
    label: 'LMB',
    mouseButton: 0,
    nx: 0.90,
    ny: 0.58,
    sizeDp: 60,
    kind: VTouchKind.mouse,
  ),
  VTouchControl(
    id: 'use',
    label: 'RMB',
    mouseButton: 1,
    nx: 0.80,
    ny: 0.44,
    sizeDp: 56,
    kind: VTouchKind.mouse,
  ),
  // 右上：功能
  VTouchControl(
    id: 'inventory',
    label: 'E',
    keyCode: 69,
    nx: 0.955,
    ny: 0.14,
    sizeDp: 46,
  ),
  VTouchControl(
    id: 'drop',
    label: 'Q',
    keyCode: 81,
    nx: 0.875,
    ny: 0.14,
    sizeDp: 46,
  ),
  VTouchControl(
    id: 'perspective',
    label: 'F5',
    keyCode: 294,
    nx: 0.795,
    ny: 0.14,
    sizeDp: 46,
  ),
  VTouchControl(
    id: 'chat',
    label: 'T',
    keyCode: 84,
    nx: 0.955,
    ny: 0.27,
    sizeDp: 46,
  ),
  VTouchControl(
    id: 'tab',
    label: 'TAB',
    keyCode: 258,
    nx: 0.875,
    ny: 0.27,
    sizeDp: 46,
  ),
  VTouchControl(
    id: 'slot1',
    label: '1',
    keyCode: 49,
    nx: 0.795,
    ny: 0.27,
    sizeDp: 46,
  ),
  VTouchControl(
    id: 'esc',
    label: 'ESC',
    keyCode: 256,
    nx: 0.955,
    ny: 0.40,
    sizeDp: 46,
  ),
];

/// 旧默认标签 → 新键位名。只迁移**仍是旧默认**的标签；用户自己改过的不动。
const Map<String, String> _legacyLabels = {
  'stick': '移动',
  'jump': '跳',
  'sneak': '潜行',
  'sprint': '疾跑',
  'attack': '攻击',
  'use': '使用',
  'inventory': '背包',
  'drop': '丢弃',
  'perspective': '视角',
  'chat': '聊天',
  'tab': '玩家',
  'esc': '菜单',
};

/// 把旧中文默认标签迁移成键位名（与 Android ControlLayout.load 同语义）。
List<VTouchControl> migrateVTouchLabels(List<VTouchControl> controls) {
  final keyLabels = {for (final c in vtouchDefaults()) c.id: c.label};
  for (final c in controls) {
    if (_legacyLabels[c.id] == c.label) {
      c.label = keyLabels[c.id] ?? c.label;
    }
  }
  return controls;
}

/// 摇杆位移 → WASD 的纯函数（GameInputView.updateJoystick 的 Dart 版）。
///
/// 输入推杆相对底盘中心的位移与底盘半径；输出四个键的按下状态。
/// 死区 24%：微抖别让角色自己走；推到边缘外按半径截断（模拟摇杆行程）。
class JoystickKeys {
  const JoystickKeys({
    required this.w,
    required this.a,
    required this.s,
    required this.d,
  });

  final bool w;
  final bool a;
  final bool s;
  final bool d;

  /// 按下的 GLFW 键码集合（测试与注入共用）。
  Set<int> get heldKeys => {if (w) 87, if (a) 65, if (s) 83, if (d) 68};

  @override
  bool operator ==(Object other) =>
      other is JoystickKeys &&
      other.w == w &&
      other.a == a &&
      other.s == s &&
      other.d == d;

  @override
  int get hashCode => Object.hash(w, a, s, d);
}

JoystickKeys joystickKeysFor(double dx, double dy, double radius) {
  if (radius <= 0) {
    return const JoystickKeys(w: false, a: false, s: false, d: false);
  }
  final d = math.sqrt(dx * dx + dy * dy);
  final dead = radius * 0.24;
  // 位移超出行程就按方向截到边缘，方向不变。
  final nx = d > radius ? dx / d * radius : dx;
  final ny = d > radius ? dy / d * radius : dy;
  return JoystickKeys(w: ny < -dead, s: ny > dead, a: nx < -dead, d: nx > dead);
}

// ───────────────────── GLFW 键码 ↔ Windows VK ─────────────────────

/// GLFW 键码 → Windows 虚拟键（VK）。可打印 ASCII（字母 / 数字 / 空格）
/// 两边同值；其余查表。查不到返回 0（注入侧直接忽略）。
int glfwToVk(int glfw) {
  if (glfw <= 0) return 0;
  // 字母 / 数字 / 空格：GLFW 用 ASCII，VK 同值。
  if (glfw == 32) return 32; // space
  if (glfw >= 48 && glfw <= 57) return glfw; // 0-9
  if (glfw >= 65 && glfw <= 90) return glfw; // A-Z
  // 标点（GLFW 用 ANSI 位置码）→ VK_OEM_*。
  const oem = <int, int>{
    39: 0xDE, // ' → VK_OEM_7
    44: 0xBC, // , → VK_OEM_COMMA
    45: 0xBD, // - → VK_OEM_MINUS
    46: 0xBE, // . → VK_OEM_PERIOD
    47: 0xBF, // / → VK_OEM_2
    59: 0xBA, // ; → VK_OEM_1
    61: 0xBB, // = → VK_OEM_PLUS
    91: 0xDB, // [ → VK_OEM_4
    92: 0xDC, // \ → VK_OEM_5
    93: 0xDD, // ] → VK_OEM_6
    96: 0xC0, // ` → VK_OEM_3
  };
  if (oem.containsKey(glfw)) return oem[glfw]!;
  // 功能键 F1..F24 = GLFW 290..313。
  if (glfw >= 290 && glfw <= 313) return glfw - 290 + 0x70; // VK_F1..
  // 小键盘 0-9 = GLFW 320..329。
  if (glfw >= 320 && glfw <= 329) return glfw - 320 + 0x60; // VK_NUMPAD0..
  const table = <int, int>{
    256: 0x1B, // ESC
    257: 0x0D, // ENTER
    258: 0x09, // TAB
    259: 0x08, // BACKSPACE
    260: 0x2D, // INSERT
    261: 0x2E, // DELETE
    262: 0x27, // RIGHT
    263: 0x25, // LEFT
    264: 0x28, // DOWN
    265: 0x26, // UP
    266: 0x21, // PAGE UP
    267: 0x22, // PAGE DOWN
    268: 0x24, // HOME
    269: 0x23, // END
    280: 0x14, // CAPS LOCK
    281: 0x91, // SCROLL LOCK
    282: 0x90, // NUM LOCK
    283: 0x2C, // PRINT SCREEN
    284: 0x13, // PAUSE
    330: 0x6E, // KP_DECIMAL
    331: 0x6F, // KP_DIVIDE
    332: 0x6A, // KP_MULTIPLY
    333: 0x6D, // KP_SUBTRACT
    334: 0x6B, // KP_ADD
    335: 0x0D, // KP_ENTER
    336: 0xBB, // KP_EQUAL ≈ =
    340: 0xA0, // LEFT SHIFT
    341: 0xA2, // LEFT CONTROL
    342: 0xA4, // LEFT ALT
    343: 0x5B, // LEFT SUPER
    344: 0xA1, // RIGHT SHIFT
    345: 0xA3, // RIGHT CONTROL
    346: 0xA5, // RIGHT ALT
    347: 0x5C, // RIGHT SUPER
    348: 0x5D, // MENU
  };
  return table[glfw] ?? 0;
}

/// Windows VK → GLFW 键码（键位捕捉编辑用，glfwToVk 的逆）。
int vkToGlfw(int vk) {
  if (vk <= 0) return 0;
  if (vk == 32) return 32;
  if (vk >= 48 && vk <= 57) return vk;
  if (vk >= 65 && vk <= 90) return vk;
  if (vk >= 0x70 && vk <= 0x87) return vk - 0x70 + 290; // F1..F24
  if (vk >= 0x60 && vk <= 0x69) return vk - 0x60 + 320; // NUMPAD0..9
  const table = <int, int>{
    0xBA: 59,
    0xBB: 61,
    0xBC: 44,
    0xBD: 45,
    0xBE: 46,
    0xBF: 47,
    0xC0: 96,
    0xDB: 91,
    0xDC: 92,
    0xDD: 93,
    0xDE: 39,
    0x1B: 256,
    0x0D: 257,
    0x09: 258,
    0x08: 259,
    0x2D: 260,
    0x2E: 261,
    0x27: 262,
    0x25: 263,
    0x28: 264,
    0x26: 265,
    0x21: 266,
    0x22: 267,
    0x24: 268,
    0x23: 269,
    0x14: 280,
    0x91: 281,
    0x90: 282,
    0x2C: 283,
    0x13: 284,
    0x6E: 330,
    0x6F: 331,
    0x6A: 332,
    0x6D: 333,
    0x6B: 334,
    0xA0: 340,
    0xA2: 341,
    0xA4: 342,
    0x5B: 343,
    0xA1: 344,
    0xA3: 345,
    0xA5: 346,
    0x5C: 347,
    0x5D: 348,
  };
  return table[vk] ?? 0;
}

/// GLFW 键码 → 人读标签（摇杆 / 按钮编辑器里显示绑定）。
String glfwKeyLabel(int glfw) {
  if (glfw <= 0) return '无';
  if (glfw == 32) return 'Space';
  if (glfw >= 48 && glfw <= 57) return String.fromCharCode(glfw);
  if (glfw >= 65 && glfw <= 90) return String.fromCharCode(glfw);
  if (glfw >= 290 && glfw <= 313) return 'F${glfw - 290 + 1}';
  if (glfw >= 320 && glfw <= 329) return 'Num ${(glfw - 320)}';
  const table = <int, String>{
    39: "'",
    44: ',',
    45: '-',
    46: '.',
    47: '/',
    59: ';',
    61: '=',
    91: '[',
    92: '\\',
    93: ']',
    96: '`',
    256: 'Esc',
    257: 'Enter',
    258: 'Tab',
    259: 'Backspace',
    260: 'Insert',
    261: 'Delete',
    262: '→',
    263: '←',
    264: '↓',
    265: '↑',
    266: 'PageUp',
    267: 'PageDown',
    268: 'Home',
    269: 'End',
    280: 'CapsLock',
    282: 'NumLock',
    330: 'Num.',
    331: 'Num/',
    332: 'Num*',
    333: 'Num-',
    334: 'Num+',
    340: 'LShift',
    341: 'LCtrl',
    342: 'LAlt',
    343: 'LWin',
    344: 'RShift',
    345: 'RCtrl',
    346: 'RAlt',
    347: 'RWin',
    348: 'Menu',
  };
  return table[glfw] ?? 'GLFW $glfw';
}

/// 鼠标键标签。
String mouseLabel(int button) => switch (button) {
  0 => '左键',
  1 => '右键',
  2 => '中键',
  _ => '鼠标 $button',
};

/// Flutter 键盘事件的 keyLabel → GLFW 键码（键位捕捉用）。
///
/// 悬浮窗编辑键位时监听下一次按键，logicalKey.keyLabel 在 Windows 上是
/// 「A / 1 / Space / Escape / Arrow Left / Shift Left / F5 / - / =」这一套，
/// 查表转 GLFW 码；捕捉不到返回 0。
int glfwFromKeyLabel(String label) {
  final l = label.trim();
  if (l.isEmpty) return 0;
  // 字母（keyLabel 是大写单字符）与数字。
  if (l.length == 1) {
    final c = l.codeUnitAt(0);
    if ((c >= 65 && c <= 90) || (c >= 48 && c <= 57)) return c;
    const punct = <String, int>{
      "'": 39,
      ',': 44,
      '-': 45,
      '.': 46,
      '/': 47,
      ';': 59,
      '=': 61,
      '[': 91,
      '\\': 92,
      ']': 93,
      '`': 96,
    };
    if (punct.containsKey(l)) return punct[l]!;
    return 0;
  }
  const table = <String, int>{
    'Space': 32,
    'Escape': 256,
    'Enter': 257,
    'Tab': 258,
    'Backspace': 259,
    'Insert': 260,
    'Delete': 261,
    'Arrow Right': 262,
    'Arrow Left': 263,
    'Arrow Down': 264,
    'Arrow Up': 265,
    'Page Up': 266,
    'Page Down': 267,
    'Home': 268,
    'End': 269,
    'Caps Lock': 280,
    'Num Lock': 282,
    'Shift Left': 340,
    'Control Left': 341,
    'Alt Left': 342,
    'Shift Right': 344,
    'Control Right': 345,
    'Alt Right': 346,
  };
  if (table.containsKey(l)) return table[l]!;
  final f = RegExp(r'^F(\d{1,2})$').firstMatch(l);
  if (f != null) {
    final n = int.tryParse(f.group(1)!);
    if (n != null && n >= 1 && n <= 24) return 290 + n - 1;
  }
  return 0;
}
