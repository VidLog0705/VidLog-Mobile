import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/diagnostics/app_log.dart';
import 'package:vidlog_mobile/diagnostics/error_handlers.dart';

/// 全局异常钩子（2026-09-26）。
///
/// ⚠️ 这三层里**只有两层能在这里真的触发**：框架层与平台层。
/// 第三层（`runZonedGuarded`）留在 `main.dart` 里 —— 它要 `runApp`，
/// 在 widget 测试里跑不了。**不假装测过**：那一层只有真机/真跑才算验过。
void main() {
  setUp(() async => AppLog.instance.resetForTesting());
  tearDown(() async => AppLog.instance.resetForTesting());

  /// 记下来的那些行（`tail` 是同步的，不必等落盘）。
  List<String> logged() => AppLog.instance.tail.value;

  test('框架层的异常被接住_界面上看得见_盘上带堆栈', () async {
    final temp = Directory.systemTemp.createTempSync('vidlog-handlers-');
    addTearDown(() => temp.deleteSync(recursive: true));

    AppLog.instance.init(directory: temp.path, minLevel: AppLogLevel.debug);
    installFlutterErrorHandlers();

    FlutterError.reportError(FlutterErrorDetails(
      exception: StateError('构建炸了'),
      stack: StackTrace.current,
      library: 'vidlog 测试',
      context: ErrorDescription('在 build 里'),
    ));

    // 界面上要看得见**是什么**异常 —— 光写「框架层未捕获异常」对着一台手机没有用。
    expect(logged().single, contains('构建炸了'));

    await AppLog.instance.flush();

    final line = jsonDecode(File(AppLog.instance.path!).readAsLinesSync().single)
        as Map<String, Object?>;
    expect(line['lvl'], 'ERROR');
    expect((line['data']! as Map)['异常'], contains('构建炸了'));
    expect((line['data']! as Map)['library'], 'vidlog 测试');
    // 「哪个文件哪一行」正是事后唯一想知道的东西。
    expect(line['stack'], contains('error_handlers_test.dart'));
  });

  test('平台层的异常被接住_而且不让应用被带下去', () {
    installFlutterErrorHandlers();

    final handler = PlatformDispatcher.instance.onError;
    expect(handler, isNotNull, reason: '钩子没装上');

    final handled = handler!(StateError('异步任务炸了'), StackTrace.current);

    // ⚠️ 返回 true = 已处理。这是一台**连续录制**的设备，
    // 一闪退就是一段录像没了 —— 而「接住了」不等于「瞒下来了」，日志就是证据。
    expect(handled, isTrue);
    expect(logged().single, contains('异步任务炸了'));
  });

  /// ⚠️ **源码文本绊线**：`main()` 在测试里跑不了（它要 `runApp`），
  /// 所以「那两行到底有没有被调」只能这么钉。
  ///
  /// 上面那几条证明的是 [installFlutterErrorHandlers] **本身能用**，
  /// 证明不了**有人调它** —— 而这个仓吃过一次「写完了、测过了、没插电」的亏
  /// （电脑端的三处装配，见 `docs/实现决策.md`「装配的最后一跳」）。
  test('★ main 里真的装上了_而且早于 runApp', () {
    final code = File('lib/main.dart')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    final install = code.indexOf('installFlutterErrorHandlers()');
    final runApp = code.indexOf('runApp(');
    final zone = code.indexOf('runZonedGuarded(');

    expect(install, greaterThanOrEqualTo(0), reason: 'main.dart 里没有装框架层钩子');
    expect(zone, greaterThanOrEqualTo(0), reason: 'main.dart 里没有 runZonedGuarded（第三层）');
    expect(runApp, greaterThanOrEqualTo(0), reason: 'main.dart 里没有 runApp？');

    // ⚠️ **顺序是这条测试的一半**：晚于第一帧的话，那之前出的错一个都接不住 ——
    // 而启动恰恰是最容易出事的时候。
    expect(install, lessThan(runApp), reason: '钩子必须在 runApp **之前**装上');
  });

  test('装了钩子之后_没装之前那种静默就没了', () {
    // 没装的时候，`PlatformDispatcher.onError` 是 null —— 那就是改动前的样子：
    // 异常**没有任何落点**（这个仓此前 `print`/`developer.log` 全仓 0 处）。
    final before = PlatformDispatcher.instance.onError;

    installFlutterErrorHandlers();

    expect(PlatformDispatcher.instance.onError, isNot(same(before)));
    expect(logged(), isEmpty, reason: '装钩子本身不该产生日志');
  });
}
