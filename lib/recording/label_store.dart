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
/// （母仓 §6.2：数据删除必须极度克制）。**手机端现在只写不读** —— 界面上还没有
/// 任何地方要显示它，等有了再补读的那一半。
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
}
