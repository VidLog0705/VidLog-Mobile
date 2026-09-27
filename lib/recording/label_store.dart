import 'dart:convert';
import 'dart:io';

/// 一条标签。
///
/// **挂在证据（`EvidenceId`）上**，不挂单号、不挂会话。电脑端
/// `Labels/LabelStore.cs` 的选择，理由写在它的 `docs/实现决策.md` §8：
/// 同一个单号可能既发过货又退过货，挂单号上会让两段录像共用一个值，
/// 必然有一个是错的。
class RecordingLabel {
  const RecordingLabel({
    required this.evidenceId,
    required this.key,
    required this.value,
    required this.updatedAt,
  });

  final String evidenceId;
  final String key;
  final String value;
  final DateTime updatedAt;

  /// 落盘形态。键名与电脑端 `LabelDto` **逐字一致（PascalCase）**。
  ///
  /// ⚠️ 这里是 PascalCase，而本仓 `index.jsonl` 用的是 camelCase。
  /// **不是笔误**，是两边各自的历史约定：打点日志（`punches.jsonl`）与标签表
  /// 是**两端逐字对齐过的**格式。详见 `docs/实现决策.md` §19。
  ///
  /// ⚠️ **2026-09-27 更新**（原来这里写的是「索引与清单还没有【对齐】」）：
  ///
  /// - **索引那一半已经收口了**，但**不是靠统一字段名** —— 电脑端
  ///   `JsonLinesRecordingIndex` 改成了**宽容读**（候选字段名表 + 大小写不敏感），
  ///   于是 `waybill` / `Waybill` / `WaybillNumber` 三种写法都认。
  ///   ⚠️ 写端**维持原样**：两端的 `index.jsonl` 都已经在真机的盘上了，
  ///   改读端才是唯一可行的方向。
  /// - **`session.json` 根本不在这个话题里**：它是**各自工作区里的本机临时状态**
  ///   （孤儿判定用，`<root>/<sessionId>/session.json`），**两端从不交换它**。
  ///   原来把它和索引并列，是把它误当成了跨端格式。
  Map<String, Object?> toJson() => {
        'EvidenceId': evidenceId,
        'Key': key,
        'Value': value,
        // 存 UTC：墙钟时刻落盘必须带时区（与打点同一条规矩）。
        'UpdatedAt': updatedAt.toUtc().toIso8601String(),
      };

  static RecordingLabel fromJson(Map<String, Object?> json) => RecordingLabel(
        evidenceId: json['EvidenceId']! as String,
        key: json['Key']! as String,
        value: json['Value']! as String,
        updatedAt: DateTime.parse(json['UpdatedAt']! as String).toLocal(),
      );
}

/// 标签表 —— I5 的落点。
///
/// 母仓 `docs/02-数据模型.md:60`：
/// > **公司 / 分类 / 备注等属性不在这里。** 按 I5，它们只是可修正标签，
/// > 存在独立的标签表里，可随时改，不影响证据本身的同一性。
///
/// **与电脑端 `Labels/LabelStore.cs` 是同一份文件形态**：同一个文件名
/// `labels.jsonl`、同一个位置（数据根目录）、同一组键名
/// （`EvidenceId` / `Key` / `Value` / `UpdatedAt`）、同一个标签键
/// `business-type`、同一组取值（`outbound` / `return`）。
///
/// 追加写 + 读取时**同键后者胜出**，所以「改标签」是再追加一条，不是原地覆盖
/// （母仓 §6.2：数据删除必须极度克制）。
///
/// ## 读的那一半是 M5 补的（§19.7 那笔债）
///
/// 在 [loadAll] 之前，这个类**只写不读** —— 界面上没有任何地方要显示它。
/// 上传备份改变了这一点：标签要跟着录像一起交给电脑端，
/// 不然那边网页上的检索会把每一条都显示成 `unknown`（发货 / 退货分不出来）。
class LabelStore {
  LabelStore(this.path);

  final String path;

  /// 写入的串行闸。并发追加会交错写出半个 JSON 行 —— 那样的行整条读不出来。
  Future<void> _gate = Future<void>.value();

  Future<void> append(RecordingLabel label) {
    final result = _gate.then((_) => _appendNow(label));

    // 闸门要吞掉异常继续放行，否则一次失败会把后续所有写入都堵死。
    _gate = result.then((_) {}, onError: (_) {});

    return result;
  }

