import 'package:flutter/material.dart';

import 'src/blur_demo_page.dart';

void main() {
  runApp(const WasmforgeExampleApp());
}

/// The wasmforge demo app.
class WasmforgeExampleApp extends StatelessWidget {
  /// Creates the app.
  const WasmforgeExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'wasmforge demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const BlurDemoPage(),
    );
  }
}
