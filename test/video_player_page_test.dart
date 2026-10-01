import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/app/video_player_page.dart';

/// 播放器本身**没法在无头测试里验**（要真的解出一路视频、要真的转屏幕方向）——
/// 那些走真机回归。这里只钉两件**纯显示的**事，它们在真机上很显眼、在测试里很便宜。
void main() {
  group('倍速按钮上的字', () {
    test('整数不带小数点', () {
      // `1.0x` 在小按钮上看着像乱码，而四档里两档是整数。
      expect(labelForSpeed(1.0), '1x');
      expect(labelForSpeed(2.0), '2x');
    });

    test('小数照写', () {
      expect(labelForSpeed(0.5), '0.5x');
      expect(labelForSpeed(1.5), '1.5x');
    });

    test('四档就是需求方定的那四个', () {
      // 少一档、多一档、改一个数都要回去问 —— 所以把这一份钉住。
      expect(playbackSpeeds, [0.5, 1.0, 1.5, 2.0]);
    });
  });

  group('拖动进度条时连续 seek 的合流', () {
    test('一次请求就直接跑', () async {
      final performed = <Duration>[];
      final seek = LatestSeek((target) async => performed.add(target));

      await seek.request(const Duration(seconds: 5));

      expect(performed, [const Duration(seconds: 5)]);
    });

    test('⚠️ 拖过一整条进度条_只跑两次_不是六次', () async {
      // 不合流的话：用户手一划就排进几十个 seek，每个都要解码 ——
      // 拖完之后画面**还在慢慢追**，追的还是那些早就不要了的位置。
      final performed = <Duration>[];
      final gate = Completer<void>();

      final seek = LatestSeek((target) async {
        performed.add(target);
        if (performed.length == 1) await gate.future;
      });

      // 第一次进去会被 gate 挡住，后面的就都在「正在跑」这个状态里。
      final first = seek.request(const Duration(seconds: 10));

      // 手指一路划过去 —— 只该留下最后那一个。
      for (final seconds in [20, 30, 40, 50, 60]) {
        await seek.request(Duration(seconds: seconds));
      }

      gate.complete();
      await first;

      expect(performed, [const Duration(seconds: 10), const Duration(seconds: 60)]);
    });

    test('⚠️ 抬手那一下一定跑得到', () async {
      // 拖动过程中发出去的可能都被丢掉了，而**抬手的位置才是用户要停的地方**。
      final performed = <Duration>[];
      final seek = LatestSeek((target) async => performed.add(target));

      await seek.request(const Duration(seconds: 1));
      await seek.request(const Duration(seconds: 2));

      expect(performed.last, const Duration(seconds: 2));
    });

    test('跑完之后还能接着请求', () async {
      final performed = <Duration>[];
      final seek = LatestSeek((target) async => performed.add(target));

      await seek.request(const Duration(seconds: 1));
      await seek.request(const Duration(seconds: 2));

      expect(performed, [const Duration(seconds: 1), const Duration(seconds: 2)]);
    });
  });

  group('画面比例', () {
    test('正常的比例照用', () {
      expect(safeAspect(16 / 9), closeTo(16 / 9, 0.0001));
      expect(safeAspect(4 / 3), closeTo(4 / 3, 0.0001));
    });

    test('⚠️ 还没拿到尺寸时不抛', () {
      // 未初始化时 aspectRatio 可能是 0 或 NaN，直接喂给 AspectRatio 会抛断言，
      // 表现是「刚点开播放就红屏」—— 而那时候用户什么都没做。
      expect(safeAspect(0), 16 / 9);
      expect(safeAspect(double.nan), 16 / 9);
      expect(safeAspect(-3), 16 / 9);
      expect(safeAspect(double.infinity), 16 / 9);
    });
  });

  group('时长显示', () {
    test('不到一小时是 mm:ss', () {
      expect(formatDuration(const Duration(seconds: 5)), '0:05');
      expect(formatDuration(const Duration(minutes: 1, seconds: 7)), '1:07');
      expect(formatDuration(const Duration(minutes: 59, seconds: 59)), '59:59');
    });

    test('超过一小时才带上小时', () {
      expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    });

    test('负数不显示成负的', () {
      // 刚起播时 position 偶尔会是负的，而 `-1:-5` 会让人以为文件坏了。
      expect(formatDuration(const Duration(seconds: -3)), '0:00');
    });
  });
}
