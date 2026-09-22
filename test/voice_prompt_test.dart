import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/recording/recorder_events.dart';

/// 播报措辞（规格 §3.3.6 那张表）。
///
/// ## 为什么要单独钉一遍
///
/// [VoicePrompt] 是**唯一的措辞来源** —— 播报、界面日志都取它。
/// 「唯一来源」防的是两处各写一遍慢慢说岔，**防不住唯一那一处自己打错字**。
/// 而这些字符串是要**念给操作员听**的：错一个字，他就不知道下一步该干什么
/// （「面单错误，请扫描正确面单」少掉后半句，操作员只会愣在那儿）。
///
/// 所以这里写**字面量**，不是 `VoicePrompt.x.spokenText` ——
/// 后者是拿实现验实现，永远绿。
void main() {
  group('播报措辞（规格 §3.3.6）', () {
    test('★ 六句提示逐字对得上规格那张表', () {
      expect(VoicePrompt.startWorking.spokenText, '开始工作');
      expect(VoicePrompt.stopWorking.spokenText, '停止工作');

      expect(VoicePrompt.startRecording.spokenText, '开始录像');
      expect(VoicePrompt.stopRecording.spokenText, '停止录像');

      // 需求方 2026-09-22 晚些给的原话（原来是「面单不同」）。
      expect(VoicePrompt.differentWaybill.spokenText, '面单错误，请扫描正确面单');

      expect(VoicePrompt.durationTimeout.spokenText, '录制时间即将超时，是否需要停止录制？');
    });

    test('★ 手动那两句用「工作」，不是「录像」', () {
      // 刻意的：点【开始】之后相机只是开着，**还没扫到面单、还没在录**。
      // 说「开始录像」是假话 —— 而操作员会照这句话去理解系统现在在干什么。
      // 变红配方 = 把 `startWorking('开始工作')` 改成 `'开始录像'`。
      expect(VoicePrompt.startWorking.spokenText, contains('工作'));
      expect(VoicePrompt.startWorking.spokenText, isNot(contains('录像')));
      expect(VoicePrompt.stopWorking.spokenText, contains('工作'));
      expect(VoicePrompt.stopWorking.spokenText, isNot(contains('录像')));
    });

    test('★ 六句互不相同 —— 没有两句念出来一样', () {
      // 两句一样的话，操作员分不出刚才响的是哪一句，
      // 而「开始工作」和「开始录像」恰好是最容易被写成同一句的一对。
      final texts =
          VoicePrompt.values.map((p) => p.spokenText).toList(growable: false);

      expect(texts.toSet(), hasLength(texts.length));
    });

    test('没有一句是空的', () {
      for (final prompt in VoicePrompt.values) {
        expect(prompt.spokenText.trim(), isNotEmpty, reason: '$prompt 没有措辞');
      }
    });
  });
}
