import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/diagnostics/app_log.dart';
import 'package:vidlog_mobile/diagnostics/trace.dart';

/// 关联 id 要钉的是**它会不会串**。
/// 串了比没有更糟：日志会被指到**错误的那条录像**上，看的人据此得出的结论全是反的。
void main() {
  test('不在任何一件事里时是 null', () {
    expect(Trace.current, isNull);
  });

  test('在这一件事里取得到_出来就没了', () async {
    expect(await Trace.run(() async => Trace.current), isNotNull);
    expect(Trace.current, isNull, reason: '跑完就该出去');
  });

  test('⚠️ await 换微任务之后还在', () async {
    // zone 是**跟着 await 走**的 —— 这一条不成立的话，中间每一层 await 都会丢 id。
    final inside = await Trace.run(() async {
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      return Trace.current;
    });

    expect(inside, isNotNull);
  });

  test('⚠️ 两个并发各不串', () async {
    // 这正是不用全局变量的原因：全局的话后一个会把前一个覆盖掉。
    final first = Trace.run(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return Trace.current;
    }, id: 'AAA');

    final second = Trace.run(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return Trace.current;
    }, id: 'BBB');

    expect(await second, 'BBB');
    expect(await first, 'AAA');
  });

  test('给得出有意义的 id 就用它', () async {
    expect(await Trace.run(() async => Trace.current, id: 'e-123'), 'e-123');
  });

  test('给不出就生成一个 8 位十六进制', () {
    final id = Trace.newId();

    expect(id, hasLength(8));
    expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(id), isTrue, reason: '与电脑端同一个形状：$id');
  });

  test('⚠️ 落盘那一行带 trace_而且字段名与电脑端一致', () {
    // ⚠️ 字段名是**跨端的查询口径**，换成别的就等于两端的日志没法用同一个查询筛。
    final line = AppLogLine(
      at: DateTime(2026, 10, 1, 12),
      level: AppLogLevel.info,
      tag: '上传',
      message: '一条录像已归档',
      trace: 'a3f19b02',
    );

    expect(line.toJson()['trace'], 'a3f19b02');
  });

  test('没有 trace 时不写那个字段', () {
    // 与电脑端同一个口径：空字段不写，省得每行都挂一个 null。
    final line = AppLogLine(
      at: DateTime(2026, 10, 1, 12),
      level: AppLogLevel.info,
      tag: '上传',
      message: 'x',
    );

    expect(line.toJson().containsKey('trace'), isFalse);
  });
}
