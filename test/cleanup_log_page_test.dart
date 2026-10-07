/// 「清理流水」那一页（T24）。
///
/// ⚠️ 这一页会**真读盘**（`CleanupAuditLog.inRoot(rootPath).loadPage()`），
/// 所以测试里也得给一个真目录 —— 不是「用假数据喂进去」。那条路正是这一页
/// 唯一可能出错的地方：路径拼错、读失败没人管，界面照样干干净净。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/cleanup_log_page.dart';
import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/cleanup_audit.dart';
import 'package:vidlog_mobile/recording/recording_totals.dart';

/// 造一个真目录、按 [write] 塞点东西进去，再把页面推上去、**等真读盘回来**。
///
/// ⚠️ 真 IO **一律包在 `tester.runAsync` 里**。`testWidgets` 的 body 跑在
/// fake async 那个 zone 里，`await File(...).readAsLines()` 在那儿**永远
/// 不会回来** —— 页面就一直停在转圈那颗上，整个用例挂到超时
/// （第一版就是这么挂到 10 分钟超时的）。
///
/// ⚠️ 而且**一轮不够**。`runAsync` 让真 IO 完成，但它的续体登记在 fake 那个
/// zone 的 microtask 队列上，要等下一次 `pump()` 才跑 —— 而 `pump()` 里跑起来
/// 的那一句（`readAsLines`）又得等下一次 `runAsync`。`loadPage()` 至少两跳
/// （`exists` → `readAsLines`），所以这里转几圈，转到「不在转圈了」为止。
/// 顺带：`runAsync` **里面不许调 `pump`**，两个 zone 会互相等。
Future<void> open(
  WidgetTester tester, {
  required Future<void> Function(Directory root) write,
  List<RecordingSession> sessions = const [],
}) async {
  late Directory root;
  await tester.runAsync(() async {
    root = await Directory.systemTemp.createTemp('vidlog-log-page-');
    await write(root);
  });
  // 删不掉就把这个目录留下 —— 那句报错会把真正的失败盖掉。
  addTearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄还开着（多半是读没跑完）—— 临时目录，留着不管。
    }
  });

  await tester.pumpWidget(MaterialApp(
    home: CleanupLogPage(rootPath: root.path, sessions: sessions),
  ));

  for (var i = 0; i < 8; i++) {
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  CleanupAuditRecord record({
    String evidenceId = 'ev-1',
    String action = CleanupAction.deleted,
    String reason = '超过保留期',
    DateTime? at,
  }) =>
      CleanupAuditRecord(
        evidenceId: evidenceId,
        action: action,
        reason: reason,
        at: at ?? DateTime(2026, 10, 7, 9),
      );

  RecordingSession session({List<String> evidenceIds = const ['ev-1']}) =>
      RecordingSession(
        sessionId: 'sess-1',
        waybill: WaybillNumber.parse('SF1000000001'),
        startedAt: DateTime(2026, 10, 7, 10),
        duration: const Duration(minutes: 5),
        bytes: 1024,
        segmentCount: evidenceIds.length,
        evidenceIds: evidenceIds,
      );

  testWidgets('★ 流水上看得见：时间、单号、动作人话、为什么', (tester) async {
    await open(
      tester,
      write: (root) => CleanupAuditLog.inRoot(root.path).append(record()),
      sessions: [session()],
    );

    expect(find.text('已清理'), findsOneWidget);
    expect(find.text('SF1000000001'), findsOneWidget);
    expect(find.text('超过保留期'), findsOneWidget);
    // 时刻与证据 id 摆在同一行小字上。
    expect(find.textContaining('2026-10-07 09:00:00'), findsOneWidget);
    expect(find.textContaining('ev-1'), findsOneWidget);
  });

  testWidgets('★ 已经删掉的那些（列表里查不到）写（无单号），不许留一格空白', (tester) async {
    // 会话列表是**当下**那一份 —— 那条已经不在里面了，而它正是这本账的意义。
    await open(
      tester,
      write: (root) => CleanupAuditLog.inRoot(root.path).append(
        record(evidenceId: 'ev-gone'),
      ),
    );

    expect(find.text('（无单号）'), findsOneWidget);
  });

  testWidgets('★ 一条都没有时要有话说，不是一片空白', (tester) async {
    await open(tester, write: (_) async {});

    expect(find.byKey(const Key('cleanup-log-empty')), findsOneWidget);
    expect(find.textContaining('还没有清理记录'), findsOneWidget);
  });

  testWidgets('★ 读不动的行要说出来 —— 悄悄跳过的话这一页就是一句假话', (tester) async {
    await open(
      tester,
      write: (root) async {
        final audit = CleanupAuditLog.inRoot(root.path);
        await audit.append(record());

        // 写一半就断电了的那一行。
        await File(audit.path)
            .writeAsString('{"EvidenceId":"ev-2","Act', mode: FileMode.append);
      },
      sessions: [session()],
    );

    expect(find.byKey(const Key('cleanup-log-unreadable')), findsOneWidget);
    expect(find.textContaining('1 行读不动'), findsOneWidget);
  });

  testWidgets('★ 认不出的动作码原样印出来，而且不许吃掉那一行', (tester) async {
    await open(
      tester,
      write: (root) => CleanupAuditLog.inRoot(root.path).append(
        record(action: 'someFutureCode', reason: '以后才有的动作'),
      ),
      sessions: [session()],
    );

    expect(find.text('someFutureCode'), findsOneWidget);
  });

  // ⚠️ 「读盘失败」那一条分支（`AppLog.instance.warn` + `cleanup-log-failed`）
  // **没有测试盖着**，而且不是懒得写：它在本机造不出来。
  // `loadPage()` 第一句是 `if (!await file.exists()) return 空`，而
  // `File.exists()` **从不抛**（路径非法、路径上是个目录、父级不是目录，
  // 它一律返回 false）—— 于是在 Windows 上要让它真失败，得让那个文件
  // **存在但读不动**（独占锁之类），而 Dart 的 `RandomAccessFile` 在
  // Windows 上开的就是可共享读的。留着这一条不如明写在这儿：
  // 别让它看起来像验过了。
}
