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
  /// ⚠️ 这里是 PascalCase，而本仓 `index.jsonl` / `session.json` 用的是
  /// camelCase。**不是笔误**，是两边各自的历史约定：打点日志（`punches.jsonl`）
  /// 与标签表是**两端已经对齐过的**格式，索引与清单还没有。详见
  /// `docs/实现决策.md` §19。
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
}
