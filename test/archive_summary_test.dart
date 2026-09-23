import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/states.dart';
import 'package:vidlog_mobile/upload/archive_store.dart';

/// `summarizeUploadState` —— 把**一次录制**的各分段归并成界面上那一格。
///
/// 归并的顺序不是随手排的：**有失败就是失败**（不变量 I3，规格 §3.4.3 ★
/// 来自一次真实故障 —— 原系统上传失败后进终态、永不重试，用户完全不知道
/// 数据没传上去）。六段传到五段而列表上写「已备份」，正是这一页要防的假话。
void main() {
  ArchiveRecord record(String id, UploadState state) =>
      ArchiveRecord(evidenceId: id, state: state);

  group('归并一条录像的分段', () {
    test('六段全都归档了才算已备份', () {
      final records = {
        for (final id in ['s-000', 's-001', 's-002'])
          id: record(id, UploadState.archived),
      };

      expect(summarizeUploadState(['s-000', 's-001', 's-002'], records),
          UploadState.archived);
    });

    test('★ 传到第五段、第六段失败 —— 说「失败」，不是「已备份」', () {
      final records = {
        for (final id in ['s-000', 's-001'])
          id: record(id, UploadState.archived),
        's-002': record('s-002', UploadState.failed),
      };

      // 这一条要是返回 archived，列表上就会写着「已备份」而实际缺一段 ——
      // 用户会照着那句话把手机上的原文件删掉。
      expect(summarizeUploadState(['s-000', 's-001', 's-002'], records),
          UploadState.failed);
    });

    test('有在传的就先说在传', () {
      final records = {
        's-000': record('s-000', UploadState.archived),
        's-001': record('s-001', UploadState.uploading),
      };

      expect(summarizeUploadState(['s-000', 's-001'], records),
          UploadState.uploading);
    });

    test('撞上退避的说「待重试」——它还会自己再试，不用用户做什么', () {
      final records = {
        's-000': record('s-000', UploadState.archived),
        's-001': record('s-001', UploadState.backoff),
      };

      expect(summarizeUploadState(['s-000', 's-001'], records),
          UploadState.backoff);
    });

    test('失败压过退避 —— 一个要人管，一个不用', () {
      final records = {
        's-000': record('s-000', UploadState.backoff),
        's-001': record('s-001', UploadState.failed),
      };

      expect(summarizeUploadState(['s-000', 's-001'], records),
          UploadState.failed);
    });

    test('一条记录都没有时朝「还会再试一次」那头落', () {
      // ⚠️ 不落成 archived。读不到就当成已归档的话，一条其实没传上去的录像
      // 会被当成备份好了 —— 与 `ArchiveRecord._stateFromWire` 同一条规矩。
      expect(summarizeUploadState(['s-000'], const {}), UploadState.pending);
      expect(summarizeUploadState(const [], const {}), UploadState.pending);
    });

    test('记录里认不出的状态名当 pending', () {
      // 旧版本写的、或者被人手改过的 archive.jsonl —— 一条坏记录不该让
      // 这条录像显示成「已备份」。
      final decoded = ArchiveRecord.fromJson({
        'EvidenceId': 's-000',
        'State': '某个以后才会有的状态',
        'AttemptCount': 0,
      });

      expect(decoded.state, UploadState.pending);
    });
  });
}
