/// 手机端的归档状态（`<root>/archive.jsonl`）。
///
/// 对应母仓 `docs/02-数据模型.md` §1.4 的 `ArchiveRecord`。
///
/// ## 为什么这份必须落盘，不能只活在内存里
///
/// 三件事都靠它：
///
/// 1. **I1**：回执里的 `timeAnchor` 是保留期的起算点。只留在内存里，
///    重启一次「这条什么时候备份成功的」就没了 —— 而那一刻是**外部时间锚**，
///    补不回来（电脑端为同一件事专门存了 `receipts.jsonl`）。
/// 2. **§3.4.3 有限次重试**：`AttemptCount` 不落盘的话，每次开 App 都从零开始，
///    「有限次」就变成了**无限次** —— 一条永远传不上去的录像会让手机
///    一直重试下去，用户看不见任何异常。
/// 3. **§3.4.1 队列可恢复**：重启后要知道哪些还没传完、卡在哪一步。
///
/// ## 键名用 PascalCase
///
/// 与 `labels.jsonl` / `punches.jsonl` 一致，也与 §1.4 那份字段表一致。
/// 本仓的 `index.jsonl` / `session.json` 用的是 camelCase —— 两种确实并存，
/// 理由写在 `label_store.dart` 里（哪些是两边对齐过的格式、哪些还不是）。
///
/// ⚠️ **电脑端目前不写也不读这个文件**（清理与回查是 M6 的事）。
/// 等那边真开始读的时候，键名要对一次 —— 对不上会表现成「一条记录都读不出来」，
/// 是响的，不是静默的。
library;

import 'dart:convert';
import 'dart:io';

import '../states.dart';

/// 一条证据的归档状态。
class ArchiveRecord {
  const ArchiveRecord({
    required this.evidenceId,
    required this.state,
    this.attemptCount = 0,
    this.nextRetryAt,
    this.lastError,
    this.lastErrorDetail,
    this.archivedAt,
    this.timeAnchor,
    this.location,
    this.receiverDeviceName,
  });

  final String evidenceId;
  final UploadState state;

  /// 已经试了几次。**必须落盘**（见文件头第 2 条）。
  final int attemptCount;

  /// 下次该在什么时候重试（递增退避的落点）。
  final DateTime? nextRetryAt;

  /// 最后一次失败的协议码（`UploadErrorCodes` 里的那个）。给人看的中文在
  /// [lastErrorDetail] 里 —— 码是协议，详情是文案，改文案不影响判定。
  final String? lastError;
  final String? lastErrorDetail;

  /// 归档成功时刻（**本机钟**）。只用来排序展示，不参与任何判定 ——
  /// 判定用的是 [timeAnchor]。
  final DateTime? archivedAt;

  /// 接收方时间，外部时间锚（规格 §3.6.4）。**保留期从它起算。**
  final DateTime? timeAnchor;

  /// 归档层内的相对路径。
  final String? location;

  final String? receiverDeviceName;

  bool get isArchived => state == UploadState.archived;
  bool get isFailed => state == UploadState.failed;

  ArchiveRecord copyWith({
    UploadState? state,
    int? attemptCount,
    DateTime? nextRetryAt,
    String? lastError,
    String? lastErrorDetail,
    DateTime? archivedAt,
    DateTime? timeAnchor,
    String? location,
    String? receiverDeviceName,
    bool clearRetry = false,
    bool clearError = false,
  }) {
    return ArchiveRecord(
      evidenceId: evidenceId,
      state: state ?? this.state,
      attemptCount: attemptCount ?? this.attemptCount,
      // ⚠️ 成功时要把「下次重试」清掉。留着的话，界面上一条已经备份好的录像
      // 底下会一直挂着一句「下次重试 …」，而它永远不会再重试了。
      nextRetryAt: clearRetry ? null : (nextRetryAt ?? this.nextRetryAt),
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastErrorDetail: clearError ? null : (lastErrorDetail ?? this.lastErrorDetail),
      archivedAt: archivedAt ?? this.archivedAt,
      timeAnchor: timeAnchor ?? this.timeAnchor,
      location: location ?? this.location,
      receiverDeviceName: receiverDeviceName ?? this.receiverDeviceName,
    );
  }

