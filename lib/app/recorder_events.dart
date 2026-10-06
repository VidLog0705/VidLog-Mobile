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
// 一行都没改，只是位置换了（内容多重集比对可证）。这里装的是事件与日志：刷新诊断、界面日志、导诊断包。
//
// ⚠️ 只有实例方法 / getter 能装进来：extension **不许声明实例字段**，
// 所以那些字段全留在壳的类体里 —— 同 library，这里不带前缀照样读得到。
// extension **也不许**不带前缀地引用被扩展类型的静态成员
// （`unqualified_reference_to_static_member_of_extended_type`，
// 2026-10-06 实测），所以下面那个常量改成了**顶层**声明跟着搬过来。


  /// 界面事件在日志里的分类。
  ///
  /// 技术性的那些（上传、原生通道、录制编排）由各自的**收口点**记，
  /// 带自己的分类；这个标签管的是「用户在抽屉里看见的那一行」。
  const _logTag = '界面';

extension on _RecorderPageState {


  /// 重新读一遍盘上的实况。
  Future<void> _refreshDiagnostics() async {
    try {
      final root = Directory(_workspace.rootDirectory);
      final sessions = root.existsSync()
          ? root.listSync().whereType<Directory>().length
          : 0;
      final pending = (await _workspace.listOrphans()).length;
      final entries = await _index.loadAll();
      final punches = (await _punchLog.loadAll()).length;

      // 每条录像在盘上的字节数，按 evidenceId 索引。逐条 stat —— 条数以十计，
      // 而且本来就要读一遍索引，不值得为它加缓存或后台扫描。
      //
      // 量不出来（文件不在了、读不动）的**不放进来**，那一条就写「大小未知」。
      // 宁可少一个数字，也不要显示一个算不出来、但看起来很像真的的值 ——
      // 这个项目已经因为「界面上的假数字被当成真的」吃过一次亏。
      final bytes = <String, int>{};

      // 「确认真不在盘上」的那些 evidenceId。
      //
      // ⚠️ **它与「`bytes` 里没有这一条」不是一回事**：`bytes` 缺一条有两种原因
      // —— 文件没了、或者文件在但这次量不出大小。只有**前一种**才进这里。
      final gone = <String>{};

      for (final entry in entries) {
        final file = File('$_rootPath/${entry.location.value}');
        try {
          if (await file.exists()) {
            bytes[entry.evidenceId] = await file.length();
          } else {
            gone.add(entry.evidenceId);
          }
        } on Object {
          // ⚠️ **不往 `gone` 里放。** 它在盘上，只是这次量不出来（读不动、权限不对）。
          // 当成「没了」会让一条录像从界面上**静默消失** —— 那比一个数字不准坏得多，
          // 也正是上面那段「宁可少一个数字」要防的事。
          continue;
        }
      }

      // ⚠️ **索引只增不减**（追加写，§6.2），删掉的分段仍然留在里面 ——
      // 而下面 `_sessions` / `_entries` / `_locationByEvidenceId` 三样都是拿它算的。
      // 所以**必须在这儿滤一道**，否则删掉的录像会永远留在列表上：
      // 文件真没了，而列表还在、数字不变、详情页也不 pop
      // —— 用户看到的就是「删不掉」（需求方 2026-09-28 报的）。
      final present = dropGoneSegments(entries, gone);

      // 归并成「一次录制」（需求方 2026-09-22 的口径：一个单号从开始到结束为一条）。
      final merged = toSessions(present, bytes);

      // 总占用走盘，不走索引 —— 需求方要的是「实际存储到手机的视频大小总量，
      // 上传后删掉就按删除后的算」。索引只增不减，拿它求和永远降不下来。
      final videoBytes = await videoBytesOnDisk(_rootPath);

      final archiveRecords = await _archive.loadAll();

      if (!mounted) return;
      // 列表上那个【发货 / 退货】小胶囊要它（规格 §3.4.3 的第 ① 项）。
      // ⚠️ 追加写、同键**后者胜出** —— 与另外两端同一个口径。
      final labels = <String, Map<String, String>>{};
      for (final label in await _labels.loadAll()) {
        labels.putIfAbsent(label.evidenceId, () => {})[label.key] = label.value;
      }

      if (!mounted) return;

      setState(() {
        _sessionCount = sessions;
        _pendingCount = pending;
        // ⚠️ 这个**故意**是索引的原始行数，不跟着 `present` 缩 ——
        // 面板上那一行写的是「索引 N 条」，它要回答的是「收尾有没有把行写进索引」，
        // 而索引本来就是只增不减的。跟着缩就没法回答那个问题了。
        // 用户在列表上看到的条数是 `_sessions`（= `present` 归并出来的），
        // 两个数字不一样是**正常的**。
        _entryCount = entries.length;
        _punchCount = punches;
        _sessions = merged;
        _entries = present;
        _archiveRecords = archiveRecords;
        _todayCount = countToday(merged, DateTime.now());
        _videoBytes = videoBytes;
        // 手动删除要按 evidenceId 找到磁盘位置 —— 索引里那个相对路径就在这里。
        // 同样只装盘上还在的那些：删掉的那几段没有文件可删了。
        _locationByEvidenceId = {
          for (final entry in present) entry.evidenceId: entry.location.value,
        };
        _labelsByEvidence = labels;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _status = '读取工作区失败：$error');
    }
  }

  /// 界面事件 —— 同时**转发给 [AppLog]**（落盘、结构化、脱敏）。
  ///
  /// ⚠️ 2026-09-26 之前这里只往内存里插一行，`setState` **整个页面**，
  /// 而这个页面挂着平台视图（相机预览）—— 录制事件密的时候等于每来一条重建一次预览。
  /// 现在：落盘那一半是**同步入队**的（不 await 磁盘），
  /// 界面那一半由 [AppLog.tail] 这个 `ValueNotifier` 推给**只有它关心的那两个控件**。
  ///
  /// 级别从行首那个记号推出来（⚠️ / ✗ 是 warn，其余 info）——
  /// 那些记号本来就在 17 个调用点上当着，再让每处多传一个参数
  /// 只是把同一件事换个地方写。
  void _log(String line) {
    AppLog.instance.log(logLevelOfUiLine(line), _logTag, line);
  }
  Future<String> _exportDiagnostics({bool share = false}) async {
    final root = _rootPath;
    if (root.isEmpty) {
      return '还没读出数据目录，稍等一下再点。';
    }

    try {
      final entries = await _index.loadAll();
      final errors = await _scanErrors.loadAll();

      final path = await DiagnosticsPackage.build(
        rootPath: root,
        // ⚠️ 只传**安全的零件**：凭据在 `_identity` 里，绝不进去。
        settings: {
          'mode': _mode.name,
          'staticStop': _staticStop.name,
          'durationFallback': _durationFallback.name,
          'voiceEnabled': _settings?.voiceEnabled,
          // 保留期四个数：记的是**天数**（`null` = 全部保留），不是枚举名 ——
          // 它已经不是枚举了（「自定义」是任意正整数天）。
          'retentionArchivedOutbound': _retentionArchivedOutbound.days,
          'retentionArchivedReturn': _retentionArchivedReturn.days,
          'retentionUnarchivedOutbound': _retentionUnarchivedOutbound.days,
          'retentionUnarchivedReturn': _retentionUnarchivedReturn.days,
        },
        deviceName: _identity?.deviceName ?? '',
        // ⚠️ 头部那个版本号：`appVersion` 与 `pubspec.yaml` 逐字一致
        //（`test/about_page_test.dart` 守着），所以它就是这一份日志是哪个构建出的。
        appVersion: appVersion,
        sessionCount: _sessionCount,
        orphanCount: _pendingCount,
        entries: entries,
        now: DateTime.now(),
      );

      final note = describeDiagnosticsPackage(path, hasScanErrors: errors.isNotEmpty);
      if (!share) return note;

      // ⚠️ mime 用 `application/octet-stream`：它是个 `.jsonl`，
      // 说成 `text/plain` 会让某些应用拿它当文本消息**改写/截断**，
      // 而这一份是要原样发回来的。
      final problem = await _gateway.shareFile(
        path,
        mime: 'application/octet-stream',
        title: '把日志发出去',
      );

      if (problem == null) {
        _log('诊断包已生成，也弹了分享面板：$path');
        return '$note\n已弹出分享面板 —— 选一个应用（微信 / 邮件…）发出去就行。';
      }

      // 分享没成**不算导出失败**（文件确实在盘上）—— 所以这样说。
      _log('⚠️ 诊断包生成了，但分享面板没弹出来：$problem');
      return '$note\n⚠️ 分享面板没弹出来（$problem）。文件就在上面那个路径下，'
          '可以自己从「文件」里取出来发。';
    } on Object catch (error) {
      // catch 不静默：界面上那句 + 日志里一条（AGENTS.md §6.1）。
      _log('⚠️ 导出诊断包失败：$error');
      return '导出失败：$error';
    }
  }
}
