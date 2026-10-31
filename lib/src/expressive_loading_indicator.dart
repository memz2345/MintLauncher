import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

class ExpressiveLoadingIndicator extends ProgressIndicator {
  final List<RoundedPolygon>? polygons;

  final BoxConstraints? constraints;

  /// 非空 = 定态：形变与旋转由它驱动，停掉不定态的定时器与全局自转。
  /// 对应 Compose `ContainedLoadingIndicator(progress = ...)`。
  const ExpressiveLoadingIndicator({
    super.key,
    super.color,
    super.value,
    this.polygons,
    this.constraints,
    super.semanticsLabel,
    super.semanticsValue,
  }) : assert(polygons != null ? polygons.length > 1 : true);

  @override
  State<ExpressiveLoadingIndicator> createState() =>
      _ExpressiveLoadingIndicatorState();
}

class _ExpressiveLoadingIndicatorState extends State<ExpressiveLoadingIndicator>
    with TickerProviderStateMixin {
  static final List<RoundedPolygon> _defaultPolygons = [
    MaterialShapes.softBurst,
    MaterialShapes.cookie9Sided,
    MaterialShapes.pentagon,
    MaterialShapes.pill,
    MaterialShapes.sunny,
    MaterialShapes.cookie4Sided,
    MaterialShapes.oval,
  ];

  static final BoxConstraints _defaultConstraints = BoxConstraints(
    minWidth: 48.0,
    minHeight: 48.0,
    maxWidth: 48.0,
    maxHeight: 48.0,
  );

  late final List<RoundedPolygon> _polygons;

  static const int _globalRotationDurationMs = 4666;
  static const int _morphIntervalMs = 650;
  static const double _fullRotation = 360.0;

  static const double _quarterRotation = _fullRotation / 4;
  static const double _activeSize = 38;

  late final List<Morph> _morphSequence;

  late final AnimationController _morphController;
  late final AnimationController _globalRotationController;
  int _currentMorphIndex = 0;
  double _morphRotationTargetAngle = _quarterRotation;

  Timer? _morphTimer;

  final _morphAnimationSpec = SpringSimulation(
    SpringDescription.withDampingRatio(ratio: 0.6, stiffness: 200.0, mass: 1.0),
    0.0,
    1.0,
    5.0,
    snapToEnd: true,
  );

  late BoxConstraints _constraints;
  late Color _color;

  @override
  Widget build(BuildContext context) {
    final indicatorTheme = ProgressIndicatorTheme.of(context);
    _color =
        widget.color ??
        indicatorTheme.color ??
        Theme.of(context).colorScheme.primary;
    _constraints =
        widget.constraints ?? indicatorTheme.constraints ?? _defaultConstraints;

    final activeIndicatorScale =
        _activeSize / math.min(_constraints.maxWidth, _constraints.maxHeight);

    final shapesScaleFactor =
        _calculateScaleFactor(_polygons) * activeIndicatorScale;

    final progress = widget.value;

    return Semantics.fromProperties(
      properties: SemanticsProperties(
        label: widget.semanticsLabel,
        value: widget.semanticsValue,
      ),
      child: RepaintBoundary(
        child: ConstrainedBox(
          constraints: _constraints,
          child: AspectRatio(
            aspectRatio: 1.0,
            child: progress == null
                ? _buildIndeterminate(shapesScaleFactor)
                : _buildDeterminate(
                    progress.clamp(0.0, 1.0),
                    shapesScaleFactor,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildIndeterminate(double shapesScaleFactor) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _morphController,
        _globalRotationController,
      ]),
      builder: (context, child) {
        final morphProgress = _morphController.value.clamp(0.0, 1.0);
        final globalRotationDegrees =
            _globalRotationController.value * _fullRotation;

        final totalRotationDegrees =
            morphProgress * _quarterRotation +
            _morphRotationTargetAngle +
            globalRotationDegrees;

        final totalRotationRadians = totalRotationDegrees * (math.pi / 180.0);

        return Transform.rotate(
          angle: totalRotationRadians,
          child: CustomPaint(
            painter: _MorphPainter(
              morph: _morphSequence[_currentMorphIndex],
              progress: morphProgress,
              color: _color,
              scaleFactor: shapesScaleFactor,
              repaint: Listenable.merge([
                _morphController,
                _globalRotationController,
              ]),
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }

  /// 定态：形变序号与段内进度都由 [progress] 直接算出，整体逆时针转 180°。
  Widget _buildDeterminate(double progress, double shapesScaleFactor) {
    final count = _morphSequence.length;
    final morphIndex = math.min((count * progress).floor(), count - 1);
    // p==1 落在最后一段时取 1，否则 (p*n)%1 会算出 0，形状会瞬间弹回起点。
    final morphProgress = (progress == 1.0 && morphIndex == count - 1)
        ? 1.0
        : (progress * count) % 1.0;
    final rotationRadians = -progress * 180.0 * (math.pi / 180.0);

    return Transform.rotate(
      angle: rotationRadians,
      child: CustomPaint(
        painter: _MorphPainter(
          morph: _morphSequence[morphIndex],
          progress: morphProgress,
          color: _color,
          scaleFactor: shapesScaleFactor,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  @override
  void dispose() {
    _morphTimer?.cancel();
    _morphController.dispose();
    _globalRotationController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    _polygons = widget.polygons ?? _defaultPolygons;

    _morphSequence = _createMorphSequence(_polygons, circularSequence: true);

    _morphController = AnimationController.unbounded(vsync: this);

    _globalRotationController = AnimationController(
      duration: const Duration(milliseconds: _globalRotationDurationMs),
      vsync: this,
    );

    if (widget.value == null) _startAnimations();
  }

  @override
  void didUpdateWidget(covariant ExpressiveLoadingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasDeterminate = oldWidget.value != null;
    final isDeterminate = widget.value != null;
    if (wasDeterminate == isDeterminate) return;
    if (isDeterminate) {
      _stopAnimations();
    } else {
      _startAnimations();
    }
  }

  List<Morph> _createMorphSequence(
    List<RoundedPolygon> polygons, {
    required bool circularSequence,
  }) {
    final morphs = <Morph>[];

    for (int i = 0; i < polygons.length; i++) {
      if (i + 1 < polygons.length) {
        morphs.add(Morph(polygons[i], polygons[i + 1]));
      } else if (circularSequence) {
        morphs.add(Morph(polygons[i], polygons[0]));
      }
    }

    return morphs;
  }

  double _calculateScaleFactor(List<RoundedPolygon> polygons) {
    var scaleFactor = 1.0;

    for (final polygon in polygons) {
      final bounds = polygon.calculateBounds();
      final maxBounds = polygon.calculateMaxBounds();

      final boundsWidth = bounds[2] - bounds[0];
      final boundsHeight = bounds[3] - bounds[1];

      final maxBoundsWidth = maxBounds[2] - maxBounds[0];
      final maxBoundsHeight = maxBounds[3] - maxBounds[1];

      final scaleX = boundsWidth / maxBoundsWidth;
      final scaleY = boundsHeight / maxBoundsHeight;

      scaleFactor = math.min(scaleFactor, math.max(scaleX, scaleY));
    }

    return scaleFactor;
  }

  void _startAnimations() {
    _globalRotationController.repeat();

    _morphTimer = Timer.periodic(
      const Duration(milliseconds: _morphIntervalMs),
      (_) => _startMorphCycle(),
    );

    _startMorphCycle();
  }

  void _stopAnimations() {
    _morphTimer?.cancel();
    _morphTimer = null;
    _globalRotationController.stop();
    _morphController.stop();
  }

  void _startMorphCycle() {
    if (!mounted) return;

    _currentMorphIndex = (_currentMorphIndex + 1) % _morphSequence.length;

    _morphRotationTargetAngle =
        (_morphRotationTargetAngle + _quarterRotation) % _fullRotation;

    _morphController
      ..value = 0.0
      ..animateWith(_morphAnimationSpec);
  }
}

class _MorphPainter extends CustomPainter {
  final Morph morph;
  final double progress;
  final Color color;

  final double scaleFactor;

  _MorphPainter({
    required this.morph,
    required this.progress,
    required this.color,
    this.scaleFactor = 1.0,
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = morph.toPath(progress: progress);
    final processedPath = _processPath(path, size);
    canvas.drawPath(
      processedPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_MorphPainter oldDelegate) {
    return oldDelegate.morph != morph ||
        oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.scaleFactor != scaleFactor;
  }

  Path _processPath(Path path, Size size) {
    final Matrix4 scaleMatrix = Matrix4.diagonal3Values(
      size.width * scaleFactor,
      size.height * scaleFactor,
      1,
    );
    final Path scaledPath = path.transform(scaleMatrix.storage);

    final Rect bounds = scaledPath.getBounds();
    final Offset translation =
        Offset(size.width / 2, size.height / 2) - bounds.center;
    final Path finalPath = scaledPath.shift(translation);

    return finalPath;
  }
}
