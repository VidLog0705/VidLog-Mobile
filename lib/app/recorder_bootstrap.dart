// ignore_for_file: invalid_use_of_protected_member
//
// ⚠️ 上面这条是这套拆法**必须付的价**，不是图省事：`State.setState` 带
// `@protected`，而分析器不把 `extension on _RecorderPageState` 认作
// 「State 的子类内部」，于是本文件里每一处 `setState(` 都报这一条。
// 语言本身允许（同一个 library、编译通过、测试全绿）—— 那是 lint 的误报，
// 它判的是「在不在子类里」，认不出 extension。只收窄这一条规则，
// 不做 `ignore_for_file: all`。

part of 'recorder_page.dart';

// T26③ 第 2 轮第 3 刀：从 `recorder_page.dart` 整段搬过来的 —— **纯搬家**。
// 一行都没改，只是位置换了（内容多重集比对可证）。这里装的是_bootstrap / _refreshBackup / 那个每秒钟的钟。
//
// ⚠️ 只有实例方法 / getter 能装进来：extension 不许声明实例字段，
// 匿名 extension 的 static 成员又没有前缀可取（不可达），所以那些
// 字段与静态常量全留在壳的类体里 —— 同 library，这里不带前缀照样读得到。

extension on _RecorderPageState {

  /// 起那个实时时间的秒针（规格 §3.2.6）。
  ///
  /// **先对齐到整秒再转周期**：`Timer.periodic` 的相位是从启动那一刻算的，
  /// 直接周期 1 秒的话首次触发落在半秒处，屏幕上那个秒数就永远比真实时间
  /// 慢最多 1 秒。对着录像核时间时，这种偏差会让人先怀疑是哪边不准 ——
  /// 而这里多花的只是一次 `Future.delayed` 的账，不是十行代码。
  void _startClock() {
    final untilNextSecond =
        Duration(milliseconds: 1000 - DateTime.now().millisecond);

    _clockTick = Timer(untilNextSecond, () {
      if (!mounted) return;
      setState(() => _now = DateTime.now());

      _clockTick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _now = DateTime.now());
      });
    });
  }

  // ─────────────────────────────────────────────
  // 启动
  // ─────────────────────────────────────────────

  Future<void> _bootstrap() async {
    try {
      // 用**持久**目录，不用临时目录 ——「重启后收尾孤儿」靠的就是文件还在原处。
      final documents = await getApplicationDocumentsDirectory();
      final root = Directory('${documents.path}/vidlog')..createSync(recursive: true);
      _rootPath = root.path;

      // 日志：**数据目录一确定就 init**（早于其它一切业务装配）——
      // 在那之前 `AppLog` 处在缓冲模式，记是记着的，只是还没落盘。
      // ⚠️ `init` 自己吞掉建目录的失败并退化成纯内存，所以这里不 try。
      AppLog.instance.init(directory: '${root.path}/logs');

      // ⚠️ **版本号要落在日志里**，而且是数据目录一确定就说 ——
      // 光靠 `pubspec.yaml` 答不上「手上这份日志是哪个构建出的」：
      // 手机上展示的版本是「展示版本 + 构建号」双轨，而**归档下来的日志
      // 只有一个文件名和一行行 JSON**（2026-10-03 分不出 `+3` 与 `+4` 那一次）。
      _log('VidLog 手机端 $appVersion 起来了');

      _workspace = RecordingWorkspace('${root.path}/work');
      _index = JsonLinesRecordingIndex('${root.path}/index.jsonl');
      // 与电脑端同一个位置（`<root>/labels.jsonl`），键名也逐字相同 ——
      // 两端的标签表是同一份形态（`labels/label_store.dart` 里有说明）。
      _labels = LabelStore('${root.path}/labels.jsonl');
      _finalizer = SessionFinalizer(
        rootDirectory: root.path,
        index: _index,
        labels: _labels,
        // 实际解码校验（规格 §3.1.4：「停止录制后必须**实际解码校验**成品可播，
        // 校验失败不得入库为「正常」」）。
        //
        // ⚠️ 走**原生系统 API**（iOS `AVAssetImageGenerator` /
        // 安卓 `MediaMetadataRetriever`）—— 手机端没有 FFmpeg，
        // 而那两个 API 本身就是「真解一帧」。
        //
        // ⚠️ 传的就是 `_gateway` 上那个方法（不是 lambda 包一层）——
        // 少一层包装，将来换实现时不会漏改。
        verifyPlayable: (path) => _gateway.verifyPlayable(path),
      );
      // 与电脑端同一个位置（`<root>/punches.jsonl`），键名也逐字相同 ——
      // 两端的打点日志是同一份形态。
      _punchLog = PunchLog('${root.path}/punches.jsonl');
      // 错误扫描（规格 §6.1「必须保存的事实」）。与打点、标签同一层。
      _scanErrors = ScanErrorLog('${root.path}/scan-errors.jsonl');
      // 归档状态与索引同构（追加写 JSON Lines）—— 键名是 PascalCase，
      // 与 `labels.jsonl` / `punches.jsonl` 一致（见 `archive_store.dart`）。
      _archive = ArchiveStore('${root.path}/archive.jsonl');

      // ── 校时（规格 §3.6.3 / §3.6.4）──────────────────────────────
      //
      // ⚠️ 顺序：**先核对跳变，再（需要时）取公网时间**。
      // 核对是本地读盘，很快；取公网时间可能几秒 —— 排在后面不挡启动。
      final calibration = CalibrationStore('${root.path}/calibration.json');
      _clock = TrustedClock(
        initialState: await calibration.load(),
        store: calibration,
        publicSource: HttpDateClockSource(),
        log: AppLog.instance,
      );

      final jumped = await _clock!.checkStartup();
      if (jumped) {
        _log('⚠️ ${_clock!.blockedReason}');
      }

      if (!_clock!.isCalibrated) {
        // 取不到就保持「未校准」—— 而那是**会挡住录制**的状态，
        // 所以下面 `_startWorking` 会把原因说出来（I3：不存在静默失败）。
        await _clock!.tryCalibrateFromPublicTime();
      }

      // 本机身份要在 `_buildCoordinator` **之前**读出来 ——
      // 编排器建的时候就要把设备标识接进去（它写进每条录像索引的 sourceDeviceId）。
      _identity = await DeviceIdentity.load('${root.path}/device.json');

      // 用户设置也要在 `_buildCoordinator` **之前**读出来 —— 编排器建的时候
      // 就把模式和两个档位接进去了（`RecordingCoordinator` 只认构造参数，
      // 没有 setter，建完再改是改不动的）。
      _settings = await RecordingSettings.load('${root.path}/settings.json');
      _mode = _settings!.mode;
      _staticStop = _settings!.staticStop;
      _durationFallback = _settings!.durationFallback;
      _retentionArchivedOutbound = _settings!.retentionArchivedOutbound;
      _retentionArchivedReturn = _settings!.retentionArchivedReturn;
      _retentionUnarchivedOutbound = _settings!.retentionUnarchivedOutbound;
      _retentionUnarchivedReturn = _settings!.retentionUnarchivedReturn;
      _codec = _settings!.codec;
      _resolution = _settings!.resolution;
      _orientation = _settings!.orientation;

      _buildUploader();

      await _buildCoordinator();

      // 规格 §3.1.1：重启后必须能自动收尾孤儿分段。
      final recovered = await OrphanRecovery(
        workspace: _workspace,
        finalizer: _finalizer,
      ).recover();

      if (!mounted) return;
      setState(() {
        _recovered = recovered;
        _status = recovered.isEmpty
            ? '就绪'
            : '就绪 · 上次有 ${recovered.length} 段没录完，已自动收尾';
      });

      if (recovered.isNotEmpty) {
        _log('启动时收尾了 ${recovered.length} 段孤儿');
      }

      await _refreshBackup();

      // 开 App 就跑一趟队列（规格 §3.4.1：队列必须**可恢复**）。
      // 不等它：上传可能要几十秒，而界面不该在这上面卡着。
      unawaited(_runUploads());
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '初始化失败：$error');
    }
  }

  /// 刷新备份页要的东西：本机 IP、索引汇总、电脑端探测。
  ///
  /// 三件事一起做，是因为它们在界面上是**同一屏**：分开刷新会出现
  /// 「IP 已经变了、统计还是旧的」这种半新半旧的画面。
  Future<void> _refreshBackup() async {
    final ip = await lanAddress();
    if (mounted) setState(() => _lanIp = ip);

    await _refreshDiagnostics();
    if (!mounted) return;

    await _probeHost();
    if (!mounted) return;

    // ── 启动时算一次清理计划，**给用户看过才动手**（规格 §3.5.5）──────
    //
    // ⚠️ 放在 `_probeHost()` **之后**：清理要逐条回查电脑端（§3.5.4），
    // 而回查要走 `_client`（地址与凭据在探主机那一步才备齐）。
    // ⚠️ 也放在所有「读盘」之后：计划要索引 / 标签 / 归档记录三样都在手。
    await _offerCleanup();
  }
}
