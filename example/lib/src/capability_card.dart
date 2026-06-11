import 'package:flutter/foundation.dart' show kIsWasm;
import 'package:flutter/material.dart';
import 'package:wasmforge/wasmforge.dart';

/// Renders the detected capability matrix plus pool status.
class CapabilityCard extends StatelessWidget {
  /// Creates the card. [liveWorkers] is the pool's current worker count
  /// (null before the pool exists).
  const CapabilityCard({super.key, this.liveWorkers});

  /// Live worker count, when the pool has been spawned.
  final int? liveWorkers;

  @override
  Widget build(BuildContext context) {
    final entries = <(String, bool, String)>[
      ('isWeb', isWeb, 'compiled for the web'),
      (
        'isCrossOriginIsolated',
        isCrossOriginIsolated,
        'COOP/COEP headers present → SharedArrayBuffer usable',
      ),
      ('supportsWasmGc', supportsWasmGc, 'engine can run dart2wasm output'),
      ('kIsWasm', kIsWasm, 'this app is running as WasmGC (skwasm)'),
      (
        'SharedBuffer.isSupported',
        SharedBuffer.isSupported,
        'shared-memory mode available',
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Capability matrix',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final (name, value, hint) in entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      value ? Icons.check_circle : Icons.cancel,
                      size: 18,
                      color: value ? Colors.greenAccent : Colors.redAccent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      name,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        hint,
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            if (liveWorkers != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'WorkerPool: $liveWorkers live worker(s)',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
