/// 录制前那次**真实的可用性检查**（规格 §3.1.7）。
///
/// 规格原话：「组合是稀疏的……设备能真跑通的**远少于**这个数（4K + H.265 在多数
/// 手机上就不行）。所以**录制前要做一次真实的可用性检查**，而不是假定
/// 『列出来了就能用』」，以及「**回落必须可见**……并**明确告诉用户实际用的是什么**。
/// **不得静默回落**」。
///
/// ## 分工：能力问原生，顺序在这里
///
/// 原生只回答一件事 ——「这份候选表里第一个真能跑的是第几个」。它**不认识**
/// 回落顺序（那是产品决定，不是设备能力），也不负责措辞。
/// 于是那段顺序是一段**纯逻辑**，可以在本机用假探测验到底；
/// 而真正需要真机的那一句「这台手机能不能录 4K」被压到最小。
///
/// ⚠️ **探测失败不等于不能用。** 原生没实现这个方法（老包）或者通道出错时，
/// 这里**照用户选的走** —— 那正是加这一刀之前的行为，所以最坏情况是
/// 「回到了从前」，不会变成「录不了」。
library;

import '../diagnostics/app_log.dart';
import 'recording_spec.dart';

/// 一次规格检查的结论。
class SpecSelection {
  const SpecSelection({
    required this.spec,
    required this.changedFromRequested,
    this.reason,
  });

  /// **实际会用**的那一档。索引里记的、界面显示的都是它。
  final RecordingSpec spec;

  /// 有没有回落过。
  final bool changedFromRequested;

  /// 回落的原因（给用户看的），没回落时为 null。
  final String? reason;
}

/// 问设备「这份候选表里第一个真能跑的是第几个」。
///
/// 返回下标；一个都跑不通返回 `null`。
typedef SpecCapabilityProbe = Future<int?> Function(
    List<RecordingSpec> candidates);

/// 按 [RecordingSpec.fallbacksFrom] 的顺序逐级问，取第一个跑得通的。
///
/// 全都问不通（或者探测本身出错）时**用用户选的那一档**：
/// 那时能拿到的信息只有「问不出来」，而「问不出来」不等于「不能用」——
/// 拿它去改用户的设置是另一种静默回落。
Future<SpecSelection> selectRecordingSpec(
  RecordingSpec wanted,
  SpecCapabilityProbe probe,
) async {
  final candidates = RecordingSpec.fallbacksFrom(wanted);

  int? index;
  try {
    index = await probe(candidates);
  } on Object catch (error) {
    // 原生侧还没实现（老包）、通道断了、原生抛了 —— 一律当成「问不出来」。
    AppLog.instance.warn('录制规格', '可用性检查没问出结果，按用户选的那一档走：$error');
    return SpecSelection(spec: wanted, changedFromRequested: false);
  }

  if (index == null || index < 0 || index >= candidates.length) {
    // ⚠️ 一个都跑不通时**仍然用用户选的那一档**，而不是悄悄降到最低档。
    // 理由：探测给出 null 的两种可能 —— 设备真的都不行（那开录会由原生
    // 如实报错，用户看得见），或者原生这次没问出结果（同上面的通道出错）。
    // 两种情况都不足以让我们去改用户的选择；而**改了才是真正的静默回落**。
    if (index != null) {
      AppLog.instance.warn('录制规格', '原生给了一个越界的下标（$index），按用户选的那一档走');
    }

    return SpecSelection(spec: wanted, changedFromRequested: false);
  }

  final chosen = candidates[index];
  if (chosen == wanted) {
    return SpecSelection(spec: chosen, changedFromRequested: false);
  }

  final reason = '这台手机跑不了 ${wanted.label}，已改用它跑得通的 ${chosen.label}。';
  AppLog.instance.warn('录制规格', '规格回落：${wanted.label} → ${chosen.label}');

  // 索引里记的是**实际**那一档 —— 记用户选的那档会让这条录像的容量估算
  // 与真实文件差出一个数量级（规格 §3.5.5 的连带项）。
  return SpecSelection(
    spec: chosen,
    changedFromRequested: true,
    reason: reason,
  );
}
