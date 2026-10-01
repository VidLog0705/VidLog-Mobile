import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/live/live_counts.dart';
import 'package:vidlog_mobile/recording/business_type.dart';

/// 多画面每格下面那对 `F` / `T` 的来源（规格 §3.8 ⑥）。
///
/// 需求方 2026-10-01 定的起算点：「本次开始工作以来，到结束。以北京时间为准，
/// 00：01 开始至 23：59 分为一天，每天都重新计算。」
///
/// ⚠️ 这几条**只能在测试里验**：跨零点、设备时区不是北京 —— 真机上要守到
/// 半夜才看得见一次，而且看的人也未必在场。
void main() {
  /// 一个能拨的钟。
  DateTime now = DateTime.utc(2026, 10, 1, 4);

  LiveCounter build() => LiveCounter(now: () => now);

  setUp(() => now = DateTime.utc(2026, 10, 1, 4)); // 北京时间 12:00

  test('发货与退货分开数', () {
    final counter = build();

    counter.record(BusinessType.outbound);
    counter.record(BusinessType.outbound);
    counter.record(BusinessType.returning);

    expect(counter.counts().outbound, 2);
    expect(counter.counts().returned, 1);
  });

  test('★ 点开始工作时归零（「本次开始工作以来」）', () {
    final counter = build();

    counter.record(BusinessType.outbound);
    counter.record(BusinessType.returning);

    counter.reset();

    expect(counter.counts().outbound, 0);
    expect(counter.counts().returned, 0);
  });

  test('★ 跨北京时间自然日自己归零', () {
    final counter = build();

    counter.record(BusinessType.outbound);

    // 北京时间 10-01 23:30 → 还算是同一天。
    now = DateTime.utc(2026, 10, 1, 15, 30);
    expect(counter.counts().outbound, 1);

    // 北京时间 10-02 00:10 → 新的一天，重新计算。
    now = DateTime.utc(2026, 10, 1, 16, 10);
    expect(counter.counts().outbound, 0);
  });

  test('⚠️ 零点之后**没人扫码**也要归零（读的时候就比一次）', () {
    // 这条与上一条的区别是要守的东西：零点那一刻多半没有包裹进来，
    // 而屏幕上那两个数**必须自己归零** —— 否则它们会一直挂着昨天的数字，
    // 直到下一个包裹进来才「跳」一下。交接班时最容易被当成今天的数。
    final counter = build();

    counter.record(BusinessType.outbound);
    counter.record(BusinessType.returning);

    now = DateTime.utc(2026, 10, 1, 16, 5); // 北京时间 10-02 00:05

    expect(counter.counts().outbound, 0);
    expect(counter.counts().returned, 0);
  });

  test('跨日之后接着数，数到的是新的一天', () {
    final counter = build();

    counter.record(BusinessType.outbound);
    now = DateTime.utc(2026, 10, 1, 16, 10); // 跨日
    counter.record(BusinessType.outbound);

    expect(counter.counts().outbound, 1);
  });

  test('★ 设备时区不是北京，也按北京时间算 —— 固定 UTC+8，不读设备时区', () {
    // ⚠️ 手机可能压根不在北京时区。`DateTime.now()` 给的是**本机时间**，
    // 拿它直接取 `.day` 的话，这台手机在别的时区会把「今天」算错一天 ——
    // 而那两个数字只是屏幕上的一行，错了没人看得出来。
    //
    // 同一个**时刻**写成两种时区写法，必须得到同一天。
    final utc = DateTime.utc(2026, 10, 1, 16, 30); // 北京 10-02 00:30
    final elsewhere = utc.toLocal();

    expect(beijingDayOf(utc), '2026-10-02');
    expect(beijingDayOf(elsewhere), beijingDayOf(utc));
  });

  test('北京日的边界：23:59:59 还是当天，00:00:00 是次日', () {
    expect(beijingDayOf(DateTime.utc(2026, 10, 1, 15, 59, 59)), '2026-10-01');
    expect(beijingDayOf(DateTime.utc(2026, 10, 1, 16)), '2026-10-02');
  });

  test('UTC 的跨日与北京日的跨日**不是同一个时刻**', () {
    // 这条是上面那条的反面：如果哪天有人把 +8 去掉（改回按 UTC 或本机算），
    // 上面那些边界断言仍然可能因为别的原因过 —— 这一条会当场变红。
    expect(beijingDayOf(DateTime.utc(2026, 10, 1, 16)), isNot('2026-10-01'));
  });
}
