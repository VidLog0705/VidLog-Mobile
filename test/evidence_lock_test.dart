import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/business_type.dart';
import 'package:vidlog_mobile/recording/label_store.dart';
import 'package:vidlog_mobile/recording/lifecycle.dart';
import 'package:vidlog_mobile/recording/recording_index.dart';
import 'package:vidlog_mobile/recording/retention_setting.dart';
import 'package:vidlog_mobile/states.dart';
import 'package:vidlog_mobile/upload/archive_store.dart';

/// 争议锁定（规格 §3.6.5）。
///
/// 规格只有两行：「用户可给证据打标记、可锁定」+「**锁定后永不被自动清理**」。
///
/// ⚠️ 而这条一直是**只有读的那一半**：两端都读 `locked` 标签
/// （本机 `lifecycle._isLocked`、电脑端 `CleanupPolicy.IsLocked`），
/// **两端都没有任何地方写它** —— 所以那条硬豁免**结构性地走不到**：
/// 用户没有任何办法把一条纠纷录像保住。
///
/// 这一批补上「写」（`LabelStore.setLocked`），并**端到端**验一遍
/// 「锁上之后真的不会被清」—— 不只是验「标签写进去了」。
void main() {
  final now = DateTime(2026, 9, 27, 12);

  late Directory temp;
  late LabelStore labels;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vidlog-lock-');
    labels = LabelStore('${temp.path}/labels.jsonl');
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on Object catch (_) {
      // 宽着接（与其它测试文件同一个口径）。
    }
  });

  /// 一条「够格被清」的录像：10 天前录的、9 天前备份成功 ⇒ 早过了 3 天保留期。
  RecordingEntry entry(String id) => RecordingEntry(
        evidenceId: id,
        sessionId: 'sess-$id',
        waybill: WaybillNumber.parse('SF1234567890'),
        startedAt: now.subtract(const Duration(days: 10)),
        endedAt: now.subtract(const Duration(days: 10)),
        duration: const Duration(minutes: 5),
        location: RelativePath.parse('2026/09/17/$id.mp4'),
        contentHash: ContentHash.parse('a' * 64),
        sourceDeviceId: 'dev-1',
      );

  ArchiveRecord archived(String id) => ArchiveRecord(
        evidenceId: id,
        state: UploadState.archived,
        timeAnchor: now.subtract(const Duration(days: 9)),
      );

  /// 判定一遍 —— **先落盘、再读回来**，让标签真经过一次写与一次读。
  Future<CleanupPlan> planFor(List<RecordingEntry> entries) async {
    // ⚠️ 先给每条打上**业务类型** —— 判定层对「没有业务类型标签」的**一律不清**
    // （判不出发货还是退货，就说不出该用哪一份保留期）。
    //
    // 不打的话「这条够格被清」这个前提根本不成立，而下面几条会**绿在巧合上**
    // —— 这正是 `★ 前提` 那条测试第一次跑就抓到的：三条用例红了，
    // 而红的原因不是锁定没生效，是**根本没有候选**。
    for (final e in entries) {
      await labels.append(RecordingLabel(
        evidenceId: e.evidenceId,
        key: BusinessType.labelKey,
        value: BusinessType.outbound.wire,
        updatedAt: now,
      ));
    }

    final loaded = <String, Map<String, String>>{};
    for (final label in await labels.loadAll()) {
      loaded.putIfAbsent(label.evidenceId, () => {})[label.key] = label.value;
    }

    return planCleanup(
      entries: entries,
      labels: loaded,
      archive: {for (final e in entries) e.evidenceId: archived(e.evidenceId)},
      retentionArchivedOutbound: RetentionSetting.days3,
      retentionArchivedReturn: RetentionSetting.days3,
      now: now,
    );
  }

  test('★ 前提：没锁的时候它**确实**够格被清', () async {
    // ⚠️ 少了这一条，下面「锁上之后不被清」可能绿在一个**巧合**上 ——
    // 比如这条录像本来就因为别的原因（业务类型、起算点、24 小时豁免）不清。
    // 那正是这个项目栽过好几次的「测试绿在一个巧合上」。
    final plan = await planFor([entry('e1')]);

    expect(plan.candidates.map((c) => c.entry.evidenceId), ['e1']);
  });

  test('★ 锁上之后**不进候选** —— 规格 §3.5.3② 的硬豁免', () async {
    await labels.setLocked(evidenceId: 'e1', locked: true, now: now);

    final plan = await planFor([entry('e1')]);

    expect(plan.candidates, isEmpty, reason: '锁定后永不被自动清理');

    expect(
      plan.exempted.map((e) => e.entry.evidenceId),
      contains('e1'),
      reason: '不但不能删，还要在**豁免列表**里看得见 —— 用户查得到「这条为什么没删」',
    );
  });

  test('解锁之后又够格被清了', () async {
    await labels.setLocked(evidenceId: 'e1', locked: true, now: now);
    await labels.setLocked(evidenceId: 'e1', locked: false, now: now);

    final plan = await planFor([entry('e1')]);

    expect(plan.candidates.map((c) => c.entry.evidenceId), ['e1']);
  });

  test('★ 解锁**不是删那一行**，是再追加一条 false', () async {
    // 母仓 §6.2：数据删除必须极度克制。标签表追加写、后者胜出 ——
    // 于是「这条什么时候锁过、什么时候解的」在源码里查得到。
    await labels.setLocked(evidenceId: 'e1', locked: true, now: now);
    await labels.setLocked(evidenceId: 'e1', locked: false, now: now);

    final lines = (await File('${temp.path}/labels.jsonl').readAsLines())
        .where((l) => l.trim().isNotEmpty)
        .toList();

    expect(lines, hasLength(2), reason: '两条都在 —— 解锁是追加，不是抹掉');
    expect(lines.first, contains('true'));
    expect(lines.last, contains('false'));
  });

  test('写进去的值就是 true / false 这两个词', () async {
    // ⚠️ 两端的判据都是「先 bool.TryParse，**认不出来当锁着**」（朝少删那头落）。
    // 所以写 '1' / 'yes' 会变成「永远锁着」—— 用户解不开，
    // 而界面上看不出为什么。这一条把值钉死。
    await labels.setLocked(evidenceId: 'e1', locked: true, now: now);

    expect((await labels.loadAll()).single.value, 'true');
  });

  test('锁定只管自己那一条', () async {
    await labels.setLocked(evidenceId: 'e1', locked: true, now: now);

    final plan = await planFor([entry('e1'), entry('e2')]);

    expect(plan.candidates.map((c) => c.entry.evidenceId), ['e2']);
  });
}
