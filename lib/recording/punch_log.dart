import 'dart:convert';
import 'dart:io';

import '../primitives.dart';

/// 一次打点的来源。规格 §3.2.1 的两个入口 + 手动输入兜底（§3.2.2）。
///
/// 落盘用的名字必须与电脑端 `PunchLog.cs` 里那个枚举的 `ToString()` **逐字一致**
/// —— 两端的 `punches.jsonl` 是同一份形态，读对方的文件不能出现认不出的取值。
enum PunchSource {
  keyboardScanner('KeyboardScanner'),
  cameraDecoder('CameraDecoder'),
  manualEntry('ManualEntry');

  const PunchSource(this.wire);

  final String wire;

  /// 认不出来的一律当手动输入。
  ///
  /// 与电脑端同样的兜底：多一条来源可疑的打点，好过整行读不出来。
  static PunchSource fromWire(String? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => PunchSource.manualEntry);
}

/// 一次打点 —— **时刻**与单号的关联。
///
/// 规格 §1 术语表：打点是「识别到单号的**那一时刻**」。
/// 与录像（区间）的关系见母仓 `docs/02-数据模型.md` §2：
/// 一次打包事件是区间、可能横跨多个分段；打点只是区间里的一个点。
class Punch {
  const Punch({
    required this.punchId,
    required this.sessionId,
    required this.waybill,
    required this.punchedAt,
    required this.monotonicOffsetMilliseconds,
    required this.source,
  });

  /// 本地生成，全局唯一（回放要按它定位）。
  final String punchId;

  /// 所属录制会话。
  final String sessionId;

  final WaybillNumber waybill;

  /// 墙钟时刻。**只用于呈现** —— 算位置用 [monotonicOffsetMilliseconds]。
  final DateTime punchedAt;

  /// 相对**会话起点**的单调偏移，毫秒。
  final int monotonicOffsetMilliseconds;

  final PunchSource source;

  /// 落盘形态。键名与电脑端 `PunchDto` 逐字一致（PascalCase）。
  Map<String, Object?> toJson() => {
        'PunchId': punchId,
        'SessionId': sessionId,
        'WaybillNumber': waybill.value,
        // 存 UTC：墙钟时刻落盘必须带时区，否则换时区读回来就错了几小时。
        'PunchedAt': punchedAt.toUtc().toIso8601String(),
        'MonotonicOffsetMilliseconds': monotonicOffsetMilliseconds,
        'Source': source.wire,
      };

  static Punch fromJson(Map<String, Object?> json) => Punch(
        punchId: json['PunchId']! as String,
        sessionId: json['SessionId']! as String,
        waybill: WaybillNumber.parse(json['WaybillNumber'] as String?),
        punchedAt: DateTime.parse(json['PunchedAt']! as String).toLocal(),
        monotonicOffsetMilliseconds:
            (json['MonotonicOffsetMilliseconds'] as num).toInt(),
        source: PunchSource.fromWire(json['Source'] as String?),
      );
}

/// 按行追加的打点日志。
///
/// 与电脑端 `JsonLinesPunchLog` 同样的形态与理由（见母仓 `docs/02-数据模型.md` §1.3）：
/// 追加一行比改写整个文件便宜，且**掉电时已写的行仍然完整** ——
/// 而规格 §3.2.4 要的正是「产生即落盘」，不是会话结束时批量写。
///
/// 放在**根目录**（`<root>/punches.jsonl`）而不是会话目录里，与电脑端
/// `DataLayout.PunchLogPath` 一致：一台设备一份日志，会话靠 `SessionId` 区分。
class PunchLog {
  PunchLog(this.path);

  final String path;

  /// 写入的串行闸。并发追加会交错写出半个 JSON 行 —— 那样的行整条读不出来。
  Future<void> _gate = Future<void>.value();

  Future<void> append(Punch punch) {
    final result = _gate.then((_) => _appendNow(punch));

    // 闸门要吞掉异常继续放行，否则一次失败会把后续所有打点都堵死。
    _gate = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _appendNow(Punch punch) async {
    final file = File(path);
    await file.parent.create(recursive: true);

    // flush: true —— 规格 §3.2.4 要的是「立即持久化」，正是为了掉电不丢。
    // 交给操作系统的缓冲区就达不到这个目的。
    await file.writeAsString(
      '${jsonEncode(punch.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// 读出全部打点。文件不存在时返回空表（还没打过点不是错误）。
  Future<List<Punch>> loadAll() async {
    final file = File(path);
    if (!await file.exists()) return [];

    final punches = <Punch>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        punches.add(Punch.fromJson(jsonDecode(line) as Map<String, Object?>));
      } on Object {
        // 半个 JSON 行（掉电时写到最后一行）—— 跳过它，别让一条坏行
        // 把整个会话的打点都读不出来。
        continue;
      }
    }

    return punches;
  }

  /// 只取某一次会话的打点，按时间偏移排好序。
  Future<List<Punch>> forSession(String sessionId) async {
    final all = await loadAll();
    return all.where((p) => p.sessionId == sessionId).toList()
      ..sort((a, b) =>
          a.monotonicOffsetMilliseconds.compareTo(b.monotonicOffsetMilliseconds));
  }
}
