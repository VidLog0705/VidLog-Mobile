import 'dart:async';

import 'package:flutter/material.dart';

import '../diagnostics/app_log.dart';
import '../recording/cleanup_audit.dart';
import '../recording/cleanup_log_view.dart';
import '../recording/recording_totals.dart';
import 'corners.dart';
import 'palette.dart';

/// 「清理流水」二级页（T24）：把 `<root>/cleanup-audit.jsonl` 摊开给用户看。
///
/// ## 为什么要有这一页
///
/// 规格 §6.2「禁止静默清理」是**两半**：删之前必须预告（那半早就做完了），
/// **且保留可查的清理记录**。审计一直在写盘，而**没有任何地方能看** ——
/// 文件躺在应用目录底下，用户答不上来「我那条录像什么时候没的」。
/// 与电脑端 `CleanupLogWindow` 是同一件事的两端实现（P6 = A）。
///
/// ⚠️ **这一页只画，不判**：动作码翻人话、时间格式、单号查不到时的兜底、
/// 那个小标该用哪支色，全在 `CleanupLogView` / `cleanupActionLook` 里 ——
/// 这一端没有 App 层的测试工程，写在这儿的判断没有任何东西挡得住。
///
/// ⚠️ 与 [RecordDetailPage] 不同的是，这一页**必须自己读盘**（流水不在内存里，
/// 而且它随时会被另一端追加）。读失败时**界面上那句话会随关页消失**，
/// 所以那一次的原话另落一条日志（同 `净盘页` 的口径）。
class CleanupLogPage extends StatefulWidget {
  const CleanupLogPage({
    super.key,
    required this.rootPath,
    required this.sessions,
  });

  /// 录像根目录 —— 流水就在它下面（`CleanupAuditLog.inRoot`）。
  final String rootPath;

  /// 当前的录像列表，**只用来把证据 id 换成单号**。
  ///
  /// ⚠️ 快照。已经删掉的那几条不在这里面 —— 那正该显示
  /// 「（无单号）」：它们是**流水上唯一还留着的痕迹**，
  /// 拿当前列表去反查本来就查不到（见 `CleanupLogView.build`）。
  final List<RecordingSession> sessions;

  @override
  State<CleanupLogPage> createState() => _CleanupLogPageState();
}

class _CleanupLogPageState extends State<CleanupLogPage> {
  CleanupAuditPage? _page;
  String? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final page = await CleanupAuditLog.inRoot(widget.rootPath).loadPage();
      if (!mounted) return;
      setState(() => _page = page);
    } on Object catch (error) {
      // ⚠️ 只写在界面上不算数：用户看到这句、把页一关就没了，而
      // 「流水读不出来」正是他会来报的那种事（同 `SettingsWindow` 那几处）。
      AppLog.instance.warn('清理', '读不出清理流水', data: {'error': '$error'});

      if (!mounted) return;
      setState(() => _failure = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;

    return Scaffold(
      appBar: AppBar(title: const Text('清理流水')),
      body: page == null ? _waiting(context) : _flow(context, page),
    );
  }

  Widget _waiting(BuildContext context) {
    final failure = _failure;
    if (failure == null) return const Center(child: CircularProgressIndicator());

    return Padding(
      key: const Key('cleanup-log-failed'),
      padding: const EdgeInsets.all(16),
      child: Text(
        '读不出清理流水：$failure',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  Widget _flow(BuildContext context, CleanupAuditPage page) {
    final rows = CleanupLogView.build(page.records, widget.sessions);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '这里记着清过哪一条、为什么清、哪几条按 I8 保留。',
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: Palette.muted),
        ),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          Text(
            CleanupLogView.emptyText,
            key: const Key('cleanup-log-empty'),
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Palette.muted),
          )
        else
          for (final row in rows) _row(context, row),
        // ⚠️ 读不动的行**必须说出来**。悄悄跳过的话，这一页看着干干净净 ——
        // 而「干干净净」在这里恰恰是一句假话：这份流水是「这条录像什么时候没的」
        // 的唯一凭据。与电脑端 `DescribeUnreadable` 逐字同一句。
        if (page.unreadableLines > 0) ...[
          const SizedBox(height: 12),
          Text(
            CleanupLogView.describeUnreadable(page.unreadableLines),
            key: const Key('cleanup-log-unreadable'),
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: Palette.danger),
          ),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, CleanupLogRow row) {
    final look = cleanupActionLook(row.action);

    return Card(
      key: Key('cleanup-log-${row.evidenceId}-${row.action}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    row.waybillText,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                _pill(context, row.actionText, look.color, look.tint),
              ],
            ),
            const SizedBox(height: 4),
            Text(row.reasonText, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            // 时刻 + 证据 id。证据 id 平时没用，出事时要拿它去比对那一份录像 ——
            // 电脑端把同样这两个值挂在 tooltip 上，手机上没有 tooltip，就摆出来。
            Text(
              '${row.atText} · ${row.evidenceId}',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Palette.muted),
            ),
          ],
        ),
      ),
    );
  }

  /// 与详情页那颗胶囊同一对色、同一个圆角（`Corners.tag`）。
  Widget _pill(BuildContext context, String text, Color color, Color tint) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(Corners.tag),
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
      );
}
