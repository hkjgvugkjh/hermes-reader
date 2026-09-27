import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A lightweight, loop-friendly splash animation of a little robot flipping a
/// book page from right to left. Drawn with a [CustomPainter] so it needs no
/// image assets and scales to any size.
class RobotReadingAnimation extends StatefulWidget {
  const RobotReadingAnimation({super.key, this.size = 140});

  /// Width/height of the square animation area.
  final double size;

  @override
  State<RobotReadingAnimation> createState() => _RobotReadingAnimationState();
}

class _RobotReadingAnimationState extends State<RobotReadingAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brand = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
          painter: _RobotPainter(
            progress: _c.value,
            brand: brand,
          ),
        ),
      ),
    );
  }
}

class _RobotPainter extends CustomPainter {
  _RobotPainter({required this.progress, required this.brand});

  /// 0..1 loop position.
  final double progress;
  final Color brand;

  static const _paper = Color(0xFFFDFDFF);
  static const _paperEdge = Color(0xFFDEDBEB);
  static const _robot = Colors.white;
  static const _robotShade = Color(0xFFE4E2F0);
  static const _eye = Color(0xFF282242);
  static const _eyeGlow = Color(0xFF96EBFF);
  static const _accent = Color(0xFFFFC759);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final s = math.min(w, h);

    // Small bob so the robot feels alive.
    final bob = math.sin(progress * 2 * math.pi) * (s * 0.012);

    _paintBook(canvas, s, h);
    _paintRobot(canvas, s, h, bob);
  }

  void _paintBook(Canvas canvas, double s, double h) {
    final bookW = s * 0.66;
    final bookH = s * 0.22;
    final bx = (s - bookW) / 2;
    final by = h * 0.72;
    final spineX = bx + bookW / 2;

    final page = Paint()..color = _paper;
    final edge = Paint()
      ..color = _paperEdge
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.006;

    // Two spread pages.
    final rr = RRect.fromRectAndRadius(
      Rect.fromLTWH(bx, by, bookW, bookH),
      Radius.circular(s * 0.02),
    );
    canvas.drawRRect(rr, page);
    canvas.drawRRect(rr, edge);

    // Spine.
    canvas.drawLine(
      Offset(spineX, by + s * 0.01),
      Offset(spineX, by + bookH - s * 0.01),
      edge,
    );

    // Left page ruling.
    final rule = Paint()
      ..color = _paperEdge
      ..strokeWidth = s * 0.008
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final y = by + s * 0.045 + i * s * 0.045;
      canvas.drawLine(
        Offset(bx + s * 0.035, y),
        Offset(spineX - s * 0.025, y),
        rule,
      );
    }

    // The flipping page: starts standing up on the right, sweeps to lie flat
    // on the left. Tilt goes from +72° to -4°, and it fades near the end so it
    // "lands" onto the left stack.
    final t = Curves.easeInOutCubic.transform(progress);
    final angle = (72 - 76 * t) * math.pi / 180;
    final pageW = bookW * 0.5;
    final pivot = Offset(spineX, by + bookH);

    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(angle);
    final flipRect = Rect.fromLTWH(-pageW * 0.05, -bookH, pageW, bookH);
    final flipPaint = Paint()
      ..color = _accent.withValues(alpha: t > 0.86 ? (1 - (t - 0.86) / 0.14) : 1.0);
    canvas.drawRRect(
      RRect.fromRectAndRadius(flipRect, Radius.circular(s * 0.018)),
      flipPaint,
    );
    // Curl highlight along the outer edge.
    final curl = Paint()
      ..color = const Color(0xFFFFE2A0)
      ..strokeWidth = s * 0.008
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(flipRect.left + s * 0.012, flipRect.top + s * 0.012),
      Offset(flipRect.left + s * 0.012, flipRect.bottom - s * 0.012),
      curl,
    );
    canvas.restore();
  }

  void _paintRobot(Canvas canvas, double s, double h, double bob) {
    final cx = s / 2;
    final headR = s * 0.17;
    final headCy = h * 0.34 + bob;

    final body = Paint()..color = _robot;
    final shade = Paint()
      ..color = _robotShade
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.008;

    // Antenna.
    final antenna = Paint()
      ..color = _robot
      ..strokeWidth = s * 0.014
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(cx, headCy - headR),
      Offset(cx, headCy - headR - s * 0.07),
      antenna,
    );
    canvas.drawCircle(
      Offset(cx, headCy - headR - s * 0.085),
      s * 0.025,
      Paint()..color = _accent,
    );

    // Head.
    final head = Rect.fromCircle(center: Offset(cx, headCy), radius: headR);
    canvas.drawOval(head, body);
    canvas.drawOval(head, shade);

    // Visor.
    final visorW = headR * 1.35;
    final visorH = headR * 0.62;
    final visor = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: Offset(cx, headCy), width: visorW, height: visorH),
      Radius.circular(visorH / 2),
    );
    canvas.drawRRect(visor, Paint()..color = _eye);

    // Eyes (blink subtly).
    final blink = (math.sin(progress * 2 * math.pi) + 1) / 2; // 0..1
    final eyeR = headR * (0.13 + 0.03 * blink);
    final eyePaint = Paint()..color = _eyeGlow;
    for (final dx in [-headR * 0.32, headR * 0.32]) {
      canvas.drawCircle(Offset(cx + dx, headCy), eyeR, eyePaint);
    }

    // Smile.
    final smile = Paint()
      ..color = _robotShade
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.012
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCenter(
          center: Offset(cx, headCy + headR * 0.42),
          width: headR * 0.7,
          height: headR * 0.5),
      0.35,
      math.pi - 0.7,
      false,
      smile,
    );

    // Body.
    final bodyW = headR * 1.7;
    final bodyTop = headCy + headR * 0.85;
    final bodyH = s * 0.14;
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(cx - bodyW / 2, bodyTop, bodyW, bodyH),
      Radius.circular(bodyW * 0.28),
    );
    canvas.drawRRect(bodyRect, body);
    canvas.drawRRect(bodyRect, shade);

    // Chest light.
    canvas.drawCircle(
      Offset(cx, bodyTop + bodyH * 0.5),
      s * 0.022,
      Paint()..color = _accent,
    );
  }

  @override
  bool shouldRepaint(covariant _RobotPainter old) =>
      old.progress != progress || old.brand != brand;
}