  Map<String, Object?> toJson() => {
        'EvidenceId': evidenceId,
        'State': state.name,
        'AttemptCount': attemptCount,
        'NextRetryAt': nextRetryAt?.toUtc().toIso8601String(),
        'LastError': lastError,
        'LastErrorDetail': lastErrorDetail,
        'ArchivedAt': archivedAt?.toUtc().toIso8601String(),
        'TimeAnchor': timeAnchor?.toUtc().toIso8601String(),
        'Location': location,
        'ReceiverDeviceName': receiverDeviceName,
      };

  static ArchiveRecord fromJson(Map<String, Object?> json) => ArchiveRecord(
        evidenceId: json['EvidenceId']! as String,
        state: _stateFromWire(json['State'] as String?),
        attemptCount: ((json['AttemptCount'] as num?) ?? 0).toInt(),
        nextRetryAt: _time(json['NextRetryAt']),
        lastError: json['LastError'] as String?,
        lastErrorDetail: json['LastErrorDetail'] as String?,
        archivedAt: _time(json['ArchivedAt']),
        timeAnchor: _time(json['TimeAnchor']),
        location: json['Location'] as String?,
        receiverDeviceName: json['ReceiverDeviceName'] as String?,
      );

  /// 认不出的状态一律当 `pending` —— **朝「还会再试一次」的那头落**。
  /// 读不出来就当成已归档的话，一条其实没传上去的录像会被当成备份好了。
  static UploadState _stateFromWire(String? value) => UploadState.values
      .firstWhere((state) => state.name == value, orElse: () => UploadState.pending);

  static DateTime? _time(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toLocal() : null;
}

/// 归档状态表 —— 与索引同构的追加写 JSON Lines，**读取时同 `evidenceId` 后者胜出**。
///
/// 追加写而不是原地改：一条记录的状态会变好几次（待传 → 上传中 → 失败 → 再传 → 已归档），
/// 原地改要重写整个文件，而「重写到一半掉电」会把**所有**证据的归档状态一起弄坏。
/// 追加写最坏只丢最后一行（母仓 §6.2「数据删除必须极度克制」的同一条精神）。
class ArchiveStore {
  ArchiveStore(this.path);

  final String path;

  /// 写入的串行闸。并发追加会交错写出半个 JSON 行 —— 那样的行整条读不出来。
  Future<void> _gate = Future<void>.value();

  /// 追加一条状态。返回之后这一条已经在盘上了。
  Future<void> record(ArchiveRecord record) {
    final result = _gate.then((_) => _appendNow(record));

    // 闸门要吞掉异常继续放行，否则一次失败会把后续所有写入都堵死。
    _gate = result.then((_) {}, onError: (_) {});

    return result;
  }

  Future<void> _appendNow(ArchiveRecord record) async {
    final file = File(path);
    await file.parent.create(recursive: true);

    // flush: true —— 这不是缓存，是「这台手机有没有备份」的唯一凭据。
    // 交给操作系统的缓冲区就达不到这个目的。
    await file.writeAsString(
      '${jsonEncode(record.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// 读出全部归档状态，按 `evidenceId` 归并（后者胜出）。
  Future<Map<String, ArchiveRecord>> loadAll() async {
    final file = File(path);
    if (!await file.exists()) return {};

    final records = <String, ArchiveRecord>{};

    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;

      try {
        final record =
            ArchiveRecord.fromJson(jsonDecode(line) as Map<String, Object?>);
        records[record.evidenceId] = record;
      } on Object {
        // 半个 JSON 行（掉电时写到最后一行）—— 跳过它，
        // 别让一条坏行把整张表都读不出来。
        continue;
      }
    }

    return records;
  }

  Future<ArchiveRecord?> find(String evidenceId) async =>
      (await loadAll())[evidenceId];
}
