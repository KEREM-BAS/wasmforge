import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A continuously animating widget with a frames-per-second readout.
///
/// While heavy compute runs on workers this stays at the display rate;
/// when the same work runs on the main thread it visibly stalls — the
/// demo's proof that the UI thread is free.
class FpsMeter extends StatefulWidget {
  /// Creates the meter.
  const FpsMeter({super.key});

  @override
  State<FpsMeter> createState() => _FpsMeterState();
}

class _FpsMeterState extends State<FpsMeter>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final Queue<Duration> _frameTimes = Queue<Duration>();
  Duration _elapsed = Duration.zero;
  double _fps = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    _frameTimes.addLast(elapsed);
    final cutoff = elapsed - const Duration(seconds: 1);
    while (_frameTimes.isNotEmpty && _frameTimes.first < cutoff) {
      _frameTimes.removeFirst();
    }
    setState(() {
      _elapsed = elapsed;
      _fps = _frameTimes.length.toDouble();
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final angle = _elapsed.inMicroseconds * 2 * math.pi / 2e6;
    final smooth = _fps >= 50;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.rotate(
          angle: angle,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Colors.cyanAccent, Colors.deepPurpleAccent],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '${_fps.toStringAsFixed(0)} fps',
          style: TextStyle(
            fontSize: 22,
            fontFeatures: const [FontFeature.tabularFigures()],
            fontWeight: FontWeight.bold,
            color: smooth ? Colors.greenAccent : Colors.orangeAccent,
          ),
        ),
      ],
    );
  }
}