  Future<void> _appendNow(RecordingLabel label) async {
    final file = File(path);
    await file.parent.create(recursive: true);

    await file.writeAsString(
      '${jsonEncode(label.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// 读出全部标签。文件不存在时返回空表（还没写过不是错误）。
  Future<List<RecordingLabel>> loadAll() async {
    final file = File(path);
    if (!await file.exists()) return [];

    final labels = <RecordingLabel>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        labels.add(
            RecordingLabel.fromJson(jsonDecode(line) as Map<String, Object?>));
      } on Object {
        // 半个 JSON 行（掉电时写到最后一行）—— 跳过它，别让一条坏行
        // 把整张标签表都读不出来。
        continue;
      }
    }

    return labels;
  }

  /// 某一条证据的全部标签，**同键后者胜出**（与写入时的语义一致）。
  ///
  /// 上传备份用它把这条录像的标签随 `commit` 一起交给电脑端 ——
  /// 不带的话，那边网页上这一条会显示成 `unknown`。
  Future<List<RecordingLabel>> forEvidence(String evidenceId) async {
    final byKey = <String, RecordingLabel>{};

    for (final label in await loadAll()) {
      if (label.evidenceId != evidenceId) continue;
      byKey[label.key] = label;
    }

    return byKey.values.toList();
  }

  /// 锁定 / 解锁一条证据（规格 §3.6.5）。
  ///
  /// 锁定后**永不被自动清理**（§3.5.3② 的硬豁免）—— 而那条豁免在两边都是
  /// 靠**读这个标签**实现的（本机 `lifecycle._isLocked`、
  /// 电脑端 `CleanupPolicy.IsLocked`），所以这个方法是那条豁免的**唯一开关**。
  ///
  /// ⚠️ **值只写 `'true'` / `'false'`**：两端的判据都是先 `bool.TryParse`，
  /// **认不出来就当锁着**（朝少删的那头落）。写 `'1'` / `'yes'` 之类
  /// 会变成「永远锁着」—— 用户解不开，而界面上看不出为什么。
  ///
  /// ⚠️ 解锁**不是删那一行**，是再追加一条 `false`（标签表追加写、
  /// 后者胜出）。母仓 §6.2：数据删除必须极度克制。
  Future<void> setLocked({
    required String evidenceId,
    required bool locked,
    required DateTime now,
  }) =>
      append(RecordingLabel(
        evidenceId: evidenceId,
        key: lockedLabelKey,
        value: locked ? 'true' : 'false',
        updatedAt: now,
      ));
}

/// 某一条证据锁着没有（规格 §3.6.5）。
///
/// ⚠️ **判据只有这一处**：`lifecycle._isLocked`（清理判定）与界面上的锁定图标
/// 都调它。分成两份的话会出现「界面显示没锁、清理却把它保留了」
/// —— 用户没机会理解那个状态。
///
/// 判据三条（与电脑端 `CleanupPolicy.IsLocked` **同向**）：
/// 1. **没打过这个标签 = 没锁**（绝大多数证据的常态）；
/// 2. 打过了、值也认得出 ⇒ 按那个值；
/// 3. 打过了但**认不出来** ⇒ **当锁着** —— 朝**少删**的那头落。
///    ⚠️ 第 1 条必须单独判：少了它，「认不出来就当锁着」会把整个库永久锁死。
bool isEvidenceLocked(Map<String, String>? labelsForEvidence) {
  final raw = labelsForEvidence?[lockedLabelKey];

  if (raw == null) return false;

  return bool.tryParse(raw.trim()) ?? true;
}

/// 锁定标记的标签键。**与电脑端 `LabelKeys.Locked` 逐字一致。**
///
/// ⚠️ 它原来定义在 `lifecycle.dart` 里，2026-09-27 挪到这儿 ——
/// 理由是**位置该与另一端同构**：电脑端那个常量就在 `Labels/LabelStore.cs` 里。
/// 放在判定层的话，「写」与「读」两半各在一个文件，改一处容易漏另一处。
///
/// ⚠️ 写错的代价**是静默的**：电脑端按 `locked` 去查，查不到就当「没打过这个
/// 标签」—— 一条锁好的证据会被当成没锁。与 `BusinessType.labelKey` 同一个坑。
const String lockedLabelKey = 'locked';
