import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../diagnostics/app_log.dart';
import '../primitives.dart';

/// 一次「扫到别的面单」（规格 §3.3.2 错码保护触发）。
///
/// 形状照母仓 `docs/02-数据模型.md` §1.7 那张表，四个字段**逐字对齐**：
/// `SessionId` / `ExpectedWaybill` / `ScannedWaybill` / `OccurredAt`。
///
/// > **这是一条事后诊断记录，不是控制流的输入。**
///
/// 扫到错码时的行为是「不停录 + 语音提示」，判定**不依赖**本表 ——
/// 所以这里写失败**绝不能影响录制**（见 [ScanErrorLog.record]）。
@immutable
class ScanErrorEvent {
  const ScanErrorEvent({
    required this.sessionId,
    required this.expectedWaybill,
    required this.scannedWaybill,
    required this.occurredAt,
  });

  final String sessionId;

  /// 首扫开录的那个单号。
  final WaybillNumber expectedWaybill;

  /// 实际扫到的、不一样的单号。
  final WaybillNumber scannedWaybill;

  final DateTime occurredAt;

  /// 落盘形态。键名与电脑端逐字一致（PascalCase）。
  Map<String, Object?> toJson() => {
        'SessionId': sessionId,
        'ExpectedWaybill': expectedWaybill.value,
        'ScannedWaybill': scannedWaybill.value,
        // 存 UTC：墙钟时刻落盘必须带时区，否则换时区读回来就错了几小时。
        'OccurredAt': occurredAt.toUtc().toIso8601String(),
      };

  static ScanErrorEvent fromJson(Map<String, Object?> json) => ScanErrorEvent(
        sessionId: json['SessionId']! as String,
        expectedWaybill: WaybillNumber.parse(json['ExpectedWaybill'] as String?),
        scannedWaybill: WaybillNumber.parse(json['ScannedWaybill'] as String?),
        occurredAt: DateTime.parse(json['OccurredAt']! as String).toLocal(),
      );
}

/// 按行追加的错误扫描记录。
///
/// 与 `punches.jsonl` / `labels.jsonl` 同一套形态（`<root>/scan-errors.jsonl`，
/// 追加写、读取时后写胜出），理由也一样：追加一行比改写整个文件便宜，
/// 且掉电时已写的行仍然完整。
///
/// ## ⚠️ 它是一条**规格欠账**的补齐，不是新功能
///
/// `docs/01-行为规格书.md` §6.1「必须保存的事实」里点名要有这一条
/// （原文：「错误扫描 | 错码保护触发的事件（诊断用）」），
/// 而 2026-09-26 之前**两端都没有实现**：错码保护只做了界面提示与 TTS，
/// **没有落任何记录**。
class ScanErrorLog {
  ScanErrorLog(this.path);

  final String path;

  /// 写入的串行闸。并发追加会交错写出半个 JSON 行 —— 那样的行整条读不出来。
  Future<void> _gate = Future<void>.value();

  /// 记一条。
  ///
  /// ⚠️ **写失败不抛**（与别处的存储不同）：本表按规格「不是控制流的输入」，
  /// 而它触发的那条路径正在**录着像**。为一条诊断记录把录制搞坏，
  /// 与 I4（坏配置不得影响录制）是同一条账。
  Future<void> record(ScanErrorEvent event) {
    final result = _gate.then((_) => _appendNow(event));

    // 闸门要吞掉异常继续放行，否则一次失败会把后续所有记录都堵死。
    _gate = result.then((_) {}, onError: (_) {});
    return _gate;
  }

  Future<void> _appendNow(ScanErrorEvent event) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);

      await file.writeAsString(
        '${jsonEncode(event.toJson())}\n',
        mode: FileMode.append,
        // 不 flush：这是一条**事后诊断**记录，不值得为它等一次 fsync
        // （那会让正在录制的这条路径卡在磁盘上）。
        flush: false,
      );
    } on Object catch (error) {
      // 留痕但不抛：这一条记录不下来，也不该把录制带走。
      AppLog.instance.warn('录制', '错误扫描记录写不下去', data: {'原因': '$error'});
    }
  }

  /// 读回来（诊断包与真机验收用）。
  Future<List<ScanErrorEvent>> loadAll() async {
    final file = File(path);
    if (!await file.exists()) return const [];

    final events = <ScanErrorEvent>[];

    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;

      try {
        events.add(ScanErrorEvent.fromJson(
            jsonDecode(line) as Map<String, Object?>));
      } on Object {
        // 坏行跳过 —— 与索引、打点、标签同一条规矩：
        // 一行坏掉不该让整份记录读不出来。
      }
    }

    return events;
  }
}
