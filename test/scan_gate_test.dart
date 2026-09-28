import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/scanning/scan_gate.dart';
import 'package:vidlog_mobile/scanning/viewfinder.dart';

/// 把相机的**连续识码**变成**离散的扫码事件**。
///
/// 这一层存在的理由很具体：相机每秒会把同一个包裹报好几次，
/// 而「同码停」的规则是**复扫**才停。少这一层，包裹一放上去
/// 就会被自己的持续识别停掉 —— 录不到任何东西。
void main() {
  const second = 1000;
  const t0 = 1000000;

  /// 中心点落在画面正中的框：左右上下各留 25%。
  ScanGate makeGate({Duration absence = const Duration(seconds: 2)}) => ScanGate(
        viewfinder: const Viewfinder(
          rect: NormalizedRect(left: 0.25, top: 0.25, width: 0.5, height: 0.5),
        ),
        absenceThreshold: absence,
      );

  BarcodeSighting sighting(String text, {double x = 0.5, double y = 0.5}) =>
      BarcodeSighting(text: text, centerX: x, centerY: y);

  group('取景框（规格 §3.2.2：框外一律忽略）', () {
    test('框内的识码被采纳', () {
      expect(makeGate().accept(sighting('SF1000000001'), t0), isNotNull);
    });

    test('画面角落的识码被忽略', () {
      // 这正是要防的：同一画面里另一个包裹的面单。
      final gate = makeGate();

      expect(gate.accept(sighting('SF1000000001', x: 0.05, y: 0.05), t0), isNull);
      expect(gate.accept(sighting('SF1000000002', x: 0.95, y: 0.95), t0), isNull);
    });

    test('框外的识码不会污染去重记录', () {
      // 若把框外的也记进「最后见到」，同一个码之后挪进框里时
      // 会被当成「刚刚见过」而漏报。这条锁的就是这一点。
      final gate = makeGate();

      expect(gate.accept(sighting('SF1', x: 0.05, y: 0.5), t0), isNull);
      expect(gate.accept(sighting('SF1', x: 0.5, y: 0.5), t0 + 100), isNotNull);
    });
  });

  group('★ 连续识码 → 离散扫码', () {
    test('包裹一直摆在画面里，只算一次扫码', () {
      final gate = makeGate();

      // 第一次：算开录那一次
      expect(gate.accept(sighting('SF1000000001'), t0), isNotNull);

      // 之后相机每 300ms 报一次，连续 10 秒 —— 一次都不该再算
      for (var ms = 300; ms <= 10 * second; ms += 300) {
        expect(
          gate.accept(sighting('SF1000000001'), t0 + ms),
          isNull,
          reason: '第 $ms 毫秒时不该被当成复扫 —— 包裹还没离开画面',
        );
      }
    });

    test('拿开一会儿再放回来，才算复扫', () {
      final gate = makeGate();

      expect(gate.accept(sighting('SF1000000001'), t0), isNotNull);
      expect(gate.accept(sighting('SF1000000001'), t0 + 300), isNull); // 还在画面里

      // 拿开了 3 秒（超过 2 秒阈值）再放回来
      expect(gate.accept(sighting('SF1000000001'), t0 + 3 * second), isNotNull,
          reason: '离开了足够久，这一次是复扫');
    });

    test('刚好卡在阈值上算复扫', () {
      final gate = makeGate();

      gate.accept(sighting('SF1'), t0);
      expect(gate.accept(sighting('SF1'), t0 + 2 * second), isNotNull);
    });

    test('差一毫秒到阈值不算复扫', () {
      final gate = makeGate();

      gate.accept(sighting('SF1'), t0);
      expect(gate.accept(sighting('SF1'), t0 + 2 * second - 1), isNull);
    });

    test('抖动导致的短暂丢帧不会误判成复扫', () {
      // 相机偶尔会漏一帧。若把「一次没看到」当成离开，复扫会误触发。
      final gate = makeGate();

      gate.accept(sighting('SF1'), t0);
      // 漏了 300ms（一帧），然后又看到了
      expect(gate.accept(sighting('SF1'), t0 + 300), isNull);
      expect(gate.accept(sighting('SF1'), t0 + 600), isNull);
    });
  });

  group('★ 开录时标记「刚见过」', () {
    test('标记之后，持续识码不会立刻算复扫', () {
      // 开录用的那个单号此刻就在画面里。不标记的话，相机的第一次识码
      // 就会被当成复扫 —— 录制**一秒都录不到**。
      final gate = makeGate();

      gate.markSeen(WaybillNumber.parse('SF1000000001'), t0);

      expect(gate.accept(sighting('SF1000000001'), t0 + 300), isNull);
      expect(gate.accept(sighting('SF1000000001'), t0 + second), isNull);
    });

    test('标记过之后拿开够久，仍然能复扫', () {
      final gate = makeGate();
      gate.markSeen(WaybillNumber.parse('SF1'), t0);

      expect(gate.accept(sighting('SF1'), t0 + 5 * second), isNotNull);
    });
  });

  group('多单号', () {
    test('不同单号各自独立计时', () {
      final gate = makeGate();

      expect(gate.accept(sighting('SF1'), t0), isNotNull);
      expect(gate.accept(sighting('YT2'), t0 + 100), isNotNull,
          reason: '另一个单号第一次出现，该被采纳');
      expect(gate.accept(sighting('SF1'), t0 + 200), isNull,
          reason: 'SF1 还在画面里');
    });

    test('扫错码的场景：A 在画面里，B 出现，A 还在', () {
      // 错码保护要的就是这个：B 出现时报一次（于是播「面单不同」），
      // 而 A 一直没离开，所以不会因为抖动就被当成复扫。
      final gate = makeGate();

      expect(gate.accept(sighting('A'), t0), isNotNull);
      expect(gate.accept(sighting('B'), t0 + 300), isNotNull);
      expect(gate.accept(sighting('A'), t0 + 600), isNull);
      expect(gate.accept(sighting('B'), t0 + 900), isNull);
    });
  });

  group('非单号内容', () {
    test('二维码里的 URL 不会被当单号', () {
      // iOS 侧刻意只开了一维码，但万一将来开了二维码，
      // 这一层也会因为归一化后不含空白而放行 URL —— 所以这里锁的是
      // 「URL 不在框里就不采纳」，而不是「URL 一定被拒」。
      // 真正拦住它的是原生层只开一维码（见 CameraSegmentRecorder.swift）。
      final gate = makeGate();

      expect(gate.accept(sighting('https://x', x: 0.02, y: 0.5), t0), isNull);
    });

    test('空文本不算扫码', () {
      expect(makeGate().accept(sighting(''), t0), isNull);
      expect(makeGate().accept(sighting('   '), t0), isNull);
    });
  });

  group('重置', () {
    test('reset 之后同一个码算新的一次', () {
      final gate = makeGate();
      gate.accept(sighting('SF1'), t0);

      gate.reset();

      expect(gate.accept(sighting('SF1'), t0 + 100), isNotNull);
    });
  });

  // ── 面单条码最短长度（需求方 2026-09-28 新增）──────
  //
  // 它拦的是**印在面单上的码**，也就是相机这条路。手工输入那条路
  // （`_simulateScan`）**不走 ScanGate**，所以不在这一组里 ——
  // 它由编排器那一层测（见 `recording_coordinator_test.dart` 的
  // 「条码最短长度只挡相机」）。
  group('★ 面单条码最短长度', () {
    ScanGate makeMinGate(int minLength, {List<String>? tooShort}) {
      final gate = ScanGate(
        viewfinder: const Viewfinder(
          rect: NormalizedRect(left: 0.25, top: 0.25, width: 0.5, height: 0.5),
        ),
        minLength: minLength,
      );
      gate.onTooShort = (text, min) => tooShort?.add('$text/$min');
      return gate;
    }

    test('短于下限的条码不触发录制', () {
      expect(makeMinGate(11).accept(sighting('SF12345678'), t0), isNull);
    });

    test('刚好等于下限的条码**放行**（判据是「短于」不是「不长于」）', () {
      // 11 位单号是常态。写成 `<=` 的话，默认档会把每一张正常面单都挡掉。
      expect(makeMinGate(11).accept(sighting('SF123456789'), t0), isNotNull);
    });

    test('长于下限的条码照旧', () {
      expect(makeMinGate(11).accept(sighting('SF1234567890123'), t0), isNotNull);
    });

    test('**不限**（0）时什么长度都放行', () {
      // ⚠️ 0 是「不限」这个真档位，不是「没设过」。判据写成 `!= 0` 或
      // 忘了 `minLength > 0` 的话，这一档会把所有短码都挡掉。
      final gate = makeMinGate(0);
      expect(gate.accept(sighting('A'), t0), isNotNull);
      expect(gate.accept(sighting('AB'), t0 + 100), isNotNull);
    });

    test('数的是**归一化之后**的长度，不是原始字节数', () {
      // 'SF 123456789' 原样 12 个字符，归一化后是 11 位。
      // 按原始长度判的话，一个带空格的正常单号会被误挡。
      expect(makeMinGate(11).accept(sighting('SF 123456789'), t0), isNotNull);
    });

    test('被挡下时报一次，而且**只报一次**', () {
      // ⚠️ 这条是本组最要紧的一条。短码会一直摆在画面里，每帧都回调一次的话
      // 事件列表会被刷爆 —— 所以它必须与放行那条路**共用同一套去重**。
      final seen = <String>[];
      final gate = makeMinGate(11, tooShort: seen);

      expect(gate.accept(sighting('SF12345'), t0), isNull);
      for (var ms = 300; ms <= 10 * second; ms += 300) {
        expect(gate.accept(sighting('SF12345'), t0 + ms), isNull);
      }

      expect(seen, ['SF12345/11'], reason: '叫了 ${seen.length} 次 —— 短码摆在画面里刷屏了');
    });

    test('短码拿开够久再出现，会再报一次', () {
      final seen = <String>[];
      final gate = makeMinGate(11, tooShort: seen);

      gate.accept(sighting('SF12345'), t0);
      gate.accept(sighting('SF12345'), t0 + 5 * second);

      expect(seen, ['SF12345/11', 'SF12345/11']);
    });

    test('被挡下的短码**不污染**长码的采纳', () {
      // 同一个画面里既有货架短码又有真面单，真面单必须照常开录。
      final gate = makeMinGate(11);

      expect(gate.accept(sighting('EAN13'), t0), isNull);
      expect(gate.accept(sighting('SF123456789'), t0 + 100), isNotNull);
    });
  });
}
