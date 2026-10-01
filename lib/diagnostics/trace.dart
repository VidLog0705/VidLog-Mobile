import 'dart:async';
import 'dart:math';

/// 一次「一件事」的关联 id（规格要求的 request_id；与电脑端**同一个字段名** `trace`）。
///
/// ## ⚠️ 为什么用 zone 值，不用全局变量
///
/// Dart 的 zone **跟着 `await` 走**：在 `runZoned(zoneValues: …)` 里发起的那条链上，
/// 无论 `await` 切到哪个微任务，`Zone.current` 都还是那一个。
///
/// 全局变量做不到 —— **两个并发上传会互相覆盖**，日志串成一条乱麻。
/// 而那比「没有 id」更糟：它会把日志**指到错误的那条录像**上，
/// 看日志的人据此得出的结论全是反的。
///
/// 电脑端是同一个理由：它用 `AsyncLocal` 而**不是** `[ThreadStatic]`，
/// 并且有一条用例专门钉「两个并发任务互不串」。这一端同样钉
/// （见 `test/trace_test.dart`）。
///
/// ⚠️ 与电脑端的一处不同：那边开在 **HTTP 请求入口**（`PlaybackServer`）；
/// 这一端**不监听端口**，所以开在**每一次实际干活**上 ——
/// 一次上传一条录像、一次录像会话。
class Trace {
  Trace._();

  /// zone 里那个键。用 `Symbol` 而不是字符串：不会和别人的 zone 值撞名。
  static const _key = #vidlogTrace;

  /// 现在这条链属于哪一件事。没有就是 `null`（那时日志**不带** `trace` 字段，
  /// 与电脑端同一个口径 —— 空字段不写，省得每行都挂一个 `null`）。
  static String? get current => Zone.current[_key] as String?;

  /// 在这一件事里跑 [body]：链上所有日志**自动**带上这个 id。
  ///
  /// [id] 给得出一个**有意义的**就传进来（比如 `evidenceId`）——
  /// 「这条日志是哪条录像的」比一个随机串有用得多。给不出就自动生成一个。
  static Future<T> run<T>(Future<T> Function() body, {String? id}) =>
      runZoned(body, zoneValues: {_key: id ?? newId()});

  /// 8 位十六进制 —— 与电脑端 `Trace` 生成的**同一个形状**，
  /// 于是两端的日志可以用同一个查询去筛。
  static String newId() {
    final random = Random();

    return List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
  }
}
