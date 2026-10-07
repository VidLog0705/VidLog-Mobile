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
// 一行都没改，只是位置换了（内容多重集比对可证）。这里装的是记录操作：锁定、清理、删除（单条与批量）、分享、改设备名。
//
// ⚠️ 只有实例方法 / getter 能装进来：extension **不许声明实例字段**，
// 所以那些字段全留在壳的类体里 —— 同 library，这里不带前缀照样读得到。

extension on _RecorderPageState {
  bool _isSessionLocked(RecordingSession session) =>
      session.evidenceIds.any((id) => isEvidenceLocked(_labelsByEvidence[id]));

  /// 锁定 / 解锁这一条（规格 §3.6.5）。
  ///
  /// ⚠️ **每一段都要写**：清理的候选是按**分段**算的（`planCleanup` 吃的是
  /// `RecordingEntry`），只锁第一段的话后面几段照样会被清掉 ——
  /// 而界面上那一条看起来是「已锁定」。这种不一致比没有锁定更糟。
  /// 返回值是**按完之后的锁态**（`true` = 现在锁着）—— 详情页拿它当场换文案。
  /// 详情页那个 `locked` 是构造参数的一次性快照，父页的 `setState` 重建不了
  /// 已经 push 上去的那条路由（见 `record_detail_page.dart` 里 `onToggleLock`）。
  Future<bool> _toggleLock(RecordingSession session) async {
    final before = _isSessionLocked(session);
    final want = !before;
    final now = DateTime.now();

    // ⚠️ 写盘会抛（`writeAsString` 不吞异常），而这里**不许让它冒出去**：
    // 冒出去的话 `onPressed` 那个 async 闭包就悄悄断了，用户按了**一点反应
    // 都没有**（连「失败」都不说）—— 跟 2026-10-06 修的那个「按完当场不变」
    // 是同一族的毛病。吞掉、记一条、把**盘上的实际状态**回给界面。
    try {
      for (final id in session.evidenceIds) {
        await _labels.setLocked(evidenceId: id, locked: want, now: now);
      }
    } on Object catch (error) {
      _log('⚠️ 锁定没写进去：${session.waybill.value} —— $error');
    }

    // 重新读一遍标签 —— 界面上的图标与 tooltip 才会跟着变。
    await _refreshDiagnostics();

    // ⚠️ 记的是**盘上真成了没有**，不是「按过了」。照 `want` 记的话，写盘
    // 失败时日志里会躺着一条「已锁定」而盘上一个字都没写 —— 事后查
    // 「这条为什么被清了」会照着日志把它当成锁着的（§6.1 不可逆动作那行）。
    //
    // ⚠️ 也别回 `want`：`loadAll` **会跳过认不出的行**（掉电写了一半的那条），
    // 于是「写过了」和「读出来是锁着的」不是一回事 —— 界面得照实说。
    final actual = _isSessionLocked(session);
    if (actual == want) {
      _log(actual
          ? '已锁定 ${session.waybill.value}（不会被自动清理）'
          : '已解锁 ${session.waybill.value}');
    } else {
      _log('⚠️ 锁定没生效：${session.waybill.value} 盘上现在还是'
          '${actual ? '锁定' : '未锁定'} —— 界面按这个显示，清理也按这个来');
    }

    return actual;
  }

