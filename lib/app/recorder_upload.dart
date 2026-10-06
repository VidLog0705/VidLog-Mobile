// ignore_for_file: invalid_use_of_protected_member
//
// ⚠️ 上面这条是这套拆法**必须付的价**，不是图省事：`State.setState` 带
// `@protected`，而分析器不把 `extension on _RecorderPageState` 认作
// 「State 的子类内部」，于是本文件里每一处 `setState(` 都报这一条。
// 语言本身允许（同一个 library、编译通过、测试全绿）—— 那是 lint 的误报，
// 它判的是「在不在子类里」，认不出 extension。只收窄这一条规则，
// 不做 `ignore_for_file: all`。

part of 'recorder_page.dart';

// T26③ 第 2 轮第 4 刀：从 `recorder_page.dart` 整段搬过来的 —— **纯搬家**。
// 一行都没改，只是位置换了（内容多重集比对可证）。这里装的是上传：建上传器、跑一轮、重试闹钟、逐条重传、失败弹窗。
//
// ⚠️ 只有实例方法 / getter 能装进来：extension **不许声明实例字段**，
// 所以那些字段全留在壳的类体里 —— 同 library，这里不带前缀照样读得到。

extension on _RecorderPageState {

  // ─────────────────────────────────────────────
  // 上传备份（M5）
  // ─────────────────────────────────────────────

  /// 建（或重建）上传器。
  ///
  /// ⚠️ **凭据与地址是构造参数，所以入网成功、改完地址之后都必须重建一次。**
  /// 不重建的话上传会一直拿着旧凭据，而表现是「刚配对成功，还是一条都传不上去」
  /// —— 用户会回头去怀疑地址、怀疑网络，真正的原因（对象是旧的）浮现不出来。
  void _buildUploader() {
    final identity = _identity;
    if (identity == null) return;

    _uploader = Uploader(
      rootPath: _rootPath,
      identity: identity,
      index: _index,
      punchLog: _punchLog,
      labels: _labels,
      archive: _archive,
      client: _client = UploadClient(
        address: identity.hostAddress,
        // 端口来自**二维码里那一串**（`hostPort`），默认 8720 ——
        // 不传的话，扫码连进来的那台电脑端只要不是默认端口，
        // 入网会成功、之后的每一次上传都会打到 8720 上。
        port: identity.hostPort,
        credential: identity.credential,
      ),
    );
  }

  /// 跑一趟上传队列。
  ///
  /// [manual] = 用户按了「立即备份」：**不再等退避**，当场都试一遍。
  /// 用户明确要求的东西不该被一个他自己看不见的倒计时挡住。
  Future<void> _runUploads({bool manual = false}) async {
    if (_uploading) return;
    if ((_identity?.hostAddress ?? '').isEmpty) return;

    setState(() => _uploading = true);

    try {
      final pass = await _uploader.runOnce(manual: manual);
      if (!mounted) return;

      await _refreshDiagnostics();
      if (!mounted) return;

      setState(() => _uploading = false);
      _armRetry(pass.nextRetryAt);

      // ── 归档回执里的时间锚 = 第二个校准来源（规格 §3.6.4）──────────
      //
      // 「取到过任何一个即算校准」，而这一条**局域网即可、不需要公网** ——
      // 对一台在仓库里、联不上公网但能连上电脑端的手机，这是唯一拿得到的锚。
      //
      // ⚠️ 用一个**新归档成功**的那条（`timeAnchor` 是电脑端盖的，用户改不了）。
      // `calibrateFromReceipt` 自己会拒绝「已经校准过」的情况 —— 换锚会让
      // 时间线在两条线之间跳一下，而那正是跳变检测要防的事。
      for (final outcome in pass.outcomes) {
        final anchor = outcome.record.timeAnchor;
        if (anchor == null) continue;

        if (await _clock?.calibrateFromReceipt(anchor) ?? false) {
          _log('✅ 已按电脑端回执的时间锚完成校准');
          break;
        }
      }

      // ⚠️ 失败要**说出来**（不变量 I3，规格 §3.4.3 ★ 来自一次真实故障：
      // 原系统上传失败后进终态、永不重试，用户完全不知道数据没传上去）。
      // 列表上那个红标是主入口，这句日志是给「正在看事件面板的人」的。
      final failed =
          pass.outcomes.where((o) => o.kind == UploadOutcomeKind.failed).toList();
      if (failed.isNotEmpty) {
        _log('${failed.length} 条传不上去：${failed.first.message ?? failed.first.record.lastError ?? ''}');
      }
    } on Object catch (error) {
      // `runOnce` 把每一条的失败都收进了状态里，走到这里是它**自己**炸了
      // （磁盘读不动之类）。同样必须看得见 —— 吞掉的话这一趟就等于没发生，
      // 而用户以为它传了。
      if (mounted) {
        setState(() => _uploading = false);
        _log('备份出错：$error');
      }
    }
  }

  /// 排下一次自动重试。见 [_retryTimer] 的说明。
  void _armRetry(DateTime? at) {
    _retryTimer?.cancel();
    _retryTimer = null;
    _nextRetryAt = at;
    if (at == null) return;

    final delay = at.difference(DateTime.now());
    _retryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      unawaited(_runUploads());
    });
  }

  /// 手动重试**一条录像的全部未完成分段**（规格 §3.4.3 的那个入口）。
  ///
  /// 没有它，一条耗尽重试的录像就再也救不回来了 —— 而它就在手机里，
  /// 内容好好的。
  Future<void> _retrySession(RecordingSession session) async {
    if (_uploading) return;

    final ids = session.evidenceIds.toSet();
    final entries = _entries.where((e) => ids.contains(e.evidenceId)).toList();
    if (entries.isEmpty) return;

    setState(() => _uploading = true);

    try {
      for (final entry in entries) {
        await _uploader.upload(entry, manual: true);
      }
    } on Object catch (error) {
      if (mounted) _log('重试出错：$error');
    }

    if (!mounted) return;

    await _refreshDiagnostics();
    if (!mounted) return;

    setState(() => _uploading = false);
    _armRetry(null);
  }

  /// 一条录像到底卡在哪 —— 给用户看的话，以及一个能救回来的按钮。
  Future<void> _showUploadFailure(RecordingSession session) async {
    final ids = session.evidenceIds.toSet();
    final problems = [
      for (final entry in _entries)
        if (ids.contains(entry.evidenceId))
          if (_archiveRecords[entry.evidenceId] case final record?
              when record.state == UploadState.failed)
            record,
    ];

    final seen = <String>{};
    final hints = <String>[];
    for (final record in problems) {
      final hint = record.lastErrorDetail ?? record.lastError ?? '上传失败';
      if (seen.add(hint)) hints.add(hint);
    }

    if (!mounted) return;

    final retry = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('这一条没传上去'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final hint in hints)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(hint, style: const TextStyle(fontSize: 13)),
              ),
            const SizedBox(height: 4),
            const Text(
              '手机上的原文件还在，不会因为传不上去就没了。',
              style: TextStyle(fontSize: 12, color: Palette.muted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('知道了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('再试一次'),
          ),
        ],
      ),
    );

    if (retry == true) await _retrySession(session);
  }
}
