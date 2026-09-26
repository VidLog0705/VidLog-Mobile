import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_log.dart';

/// 接住「框架层」与「平台层」的未捕获异常，写进 [AppLog]。
///
/// ## 为什么是三个钩子（第三个在 `main.dart` 里）
///
/// 这三层各挡一类，缺一不可：
/// 1. **`FlutterError.onError`** —— 构建/布局/绘制的异常；
/// 2. **`PlatformDispatcher.onError`** —— 平台侧（异步任务、通道回调）冒上来的；
/// 3. **`runZonedGuarded`**（在 `main.dart` 里）—— 根 zone 上没人接的那些。
///
/// ## 为什么抽成函数
///
/// `main()` 里那段**在测试里跑不了**（它要 `runApp`）。抽出来之后，
/// 前两个钩子能被测试**真的触发一次**（`FlutterError.reportError` 与
/// 直接调 `PlatformDispatcher.instance.onError`），而不是只靠读代码相信它装上了。
/// 第三个（zone）留在 `main` 里 —— 那一层确实测不了，**别假装测过**。
///
/// ⚠️ **必须由 `main()` 在 `runApp` 之前调用**：晚于第一帧的话，
/// 那之前出的错一个都接不住 —— 而启动恰恰是最容易出事的时候。
void installFlutterErrorHandlers() {
  FlutterError.onError = (details) {
    // 保留默认行为（debug 下打到控制台），再叠一层落盘。
    // 只记不报的话，开发期会少掉那条熟悉的控制台输出。
    FlutterError.presentError(details);

    AppLog.instance.error(
      '界面',
      '框架层未捕获异常',
      error: details.exception,
      stackTrace: details.stack,
      // 哪一次构建、哪个库报的 —— 只有这个上下文能说清。
      data: {
        if (details.library != null) 'library': details.library,
        if (details.context != null) '上下文': details.context!.toDescription(),
      },
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.instance.error('界面', '平台层未捕获异常', error: error, stackTrace: stack);

    // ⚠️ 返回 true = **已处理**，不让它再把应用带下去。
    // 这是一台**连续录制**的设备：一闪退就是一段录像没了（还可能要重录）。
    // 而「接住了」不等于「瞒下来了」—— 上面那一条日志就是证据。
    return true;
  };
}

/// 挂起（退到后台）之前把排队的日志刷出去。
///
/// ⚠️ iOS 上挂起之后**随时可能被系统杀掉**，那是最后一次机会。
/// 平时靠 200ms 那批攒着写（见 [AppLog]），只在切后台时强制刷一次。
///
/// 返回监听器本身：**它由框架持有，调用方要留个引用**（否则可能被回收，
/// 那样切后台就不会触发了，而且不会有任何报错）。
AppLifecycleListener attachLogFlushOnPause() => AppLifecycleListener(
      onPause: () => unawaited(AppLog.instance.flush()),
    );
