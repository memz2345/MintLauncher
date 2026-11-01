import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mint/ui/window_chrome.dart';

/// iOS 26+ 的原生返回键（平台视图 `mint/native_back_button`）。
///
/// UIKit 负责整颗按钮：`UIButton.Configuration.glass()` 的系统玻璃底盘、
/// SF Symbol `chevron.backward`（iOS 26 返回图标）、按压回弹；长按由
/// `UIContextMenuInteraction` 弹系统 context menu（竖向原生玻璃层级菜单）。
/// Flutter 只负责布局和路由结果：
///   - 点按 → `onBack`（Navigator.maybePop）
///   - 长按选层 → `onSelect(index)`（popUntil 对应 PageRoute）
class IosNativeBackButton extends StatefulWidget {
  const IosNativeBackButton({
    super.key,
    required this.targets,
    required this.onBack,
    required this.onSelect,
    this.glass = true,
    this.dark = false,
  });

  /// 当前层级在前、更早层级在后（和系统返回菜单一致）。
  final List<MintBackTarget> targets;

  final VoidCallback onBack;
  final ValueChanged<int> onSelect;
  final bool glass;
  final bool dark;

  @override
  State<IosNativeBackButton> createState() => _IosNativeBackButtonState();
}

class _IosNativeBackButtonState extends State<IosNativeBackButton> {
  MethodChannel? _channel;

  void _onPlatformViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final channel = MethodChannel('mint/ios_back_button_$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted) return null;
      switch (call.method) {
        case 'onBackPressed':
          widget.onBack();
        case 'onBackMenuSelected':
          final args = call.arguments;
          final index = args is Map ? (args['index'] as num?)?.toInt() : null;
          if (index != null) widget.onSelect(index);
      }
      return null;
    });
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: UiKitView(
        viewType: 'mint/native_back_button',
        creationParams: {
          'titles': [for (final t in widget.targets) t.title],
          'currentIndex': 0,
          'glass': widget.glass,
          'dark': widget.dark,
        },
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      ),
    );
  }
}
