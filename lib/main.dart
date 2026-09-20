import 'package:flutter/material.dart';

import 'app/recorder_page.dart';

void main() {
  runApp(const VidLogApp());
}

/// VidLog 手机端。
///
/// 现场采集：连续分段录像、扫码打点、停录机制。
/// 规格见母仓 `VidLog0705/VidLog` 的 `docs/01-行为规格书.md` §3.1–3.3。
class VidLogApp extends StatelessWidget {
  const VidLogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VidLog',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const RecorderPage(),
    );
  }
}
