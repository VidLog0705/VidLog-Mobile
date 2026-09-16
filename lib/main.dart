import 'package:flutter/material.dart';

void main() {
  runApp(const VidLogApp());
}

/// VidLog 手机端应用外壳。
///
/// M0 阶段只到「能启动」为止。现场采集、连续分段录制、扫码打点与停录机制
/// 按规格 §3.1–3.3 在 M4 实现。
class VidLogApp extends StatelessWidget {
  const VidLogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VidLog',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const Scaffold(
        body: Center(child: Text('VidLog')),
      ),
    );
  }
}
