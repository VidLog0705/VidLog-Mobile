import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/package_tracker.dart';
import 'package:vidlog_mobile/recording/recorder_events.dart';

/// 目标跟踪（规格 §3.3.1「同码离场后再入场」）。
///
/// 跟踪的是**那个条码还在不在画面里** —— 相机只报「见到了什么」，
/// 所以「离场」只能靠时间上的缺席推出来。这一层最容易错的地方是
/// 「抖动导致的漏帧被当成离场」：那会让静止时钟反复重置，
/// **扫码静止停录这个模式就永远停不下来**。
void main() {
  const second = 1000;
  const t0 = 1000000;

  final waybillA = WaybillNumber.parse('SF1000000001');
  final waybillB = WaybillNumber.parse('YT9999999999');

  late PackageTracker tracker;

  setUp(() {
    tracker = PackageTracker();
    tracker.track(waybillA, t0);
  });

  group('离场', () {
    test('一直没再见到，超过阈值就报离场', () {
      expect(tracker.onTick(t0 + 1 * second), isNull, reason: '还没到阈值');
      expect(tracker.onTick(t0 + 2 * second), isA<TrackedPackageLeft>());
    });

    test('★ 相机漏一帧不算离场', () {
      // 抖一下、反个光就会漏一帧。照单帧判离场的话，静止时钟被反复重置，
      // 这个模式就永远停不下来 —— 那不是更安全，是把功能弄没了。
      expect(tracker.onTick(t0 + 300), isNull);
      expect(tracker.onSighting(waybillA, t0 + 400), isNull);
      expect(tracker.onTick(t0 + 500), isNull);
    });

    test('离场只报一次', () {
      expect(tracker.onTick(t0 + 3 * second), isA<TrackedPackageLeft>());
      expect(tracker.onTick(t0 + 4 * second), isNull, reason: '还没等到入场');
    });

    test('还没开始跟踪时不报事件', () {
      final fresh = PackageTracker();
      expect(fresh.onTick(t0 + 60 * second), isNull);
    });
  });

  group('入场', () {
    test('离场之后再见到才算入场', () {
      tracker.onTick(t0 + 3 * second);

      expect(tracker.onSighting(waybillA, t0 + 4 * second), isA<TrackedPackageEntered>());
    });

    test('★ 没离场就一直见到，不会有入场', () {
      // 包裹一直摆在画面里：入场事件不该出现。出现了的话，
      // 静止时钟每 0.3 秒被重置一次 —— 静止停录永远不触发。
      for (var ms = 0; ms <= 10 * second; ms += 300) {
        expect(tracker.onSighting(waybillA, t0 + ms), isNull);
      }
    });

    test('入场只报一次，之后恢复成「还在画面里」', () {
      tracker.onTick(t0 + 3 * second);
      tracker.onSighting(waybillA, t0 + 4 * second);

      expect(tracker.onSighting(waybillA, t0 + 5 * second), isNull);
      expect(tracker.onTick(t0 + 6 * second), isNull);
    });

    test('重新计：入场后再离场，还能再报一次', () {
      tracker.onTick(t0 + 3 * second);
      tracker.onSighting(waybillA, t0 + 4 * second);

      expect(tracker.onTick(t0 + 7 * second), isA<TrackedPackageLeft>());
    });
  });

  group('认的是「哪一件」', () {
    test('★ 别的单号不影响被跟踪那件的离场时钟', () {
      // 错码保护：扫到 B 的时候 A 还在画面里。若 B 的识码把 A 的时钟推后，
      // A 的离场就永远报不出来。反过来，若 B 的识码被当成 A 见到了，
      // 离场会被凭空取消。
      tracker.onTick(t0 + 1 * second);

      expect(tracker.onSighting(waybillB, t0 + 3 * second), isNull);
      expect(tracker.onTick(t0 + 3 * second), isA<TrackedPackageLeft>(),
          reason: 'B 的识码不该被算成 A 还在');
    });

    test('换一件包裹跟踪时，上一件的状态不残留', () {
      tracker.onTick(t0 + 3 * second);
      expect(tracker.hasLeft, isTrue);

      tracker.track(waybillB, t0 + 4 * second);

      expect(tracker.tracked, waybillB);
      expect(tracker.hasLeft, isFalse);
      expect(tracker.onSighting(waybillB, t0 + 5 * second), isNull);
    });

    test('reset 之后什么都不报', () {
      tracker.reset();

      expect(tracker.tracked, isNull);
      expect(tracker.onTick(t0 + 60 * second), isNull);
      expect(tracker.onSighting(waybillA, t0 + 60 * second), isNull);
    });
  });
}
