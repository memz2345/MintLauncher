import 'package:flutter_test/flutter_test.dart';

import 'package:mint/services/vtouch/vtouch_layout.dart';

void main() {
  group('布局模型（与 Android ControlLayout JSON 对齐）', () {
    test('JSON 字段名与 Android 完全一致，round-trip 无损', () {
      final c = VTouchControl(
        id: 'jump',
        label: '跳',
        keyCode: 32,
        nx: 0.88,
        ny: 0.80,
        sizeDp: 66,
      );
      final json = c.toJson();
      // Android ControlButton.toJson 的键：id/label/key/mouse/nx/ny/size/kind。
      expect(
        json.keys,
        containsAll([
          'id',
          'label',
          'key',
          'mouse',
          'nx',
          'ny',
          'size',
          'kind',
        ]),
      );
      final back = VTouchControl.fromJson(json);
      expect(back.id, c.id);
      expect(back.label, c.label);
      expect(back.keyCode, c.keyCode);
      expect(back.mouseButton, c.mouseButton);
      expect(back.nx, c.nx);
      expect(back.ny, c.ny);
      expect(back.sizeDp, c.sizeDp);
      expect(back.kind, c.kind);
    });

    test('kind 字符串与 Android ControlKind 枚举同名', () {
      expect(VTouchKind.joystick.id, 'JOYSTICK');
      expect(VTouchKind.button.id, 'BUTTON');
      expect(VTouchKind.mouse.id, 'MOUSE');
      // 未知 kind 回落 BUTTON（不炸）。
      expect(VTouchKindX.fromId('whatever'), VTouchKind.button);
    });

    test('默认布局：有摇杆、右下动作键、右上功能键', () {
      final defaults = vtouchDefaults();
      final stick = defaults.where((c) => c.isJoystick).toList();
      expect(stick, hasLength(1));
      expect(stick.first.id, 'stick');
      expect(stick.first.nx, lessThan(0.3)); // 左下
      expect(stick.first.ny, greaterThan(0.5));
      // 鼠标键（攻击=左键 / 使用=右键）。
      final mice = defaults.where((c) => c.isMouse).toList();
      expect(mice.map((c) => c.mouseButton), containsAll([0, 1]));
      // ESC（GLFW 256）与 WASD 摇杆并存。
      expect(defaults.any((c) => c.keyCode == 256), isTrue);
    });

    test('默认按键标签用键位名，不用中文（FCL 风格）', () {
      final defaults = vtouchDefaults();
      final cjk = RegExp(r'[\u4e00-\u9fff]');
      for (final c in defaults) {
        expect(
          cjk.hasMatch(c.label),
          isFalse,
          reason: '${c.id} 的标签「${c.label}」不应是中文',
        );
      }
      expect(defaults.firstWhere((c) => c.id == 'esc').label, 'ESC');
      expect(defaults.firstWhere((c) => c.id == 'inventory').label, 'E');
      expect(defaults.firstWhere((c) => c.id == 'jump').label, 'SPACE');
      expect(defaults.firstWhere((c) => c.id == 'attack').label, 'LMB');
    });

    test('旧中文默认标签迁移成键位名，自定义标签不覆盖', () {
      final old = [
        VTouchControl(id: 'esc', label: '菜单', keyCode: 256, nx: 0.9, ny: 0.4),
        VTouchControl(id: 'jump', label: '跳', keyCode: 32, nx: 0.8, ny: 0.8),
        VTouchControl(
          id: 'custom',
          label: '我的键',
          keyCode: 70,
          nx: 0.5,
          ny: 0.5,
        ),
      ];
      migrateVTouchLabels(old);
      expect(old[0].label, 'ESC');
      expect(old[1].label, 'SPACE');
      expect(old[2].label, '我的键');
    });

    test('坏布局回落默认并补摇杆（与 Android load 兜底一致）', () {
      // 半截布局：删掉摇杆后剩下的仍可用。
      final withoutStick = vtouchDefaults()
          .where((c) => !c.isJoystick)
          .map((c) => c.toJson())
          .toList();
      final parsed = [
        for (final item in withoutStick) VTouchControl.fromJson(item),
      ];
      expect(parsed.any((c) => c.isJoystick), isFalse);
    });
  });

  group('摇杆数学（GameInputView.updateJoystick 同款）', () {
    test('死区内：全松开（微抖不走）', () {
      final keys = joystickKeysFor(5, 5, 100);
      expect(keys.heldKeys, isEmpty);
    });

    test('推上方 = W；推下方 = S；推左 = A；推右 = D', () {
      expect(joystickKeysFor(0, -60, 100).heldKeys, {87}); // W
      expect(joystickKeysFor(0, 60, 100).heldKeys, {83}); // S
      expect(joystickKeysFor(-60, 0, 100).heldKeys, {65}); // A
      expect(joystickKeysFor(60, 0, 100).heldKeys, {68}); // D
    });

    test('推斜角 = 两键按住（W+A / S+D）', () {
      final wa = joystickKeysFor(-50, -50, 100);
      expect(wa.heldKeys, {87, 65});
      final sd = joystickKeysFor(50, 50, 100);
      expect(sd.heldKeys, {83, 68});
    });

    test('推出行程按方向截断，方向不变', () {
      final far = joystickKeysFor(0, -300, 100);
      expect(far.heldKeys, {87});
      // 截断后仍是斜角两键（右上方 = W+D）。
      final diagFar = joystickKeysFor(200, -200, 100);
      expect(diagFar.heldKeys, {87, 68});
    });

    test('半径非法时不按任何键', () {
      expect(joystickKeysFor(10, 10, 0).heldKeys, isEmpty);
    });
  });

  group('GLFW 键码 ↔ Windows VK', () {
    test('字母 / 数字 / 空格两边同值', () {
      expect(glfwToVk(87), 87); // W
      expect(glfwToVk(65), 65); // A
      expect(glfwToVk(49), 49); // 1
      expect(glfwToVk(32), 32); // Space
      expect(vkToGlfw(87), 87);
    });

    test('特殊键映射：ESC / TAB / 修饰键 / F5 / 方向键', () {
      expect(glfwToVk(256), 0x1B); // ESC
      expect(glfwToVk(258), 0x09); // TAB
      expect(glfwToVk(340), 0xA0); // LEFT SHIFT
      expect(glfwToVk(341), 0xA2); // LEFT CONTROL
      expect(glfwToVk(294), 0x74); // F5
      expect(glfwToVk(265), 0x26); // UP
      expect(glfwToVk(320), 0x60); // NUMPAD0
      // 逆映射对上。
      expect(vkToGlfw(0x1B), 256);
      expect(vkToGlfw(0xA0), 340);
      expect(vkToGlfw(0x74), 294);
      expect(vkToGlfw(0x26), 265);
    });

    test('映射成对：glfwToVk(vkToGlfw) 与 vkToGlfw(glfwToVk) 稳定', () {
      const glfwKeys = [
        32,
        49,
        65,
        87,
        256,
        257,
        258,
        262,
        263,
        264,
        265,
        294,
        320,
        340,
        341,
        342,
        344,
        345,
        346,
      ];
      for (final g in glfwKeys) {
        final vk = glfwToVk(g);
        expect(vk, isNonZero, reason: 'GLFW $g 应有 VK 映射');
        expect(vkToGlfw(vk), g, reason: 'VK $vk 往返应回 GLFW $g');
      }
    });

    test('未知键码返回 0（注入侧忽略，不炸）', () {
      expect(glfwToVk(0), 0);
      expect(glfwToVk(-5), 0);
      expect(glfwToVk(9999), 0);
      expect(vkToGlfw(0), 0);
      expect(vkToGlfw(0x07), 0); // 未列入的 VK
    });
  });

  group('键位标签（编辑器显示 / 捕捉）', () {
    test('glfwKeyLabel 常用键', () {
      expect(glfwKeyLabel(87), 'W');
      expect(glfwKeyLabel(32), 'Space');
      expect(glfwKeyLabel(256), 'Esc');
      expect(glfwKeyLabel(294), 'F5');
      expect(glfwKeyLabel(340), 'LShift');
      expect(glfwKeyLabel(0), '无');
    });

    test('Flutter keyLabel → GLFW：字母 / 方向 / F 键 / 修饰键', () {
      expect(glfwFromKeyLabel('A'), 65);
      expect(glfwFromKeyLabel('5'), 53);
      expect(glfwFromKeyLabel('Space'), 32);
      expect(glfwFromKeyLabel('Escape'), 256);
      expect(glfwFromKeyLabel('Arrow Left'), 263);
      expect(glfwFromKeyLabel('F5'), 294);
      expect(glfwFromKeyLabel('Shift Left'), 340);
      expect(glfwFromKeyLabel('Control Right'), 345);
      expect(glfwFromKeyLabel('-'), 45);
      expect(glfwFromKeyLabel('Nonsense'), 0);
    });

    test('mouseLabel', () {
      expect(mouseLabel(0), '左键');
      expect(mouseLabel(1), '右键');
      expect(mouseLabel(2), '中键');
    });
  });
}
