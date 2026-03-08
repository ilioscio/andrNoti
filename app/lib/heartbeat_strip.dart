import 'dart:math';
import 'package:flutter/material.dart';

/// A scrolling ECG-style heartbeat strip.
///
/// Call [addBeat] whenever a heartbeat event arrives (connected=true) or
/// [addDisconnect] when the connection drops. The line scrolls continuously
/// left; beat events produce a spike, disconnected periods draw a flat dim line.
class HeartbeatStrip extends StatefulWidget {
  final double height;

  const HeartbeatStrip({super.key, this.height = 56});

  @override
  State<HeartbeatStrip> createState() => HeartbeatStripState();
}

// Public state so HomeScreen can call addBeat / addDisconnect via a GlobalKey.
class HeartbeatStripState extends State<HeartbeatStrip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;

  // Each sample is a value 0.0–1.0 (amplitude) and whether the line is live.
  final List<_Sample> _samples = [];
  static const _sampleCount = 200; // how many columns we track

  // Spike template: ECG shape (flat, up, sharp down, up, flat)
  static const _spikeDuration = 18; // samples wide
  static const _spikeShape = [
    0.0, 0.0, 0.05, 0.1, 0.15, 0.5, 1.0, 0.6, -0.3, 0.2, 0.15, 0.1,
    0.05, 0.0, 0.0, 0.0, 0.0, 0.0,
  ];

  int _phase = 0; // animation phase counter for scrolling

  @override
  void initState() {
    super.initState();
    // Seed with flat disconnected line
    for (var i = 0; i < _sampleCount; i++) {
      _samples.add(_Sample(0.0, false));
    }
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _ticker.addListener(_tick);
  }

  @override
  void dispose() {
    _ticker.removeListener(_tick);
    _ticker.dispose();
    super.dispose();
  }

  // --- public API ---

  void addBeat(bool connected) {
    if (!connected) {
      _push(_Sample(0.0, false));
      return;
    }
    // Push the ECG spike shape
    for (var i = 0; i < _spikeDuration; i++) {
      _push(_Sample(_spikeShape[i], true));
    }
  }

  // --- internals ---

  void _tick() {
    // Drive gentle "idle" scrolling — push one sample per ~4 ticks
    _phase++;
    if (_phase % 4 == 0) {
      // If the last sample is live and flat (between beats), push a small sine ripple
      final last = _samples.isNotEmpty ? _samples.last : null;
      final amp = (last != null && last.live)
          ? 0.04 * sin(_phase * 0.18)
          : 0.0;
      _push(_Sample(amp, last?.live ?? false));
    }
    setState(() {});
  }

  void _push(_Sample s) {
    _samples.add(s);
    if (_samples.length > _sampleCount) _samples.removeAt(0);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: widget.height,
      child: CustomPaint(
        painter: _EcgPainter(_samples),
      ),
    );
  }
}

class _Sample {
  final double amp; // -1.0 to 1.0
  final bool live;  // false = disconnected (dim)
  const _Sample(this.amp, this.live);
}

class _EcgPainter extends CustomPainter {
  final List<_Sample> samples;
  _EcgPainter(this.samples);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);

    if (samples.isEmpty) return;

    final mid = size.height * 0.5;
    final amp = size.height * 0.42;
    final step = size.width / samples.length;

    // Build path
    final livePath = Path();
    final deadPath = Path();
    bool liveStarted = false;
    bool deadStarted = false;

    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final x = i * step;
      final y = mid - s.amp.clamp(-1.0, 1.0) * amp;

      if (s.live) {
        if (!liveStarted) {
          livePath.moveTo(x, y);
          liveStarted = true;
        } else {
          livePath.lineTo(x, y);
        }
        deadStarted = false;
      } else {
        if (!deadStarted) {
          deadPath.moveTo(x, y);
          deadStarted = true;
        } else {
          deadPath.lineTo(x, y);
        }
        liveStarted = false;
      }
    }

    // Draw dead line (dim red)
    canvas.drawPath(
      deadPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0xFF6B0000)
        ..strokeCap = StrokeCap.round,
    );

    // Draw live glow (three passes: wide blur, mid, sharp)
    for (final (width, opacity) in [
      (6.0, 0.15),
      (3.0, 0.35),
      (1.5, 0.9),
    ]) {
      canvas.drawPath(
        livePath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = Color.fromRGBO(0, 255, 120, opacity)
          ..strokeCap = StrokeCap.round,
      );
    }

    // Scan line — bright leading edge
    if (samples.isNotEmpty && samples.last.live) {
      final lastX = (samples.length - 1) * step;
      final lastY = mid - samples.last.amp.clamp(-1.0, 1.0) * amp;
      canvas.drawCircle(
        Offset(lastX, lastY),
        3,
        Paint()..color = const Color(0xFF00FF80),
      );
    }
  }

  @override
  bool shouldRepaint(_EcgPainter old) => true;
}
