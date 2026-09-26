import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/recording/recording_spec.dart';
import 'package:vidlog_mobile/recording/recording_spec_probe.dart';

/// 录制前那次可用性检查的**策略那一半**（规格 §3.1.7）。
///
/// 原生只回答「候选表里第一个真能跑的是第几个」，顺序与措辞都在这里 ——
/// 所以这一段能在本机验到底。真正要真机的是「这台手机能不能录 4K」，
/// 那一句只有设备知道，如实记在文档里。
void main() {
  const wanted4kH265 = RecordingSpec(
    codec: VideoCodec.h265,
    resolution: VideoResolution.uhd4K,
    orientation: RecordingOrientation.landscapeLeft,
  );

  /// 假探测：只认某些组合（与真机一样，组合是稀疏的）。
  SpecCapabilityProbe probeAllowing(Set<RecordingSpec> usable) =>
      (candidates) async {
        final index = candidates.indexWhere(usable.contains);
        return index < 0 ? null : index;
      };

  test('用户选的那一档能跑通 → 不回落、没有原因', () async {
    final selection = await selectRecordingSpec(wanted4kH265, probeAllowing({wanted4kH265}));

    expect(selection.spec, wanted4kH265);
    expect(selection.changedFromRequested, isFalse);
    expect(selection.reason, isNull);
  });

  test('★ 跑不通就回落，而且**必须带回一句话**', () async {
    // 规格：「**回落必须可见**……并**明确告诉用户实际用的是什么**。
    // **不得静默回落**」。所以这条不只看落到哪一档，还要看有没有话可说 ——
    // 只说「实际是 H.264」而不说为什么，用户会以为自己选错了。
    const only720 = RecordingSpec(
      codec: VideoCodec.h265,
      resolution: VideoResolution.p720,
      orientation: RecordingOrientation.landscapeLeft,
    );

    final selection = await selectRecordingSpec(wanted4kH265, probeAllowing({only720}));

    expect(selection.spec, only720);
    expect(selection.changedFromRequested, isTrue);
    expect(selection.reason, isNotNull);
    expect(selection.reason, contains('H.265'));  // 实际用的那一档
    expect(selection.reason, contains('4K'));     // 用户选的那一档
  });

  test('候选表按回落顺序递过去：先用户选的，最后才换回 H.264', () async {
    List<RecordingSpec>? seen;

    await selectRecordingSpec(wanted4kH265, (candidates) async {
      seen = candidates;
      return 0;
    });

    expect(seen, isNotNull);
    expect(seen!.first, wanted4kH265);
    expect(seen!.last.codec, VideoCodec.h264);
    // 不重复试
    expect(seen!.map((s) => s.label).toSet().length, seen!.length);
  });

  test('回落不换方向 —— 那是「怎么拿手机」，不是设备能力', () async {
    final selection = await selectRecordingSpec(
      wanted4kH265,
      probeAllowing({const RecordingSpec(resolution: VideoResolution.p720,
          orientation: RecordingOrientation.landscapeLeft)}),
    );

    expect(selection.spec.orientation, RecordingOrientation.landscapeLeft);
  });

  test('⚠️ 探测本身出错（老包没有这个方法）→ 按用户选的走，不是按最低档走', () async {
    // 这是**最坏情况必须等于改动前的行为**那条：加这一刀之前没有这次检查，
    // 相机就是按用户选的开。若这里改成「回落到底」，一次通道抖动
    // 就会把用户的 4K 降成 720P —— 那才是真正的静默回落。
    final selection = await selectRecordingSpec(
      wanted4kH265,
      (_) async => throw MissingPluginException('老包没有 firstUsableSpec'),
    );

    expect(selection.spec, wanted4kH265);
    expect(selection.changedFromRequested, isFalse);
  });

  test('⚠️ 一个都跑不通（null）→ 也按用户选的走，让原生开录时如实报错', () async {
    final selection = await selectRecordingSpec(wanted4kH265, (_) async => null);

    expect(selection.spec, wanted4kH265);
    expect(selection.changedFromRequested, isFalse);
  });

  test('原生给了个越界的下标 → 不崩，按用户选的走', () async {
    for (final bad in <int>[99, -1]) {
      final selection = await selectRecordingSpec(wanted4kH265, (_) async => bad);

      expect(selection.spec, wanted4kH265);
      expect(selection.changedFromRequested, isFalse);
    }
  });
}