  /// 自动清理的**预告 + 执行**（规格 §3.5.4 / §3.5.5）。
  ///
  /// ⚠️ **禁止静默清理**（规格原话：「清理前必须给出预告（将删除多少条、
  /// 多少容量）」）—— 所以是「先算 → 给用户看过 → 他点了才删」，
  /// 与电脑端 `MainWindow.RunStartupCleanupAsync` **同一个形状**。
  ///
  /// ⚠️ 排在 `_bootstrap` 的**最后**（`_probeHost()` 之后）：清理要**逐条回查
  /// 电脑端**（§3.5.4），而那条路要先知道地址与凭据（`_client`）。
  ///
  /// ⚠️ 没有候选时**不打扰**：每次开 App 弹一句「没什么要清的」是噪音，
  /// 而噪音会把真正该看的那一次淹掉。
  ///
  /// ⚠️ **未备份那一列永不自动删**（§3.5.2.1）在判定层是**结构性**保证的
  /// （它们落在 `nudges` 而不是 `candidates`）—— 这里不重复判，也不该判。
  Future<void> _offerCleanup() async {
    final settings = _settings;
    final client = _client;

    // 设置没读出来、或电脑端的地址/凭据还没准备好 —— 这次不清理。
    // 回查是**硬要求**（查不了就不许删），所以没有 client 就整件事做不了。
    if (settings == null || client == null) return;

    final plan = planCleanup(
      entries: _entries,
      labels: _labelsByEvidence,
      archive: _archiveRecords,
      retentionArchivedOutbound: settings.retentionArchivedOutbound,
      retentionArchivedReturn: settings.retentionArchivedReturn,
      retentionUnarchivedOutbound: settings.retentionUnarchivedOutbound,
      retentionUnarchivedReturn: settings.retentionUnarchivedReturn,
      now: DateTime.now(),
    );

    if (plan.candidates.isEmpty) return; // 不打扰
    if (!mounted) return;

    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理手机上的录像'),
        content: Text(cleanupPreviewText(plan)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('现在清理'),
          ),
        ],
      ),
    );

    if (answer != true || !mounted) return;

    final root = _rootPath;

    final outcome = await runCleanup(
      plan: plan,
      locationByEvidenceId: _locationByEvidenceId,
      rootDirectory: root,
      // 与手动删除**同一个文件、同一个形状**（审计是同一份流水）。
      audit: CleanupAuditLog.inRoot(root),
      now: DateTime.now(),
      verify: (evidenceId) async {
        final location = _locationByEvidenceId[evidenceId];

        if (location == null || location.isEmpty) {
          // 老索引行可能没有路径 —— 没法回查，那就是「查不了」。
          return const VerifyOutcome(
            exists: false,
            couldNotVerify: true,
            reason: '索引里没有这一段的相对路径',
          );
        }

        try {
          return await client.verifyLocation(location);
        } on Object catch (error) {
          // 连不上 / 超时 / 电脑端没开 —— 一律「查不了」，
          // **绝不当成「在」**（§3.5.4：删掉的可能就是最后一份）。
          return VerifyOutcome(exists: false, couldNotVerify: true, reason: '$error');
        }
      },
    );

    _log(
      '清理完成：删了 ${outcome.deleted.length} 段，'
      '归档层上查不到（因此没删）${outcome.refused.length} 段，'
      '删不动 ${outcome.failed.length} 段。',
    );

    await _refreshDiagnostics();
  }

  Future<void> _askDelete(RecordingSession session) async {
    final client = _client;
    final root = _rootPath;

    if (client == null) {
      _log('⚠️ 还不能删除：电脑端地址或凭据没准备好');
      return;
    }

    // 先按本地记录判一遍「备份了没有」—— 未备份的那些不用回查。
    final preliminary = planManualDelete(
      session: session,
      records: _archiveRecords,
      verify: const {},
    );

    var verify = const <String, VerifyOutcome>{};

    if (!preliminary.needsUploadChoice) {
      verify = await _verifyEachSegment(session, client);
    }

    if (!mounted) return;

    final plan = planManualDelete(
      session: session,
      records: _archiveRecords,
      verify: verify,
    );

    if (!plan.deletionAllowed) {
      // ⚠️ **不许删时不弹删除窗** —— 只把原因说清楚。
      // 弹了就等于把这个动作交给用户去点，而系统已经知道它不该做。
      //
      // 例外只有一种：「查不了」多给一条出路（需求方 2026-09-28 裁决，见
      // `DeletePlan.canOverrideUnverified`）。即便走那条路，**默认方向仍然是
      // 拒绝** —— 它不在这颗窗里删任何东西，只是让用户能明确地说
      // 「我知道没核对上，但电脑上确实有」。
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('这条现在不能删'),
          content: Text(
            plan.canOverrideUnverified
                // 这句必须说清「我们没能替你核对」这件事本身 ——
                // 用户要能分辨「电脑上真没有」与「我们问不到电脑」，
                // 否则他会以为自己看到的是一个确定的结论。
                ? '${plan.reason}\n\n'
                    '如果你确定那台电脑上还留着这一份（能自己去上面看到它），'
                    '也可以仍然删掉手机上这一条。这一步没人能替你核对 —— '
                    '万一电脑上那份也没了，删掉就是永久没了。'
                : plan.reason,
          ),
          actions: [
            TextButton(
              key: const Key('delete-refusal-ok'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('知道了'),
            ),
            // ⚠️ 措辞**不能与另一个窗里的「确认删除」长得一样** ——
            // 那两个窗是「删一条已经核对过的」与「删一条没备份的」，
            // 这一个的前提完全不同（我们**没**核对上）。同一句话会让用户
            // 以为自己按的是那个普通的确认删除（§3.5.6② 不许合并的同一个理由）。
            if (plan.canOverrideUnverified)
              TextButton(
                key: const Key('delete-override'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('我确认电脑上有，仍然删除'),
              ),
          ],
        ),
      );

      if (confirm != true || !mounted) return;

      final forced = overrideUnverifiedRefusal(session: session, plan: plan);

      // `canOverrideUnverified` 为真时它必定非空。真为空就是判定层与这里脱节了
      // —— 那时**什么都不做**，绝不拿一颗空 `evidenceIds` 的 plan 往下走：
      // 那会「一段都没删，界面上却走完了删除成功的整条路」。
      if (forced == null) return;

      await _deleteNow(session, forced, root);
      return;
    }

    final confirmed = await _confirmDelete(session, plan);
    if (confirmed != true || !mounted) return;

    await _deleteNow(session, plan, root);
  }

  /// 逐段回查归档层。**问不到就当查不了**，绝不当成「在」。
  Future<Map<String, VerifyOutcome>> _verifyEachSegment(
    RecordingSession session,
    UploadClient client,
  ) async {
    final results = <String, VerifyOutcome>{};

    for (final evidenceId in session.evidenceIds) {
      final location = _locationByEvidenceId[evidenceId];
      if (location == null || location.isEmpty) continue;

      try {
        results[evidenceId] = await client.verifyLocation(location);
      } on Object catch (error) {
        // 连不上 / 超时 / 电脑端没开 —— 一律「查不了」。
        results[evidenceId] = VerifyOutcome(
          exists: false,
          couldNotVerify: true,
          reason: '$error',
        );
      }
    }

    return results;
  }

  /// 按「备份了没有」弹那两种窗（规格 ②：**不许合成一个**）。
  Future<bool?> _confirmDelete(RecordingSession session, DeletePlan plan) async {
    final unarchived = plan.needsUploadChoice;

    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(unarchived ? '这一条还没备份' : '删除这一条录像'),
        content: Text(
          unarchived
              ? '${plan.reason}\n\n可以点【重新上传】先把这一条传上去（那就不会删），'
                  '或者仍然删掉它。'
              : plan.reason,
        ),
        actions: [
          if (unarchived)
            TextButton(
              key: const Key('delete-upload-instead'),
              onPressed: () {
                // 「重新上传」与「删除」是**互斥的两个意图** ——
                // 点完它还把文件删了，是最不该发生的一种。
                Navigator.of(context).pop(false);
                unawaited(_runUploads(manual: true));
              },
              child: const Text('重新上传'),
            ),
          TextButton(
            key: const Key('delete-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(unarchived ? '取消删除' : '取消'),
          ),
          TextButton(
            key: const Key('delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
  }

  /// 真删：先写审计，再删文件（规格 §3.5.6④）。
  Future<void> _deleteNow(RecordingSession session, DeletePlan plan, String root) async {
    try {
      final deleted = await deleteSessionFiles(
        plan: plan,
        locationByEvidenceId: _locationByEvidenceId,
        rootDirectory: root,
        audit: CleanupAuditLog.inRoot(root),
        now: DateTime.now(),
      );

      _log('🗑 删掉了 ${session.waybill.value} 的 ${deleted.length} 段本地副本');

      // 删完刷新备份页：列表、未备份计数、占用都要跟着变
      // （占用那一项走盘、不走索引，所以必须重读）。
      await _refreshDiagnostics();
      if (mounted) setState(() {});
    } on Object catch (error) {
      // ⚠️ 审计写不进去 ⇒ `deleteSessionFiles` 抛 ⇒ **这一条没删**（那是它的设计）。
      // 所以这里要说清楚「没删」，而不是笼统报错 —— 用户以为删了而其实没删，
      // 或者反过来，都是他会照着做决定的信息。
      _log('⚠️ 删除没能进行（没有文件被删）：$error');
      if (mounted) setState(() {});
    }
  }

  /// 打开这一条的详情页（需求方 2026-09-27 照草图定的）。
  ///
  /// 行上原来挤着三个操作（锁定 / 交付 / 删除），现在都收进这一页。
  ///
  /// ⚠️ 时间 / 时长 / 大小 / 分段四串**在这一层格式化好再传进去** ——
  /// 详情页自己不格式化。两处各写一套的话，列表上写着 `9月16日` 而详情页
  /// 写着 `09-16`，同一个东西两个样子（而搜索框是按屏幕上真有的字匹配的）。
  Future<void> _openDetail(RecordingSession session) async {
    final evidenceId = session.evidenceIds.first;
    final look = _uploadLook(summarizeUploadState(session.evidenceIds, _archiveRecords));

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RecordDetailPage(
          title: waybillOf(session),
          businessType: _businessTypeOf(session),
          uploadText: look.text,
          uploadColor: look.color,
          uploadTint: look.tint,
          timeText: _stamp(session.startedAt),
          durationText: _durationLabel(session.duration),
          sizeText: _sizeLabel(session.bytes),
          segmentText: '${session.evidenceIds.length} 段',
          location: _locationByEvidenceId[evidenceId] ?? '（索引里没记路径）',
          locked: _isSessionLocked(session),
          preview: _thumbImage(session),
          onPlay: () => _play(
            session,
            '$_rootPath/${_locationByEvidenceId[evidenceId] ?? ''}',
          ),
          onToggleLock: () => _toggleLock(session),
          onShare: () => _shareSession(session),
          // ⚠️ **返回真删掉了才 pop**（见 `RecordDetailPage.onDelete`）——
          // 删不成（回查没过、审计写不进去）时要留在原地，用户才看得到那句为什么。
          //
          // 判据是「录像真的少了一条」：`_askDelete` 在弹窗里点了取消时
          // **什么都不做**，按返回值判的话「取消」会被当成删成功然后 pop 掉。
          onDelete: () async {
            final before = _sessions.length;
            await _askDelete(session);
            return _sessions.length < before;
          },
        ),
      ),
    );

    // 回来之后重画一次：锁没锁、那条还在不在，列表上都要跟着变。
    // （`_refreshDiagnostics` 自己会 setState，但**它不一定跑过** ——
    // 用户可能只是在详情页里点了两下就返回。）
    if (mounted) setState(() {});
  }

  /// 【扫码搜索】：扫一张面单，把单号填进搜索框（需求方 2026-09-27 照草图加）。
  ///
  /// ⚠️ **扫到只填搜索框** —— 不开始录像、不切到发货栏。用户在这一页扫，
  /// 是为了**找一条录像**，不是为了录；悄悄把录制开起来是这一页最坏的一种
  /// 反应（`ScanWaybillPage` 底部那句提示也是这么说的）。
  Future<void> _scanToSearch() async {
    final text = await ScanWaybillPage.open(
      context,
      gateway: _gateway,
      // 相机在这一页之前就开着的话**不能关** —— 那可能是录制中，
      // 或者发货栏的取景框还开着。关了就是掐掉别人的会话。
      closeCameraWhenDone: _coordinator?.isCameraOpen != true,
      // 那一页要按同一套规格摆画面，并且在**新开**相机时按它开 ——
      // 否则扫完回来，留在会话上的是另一个分辨率。
      spec: _coordinator?.effectiveSpec ?? _requestedSpec(),
    );

    if (text == null || !mounted) return; // 用户返回了，没扫

    // ⚠️ 扫进来的是**面单上的原文**，可能带空格或换行。直接塞进搜索框的话，
    // `matchesQuery` 里那个 `trim` 会把它们吃掉，看起来没差别；
    // 但搜索框里显示着一段带换行的字，用户会以为是自己扫错了。
    final waybill = text.trim();
    if (waybill.isEmpty) return;

    _applyFilter(() {
      _recordsSearch.text = waybill;
      _recordsQuery = waybill;
    });
  }

  /// 批量锁定（需求方 2026-09-27 要的）。
  ///
  /// ⚠️ **只加锁、不解锁。** 一个按钮同时干两件事，用户按之前没法知道
  /// 这一次是锁还是解 —— 而「把一条纠纷录像解锁了」是要命的（规格 §3.6.5：
  /// 锁定是三条硬豁免之一，解了它保留期一到就会被清掉本机那份）。
  /// 解锁仍然在详情页里**一条一条**做。
  Future<void> _runBatchLock() async {
    final targets = _selectedSessions;
    if (targets.isEmpty) return;

    final now = DateTime.now();

    // ⚠️ 每一段都要写（与 `_toggleLock` 同一个理由）：清理的候选是按
    // **分段**算的，只锁第一段的话后面几段照样会被清掉 ——
    // 而界面上那一条看起来是「已锁定」。
    for (final session in targets) {
      for (final id in session.evidenceIds) {
        await _labels.setLocked(evidenceId: id, locked: true, now: now);
      }
    }

    await _refreshDiagnostics();
    _log('已锁定 ${targets.length} 条（不会被自动清理）');

    if (mounted) setState(() => _selected.clear());
  }

  /// 批量删除（需求方 2026-09-27 要的）。
  ///
  /// ⚠️ 规则是**只要有一条不能删，整批一条都不删**（`BatchDeletePlan`）——
  /// 「删了 7 条、跳掉 3 条」这个结果用户很难核对，他记住的是「我删了 10 条」，
  /// 而留在盘上那几条会变成他以为早就没了的东西。
  ///
  /// ⚠️ 顺序与单条那条路**逐字相同**（`_askDelete`）：**先回查、再弹窗** ——
  /// 回查的结果决定了该不该弹那个「确认删除」。
  Future<void> _runBatchDelete() async {
    final client = _client;
    final root = _rootPath;
    final targets = _selectedSessions;

    if (client == null) {
      // 没凭据就没法逐段回查，而查不了 ⇒ 不许删（I8）。
      _log('⚠️ 还不能删除：电脑端地址或凭据没准备好');
      return;
    }
    if (targets.isEmpty) return;

    // 已备份的那些才需要回查（未备份的没有那份可查）。
    final verifyBySession = <String, Map<String, VerifyOutcome>>{};

    for (final session in targets) {
      final preliminary = planManualDelete(
        session: session,
        records: _archiveRecords,
        verify: const {},
      );
      if (preliminary.needsUploadChoice) continue;

      verifyBySession[session.sessionId] = await _verifyEachSegment(session, client);
    }

    if (!mounted) return;

    final plan = planBatchDelete(
      sessions: targets,
      records: _archiveRecords,
      verifyBySession: verifyBySession,
    );

    if (!plan.canDelete) {
      // ⚠️ **不许删时不弹删除窗** —— 只把原因说清楚（与 `_askDelete` 同一个规矩）。
      // 弹了就等于把一个系统已经知道不该做的动作交给用户去点。
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('这一批现在不能删'),
          content: Text(batchDeletePreviewText(plan)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }

    final confirmed = await _confirmBatchDelete(plan);
    if (confirmed != true || !mounted) return;

    await _deleteBatch(plan.items, root);
  }

  /// 批量删除那个确认窗。
  ///
  /// ⚠️ 与单条那条路**不是同一个窗**：单条那个按「备份了没有」分两种
  /// （规格 §3.5.6②，**不许合并**）。一批里**可能两种都有**，所以是把
  /// 「其中有几条是唯一一份」写在正文里（`batchDeletePreviewText`），
  /// 而不是再分成两个窗 —— 分成两个窗的话，一次操作会被拆成两次，
  /// 而用户以为他按的是一次。
  ///
  /// ⚠️ **不给【重新上传】**（单条那个窗有）：一批里可能只有几条未备份，
  /// 「重新上传」对另外那些没有意义，点了却结束不了删除意图，
  /// 很容易变成「我以为按了重新上传，结果它删了」。
  /// 要传就退出管理、按上面那个【立即备份】。
  Future<bool?> _confirmBatchDelete(BatchDeletePlan plan) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('删除这 ${plan.count} 条录像'),
          content: Text(batchDeletePreviewText(plan)),
          actions: [
            TextButton(
              key: const Key('batch-delete-cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              key: const Key('batch-delete-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认删除'),
            ),
          ],
        ),
      );

  /// 真去删这一批。**归档层那份不动**（规格 §3.5.6①）。
  ///
  /// ⚠️ 逐条走 `deleteSessionFiles`（**先写审计再删文件**，那是它的设计）——
  /// 一条删不动不该让整批停下（与自动清理同一个取舍）。
  ///
  /// ⚠️ 与单条那条路的一处**不同**：这里可能删到一半抛（审计写不进去）。
  /// 那时**前面那些已经删了、不恢复**，所以日志必须说清是「删到一半」，
  /// 而不是笼统报错 —— 用户以为一条都没删，或者以为全删了，都会照错的信息做决定。
  Future<void> _deleteBatch(List<BatchItem> items, String root) async {
    var segments = 0;

    try {
      for (final item in items) {
        final deleted = await deleteSessionFiles(
          plan: item.plan,
          locationByEvidenceId: _locationByEvidenceId,
          rootDirectory: root,
          audit: CleanupAuditLog.inRoot(root),
          now: DateTime.now(),
        );
        segments += deleted.length;
      }

      _log('🗑 删掉了 ${items.length} 条录像的本地副本（共 $segments 段）');
    } on Object catch (error) {
      _log('⚠️ 批量删除没能进行完（已经删掉的那些不恢复，剩下没删）：$error');
    }

    // 无论成败都刷一遍：删掉的那些要从列表和占用里消失。
    await _refreshDiagnostics();
    if (mounted) setState(() => _selected.clear());
  }
  void _toggleManage() {
    setState(() {
      _managing = !_managing;
      _selected.clear();
    });
  }

  /// 选中那些录像，**按列表顺序**（弹窗里那一串要有稳定的顺序，
  /// 跟着点击先后走的话，同一次选择在两台手机上列出来的次序都不一样）。
  List<RecordingSession> get _selectedSessions =>
      [for (final session in _sessions) if (_selected.contains(session.sessionId)) session];

  // ── 两处编辑弹窗 ──────────────────────────────

  /// 改本机名。**落盘** —— 只在内存里留着的名字，重连一次就没了。
  ///
  /// 上限 [maxDeviceNameWidth] 格（汉字算 2 格）：打字时超了就拦，
  /// 框下面有实时格数 —— 需求方 2026-09-23 定的规矩。
  Future<void> _editDeviceName() async {
    final identity = _identity;
    if (identity == null) return;

    final controller = TextEditingController(text: identity.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本机名'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              // 上限是显示宽度（汉字算 2 格），所以用不了 `maxLength` ——
              // 理由与「为什么退回而不是截断」见 [deviceNameInputFormatter]。
              inputFormatters: [deviceNameInputFormatter],
              decoration: const InputDecoration(
                labelText: '电脑端用这个名字区分机位',
                hintText: defaultDeviceName,
              ),
              onSubmitted: (value) => Navigator.of(context).pop(value),
            ),
            // 打字打到头会被拦住，而**拦住了没有任何解释的话，用户只会以为
            // 输入框坏了**（踩坑 #13）。这一行就是那个解释；
            // 顺带把「汉字算 2 格」写在这儿，不然「12 格」本身也是个谜。
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final width = deviceNameWidth(value.text);
                final full = width >= maxDeviceNameWidth;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '$width / $maxDeviceNameWidth 格（汉字算 2 格）${full ? '，已满' : ''}',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: full ? context.palette.amber : context.palette.muted,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (name == null) return;

    // ── 规格 §3.4.5 ③：**二次改名要电脑端同意** ──────────────────────
    //
    // ⚠️ 两种情形**不是一回事**，别合并：
    //   · **还没入网**（没有凭据）⇒ 这次命名是入网那一步的一部分 ——
    //     电脑端在「同意连接」时已经同意了这台设备，不必再问一次；
    //   · **已经入网**（有凭据）⇒ 需求方原话「如需要再次更改，
    //     需要电脑端同意才能更改」。
    // ⚠️ `credential` 是**非可空**的 String（空串 = 还没入网），
    // 判据本体在 `DeviceIdentity.renameNeedsApproval`（那一处能测）。
    if (!DeviceIdentity.renameNeedsApproval(identity.credential)) {
      // 空名会退回默认名（见 `DeviceIdentity.rename`）—— 允许名字变空
      // 等于允许这台手机在电脑端消失。
      await identity.rename(name);
      if (mounted) setState(() {});
      return;
    }

    await _requestRename(identity, name);
  }

  /// 已入网之后改名 ⇒ 请电脑端批准（规格 §3.4.5 ③）。
  ///
  /// ⚠️ **批准之前不动本机名字**：先改本机再等批准的话，用户看到名字变了、
  /// 而电脑端那边还是旧的（他甚至可能拒绝）—— 表现是「改了没生效但看着像生效了」。
  ///
  /// ⚠️ 等待必须是**看得见的**（I3 的精神）：与入网那一步同形，
  /// 每轮把「已经等了多久」写到状态行上。
  Future<void> _requestRename(DeviceIdentity identity, String name) async {
    final client = _client;

    if (client == null) {
      _log('⚠️ 还不能改名：电脑端地址或凭据没准备好');
      return;
    }

    EnrollOutcome? outcome;

    try {
      outcome = await Enroller(client: client).requestRename(
        deviceName: name,
        // 界面关了就停 —— 没有别的取消入口（等待上限在 `requestRename` 里）。
        cancelled: () => !mounted,
        onWaiting: (waited) {
          if (mounted) {
            setState(() => _status = '等电脑端同意改名…（已等 ${waited.inSeconds} 秒）');
          }
        },
      );
    } on Object catch (error) {
      // 连不上 / 凭据作废 —— 都没改本机名字，说清楚就行。
      _log('⚠️ 改名没能请求成功：$error');
      return;
    }

    if (!mounted || outcome == null) {
      // 界面关了，或者等超了（电脑端一直没人点那个弹窗）。
      return;
    }

    if (outcome.status == EnrollStatus.approved) {
      await identity.rename(name);
      if (mounted) setState(() {});
      _log('机位名已改成「${identity.deviceName}」（电脑端已同意）');
      return;
    }

    _log(outcome.status == EnrollStatus.rejected
        ? '电脑端拒绝了这次改名，名字没变。'
        : '改名没有完成。');
  }
}
