import 'dart:async';

import 'package:flutter/material.dart';

import 'app/recorder_page.dart';
import 'diagnostics/app_log.dart';
import 'diagnostics/error_handlers.dart';

void main() {
  // ⚠️ 三层未捕获异常钩子里的**第三层**（前两层在 installFlutterErrorHandlers）。
  // 全局异常必须带堆栈落盘 —— 这个应用退到后台之后随时可能被杀，
  // 用户报「它自己没了」时，磁盘上那条是唯一可查的东西。
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      installFlutterErrorHandlers();
      runApp(const VidLogApp());
    },
    (error, stack) {
      AppLog.instance.error('界面', '未捕获异常（根 zone）', error: error, stackTrace: stack);
    },
  );
}

/// VidLog 手机端。
///
/// 现场采集：连续分段录像、扫码打点、停录机制。
/// 规格见母仓 `VidLog0705/VidLog` 的 `docs/01-行为规格书.md` §3.1–3.3。
///
/// 界面按**需求方口述的要求**实现（2026-09-21）：底部四栏
/// （备份 / 发货 / 退货 / 设置），按钮蓝色。
class VidLogApp extends StatelessWidget {
  const VidLogApp({super.key});

  /// 主题主色 —— 需求方要求按钮为蓝色。
  ///
  /// 用蓝色系而不是默认的紫色：`FilledButton` / `NavigationBar` 选中态
  /// 都取这里的主色，所以「一键改主题色」是真的只改这一处。
  static const seedColor = Color(0xFF1565C0);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VidLog',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seedColor),
      ),
      home: const RecorderPage(),
    );
  }
}
