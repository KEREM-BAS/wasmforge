import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:wasmforge/wasmforge.dart';

import 'blur_runner.dart';
import 'capability_card.dart';
import 'fps_meter.dart';
import 'pixel_source.dart';

const int _imageWidth = 3840;
const int _imageHeight = 2160;

/// The demo: blur a 4K image on a WorkerPool while the fps meter proves the
/// UI thread stays free, with shared-memory vs message-passing timings.
class BlurDemoPage extends StatefulWidget {
  /// Creates the page.
  const BlurDemoPage({super.key});

  @override
  State<BlurDemoPage> createState() => _BlurDemoPageState();
}

class _BlurDemoPageState extends State<BlurDemoPage> {
  final BlurRunner _runner = BlurRunner(
    width: _imageWidth,
    height: _imageHeight,
  );

  Uint8List? _sourcePixels;
  ui.Image? _displayImage;
  String _status = 'Generating 4K test image…';
  bool _busy = true;
  int? _liveWorkers;
  double _progress = 0;
  Timer? _progressTimer;
  final Map<String, Duration> _timings = <String, Duration>{};

  @override
  void initState() {
    super.initState();
    // Let the first frame paint, then generate the source image.
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  Future<void> _prepare() async {
    final pixels = generatePlasmaRgba(_imageWidth, _imageHeight);
    final image = await _decode(pixels);
    if (!mounted) {
      return;
    }
    setState(() {
      _sourcePixels = pixels;
      _displayImage = image;
      _busy = false;
      _status =
          'Ready — ${_imageWidth}x$_imageHeight RGBA '
          '(${(pixels.length / (1 << 20)).toStringAsFixed(1)} MiB)';
    });
  }

  Future<ui.Image> _decode(Uint8List rgba) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      _imageWidth,
      _imageHeight,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  void _watchProgress() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _progress = _runner.progressCount / _runner.totalSteps;
        _liveWorkers = _runner.liveWorkers;
      });
    });
  }

  Future<void> _run(
    String label,
    Future<BlurResult> Function(Uint8List pixels) mode,
  ) async {
    final source = _sourcePixels;
    if (source == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'Running $label…';
    });
    _watchProgress();
    try {
      final result = await mode(source);
      final image = await _decode(result.pixels);
      if (!mounted) {
        return;
      }
      setState(() {
        _timings[label] = result.elapsed;
        _displayImage = image;
        _status = '$label finished in ${result.elapsed.inMilliseconds} ms';
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _status = '$label failed: $error');
    } finally {
      _progressTimer?.cancel();
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = 0;
          _liveWorkers = _runner.liveWorkers;
        });
      }
    }
  }

  Future<void> _runMainThread() async {
    final source = _sourcePixels;
    if (source == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Running main thread (watch the fps meter freeze)…';
    });
    // Give the status frame a chance to paint before blocking.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final result = _runner.runMainThread(source);
    final image = await _decode(result.pixels);
    if (!mounted) {
      return;
    }
    setState(() {
      _timings['main thread'] = result.elapsed;
      _displayImage = image;
      _status =
          'main thread finished in ${result.elapsed.inMilliseconds} ms '
          '(UI was blocked the whole time)';
      _busy = false;
    });
  }

  Future<void> _showSource() async {
    final source = _sourcePixels;
    if (source == null || _busy) {
      return;
    }
    final image = await _decode(source);
    if (!mounted) {
      return;
    }
    setState(() {
      _displayImage = image;
      _status = 'Showing the unblurred source image';
    });
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    unawaited(_runner.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sabSupported = SharedBuffer.isSupported;
    return Scaffold(
      appBar: AppBar(
        title: const Text('wasmforge — 4K box blur off the UI thread'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 24,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const FpsMeter(),
              SizedBox(
                width: 420,
                child: CapabilityCard(liveWorkers: _liveWorkers),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              Tooltip(
                message: sabSupported
                    ? 'Zero-copy: pixels live in SharedArrayBuffers; workers '
                          'blur bands in place; progress via Atomics.'
                    : 'Unavailable: this page is not cross-origin isolated '
                          '(COOP/COEP headers missing), so SharedArrayBuffer is '
                          'disabled and wasmforge falls back to message passing.',
                child: FilledButton.icon(
                  onPressed: _busy || !sabSupported
                      ? null
                      : () => _run('shared memory', _runner.runSharedMemory),
                  icon: const Icon(Icons.memory),
                  label: const Text('Blur on workers — shared memory'),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy
                    ? null
                    : () => _run('message passing', _runner.runCopy),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Blur on workers — message passing'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _runMainThread,
                icon: const Icon(Icons.block),
                label: const Text('Blur on main thread (blocks UI)'),
              ),
              TextButton(
                onPressed: _busy ? null : _showSource,
                child: const Text('Show source'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_busy && _progress > 0)
            LinearProgressIndicator(value: _progress.clamp(0, 1)),
          const SizedBox(height: 8),
          Text(_status),
          if (_timings.isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Timings (4K, radius 8, two passes, '
                      '${_runner.bands} bands, ${_runner.poolSize} workers)',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    for (final entry in _timings.entries)
                      Text(
                        '${entry.key.padRight(16)} '
                        '${entry.value.inMilliseconds} ms',
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (_displayImage != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: _imageWidth.toDouble(),
                  height: _imageHeight.toDouble(),
                  child: RawImage(image: _displayImage),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
