import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/recording/recording_spec.dart';

/// 录制规格（规格 §3.1.7）—— 手机端那一半。
///
/// ⚠️ 这里验的是**规格本身的算法**（尺寸、方向、回落顺序、容量系数）。
/// 「这台手机真能跑哪一档」验不了 —— 那要真机，见 `docs/实现决策.md`。
void main() {
  group('档位与名字', () {
    test('默认档是 H.264 + 1080P + 竖屏', () {
      expect(RecordingSpec.standard.codec, VideoCodec.h264);
      expect(RecordingSpec.standard.resolution, VideoResolution.p1080);
      expect(RecordingSpec.standard.orientation, RecordingOrientation.portrait);
    });

    test('界面上只有一种写法，而且不出现 HEVC', () {
      // 规格原话：「界面上统一写「H.265」，任何地方都不得出现「HEVC」——
      // 两个名字混用会让用户以为是两种不同的编码」。
      for (final codec in VideoCodec.values) {
        final label = RecordingSpec(codec: codec).codecLabel;

        expect(label.toUpperCase(), isNot(contains('HEVC')));
        expect(label.replaceAll('H.265', ''), isNot(contains('265')));
      }

      expect(const RecordingSpec(codec: VideoCodec.h265).codecLabel, 'H.265');
      expect(const RecordingSpec(codec: VideoCodec.h264).codecLabel, 'H.264');
    });

    test('三档分辨率与方向名', () {
      expect(const RecordingSpec(resolution: VideoResolution.uhd4K).resolutionLabel, '4K');
      expect(const RecordingSpec(resolution: VideoResolution.p1080).resolutionLabel, '1080P');
      expect(const RecordingSpec(resolution: VideoResolution.p720).resolutionLabel, '720P');

      expect(const RecordingSpec(orientation: RecordingOrientation.landscapeLeft).orientationLabel,
          '横左');
      expect(const RecordingSpec(orientation: RecordingOrientation.landscapeRight).orientationLabel,
          '横右');
      expect(const RecordingSpec().orientationLabel, '竖屏');
    });

    test('帧率是常量，不是档位', () {
      // 规格「最高 30 帧、不提供选择」—— 摆一个只有一个选项的下拉是骗人的。
      expect(kFrameRate, 30);
    });
  });

  group('尺寸与方向', () {
    test('竖屏把宽高对调，横屏是标准 16:9', () {
      const portrait4k = RecordingSpec(resolution: VideoResolution.uhd4K);
      expect(portrait4k.size, (2160, 3840));

      const landscape = RecordingSpec(orientation: RecordingOrientation.landscapeLeft);
      expect(landscape.size, (1920, 1080));
      expect(const RecordingSpec(resolution: VideoResolution.p720).size, (720, 1280));
    });

    test('画面比例跟着方向走 —— 取景框不能再是常量', () {
      // 规格 §3.2.2 的连带项：框画出来的范围和系统实际判定的必须严格一致。
      const portrait = RecordingSpec();
      const landscape = RecordingSpec(orientation: RecordingOrientation.landscapeLeft);

      expect(portrait.aspectRatio, closeTo(720 / 1280, 1e-9));
      expect(landscape.aspectRatio, closeTo(16 / 9, 1e-9));
    });

    test('每个分辨率 × 每个方向都能算出正数尺寸', () {
      for (final resolution in VideoResolution.values) {
        for (final orientation in RecordingOrientation.values) {
          final spec = RecordingSpec(resolution: resolution, orientation: orientation);
          final (width, height) = spec.size;

          expect(width, greaterThan(0));
          expect(height, greaterThan(0));
          expect(spec.aspectRatio, greaterThan(0));
        }
      }
    });
  });

  group('码率', () {
    test('4K 的码率必须高于 720P —— 否则那一档编出来是糊的', () {
      const p720 = RecordingSpec(resolution: VideoResolution.p720);
      const p1080 = RecordingSpec(resolution: VideoResolution.p1080);
      const fourK = RecordingSpec(resolution: VideoResolution.uhd4K);

      expect(p1080.bitRate, greaterThan(p720.bitRate));
      expect(fourK.bitRate, greaterThan(p1080.bitRate));
    });

    test('同一档下 H.265 比 H.264 省', () {
      const h264 = RecordingSpec(codec: VideoCodec.h264);
      const h265 = RecordingSpec(codec: VideoCodec.h265);

      expect(h265.bitRate, lessThan(h264.bitRate));
    });
  });

  group('回落顺序', () {
    test('先保住用户选的编码', () {
      const wanted = RecordingSpec(
          codec: VideoCodec.h265, resolution: VideoResolution.uhd4K);
      final fallbacks = RecordingSpec.fallbacksFrom(wanted);

      expect(fallbacks.first, wanted); // ① 先试用户选的
      expect(fallbacks[1].codec, VideoCodec.h265); // ② 同编码降分辨率
      expect(fallbacks[1].resolution, VideoResolution.p1080);
      expect(fallbacks.any((s) => s.codec == VideoCodec.h264), isTrue); // ③ 最后才换编码

      // 不重复
      expect(fallbacks.map((s) => s.label).toSet().length, fallbacks.length);
    });

    test('回落不换方向 —— 那是「怎么拿手机」，不是设备能力', () {
      const wanted = RecordingSpec(orientation: RecordingOrientation.landscapeRight);

      for (final spec in RecordingSpec.fallbacksFrom(wanted)) {
        expect(spec.orientation, RecordingOrientation.landscapeRight);
      }
    });

    test('用户选的就是默认档时，回落表里它只出现一次', () {
      final fallbacks = RecordingSpec.fallbacksFrom(RecordingSpec.standard);

      expect(fallbacks.first, RecordingSpec.standard);
      expect(fallbacks.where((s) => s == RecordingSpec.standard).length, 1);
    });
  });

  group('配置解析（I4：坏配置不许导致录制失败）', () {
    test('认得出另一端写的名字，也扛得住各种写法', () {
      expect(VideoCodec.fromConfig('H265'), VideoCodec.h265); // 电脑端写枚举名
      expect(VideoCodec.fromConfig('h265'), VideoCodec.h265);
      expect(VideoCodec.fromConfig(' H.265 '), VideoCodec.h265);
      expect(VideoCodec.fromConfig('H-264'), VideoCodec.h264);

      expect(VideoResolution.fromConfig('uhd4K'), VideoResolution.uhd4K);
      expect(VideoResolution.fromConfig('P720'), VideoResolution.p720);

      expect(RecordingOrientation.fromConfig('landscape_left'),
          RecordingOrientation.landscapeLeft);
    });

    test('垃圾输入一律回默认档，绝不抛', () {
      for (final raw in <Object?>[null, 42, '', '乱写', true, <String>[]]) {
        expect(VideoCodec.fromConfig(raw), VideoCodec.h264);
        expect(VideoResolution.fromConfig(raw), VideoResolution.p1080);
        expect(RecordingOrientation.fromConfig(raw), RecordingOrientation.portrait);
      }
    });
  });

  group('容量系数（规格 §3.5.5 的连带项）', () {
    test('两端同一张表 —— 数字对不上用户会以为其中一端在骗他', () {
      // 单位 KB/s。这六个数字与电脑端 `CleanupPlanner.BytesPerSecond` **逐字相同**。
      expect(RecordingSpec.bytesPerSecondOf('h265', 'uhd4K'), 2500 * 1024);
      expect(RecordingSpec.bytesPerSecondOf('h265', 'p1080'), 700 * 1024);
      expect(RecordingSpec.bytesPerSecondOf('h265', 'p720'), 350 * 1024);
      expect(RecordingSpec.bytesPerSecondOf('h264', 'uhd4K'), 4000 * 1024);
      expect(RecordingSpec.bytesPerSecondOf('h264', 'p720'), 550 * 1024);
      expect(RecordingSpec.bytesPerSecondOf('h264', 'p1080'), 1100 * 1024);
    });

    test('缺字段 / 认不出的规格走默认档那一格', () {
      // 老索引行没有 codec/resolution 两个字段（2026-09-27 才加），
      // 那些行必须算得出一个数，而不是算出 0（0 会让「将腾出多少」变成谎话）。
      expect(RecordingSpec.bytesPerSecondOf(null, null), 1100 * 1024);
      expect(RecordingSpec.bytesPerSecondOf('乱写', '乱写'), 1100 * 1024);
    });

    test('4K 比 1080P 明显大 —— 这正是那个写死的 160 KB/s 错得离谱的地方', () {
      expect(RecordingSpec.bytesPerSecondOf('h264', 'uhd4K'),
          greaterThan(3 * RecordingSpec.bytesPerSecondOf('h264', 'p1080')));
    });
  });
}
