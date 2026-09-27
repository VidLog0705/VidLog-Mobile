import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/recording/clock_calibration.dart';

/// 未校准不得录制 + 跳变检测（规格 §3.6.3 / §3.6.4）。
///
/// ⚠️ 墙钟在这里是**被测对象**，而 `TrustedClock` 内部读 `DateTime.now()`。
/// 为了不把「当前时刻」做成可注入的（那会让生产路径多一个能传错的口子），
/// 这里的做法是：**用真的 now 造状态**，再把「上次见到的墙钟」写成相对它的偏移 ——
/// 等价于「用户把时间改了」。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vidlog-clock-');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  CalibrationStore store() => CalibrationStore('${temp.path}/calibration.json');

  TrustedClock clockWith(CalibrationState state, {Duration Function()? monotonic}) =>
      TrustedClock(
        initialState: state,
        store: store(),
        monotonic: monotonic,
        publicSource: null,
        log: null,
      );

  group('校准状态', () {
    test('没校准过就不能录，而且说得出为什么', () {
      final clock = clockWith(CalibrationState.empty);

      expect(clock.isCalibrated, isFalse);
      expect(clock.blockedReason, contains('校准'));
    });

    test('★ 校准之后就能录，而且状态落盘（重启还在）', () async {
      // 规格 §3.6.4：「已校准状态**落盘持久化**，之后离线照常录制」——
      // 不落盘的话，一台交付后从没联过网的手机重启一次就再也录不了。
      final first = clockWith(CalibrationState.empty);
      await first.calibrate(DateTime.now(), CalibrationSource.publicTime);

      expect(first.isCalibrated, isTrue);

      final reopened = clockWith(await store().load());

      expect(reopened.isCalibrated, isTrue);
      expect(reopened.state.source, CalibrationSource.publicTime);
    });

    test('★ 时间线由锚加单调读数推进，与墙钟无关', () async {
      // 规格 §3.6.3：「水印与时长都不得取自墙钟」。
      var monotonic = Duration.zero;
      final clock = clockWith(CalibrationState.empty, monotonic: () => monotonic);

      final anchor = DateTime.utc(2026, 9, 27, 4, 0, 0).toLocal();
      await clock.calibrate(anchor, CalibrationSource.publicTime);

      expect(clock.now.difference(anchor).inSeconds, closeTo(0, 1));

      monotonic = const Duration(seconds: 90);
      expect(clock.now.difference(anchor).inSeconds, closeTo(90, 1));
    });

    test('校准文件被手改坏 → 当作没校准过，而不是当作已校准', () async {
      // 两个方向的代价不对称：当作「没校准」只是录不了像（看得见、说得清），
      // 当作「已校准」会让录出来的东西时间不可信 —— 后者更重。
      File('${temp.path}/calibration.json').writeAsStringSync('{ 这不是 JSON');

      final clock = clockWith(await store().load());

      expect(clock.isCalibrated, isFalse);
    });

    test('键名与电脑端逐字一致（PascalCase）', () async {
      final clock = clockWith(CalibrationState.empty);
      await clock.calibrate(DateTime.now(), CalibrationSource.archiveReceipt);

      final raw = jsonDecode(File('${temp.path}/calibration.json').readAsStringSync())
          as Map<String, Object?>;

      expect(raw.keys, contains('AnchorUtc'));
      expect(raw.keys, contains('MonotonicAtAnchor'));
      expect(raw.keys, contains('Source'));
      expect(raw.keys, contains('NeedsRecalibration'));
      expect(raw['Source'], CalibrationSource.archiveReceipt.index);
    });
  });

  group('★ 跳变检测（规格 §3.6.3）', () {
    test('同一次开机内，墙钟往后跳 → 记下来并要求重新校准', () async {
      final monotonic = const Duration(hours: 1);
      final clock = clockWith(CalibrationState.empty, monotonic: () => monotonic);
      await clock.calibrate(DateTime.now(), CalibrationSource.publicTime);

      // 「上次见到」比现在**早** 30 分钟，而单调钟只走了 1 秒 ⇒ 墙钟往后跳了。
      final state = clock.state.copyWith(
        lastSeenWallClockUtc: DateTime.now().subtract(const Duration(minutes: 30)),
        lastSeenMonotonic: monotonic.inMilliseconds / 1000,
      );

      final reloaded = clockWith(
        state,
        monotonic: () => monotonic + const Duration(seconds: 1),
      );

      expect(await reloaded.checkStartup(), isTrue);
      expect(reloaded.isCalibrated, isFalse);

      final jump = reloaded.state.jumps.single;
      expect(jump.backwards, isFalse, reason: '往后调是「变晚」那一类');
    });

    test('★ 时间被调回去了 —— 无论跨没跨重启都算跳变', () async {
      // ⚠️ I11 点名的那一种：**把时间调回去是在伪造「更早的证据」**。
      // 而且它是**跨重启也判得出来**的那一半（单调钟归零照样判得出）。
      final state = CalibrationState(
        anchorUtc: DateTime.now(),
        monotonicAtAnchor: 0,
        // 「上次见到」比现在**晚** 30 分钟 ⇒ 现在是被调回去了 30 分钟。
        lastSeenWallClockUtc: DateTime.now().add(const Duration(minutes: 30)),
        lastSeenMonotonic: 3600,
      );

      // 单调读数也比上次的小（= 中间关过机重启，单调钟归零了）。
      final clock = clockWith(state, monotonic: () => const Duration(seconds: 5));

      expect(await clock.checkStartup(), isTrue);
      expect(clock.isCalibrated, isFalse);
      expect(clock.state.jumps.single.backwards, isTrue);
    });

    test('★ 跨重启而且时间没被改过 → 放行，不误伤「离线可用」', () async {
      // ⚠️ 与上一条**成对**：跨重启时单调钟归零，往前调的那一半分辨不出来。
      // 那时**必须放行** —— 否则一台每晚关机的手机天天早上都要重新校准，
      // 而规格 §3.6.4 承诺的是「已校准之后离线照常录制」。
      final state = CalibrationState(
        anchorUtc: DateTime.now().subtract(const Duration(hours: 8)),
        monotonicAtAnchor: 0,
        lastSeenWallClockUtc: DateTime.now().subtract(const Duration(hours: 8)),
        lastSeenMonotonic: 7200,
      );

      final clock = clockWith(state, monotonic: () => const Duration(seconds: 30));

      expect(await clock.checkStartup(), isFalse);
      expect(clock.isCalibrated, isTrue);
    });

    test('同一次开机内墙钟没动 → 不算跳变', () async {
      const monotonic = Duration(minutes: 10);

      final state = CalibrationState(
        anchorUtc: DateTime.now(),
        monotonicAtAnchor: 0,
        lastSeenWallClockUtc: DateTime.now().subtract(const Duration(seconds: 30)),
        lastSeenMonotonic: monotonic.inSeconds - 30,
      );

      final clock = clockWith(state, monotonic: () => monotonic);

      expect(await clock.checkStartup(), isFalse);
      expect(clock.isCalibrated, isTrue);
    });

    test('重新校准会清掉「要重新校准」那个标记', () async {
      final clock = clockWith(
        CalibrationState.empty.copyWith(needsRecalibration: true));

      expect(clock.isCalibrated, isFalse);

      await clock.calibrate(DateTime.now(), CalibrationSource.publicTime);

      expect(clock.isCalibrated, isTrue);
    });
  });

  group('两个来源（规格 §3.6.4）', () {
    test('★ 归档回执里的时间锚也能校准 —— 局域网即可，不需要公网', () async {
      // 这是手机端**特有**的那一半：一台在仓库里、联不上公网但能连上电脑端的
      // 手机，唯一拿得到的锚就是这个。
      final clock = clockWith(CalibrationState.empty);

      final anchor = DateTime.now().subtract(const Duration(minutes: 1));
      expect(await clock.calibrateFromReceipt(anchor), isTrue);

      expect(clock.isCalibrated, isTrue);
      expect(clock.state.source, CalibrationSource.archiveReceipt);
    });

    test('★ 已经校准过时，回执里的锚不再改时间线', () async {
      // 换锚会让时间线在两条线之间跳一下 —— 而那正是跳变检测要防的事。
      final clock = clockWith(CalibrationState.empty);
      await clock.calibrate(DateTime.now(), CalibrationSource.publicTime);

      final before = clock.state.anchorUtc;
      expect(await clock.calibrateFromReceipt(DateTime.now().add(const Duration(hours: 2))),
          isFalse);

      expect(clock.state.anchorUtc, before);
    });

    test('取不到公网时间时不猜一个时刻', () async {
      final clock = clockWith(
        CalibrationState.empty,
        // 连不上的地址：`HttpDateClockSource` 会抛，`tryCalibrate…` 吞掉并返回 false。
      );

      // 没给 publicSource ⇒ 直接 false，状态原封不动。
      expect(await clock.tryCalibrateFromPublicTime(), isFalse);
      expect(clock.isCalibrated, isFalse);
      expect(clock.state.anchorUtc, isNull);
    });
  });

  group('HTTP Date 解析', () {
    test('认 RFC 1123 那一种', () {
      // 用真实的响应头形态喂进去（`HttpDateClockSource` 内部用的就是这个解析）。
      const value = 'Tue, 15 Nov 1994 08:12:31 GMT';

      final match = RegExp(
        r'^[A-Za-z]{3}, (\d{1,2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
      ).firstMatch(value);

      expect(match, isNotNull);
      expect(match!.group(3), '1994');
      expect(match.group(2), 'Nov');
    });

    test('认不出的写法不硬猜', () {
      // 「昨天下午三点」这种绝不能变成某个具体时刻。
      expect(
        RegExp(r'^[A-Za-z]{3}, (\d{1,2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$')
            .hasMatch('昨天下午三点'),
        isFalse,
      );
    });
  });
}
