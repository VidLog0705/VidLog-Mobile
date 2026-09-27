import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../diagnostics/app_log.dart';
import '../diagnostics/diagnostics_package.dart';
import '../diagnostics/error_handlers.dart';
import '../primitives.dart';
import '../recording/business_type.dart';
import '../recording/cleanup_audit.dart';
import '../recording/cleanup_executor.dart';
import '../recording/clock_calibration.dart';
import '../recording/device_identity.dart';
import '../recording/label_store.dart';
import '../recording/lan_probe.dart';
import '../recording/lifecycle.dart';
import '../recording/manual_delete.dart';
import '../recording/punch_log.dart';
import '../recording/scan_error_log.dart';
import '../recording/thumbnail_cache.dart';
import '../recording/recorder_config.dart';
import '../recording/recorder_events.dart';
import '../recording/recorder_gateway.dart';
import '../recording/recording_coordinator.dart';
import '../recording/recording_index.dart';
import '../recording/recording_settings.dart';
import '../recording/recording_spec.dart';
import '../recording/retention_setting.dart';
import '../recording/recording_totals.dart';
import '../recording/recording_workspace.dart';
import '../recording/session_finalizer.dart';
import '../recording/work_mode.dart';
import '../states.dart';
import '../upload/archive_store.dart';
import '../upload/enrollment.dart';
import '../upload/upload_protocol.dart';
import '../upload/uploader.dart';
import 'camera_preview.dart';
import 'scan_connect_page.dart';
import 'zoom_dial.dart';

/// 采集页底部抽屉里正在展开哪一块。`null` = 三块都收着。
///
/// 需求方 2026-09-22 定的布局：**取景铺满整页**，控件是压在上面的浮层；
/// 「手动输入」与「事件」收进抽屉，点开才占屏。
///
/// ⚠️ 这是**页面本地的界面状态**，不是业务状态 —— 它不参与任何判定，
/// 也不落盘。切栏、停录都不需要动它。
enum _WorkSheet { manual, events, diagnostics }

/// 切到 [tab] 时要播报哪一句；不该播报就返回 null。
///
/// **纯函数**：没有平台通道的 widget 测试里也能验。放成员方法里就只能
/// 靠起真相机来测，等于测不了。
///
/// 发货与退货**共用同一个录制页**，所以「进哪一栏」这件事只有播报要区分。
VoicePrompt? modeAnnouncementFor(int tab, int previousTab) {
  // 重复点当前那一栏：相机不用重开，话也不用再说一遍。
  // 没有这道闸的话，手抖连点两下发货就会连播两遍。
  if (tab == previousTab) return null;

  return switch (tab) {
    1 => VoicePrompt.shippingModeOn,
    2 => VoicePrompt.returnModeOn,
    _ => null,
  };
}

/// 本机名输入框的守门人：**超过 [maxDeviceNameWidth] 格就把这次输入整个退回**。
///
/// ## ⚠️ 为什么不用 `maxLength`
///
/// `maxLength` 数的是**字符数**，而规矩是**显示宽度**（一个汉字算 2 格）。
/// 拿它当上限，「6 个汉字」会被判成 6、全部放行 —— 上限白白放宽一倍，
/// 而界面上那行字明明写着 12 格。
///
/// 退回（而不是截断）是有意的：用户在中间插字时，截断会**动他已经敲好的后半段**。
///
/// 提成顶层是为了**能在测试里直接调** —— 弹窗要先加载 `device.json`，
/// widget 测试里没有平台通道，那个框根本打不开（放成员里就等于测不了）。
final TextInputFormatter deviceNameInputFormatter = TextInputFormatter.withFunction(
  (oldValue, newValue) => deviceNameWidth(newValue.text) <= maxDeviceNameWidth
      ? newValue
      : oldValue,
);

/// 采集页。
///
/// ## 它为什么长这样
///
/// M4 的六条验收（连续录 30 分钟、杀进程后收尾孤儿、静止停录、封顶修正、
/// 错码保护、时长兜底）**全部要在真机上跑**。这个页面的每一个控件都为其中
/// 某一条服务 —— 不是演示界面，是**验收工具**。
///
/// **界面层不做任何判定。** 停录、收尾、索引全部走 `lib/recording/` 里那些
/// 带测试的代码；这里只做三件事：把事件喂进去、把动作放出来、把状态显示出来。
class RecorderPage extends StatefulWidget {
  const RecorderPage({super.key});

  @override
  State<RecorderPage> createState() => _RecorderPageState();
}

class _RecorderPageState extends State<RecorderPage> {
  final _gateway = ChannelRecorderGateway();

  late RecordingWorkspace _workspace;
  late SessionFinalizer _finalizer;
  late RecordingIndex _index;
  late PunchLog _punchLog;
  late ScanErrorLog _scanErrors;
  late LabelStore _labels;
  late ArchiveStore _archive;

  /// 上传器。**建好之后不直接改** —— 凭据是 `UploadClient` 的构造参数，
  /// 入网成功或地址变了都要整个重建（见 [_buildUploader]）。
  late Uploader _uploader;

  RecordingCoordinator? _coordinator;
  Timer? _heartbeat;

  /// 当前在哪一栏：0 = 备份，1 = 发货，2 = 退货，3 = 设置（需求方 2026-09-21 定的四栏）。
  ///
  /// **发货与退货共用同一个录制页** —— 两栏只是同一套采集流程的两个入口，
  /// 差别在于「这一件是发货还是退货」。做成两份页面会让相机开两次，
  /// 也不符合「同一时刻只有一段录制」的前提。
  int _tab = 0;

  /// 采集页当前属于哪一栏：1 = 发货，2 = 退货。
  ///
  /// **只在进入采集栏时更新，切走不动。** 工作中切到备份或设置栏看一眼再回来，
  /// 这一段录像仍然属于原来那一栏 —— 拿 `_tab` 现算的话，人只是去设置页翻了
  /// 一眼，回来那一件的标签就变了（换件开新段时尤其明显：
  /// 扫下一件那一刻人可能正站在设置页上）。
  int _workTab = 1;

  /// 录制页属于哪一栏。标题、顶部那个 Chip、以及**落盘的标签**共用这一个来源。
  bool get _isReturn => _workTab == 2;

  /// 当前这一栏对应哪个业务类型（发货 / 退货）。
  BusinessType get _businessType =>
      _isReturn ? BusinessType.returning : BusinessType.outbound;

  /// 用户选的设置（工作模式 + 两个档位）。落盘在 `<root>/settings.json`。
  ///
  /// **`null` = 还没读出来**（`_bootstrap` 是异步的，文件没读完之前改设置
  /// 会被随后读出来的盘上值覆盖掉，等于改了没反应）。所以设置页的控件
  /// 在它为 `null` 时是禁用的 —— 见 `_updateSettings`。
  RecordingSettings? _settings;

  WorkMode _mode = WorkMode.fallback;
  StaticStopSetting _staticStop = StaticStopSetting.fallback;

  /// 时长兜底档位。**与静止档位互相独立** —— 关一个不影响另一个。
  DurationFallbackSetting _durationFallback = DurationFallbackSetting.fallback;

  /// 保留期四个数（规格 §3.5.2.1）：发货 / 退货 × 已备份 / 未备份。
  ///
  /// ⚠️ **两列语义相反**：已备份那列到期真删；未备份那列**永不自动删**、只催。
  RetentionSetting _retentionArchivedOutbound = RetentionSetting.fallback;
  RetentionSetting _retentionArchivedReturn = RetentionSetting.fallback;
  RetentionSetting _retentionUnarchivedOutbound = RetentionSetting.fallback;
  RetentionSetting _retentionUnarchivedReturn = RetentionSetting.fallback;

  /// 录制规格三项（规格 §3.1.7）。**用户选的**那一档 ——
  /// 实际生效的可能是回落之后的另一档（见 `_coordinator.effectiveSpec`）。
  VideoCodec _codec = VideoCodec.fallback;
  VideoResolution _resolution = VideoResolution.fallback;
  RecordingOrientation _orientation = RecordingOrientation.fallback;

  /// 把时长兜底的首次询问时机缩短，好让验收不必真的等 4 分钟。
  /// **只压首次询问时机**，不动档位本身，也不碰静止档位。
  ///
  /// ⚠️ **故意不落盘。** 它是验收工具，不是产品设置：一旦存下来，验收完
  /// 忘了关，真实录制就会在开录 20 秒后被问「是否停止」，而用户看着它像正常功能。
  bool _accelerated = false;

  final _waybillController = TextEditingController();

  /// 切后台时刷日志的那个监听器（见 `initState`）。
  AppLifecycleListener? _lifecycle;

  String _status = '正在准备…';
  bool _askingToContinue = false;
  bool _starting = false;

  /// 启动时收尾的孤儿。
  List<FinalizeOutcome> _recovered = const [];

  /// 当前变焦倍率（规格 §3.1.2）。
  ///
  /// 只在内存里 —— 规格要的是「在本次工作期间保持」，
  /// 「按设备记忆」是**建议**（原文如此），要做得先有个按设备存的配置区，
  /// 而 M4 的配置区还没到那一步。
  double _zoom = 1;

  /// 表盘刻度画到哪 —— 设备的真实上限，问不到时用 [zoomMaxRatio]。
  double _maxZoom = zoomMaxRatio;

  /// 表盘的**左端** —— 设备的真实下限（规格 §3.1.2）。
  ///
  /// 2026-09-22 起不是常数：原生层改成优先挑带超广角的双/三镜头设备，
  /// 那时是 **0.5**。问不到就是 1.0，也就是「这台设备没有超广角」，
  /// 表盘左半圈画成平的。
  double _minZoom = zoomMinRatio;

  /// 半圆刻度盘现在是不是摊开着（需求方 2026-09-22：收进【对焦】按钮）。
  ///
  /// 之前表盘是**常驻**的 —— 压在取景画面上，挡着用户看面单。
  bool _dialOpen = false;

  /// 上一次响过拨轮声的那个刻度（取整到 0.1）。
  ///
  /// **滑过一格响一声**，不是每次 `onPanUpdate` 都响 —— 后者一秒能响几十下，
  /// 那是噪音不是反馈。用的判据就是规格 §3.1.2 那句「每个刻度 0.1」。
  int? _lastDetentTick;

  /// 上一次重新对焦的时刻（表盘滑动时）。
  ///
  /// **节流**：拖动时每帧都对焦既没意义（相机来不及合焦）又会把配置线程压满。
  /// 手指抬起时再补一次最终的（见 [_onZoomEnd]）。
  DateTime? _lastFocusAt;

  /// 滑动时两次重新对焦之间至少隔多久。
  static const _focusThrottle = Duration(milliseconds: 250);

  /// 当前会话已录时长。
  ///
  /// 曾经用 `ValueNotifier` 想省掉每秒重建 —— **那是白费**：
  /// 卡顿的真因是「原生预览视图在可滚动容器里」（见下方 `_previewArea` 的说明），
  /// 省掉重建治不了它。而多一层 notifier 反而让「已录一直是 00:00」多了一个可疑点。
  /// 秒数就老老实实 `setState`。
  Duration _elapsed = Duration.zero;

  /// 画面正上方那个实时时间的当前值（规格 §3.2.6）。
  ///
  /// ⚠️ 这里用的是**墙钟**，与录制判据正好相反（规格 §3.6.3 要单调时钟）。
  /// 区别在用途：录制判据问的是「过了多久」，用户改系统时间不该影响它；
  /// 这个钟问的是「现在几点」，而那本来就是墙钟回答的问题 ——
  /// 也是事后对着录像核时间时唯一说得通的时间。
  DateTime _now = DateTime.now();

  /// 驱动 [_now] 的秒针。
  ///
  /// **与 [_heartbeat] 分开**：心跳只在录制期间跑（`StartRecording` 起、
  /// `StopRecording` 停），而「现在几点」在没开始录的时候一样要看。
  Timer? _clockTick;

  /// 盘上的实况：工作区有几个会话、其中几个还没收尾、索引里几条。
  ///
  /// 真机验收时**失败必须是可见的** —— 上一次拿不到孤儿卡片时，
  /// 光看界面分不清「没录成」还是「录了但没收尾」，只能靠猜。
  int _sessionCount = 0;
  int _pendingCount = 0;
  int _entryCount = 0;

  /// 打点日志累积了多少条。
  ///
  /// 与上面几个同理：打点是**独立于收尾**的一条链（收尾失败不该吞掉打点，
  /// 反过来也一样），所以它得单独有个数字可看。
  /// 打点是「产生即持久化」的，这一条就等于盘上真有的条数。
  int _punchCount = 0;

  /// 本机数据根目录。索引里的 `location` 相对它 —— 备份页靠它把相对路径
  /// 还原成能 stat 的绝对路径（收尾端算这个相对路径时用的就是这个根）。
  late String _rootPath;

  /// 本机身份与本地配置（设备标识 / 本机名 / 电脑端地址）。
  DeviceIdentity? _identity;

  /// 本机的局域网 IPv4；null = 没连上局域网。
  ///
  /// **null 与「0.0.0.0」是两回事**：后者看起来像个正经地址却连不上任何东西。
  String? _lanIp;

  /// 电脑端探测结果（探的是电脑端那台机器，不是本机）。
  bool _hostOnline = false;
  bool _probingHost = false;

  /// 索引归并出来的「一次录制」——需求方口径的「一条」。
  List<RecordingSession> _sessions = const [];

  /// 索引里的全部条目。按分段记的，上一条是按它归并出来的。
  ///
  /// 留着它是因为重试要的是**分段**（`Uploader.upload` 收的是索引条目），
  /// 而列表上列的是「一次录制」—— 中间隔着一层归并。
  List<RecordingEntry> _entries = const [];

  /// 盘上的归档状态（`archive.jsonl` 读回来，按 `evidenceId`）。
  Map<String, ArchiveRecord> _archiveRecords = const {};

  /// `evidenceId → 索引里那个相对路径`。手动删除要拿它定位磁盘文件。
  Map<String, String> _locationByEvidenceId = const {};

  /// 可信时钟（规格 §3.6.4）。`null` = 还没装配好（`_bootstrap` 之前）。
  TrustedClock? _clock;

  /// 缩略图缓存（规格 §3.4.3：**不得每次进页面都重新抽帧**）。
  late final ThumbnailCache _thumbnails = ThumbnailCache(
    rootDirectory: _rootPath,
    generate: _gateway.generateThumbnail,
  );

  /// `evidenceId → 标签键 → 值`。列表要按它显示【发货 / 退货】那个小胶囊。
  Map<String, Map<String, String>> _labelsByEvidence = const {};

  /// 正在跑一趟上传。用来禁用按钮、不让两趟叠在一起。
  bool _uploading = false;

  /// 队列里最早的那个「下次该重试的时刻」，null = 没有在等重试的。
  DateTime? _nextRetryAt;

  /// 到点自动再跑一趟的闹钟。
  ///
  /// ⚠️ **没有它，一条撞上退避期的录像会永远停在退避期** —— 没有任何东西
  /// 会再来叫一次队列，界面上就是一直写着「待重试」而不动，用户只会以为
  /// 它坏了（踩坑 #13）。
  Timer? _retryTimer;

  /// 起录时间落在今天的条数。
  int _todayCount = 0;

  /// 盘上视频的实际占用（含未收尾的片段）。
  int _videoBytes = 0;

  /// 视频记录列表：搜索词 / 筛选 / 每页条数 / 当前页（0 起）。
  bool _recordsTodayOnly = false;
  int _recordsPageSize = 5;
  int _recordsPage = 0;

  /// 视频记录的搜索词（单号或日期）。
  ///
  /// **纯本地筛选，不查网、不查许可**（文档 §04 的 L8：未激活 / 试用到期 /
  /// 校验失败都不得挡住检索）。判定在 `recording_totals.dart` 的
  /// `matchesQuery` 里，那里有测试。
  final TextEditingController _recordsSearch = TextEditingController();
  String _recordsQuery = '';

  /// 采集页底部抽屉展开的是哪一块；null = 都收着。
  ///
  /// **默认收着**：取景画面必须尽量完整，而这两块都不是每时每刻要看的东西。
  _WorkSheet? _workSheet;

  @override
  void initState() {
    super.initState();
    _startClock();
    unawaited(_bootstrap());

    // 退到后台之前把排队的日志刷出去（iOS 上挂起之后随时会被系统杀掉）。
    // 挂在页面 State 上而不是 `main()` 里：它就是应用唯一那一屏，
    // 生命周期与进程一致，而且**跟着 dispose 一起收**
    // —— 顶层变量那种写法会被分析器判成「声明了没用到」，
    // 而那句警告说的其实是实话：它确实只是被「持有」着。
    _lifecycle = attachLogFlushOnPause();
  }

  @override
  void dispose() {
    _clockTick?.cancel();
    _heartbeat?.cancel();
    _retryTimer?.cancel();
    _lifecycle?.dispose();
    unawaited(_coordinator?.dispose() ?? Future<void>.value());
    _waybillController.dispose();
    _recordsSearch.dispose();
    super.dispose();
  }

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

  RecorderConfig get _config => RecorderConfig(
        // 两个档位都**原样保留用户的选择** —— 加速只压时长兜底的首次询问时机。
        staticStop: _staticStop,
        durationFallback: _durationFallback,
        promptAfterOverride: _accelerated ? const Duration(seconds: 20) : null,
        durationPromptRepeatEvery:
            _accelerated ? const Duration(seconds: 30) : const Duration(minutes: 5),
        durationPromptGrace:
            _accelerated ? const Duration(seconds: 10) : const Duration(minutes: 1),
      );

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

      _workspace = RecordingWorkspace('${root.path}/work');
      _index = JsonLinesRecordingIndex('${root.path}/index.jsonl');
      // 与电脑端同一个位置（`<root>/labels.jsonl`），键名也逐字相同 ——
      // 两端的标签表是同一份形态（`labels/label_store.dart` 里有说明）。
      _labels = LabelStore('${root.path}/labels.jsonl');
      _finalizer = SessionFinalizer(
        rootDirectory: root.path,
        index: _index,
        labels: _labels,
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

  /// 探一次电脑端在不在线上。
  ///
  /// **没填地址就不探** —— 没有地址可探，也不该显示一个探测出来的状态。
  ///
  /// ⚠️ M5 起判据从「这个端口上有 HTTP 响应」换成了**真的调一次
  /// `GET /api/v1/health` 并核对 `service`**。理由是这一页现在承诺的是
  /// 「录像能传上去」：同端口上任何一个别的 HTTP 服务，旧判据都会给一个绿灯，
  /// 而用户会照着一个假绿灯等一晚上。`lan_probe.dart` 里那段自认的债就是这个。
  Future<void> _probeHost() async {
    final address = _identity?.hostAddress ?? '';
    final port = _identity?.hostPort ?? defaultHostPort;
    if (address.isEmpty) {
      if (mounted) setState(() => _hostOnline = false);
      return;
    }

    if (mounted) setState(() => _probingHost = true);

    var online = false;
    try {
      // 这一趟**不带凭据**：健康检查是入网之前就要能调的（文档 §2.1），
      // 而且「在不在」与「认不认我」是两件事 —— 混在一起的话，一台
      // 把我们忘了的电脑端会显示成「离线」，用户就会去改地址。
      online = (await UploadClient(address: address, port: port).health()).isVidLog;
    } on Object {
      // 拒绝连接 / 超时 / 解析不了地址 / 不是我们认得的那台 —— 对界面
      // 来说都是同一件事：连不上。
      online = false;
    }

    if (!mounted) return;

    setState(() {
      _hostOnline = online;
      _probingHost = false;
    });
  }

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

  /// 当前那个客户端。**手动删除要拿它回查归档层**（规格 §3.5.6③）。
  ///
  /// 与 `_uploader` 同时建、同时换 —— 拿它自己再 new 一个的话，
  /// 地址或凭据一改就会出现「上传用的是新的、回查用的是旧的」那种错位。
  UploadClient? _client;

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

  /// 【扫码连接】：扫电脑端屏幕上那张二维码，报到、等它同意，再把凭据领回来。
  ///
  /// 规格 §3.4.5 ①（2026-09-24 改版）：**用户不需要手输任何东西**。
  ///
  /// 三步，中间的等待是**看得见的**：
  ///   1. 扫码 —— 拿到电脑端的地址与一次性令牌（[ScanConnectPage]）；
  ///   2. 反复报到、同时等电脑端上的人点【同意】—— 那一步在
  ///      `Enroller` 里，它有测试（`test/uploader_test.dart` 的入网那组）；
  ///   3. 领凭据、落盘，然后**提示用户编辑机位名**（规格 ①第 4 条）。
  ///
  /// ⚠️ **被拒绝要当场看见**（I3）：电脑端说不，这里就停下来把话说明白，
  /// 不是一直转圈。
  Future<void> _pairHost() async {
    final identity = _identity;
    if (identity == null) return;

    final payload = await ScanConnectPage.open(
      context,
      gateway: _gateway,
      // 相机在这个页面之前就开着的话**不能关** —— 那可能是录制中，
      // 或者发货栏的取景框还开着。关了就是掐掉别人的会话。
      closeCameraWhenDone: _coordinator?.isCameraOpen != true,
      // 那一页要按同一套规格摆画面、并且在**新开**相机时按它开 ——
      // 否则扫完码回来，留在会话上的是另一个分辨率。
      spec: _coordinator?.effectiveSpec ?? _requestedSpec(),
    );

    if (payload == null || !mounted) return; // 用户返回了，没扫

    await _enroll(identity: identity, host: payload.host, port: payload.port, token: payload.token);
  }

  /// 扫码之后到「拿到凭据」之间的那段路。
  ///
  /// [host] / [port] 来自二维码，但**地址允许被改**：规格 §3.4.5 ② 要求
  /// 「扫码连不上时允许手填地址」这条兜底留着 —— 一台机器可能同时插着有线、
  /// 无线、虚拟网卡，电脑端挑出来的那个地址不一定就是手机连得上的那个。
  /// 令牌仍然是被扫进来的那一张。
  Future<void> _enroll({
    required DeviceIdentity identity,
    required String host,
    required int port,
    required String token,
  }) async {
    var address = host.trim();

    while (true) {
      if (address.isEmpty) return;

      // 地址与端口落盘。换地址/端口 = 换一台电脑端 ⇒ `setHost` 会把旧凭据丢掉
      // （这是对的：那是**别的**电脑端签发的）。
      await identity.setHost(address: address, name: identity.hostName, port: port);

      if (!mounted) return;

      final attempt = await _attemptEnroll(
        identity: identity,
        address: address,
        port: port,
        token: token,
      );

      if (!mounted) return;

      final failure = attempt.failure;

      if (failure is UploadFailure && failure.code == UploadErrorCodes.network) {
        // 规格 §3.4.5 ②：**「扫码连不上时允许手填地址」这条兜底必须保留**。
        // 电脑端挑出来的地址不一定就是手机连得上的那个 —— 一台机器可能同时
        // 插着有线、无线、虚拟网卡，它挑的是「最像」的那个。
        //
        // ⚠️ 这里换的**只是地址**：令牌还是刚扫进来的那一张，没有重新扫。
        final edited = await _askHostAddress(current: '$address:$port');
        if (edited == null || edited.isEmpty || !mounted) return;

        address = edited;
        continue;
      }

      if (failure != null) {
        _snack(failure is UploadFailure ? failure.userHint : '连接失败：$failure');
        return;
      }

      final outcome = attempt.outcome;
      if (outcome == null) return; // 用户点了取消

      if (outcome.status == EnrollStatus.rejected) {
        // 规格 §3.4.5 ①：**拒绝要看得见**，而且不是「网络错误」那种说法。
        _snack('电脑端拒绝了这次连接。要重试的话，在电脑端上重新生成一张二维码再扫。');
        return;
      }

      final credential = outcome.credential;
      if (credential == null) {
        // 批准了却又没给凭据 —— 只可能是电脑端那边在这中间换了张码
        // （或者两端实现不一致）。**不当作成功**：没有凭据就是没入网。
        _snack('没有拿到凭据。请在电脑端上重新生成一张二维码，再扫一次。');
        return;
      }

      // **落盘**：只在内存里留着的凭据，重启一次就等于没入过网。
      await identity.setCredential(credential);

      if (!mounted) return;

      // 凭据换了 → 上传器必须重建（见 [_buildUploader]）。
      _buildUploader();
      setState(() => _status = '已连接');
      await _probeHost();

      if (!mounted) return;

      // 规格 §3.4.5 ①第 4 条：「同意 → 手机端提示**连接成功**，
      // 并让用户**编辑机位名**」。
      _snack('连接成功');
      await _editDeviceName();

      unawaited(_runUploads(manual: true));
      return;
    }
  }

  /// 跑一次入网：报到 → 等批准 → 领凭据，中间用进度框把等待**显示出来**。
  ///
  /// 拆出来是因为它可能被跑两次：第一次连不上时，界面会问一个能手填的地址，
  /// 拿着**同一个令牌**再跑一次（规格 §3.4.5 ② 的兜底）。
  ///
  /// 返回值用记录而不是抛：调用方要区分「用户取消」（outcome 为空）
  /// 与「连不上」（failure 是 network）—— 后者是**唯一**该问地址的情况。
  Future<({EnrollOutcome? outcome, Object? failure})> _attemptEnroll({
    required DeviceIdentity identity,
    required String address,
    required int port,
    required String token,
  }) async {
    final navigator = Navigator.of(context);
    final waited = ValueNotifier(Duration.zero);

    var cancelled = false;
    var dialogClosed = false;
    void closeDialog() {
      if (dialogClosed) return;
      dialogClosed = true;
      if (mounted) navigator.pop();
    }

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('等电脑端同意'),
        content: ValueListenableBuilder<Duration>(
          valueListenable: waited,
          builder: (context, value, child) => Text(
            '连接请求已经发给电脑端了。\n\n'
            '请到那台电脑上点【同意】—— 屏幕上会弹出'
            '「${identity.deviceName} 申请连接」。\n\n'
            '已经等了 ${value.inSeconds} 秒。',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              closeDialog();
            },
            child: const Text('取消'),
          ),
        ],
      ),
    ));

    try {
      final outcome = await Enroller(client: UploadClient(address: address, port: port)).enroll(
        deviceId: identity.deviceId,
        deviceName: identity.deviceName,
        token: token,
        cancelled: () => cancelled,
        onWaiting: (value) => waited.value = value,
      );

      return (outcome: outcome, failure: null);
    } on Object catch (error) {
      return (outcome: null, failure: error);
    } finally {
      closeDialog();
      waited.dispose();
    }
  }

  /// 问一个能手填的电脑端地址（规格 §3.4.5 ② 的兜底）。
  ///
  /// 返回**主机部分**（端口不动）；用户取消返回 null。
  Future<String?> _askHostAddress({required String current}) async {
    final host = current.split(':').first;
    final controller = TextEditingController(text: host);

    final answer = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('连不上这台电脑'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '二维码里写的地址是 $current，手机连不上。\n\n'
              '一台电脑可能同时插着有线、无线和虚拟网卡，它挑出来的不一定是你能连上的那个。'
              '在电脑端上执行 ipconfig 看一下它的局域网地址，填在这里再试一次。',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: '电脑端地址', hintText: '192.168.1.23'),
              onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('算了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('再试一次'),
          ),
        ],
      ),
    );

    controller.dispose();
    return answer?.trim();
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
              style: TextStyle(fontSize: 12, color: Colors.black54),
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

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 重建编排器（换模式、重新开始工作）。
  ///
  /// ⚠️ **必须先释放旧的**（2026-09-22 修）。旧的订阅着 `gateway.events`，
  /// 只把字段覆盖掉的话那条订阅还活着 —— 从此每来一条原生事件，两个编排器
  /// 都会各自反应一次（各写一遍 manifest、各落一条打点）。按第二次【开始】
  /// 就会这样，而画面上看不出来。
  ///
  /// **相机不跟着关**（`releaseCamera: false`）：它是进程级的**同一个原生
  /// 会话**，跟换不换编排器无关。新编排器用 `cameraAlreadyOpen` 把这个事实
  /// 继承过去 —— 否则按下【开始】那一瞬间界面会以为相机没了、把取景画面
  /// 换回「相机还没开」那块提示，而且原生还要白重建一次捕获会话。
  Future<void> _buildCoordinator() async {
    final cameraWasOpen = _coordinator?.isCameraOpen ?? false;
    await _coordinator?.dispose(releaseCamera: false);

    _coordinator = RecordingCoordinator(
      gateway: _gateway,
      workspace: _workspace,
      finalizer: _finalizer,
      punchLog: _punchLog,
      // 错码保护触发的事件要落盘（规格 §6.1「必须保存的事实」里的「错误扫描」）。
      scanErrors: _scanErrors,
      mode: _mode,
      config: _config,
      cameraAlreadyOpen: cameraWasOpen,
      // ⚠️ 可信时钟（规格 §3.6.4）——**未校准不得开始录制**。
      // 传真的那个（不是 null）：`null` 是给测试留的「不设闸」。
      trustedClock: _clock,
      // 录制规格也在这里交给编排器 —— **必须在它开相机之前**：
      // 相机会话的分辨率是开会话时定死的（iOS 的 preset / 安卓选出来的
      // 输出尺寸），开着的时候改不了。进栏就自动开的那台相机也要按这一档开，
      // 否则「用户选了 4K、屏幕上却是 720P 的画面」要等下一个人按下【开始】
      // 才会对上。
      spec: _requestedSpec(),
      onAction: _onAction,
    )..onBarcodeAccepted = _onBarcodeAccepted;

    // 可用性检查是异步的（要问原生），所以构造之后单独走一步 ——
    // 它同时把取景框的画面比例按生效的那一档算好（规格 §3.2.2 的连带项）。
    await _coordinator!.resolveRecordingSpec(_requestedSpec());
    _coordinator!.onFinalized = _onFinalized;
    _coordinator!.onSceneChanged = _onSceneChanged;
    _coordinator!.onPackageTrackingChanged = (left) =>
        _log(left ? '📦 包裹离开取景框' : '📦 包裹回到取景框');
    _coordinator!.onNativeFailure = (message) => _log('⚠️ $message');

    // 播音开关是**可变字段**，新建出来的编排器默认是「开」，
    // 所以要在这里补一次 —— 不然「开始工作」重建之后它会自己打开。
    _applyVoice();

    // 发货 / 退货也是可变字段（换段那些会话是在编排器里开起来的，
    // 而用户切栏不重建编排器）。新建出来的默认是 null，同样要补一次。
    _applyBusinessType();
  }

  /// 把当前的播报开关推给编排器（它自己不会去读设置）。
  void _applyVoice() {
    _coordinator?.voiceEnabled = _voiceOn;
  }

  /// 把「这一件是发货还是退货」推给编排器（它自己不会去读界面）。
  ///
  /// 与 [_applyVoice] 同一个理由、同一个时机：它在工作中可以改
  /// （发货↔退货互切不重建编排器），所以每次进采集栏都要推一次。
  void _applyBusinessType() {
    _coordinator?.businessType = _businessType;
  }

  /// 画面静下来 / 又动起来。
  ///
  /// 这条观测是给「静止停录」那两条验收用的：**静止计时从画面静下来那一刻起算**，
  /// 不是从开录起算。扫码时手机在手上、画面在动，所以「开录后 4 分钟才停」
  /// 完全可能是正确的（扫码 2 分钟 + 静止 2 分钟）。没有这条日志就分不清
  /// 它和「封顶失效」。
  void _onSceneChanged(bool isStatic) {
    // ⚠️ **问编排器「现在有没有在计静止」，别看静止档位开关。**
    //
    // 档位关掉时打这条是误导（真机上就是这么被误会的），所以这里要有一道闸 ——
    // 但闸的判据**不是**「档位开没开」：扫码静止停录有**它自己的 2 秒**，
    // 档位设成「关闭」时它的静止计时照样在跑。按档位判，这条日志会恰好在
    // 那个模式下被整个吃掉，而那正是最需要它的场合。
    //
    // 判据放在状态机那边（`StopController.isStaticTimingActive`），与真正
    // 决定停不停的那一份**共用同一个 getter** —— 两处各自写一遍的话，
    // 它们会从这里开始慢慢走岔。
    if (_coordinator?.stopController.isStaticTimingActive != true) return;

    _log(isStatic ? '👁 画面静止 —— 静止计时从现在起算' : '👁 画面恢复活动 —— 静止计时重置');
  }

  /// 一段录制收尾完成。
  ///
  /// **必须接这个**：停录时界面只来得及显示「正在收尾」，而收尾是异步的。
  /// 不接的话界面会**永远停在「正在收尾」**—— 看起来像卡住了，其实早就收完了。
  /// 真机上就是这么被误会的。
  Future<void> _onFinalized(FinalizeOutcome outcome) async {
    if (!mounted) return;

    // 收尾那条日志**照记**。⚠️ 位置在下面那个提前返回**之前** ——
    // 换段式连续扫时那个 return 会先跳走，而它跳走的正是「上一段收尾回来、
    // 下一段已经在录」这个**最常见的**路径。原来那句注释写的就是这个意思，
    // 只是顺序放反了，于是连续扫时这条日志一条都留不下来。
    _log(outcome.succeeded ? '✓ 已收尾入库' : '✗ 收尾失败：${outcome.failureReason}');

    // 刚入库的这一段立刻进上传队列（规格 §4.1 的状态图：已入库 → 进入上传队列）。
    // 同样要在这个提前返回之前 —— 连续扫恰恰是最需要「录完就传」的场景，
    // 那些段要是等到收工才排队，中间断一次电就全卡在手机里了。
    if (outcome.succeeded) unawaited(_runUploads());

    // 换段式连续扫（2026-09-22）：上一段收尾回来时，下一段**可能已经在录了**。
    // 这里要是照旧把状态刷成「已收尾」，画面上会显示「已收尾 · 索引里共 N 条」
    // —— 而相机正录着，用户看到的是假的。状态不动。
    if (_coordinator?.isRecording == true) return;

    await _refreshDiagnostics();
    if (!mounted) return;

    setState(() {
      _status = outcome.succeeded
          ? '已收尾 · 索引里共 $_entryCount 条'
          : '收尾失败：${outcome.failureReason}';
    });
  }

  // ─────────────────────────────────────────────
  // 状态机要的动作
  // ─────────────────────────────────────────────

  void _onAction(RecorderAction action) {
    if (!mounted) return;

    switch (action) {
      case StartRecording():
        // ⚠️ **必须在这里重新起心跳**（2026-09-22 加）。下面是停录那一臂取消
        // 心跳的地方，而换段式连续扫让「停录」从一次/班变成了**一次/件** ——
        // 只在 `_startWorking` 里起一次的话，换完第一件之后
        // `handleHeartbeat` 再也不会被调用：【画面静止停录】与【时长兜底】
        // 双双失效、已录计时也不走了，而画面上一切正常。
        _startHeartbeat();
        setState(() {
          _status = '录制中';
          _askingToContinue = false;
        });
        _log('开录 · 模式 ${_modeLabel(_mode)}');

      case StopRecording(:final trigger):
        _heartbeat?.cancel();
        _heartbeat = null;
        setState(() {
          _status = '已停止（${_triggerLabel(trigger)}）· 正在收尾';
          _askingToContinue = false;
          _elapsed = Duration.zero;
        });
        _log('停录 · ${_triggerLabel(trigger)}');
        // 不在这里刷盘：收尾是异步的，这一刻盘上还没有这次会话 ——
        // 刷出来的是收尾前的旧数字，随后 `_onFinalized` 还会再刷一次
        // （那次才是对的）。留着只会让人误读。

      case Speak(:final prompt):
        // 播报本身在编排层里发给原生（`VoicePrompt.spokenText` 是唯一措辞来源），
        // 这里只留一条可见的日志。
        //
        // ⚠️ 播报关掉时日志**照记**，只是图标换成 🔇 —— 关掉的只是声音。
        // 那个图标也是真机验收时唯一能分辨「播报被关了」和「TTS 坏了」的线索：
        // 前者显示 🔇 而屏幕上有提示，后者显示 🔊 而一点声音都没有。
        _log('${_voiceOn ? "🔊" : "🔇"} ${prompt.spokenText}');

      case ShowDurationPrompt():
        setState(() => _askingToContinue = true);

      case HideDurationPrompt():
        setState(() => _askingToContinue = false);
    }
  }

  /// 原生层报来一次识码时记一行 —— 但**只记被采纳的**，
  /// 否则相机每秒报好几次会把事件列表刷爆。
  ///
  /// 这里不重复判定，只是把「Dart 层认了哪一次」显示出来：
  /// 真正决定采纳与否的是 `ScanGate`（框外忽略 + 去重），那层有测试。
  void _onBarcodeAccepted(WaybillNumber waybill) {
    _log('📷 扫到 $waybill');
  }

  // ─────────────────────────────────────────────
  // 操作
  // ─────────────────────────────────────────────

  /// 切栏了（需求方 2026-09-22 定的四条边界）。
  ///
  /// 发货 / 退货是**采集栏**：进栏自动开相机、播报模式；离开就关；
  /// 两栏互切**不关相机**（那是同一个预览会话），但**要重播** ——
  /// 「这一件是发货还是退货」正是靠那句播报确认的。
  ///
  /// ⚠️ **触发点只有 `onDestinationSelected` 一处**，绝不能放进 `build()`：
  /// 那样每次重绘都会重开一次相机、重播一遍。
  Future<void> _onTabChanged(int previous, int index) async {
    // 播报放在最前面：**相机没起来不该把这句吞掉**。
    // 「模式切过来了」和「相机开起来了」是两件事，权限弹窗被拒、
    // 通道没接上，都不改变「用户现在在退货栏」这个事实。
    final announcement = modeAnnouncementFor(index, previous);
    if (announcement != null) {
      _log('🔊 ${announcement.spokenText}');
      // 编排器还没建起来（启动没走完）时这句发不出去 —— 但上面那行日志
      // 照记，它是「模式切没切过来」唯一的当场凭据。
      await _coordinator?.speak(announcement);
    }

    // 换栏就收起表盘：它属于刚才那一页。
    //
    // ⚠️ 必须明写这一句，不能指望「关相机顺手就收了」—— 发货 ↔ 退货**不关相机**
    // （见下），那条路上没有任何东西会碰表盘。
    if (_dialOpen && mounted) setState(_closeDial);

    const workTabs = {1, 2};

    // 进了采集栏就记下「现在这一栏是发货还是退货」，**切走时不改回去** ——
    // 下一段录像（换件开的那一段）要按这里记的值打标签。见 `_workTab` 的说明。
    if (workTabs.contains(index)) {
      setState(() => _workTab = index);
      _applyBusinessType();
    }

    if (!workTabs.contains(index)) {
      // 离开采集栏。**工作中 / 正在录时不关相机** —— 手指误滑到设置就掐掉
      // 一段正在录的像，比多开一会儿糟糕得多。
      if (_coordinator?.isWorking != true) {
        await _coordinator?.closeCamera();
        if (mounted) setState(() {});
      }
      return;
    }

    // 从一个采集栏切到另一个：相机是同一个预览会话，只播报，不重开。
    if (workTabs.contains(previous)) return;

    await _openCameraForPreview();
  }

  /// 进采集栏时把相机打开（**不开始工作**）。
  ///
  /// 与 [_startWorking] 分开：进栏只给一个取景画面让人对准面单，
  /// 真的开始录还是要点【开始】。合在一起的话，进栏那一下就自己录起来了。
  Future<void> _openCameraForPreview() async {
    final coordinator = _coordinator;

    // 启动还没走完（`_bootstrap` 是异步的）。这里**不能硬开**：
    // `_workspace` 那些 `late` 字段还没赋值，开出来的编排器写不了盘。
    if (coordinator == null || _identity == null) {
      if (mounted) setState(() => _status = '还在读设备信息，稍等一下再进这一栏');
      return;
    }

    try {
      if (!await _gateway.hasCameraPermission()) {
        final granted = await _gateway.requestCameraPermission();
        if (!granted) {
          // 不崩、不装作开好了。**【开始】是重试路径** ——
          // 用户去设置里给了权限回来按下它就重来一遍。
          if (mounted) setState(() => _status = '没有相机权限');
          return;
        }
      }

      await coordinator.openCamera();

      // 相机开起来之后才问得到设备范围（规格 §3.1.2）。
      await _readDeviceZoomRange();

      if (!mounted) return;
      setState(() {
        _zoom = 1; // 每次进栏回到 1 倍 —— 上一趟拖到 4 倍不该留给下一件
        // 表盘也收起来：它属于刚才那一趟（需求方 2026-09-22 收进【对焦】按钮）。
        _closeDial();
        _status = '把面单放进取景框';
      });
    } on Object catch (error) {
      // 开相机可能真的失败（没权限、相机被别的应用占着、设备忙）。
      // **如实显示**，不假装 —— 吞掉的话屏幕上就是一片没有画面的空白。
      if (mounted) setState(() => _status = '开相机失败：$error');
    }
  }

  /// 开始工作：**开相机、送预览、显示取景框。不录。**
  ///
  /// 规格 §3.2.2 的流程是「点开始工作 → 出现取景框 → 扫到面单才开录」。
  /// 之前把「开相机」和「开录」合成一步，表现是点了按钮屏幕上什么都没有、
  /// 但其实已经在录 —— 用户既看不到画面、也没法把面单对准。
  Future<void> _startWorking() async {
    if (_starting) return;
    setState(() => _starting = true);

    try {
      if (!await _gateway.hasCameraPermission()) {
        final granted = await _gateway.requestCameraPermission();
        if (!granted) {
          setState(() => _status = '没有相机权限');
          return;
        }
      }

      await _buildCoordinator(); // 换模式下重建，配置跟着走

      // ⚠️ 这里传的必须是**设备标识**，不是本机名（契约 §1.1 步骤 2 把两者分开：
      // 标识用来认设备，名字用来给人看）。以前这里写死 `'this-device'` ——
      // 结果**所有手机在电脑端都叫同一个名字**，根本分不开是哪台录的。
      // 标识是不变的，所以改名不会篡改历史录像的来源。
      // 录制规格也在这里交给编排器（规格 §3.1.7：**录制前可选、录制中不可改**）。
      // 它会先做一次真实的可用性检查，跑不通就回落到真能跑的那一档 ——
      // 结论落在 `_coordinator.effectiveSpec` / `specFallbackReason` 上，
      // 界面照它显示，**不静默回落**。
      await _coordinator!.startWorking(
        sourceDeviceId: _identity!.deviceId,
        spec: _requestedSpec(),
      );

      // 规格 §3.3.6：点【开始】→ 播「开始工作」，**不滴**（需求方 2026-09-22 裁决）。
      //
      // 为什么在这里、不在 `startWorking` 里：这句的起因是「用户按了那个按钮」，
      // 不是「状态机走到了某个状态」—— 与上面 [modeAnnouncementFor] 那两句
      // 是同一类东西，所以走同一条路（`RecordingCoordinator.speak`，不经状态机）。
      // 塞进 `startWorking` 的话，所有需要「在工作状态」的测试都会平白多出一句播报。
      //
      // 位置在 `startWorking` **之后**：相机没开起来就不该说「开始工作」。
      await _coordinator!.speak(VoicePrompt.startWorking);

      _log('开始工作 · 模式 ${_modeLabel(_mode)}');
      _startHeartbeat();

      // 相机开起来之后才问得到设备上限（规格 §3.1.2）——
      // 表盘的刻度要画到设备的真实上限，不然划到底是 8 倍、画面却停在 2 倍。
      await _readDeviceZoomRange();

      if (mounted) {
        setState(() => _status = '把面单放进取景框');
      }
    } on Object catch (error) {
      if (mounted) setState(() => _status = '开始失败：$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// 现在能不能录 —— 不能的话把原因说清楚（规格 §3.6.4 的界面三件事之一）。
  ///
  /// 说得清的是三件：**为什么不能录 / 怎么办 / 已有录像照常**。
  String? get _clockBlockedReason => _clock?.blockedReason;

  /// 点【重新校准】：先取公网时间，取不到就提示可以跟电脑端备份一次。
  Future<void> _recalibrate() async {
    setState(() => _status = '正在取公网时间…');

    final ok = await _clock?.tryCalibrateFromPublicTime() ?? false;

    if (!mounted) return;

    setState(() => _status = ok
        ? '已校准，可以开始录制'
        : '取不到公网时间。连上电脑端成功备份一次也能校准（那条路不需要公网）');
  }

  /// 问一次设备支持的变焦范围，用来定表盘两端（规格 §3.1.2）。
  ///
  /// **拿不到就用默认值**：问了不代表问得到（Android 端的通道还没接上、
  /// 或者相机刚开、设备还没报能力）。为这个把「开始工作」弄失败是本末倒置。
  ///
  /// 范围的取舍与不变量收在 [zoomRangeFrom] 里（有测试）——
  /// 这里只负责把问到的两个数递过去。
  Future<void> _readDeviceZoomRange() async {
    double? min;
    double? max;
    try {
      max = await _gateway.maxZoom();
      min = await _gateway.minZoom();
    } on Object {
      // 一样失败就一样按默认值办：两端各自兜底，不必知道是谁抛的。
      min = null;
      max = null;
    }

    if (!mounted) return;
    setState(() {
      final (lower, upper) = zoomRangeFrom(min, max);
      _minZoom = lower;
      _maxZoom = upper;
    });
  }

  /// 收起表盘。**只改字段，不 setState** —— 调用方要么本来就在 `setState`
  /// 里，要么直接把本方法递给 `setState`。
  ///
  /// 三个字段一起清：摊开状态、拨轮声记的「上一格」、对焦节流的时钟。
  /// 少清后两个不会出大事，但「第一下响不响取决于上一趟拖到哪」这种事
  /// 没必要留着 —— 那正是真机验收时会怀疑「拨轮声坏了」的东西。
  void _closeDial() {
    _dialOpen = false;
    _lastDetentTick = null;
    _lastFocusAt = null;
  }

  /// 用户滑动半圆刻度盘。
  Future<void> _onZoomChanged(double ratio) async {
    // 先更新表盘再发命令：原生变焦是异步的，等它回来再画会明显跟手不上。
    setState(() => _zoom = ratio);

    // ── 拨轮声 ──
    //
    // 跟着**语音播报**那个开关（它是全 App 唯一的声音开关）：用户说「嫌吵」
    // 的时候要能一次关掉所有声音，而不是发现还有个表盘在响。
    // ⚠️ 设置页那张卡的说明里必须写清这一点，否则那句话就变成假话。
    final tick = (ratio * 10).round();
    if (tick != _lastDetentTick) {
      _lastDetentTick = tick;
      if (_voiceOn) {
        unawaited(_gateway.playDetentSound().catchError(
          (Object error) => _log('⚠️ 拨轮声失败：$error'),
        ));
      }
    }

    try {
      await _gateway.setZoom(ratio);
    } on Object catch (error) {
      // 变焦失败不该中断录制（原生层也是这个态度），只留一条日志。
      _log('⚠️ 变焦失败：$error');
    }

    await _refocusThrottled();
  }

  /// 手指从表盘上抬起：**补一次对焦**。
  ///
  /// 滑动过程中是节流着对的，手指停下的那一刻才是最终位置 ——
  /// 那一下必须让它实，不然用户看到的是「松手之后画面才是清楚的」。
  Future<void> _onZoomEnd() async {
    _lastFocusAt = DateTime.now();
    await _refocus();
  }

  /// 节流版的 [_refocus]（见 [_focusThrottle]）。
  Future<void> _refocusThrottled() async {
    final now = DateTime.now();
    final last = _lastFocusAt;
    if (last != null && now.difference(last) < _focusThrottle) return;

    _lastFocusAt = now;
    await _refocus();
  }

  /// 重新对焦到画面正中。规格 §3.1.2：「无论怎么滑都自动对焦」。
  ///
  /// 倍率一变，原来对好的那点就不实了 —— 所以每滑一段都要重对一次。
  /// 失败只记一条日志：对不上焦是小事，**不能让它把录制搞坏**（I4 的精神）。
  Future<void> _refocus() async {
    try {
      await _gateway.focusNow();
    } on Object catch (error) {
      _log('⚠️ 对焦失败：$error');
    }
  }

  /// 结束工作：停掉在录的那段、关相机。
  Future<void> _stopWorking() async {
    _heartbeat?.cancel();
    _heartbeat = null;

    // 规格 §3.3.6：点【结束】→ 播「停止工作」，**不滴**（同上）。
    //
    // ⚠️ **播在收尾之前**：`stopWorking` 里要等落库（写 manifest、封段），
    // 那是磁盘 I/O，几百毫秒起步。放在后面的话用户按完按钮要先愣一下才听到
    // 声音 —— 而那一下「滞」正是他要的反馈本身。
    await _coordinator?.speak(VoicePrompt.stopWorking);

    try {
      await _coordinator?.stopWorking();
    } on Object catch (error) {
      if (mounted) setState(() => _status = '结束失败：$error');
    }

    if (mounted) {
      setState(() {
        _status = '已结束工作';
        _askingToContinue = false;
        _elapsed = Duration.zero;
        _closeDial(); // 结束工作 = 相机要关了，表盘没有存在的余地
      });
    }
    await _refreshDiagnostics();
  }

  /// 心跳驱动那些「时间到了就发生」的判定（静止、时长兜底）。
  /// 没有它，画面完全不动时没有任何事件，超时永远不会触发。
  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_coordinator?.handleHeartbeat());

      final elapsed = _coordinator?.elapsed ?? Duration.zero;

      if (mounted) {
        // 时长从编排器取 —— 它用单调时钟，墙钟在这儿算不出正确的值。
        setState(() => _elapsed = elapsed);
      }
    });
  }

  /// 模拟一次扫码。
  ///
  /// **摄像头识码已经接上了**（iOS 用系统自带的 Vision），但这个按钮仍然有用：
  /// 它走的是[PunchSource.manualEntry]，且不经过 [ScanGate] 的框内判定 ——
  /// 验状态机时不必去凑一张恰好落在取景框里的面单。
  /// 错码保护验的是状态机：首扫 A 开录、扫 B 只提示不停、扫回 A 才停。
  Future<void> _simulateScan() async {
    final waybill = WaybillNumber.tryParse(_waybillController.text);
    if (waybill == null) {
      setState(() => _status = '单号无效');
      return;
    }

    await _coordinator?.onWaybillDetected(waybill,
        source: PunchSource.manualEntry);
  }

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
      for (final entry in entries) {
        final file = File('$_rootPath/${entry.location.value}');
        try {
          if (await file.exists()) bytes[entry.evidenceId] = await file.length();
        } on Object {
          continue;
        }
      }

      // 归并成「一次录制」（需求方 2026-09-22 的口径：一个单号从开始到结束为一条）。
      final merged = toSessions(entries, bytes);

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
        _entryCount = entries.length;
        _punchCount = punches;
        _sessions = merged;
        _entries = entries;
        _archiveRecords = archiveRecords;
        _todayCount = countToday(merged, DateTime.now());
        _videoBytes = videoBytes;
        // 手动删除要按 evidenceId 找到磁盘位置 —— 索引里那个相对路径就在这里。
        _locationByEvidenceId = {
          for (final entry in entries) entry.evidenceId: entry.location.value,
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

  /// 界面事件在日志里的分类。
  ///
  /// 技术性的那些（上传、原生通道、录制编排）由各自的**收口点**记，
  /// 带自己的分类；这个标签管的是「用户在抽屉里看见的那一行」。
  static const _logTag = '界面';

  // ─────────────────────────────────────────────
  // 界面
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final recording = _coordinator?.isRecording ?? false;
    final working = _coordinator?.isWorking ?? false;

    return Scaffold(
      // 发货 / 退货两栏**没有 AppBar** —— 取景要一直铺到状态栏底下（需求方
      // 2026-09-22：页面全屏显示摄像头画面）。标题与状态改由画面上的浮层承担。
      //
      // 备份 / 设置两栏照旧留着 AppBar：那两页是**读**的页面，不是瞄面单用的，
      // 没有理由让内容顶到状态栏上。
      appBar: _tab == 1 || _tab == 2 ? null : AppBar(title: Text(_tabTitle)),
      // 用 IndexedStack 而不是 TabBarView：切走时**不销毁预览视图**，
      // 切回来不会闪一下。预览层本来就有「布局时重新挂会话」的自愈逻辑，
      // 但能不重建就别重建。
      //
      // ⚠️ **栈里只有三个孩子，不是四个**：发货与退货指向同一个录制页实例。
      // 放两份进去就会有两个 `UiKitView`、两次开相机 —— 而相机同时只能开一个。
      body: IndexedStack(
        index: switch (_tab) {
          0 => 0, // 备份
          3 => 1, // 设置
          _ => 2, // 发货 / 退货 —— 同一个录制页
        },
        children: [_backupPage(), _settingsPage(), _workPage(recording, working)],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) {
          // 重复点当前那一栏：什么都不做。`onDestinationSelected` 点了当前
          // 那一栏也会回调，不挡的话「手抖点两下发货」会重开一次相机、
          // 重播一遍模式。
          if (index == _tab) return;

          final previous = _tab;
          setState(() => _tab = index);

          // 切回备份页就重读一遍：用户多半是刚录完回来看的，
          // 摆着切走之前的旧数字等于白看。
          //
          // `_identity != null` 兼作「启动已完成」的判据 —— 它是在 `_workspace`
          // 之后设的，早于启动完成就切过来会踩到未初始化的 `late` 字段。
          if (index == 0 && _identity != null) unawaited(_refreshBackup());

          unawaited(_onTabChanged(previous, index));
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.cloud_upload_outlined),
            selectedIcon: Icon(Icons.cloud_upload),
            label: '备份',
          ),
          NavigationDestination(
            icon: Icon(Icons.local_shipping_outlined),
            selectedIcon: Icon(Icons.local_shipping),
            label: '发货',
          ),
          NavigationDestination(
            icon: Icon(Icons.assignment_return_outlined),
            selectedIcon: Icon(Icons.assignment_return),
            label: '退货',
          ),
          NavigationDestination(
            // 齿轮，不是滑杆（`Icons.tune`）—— 需求方 2026-09-23 照草图点的。
            // 四个标签里只有它和草图对不上，另外三个（云上传 / 货车 /
            // 带返回箭头的剪贴板）本来就是对的。
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }

  String get _tabTitle => switch (_tab) {
        0 => '备份',
        1 => '发货',
        2 => '退货',
        _ => '设置',
      };

  /// 备份页：本机身份 → 三个统计 → 电脑备份 → 视频记录。
  ///
  /// ## 为什么这一页先做，而且今天只能做成这样
  ///
  /// 规格 §3.4.3 标着 ★，原文写明它来自一次**真实故障**：原系统上传失败后
  /// 进入终态、永不重试，用户完全不知道数据没传上去。那类故障的第一道防线
  /// 不是重试次数，是**看得见**。
  ///
  /// 而手机端今天**一行上传代码都没有** —— 没有队列、没有网络层、没有配网。
  /// 所以「东西没备份，而且用户不知道」是眼下唯一确定会发生的事。
  /// 这一页先把它变成看得见的。
  ///
  /// ⚠️ **只显示盘上真有的东西**：已收尾的录像、盘上的实际占用、探测得到的
  /// 连通性。不放剩余空间、不放上传进度条 —— 那些今天一个都测不出来，
  /// 而假数字在真机上会被当成真的（这个项目吃过一次亏）。
  Widget _backupPage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _identityCard(),
        const SizedBox(height: 12),
        _totalsCard(),
        const SizedBox(height: 12),
        _hostCard(),
        const SizedBox(height: 12),
        _recordsCard(),
      ],
    );
  }

  // ── ① 本机身份 ───────────────────────────────

  /// 本机名 + 局域网 IP —— 两个**带标签的胶囊**（需求方 2026-09-23 照界面草图定）。
  ///
  /// 本机名是给**电脑端**区分机位用的（需求方 2026-09-22），所以它得可改，
  /// 而且改完必须落盘 —— 只在内存里留着的名字，断联重连一次就没了，
  /// 电脑端那台机位就变成一个没人认得的新设备。
  ///
  /// 标签（「机位名」「手机局域网IP」）是这次新加的：光看值，
  /// 这两串东西一个是名字、一个是地址，得猜。
  Widget _identityCard() {
    final identity = _identity;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.smartphone),
            const SizedBox(width: 8),
            // `Wrap` 而不是 `Row`：两个胶囊在窄屏上排不下一行，
            // 而**挤成省略号比换行糟得多** —— 这两个值一个字都不能缺。
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _identityChip('机位名', identity?.deviceName ?? defaultDeviceName),
                  _identityChip('手机局域网IP', _lanIp ?? '未连局域网'),
                ],
              ),
            ),
            IconButton(
              tooltip: '改本机名',
              icon: const Icon(Icons.edit_outlined),
              onPressed: identity == null ? null : _editDeviceName,
            ),
          ],
        ),
      ),
    );
  }

  /// 身份行上的一个胶囊：小字标签 + 值。
  ///
  /// 标签与值分成两个 `Text`（不拼成一串）—— 拼起来的话，
  /// 「未命名机位」这个值在界面上就不作为一个整体存在了，测试和人都找不着它。
  ///
  /// ⚠️ **值是 `Flexible` + 省略号**：本机名是**用户自己敲的**，
  /// 敲一个长名字（「三号仓西门第七个机位」）就足以把这一行撑爆 ——
  /// 而溢出的后果是黄黑条或者整行被挤出屏幕，不是「难看一点」。
  /// 省略号是看得见的截断，不是悄悄改掉用户的名字（名字本身照原样存着，点铅笔能看全）。
  Widget _identityChip(String label, String value) => Chip(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$label ',
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      );

  // ── ② 本机 / 本机全部 / 总占用 ─────────────────

  /// 三个数字并排。
  ///
  /// 三个口径都是**需求方 2026-09-22 定的**，2026-09-23 照草图改了前两块的标字：
  /// - **本机** = 起录时间落在今天 0:00~23:59 的条数
  /// - **本机全部** = 录到的总条数，**一个单号从开始到结束算一条**（不是索引行数）
  /// - **总占用** = 盘上视频的**实际**大小；传到电脑后删掉手机上的，就按删后的算
  ///
  /// ⚠️ 第一块底下写着「今日录的」：草图给它的标字是「本机」，
  /// 而这个数字只数**今天**那一天的 —— 不加这一句，它会读成「本机上全部」，
  /// 与旁边那块重复。**这一处是照着草图落的最容易歧义的一个**，
  /// 需求方要是不想要这三个字，删掉即可（数字本身不用动）。
  ///
  /// ⚠️ 总占用可能**大于**上面那些条的大小之和 —— 它含还没走完收尾的孤儿片段。
  /// 它答的是「这些视频在手机上占了多少地方」，不是「已入库的占了多少」。
  /// 所以那块底下写着「手机上现存」。
  Widget _totalsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            _statCell('本机', '$_todayCount 条', note: '今日录的'),
            _thinDivider(),
            _statCell('本机全部', '${_sessions.length} 条'),
            _thinDivider(),
            _statCell('总占用', _sizeLabel(_videoBytes), note: '手机上现存'),
          ],
        ),
      ),
    );
  }

  Widget _statCell(String label, String value, {String? note}) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(note, style: const TextStyle(fontSize: 11, color: Colors.black45)),
          ],
        ],
      ),
    );
  }

  /// 三块之间的细分隔线。
  ///
  /// **不用 `VerticalDivider`** —— 它要父级有确定高度（得再套一层
  /// `IntrinsicHeight`），为一个 1 像素的线多一层布局不划算。
  Widget _thinDivider() => Container(
        width: 1,
        height: 40,
        color: Theme.of(context).dividerColor,
      );

  // ── ③ 电脑备份 ───────────────────────────────

  /// 配对电脑 + 连通性。
  ///
  /// ⚠️ 「连接 / 离线」探的是**电脑端那台机器**（M3 已经在 8720 端口上开着的
  /// HTTP 服务），既不代表本机有网，也不代表「备份通道建好了」——
  /// 上传代码（M5）2026-09-23 已经写完，所以这一页现在**直接说备份状态**
  /// （`N 个未备份` + 每条的小标），而不是靠一句免责声明兜着。
  /// 那个绿色小字仍然不能自己单独解释自己：**它旁边必须有那个数字。**
  Widget _hostCard() {
    final identity = _identity;
    final name = identity?.hostName ?? '';
    final address = identity?.hostAddress ?? '';
    final hasHost = address.isNotEmpty;
    // 「配对过」与「填了地址」是**两件事**：填了地址只说明知道去哪儿找它，
    // 配对过才说明它认这台手机的凭据（能把包收下）。
    final paired = (identity?.credential ?? '').isNotEmpty;
    final online = hasHost && paired && _hostOnline;

    // 还有多少条没备份上去 —— **这是整页最要紧的那个数字**
    // （需求方 2026-09-23 照草图加的：「58个未备份，连接后自动备份」）。
    //
    // 判定与列表上那个小标**共用 `summarizeUploadState`**：两处各写一套的话，
    // 迟早出现「上面说 3 个没备份、下面每一条都写着已备份」，而用户没有任何
    // 办法判断哪个才对。
    //
    // ⚠️ 归档状态还没读出来（`_archiveRecords` 空）时，这里会把所有录像都算成
    // 未备份。**这个方向是对的** —— 与 `summarizeUploadState` 同一条规矩：
    // 宁可说「还没备份」，也不能说「已备份」。
    final pending = _sessions
        .where((session) =>
            summarizeUploadState(session.evidenceIds, _archiveRecords) !=
            UploadState.archived)
        .length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '电脑备份',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _hostBadge(hasHost, paired),
                if (!online) ...[
                  const SizedBox(width: 6),
                  // ⚠️ 只是个「这儿有事要处理」的记号，**不说是什么事**
                  // —— 具体是哪一件，写在下面那行和按钮上。
                  // 一个只有感叹号、别的什么都不说的图标，用户只能猜（踩坑 #13）。
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: Colors.orange,
                  ),
                ],
              ],
            ),
            if (_sessions.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                pending > 0
                    ? '$pending 个未备份，${paired ? '连上电脑后会自动传过去' : '连接后自动备份'}'
                    : '${_sessions.length} 个都已经备份到电脑端了。',
                style: TextStyle(
                  fontSize: 13,
                  color: pending > 0 ? Colors.black87 : Colors.green[700],
                ),
              ),
            ],
            _kv('电脑端名字', name.isEmpty ? '未填' : name),
            _kv('局域网 IP', hasHost ? address : '未填'),
            _kv(
              '配对',
              paired ? '已配对' : (hasHost ? '未配对 —— 点下面【配对电脑】' : '未配对'),
            ),
            if (_nextRetryAt != null)
              _kv('下次自动重试', _stamp(_nextRetryAt!)),
            const SizedBox(height: 8),
            Text(
              !paired
                  ? '还没和电脑端配对，录像传不上去。'
                      '这些录像现在只在这台手机上，手机丢了就没了。'
                  : (online
                      // I1 的原文口径：**收到回执之前不清理**。这里说的是同一件事，
                      // 只是用用户的话说。清理本身是 M6 的事，所以末句如实写着。
                      ? '收尾好的录像会自己传到电脑端。'
                          '在收到电脑端的回执之前，手机上那份不会删 —— '
                          '按保留期自动清理还没做（M6）。'
                      : '电脑端现在不在线，可重新搜索。'
                          '收尾好的录像会在连上之后自己传过去。'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            // `Wrap` 而不是 `Row`：五个按钮一行排不下，硬塞会把最后那个
            // 挤出屏幕外面 —— 而**被挤出去的那个会显得像根本没做**。
            Wrap(
              spacing: 4,
              children: [
                FilledButton.tonalIcon(
                  // 没配对就点不动，而**为什么点不动**写在上面那行「配对」和
                  // 那段说明里 —— 一个改了没反应的按钮和一句没头没尾的禁用一样糟
                  // （踩坑 #13）。
                  onPressed: (!paired || _uploading) ? null : () => _runUploads(manual: true),
                  icon: _uploading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined, size: 18),
                  label: Text(_uploading ? '备份中…' : '立即备份'),
                ),
                TextButton(
                  onPressed: identity == null ? null : _probeHost,
                  child: const Text('重新搜索'),
                ),
                TextButton(
                  onPressed: identity == null ? null : _pairHost,
                  child: Text(paired ? '重新配对' : '配对电脑'),
                ),
                TextButton(
                  onPressed: identity == null ? null : _editHost,
                  child: Text(hasHost ? '改电脑端地址' : '填电脑端地址'),
                ),
                // 扫码连接：**主路径**（规格 §3.4.5 ①）。电脑端上点
                // 【连接电脑/手机】弹出二维码，这里扫它 —— 用户不用手输任何东西。
                TextButton(
                  onPressed: identity == null ? null : _pairHost,
                  child: const Text('扫码连接'),
                ),
              ],
            ),
            const Text(
              '手机连不上电脑端时，用【改电脑端地址】把二维码里那串地址改成对的，再重扫一次。'
              '（一台电脑可能同时插着有线、无线和虚拟网卡，它挑出来的地址不一定是你能连上的那个。）',
              style: TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }

  /// 连通状态小标，贴在「电脑备份」那一行的右端（2026-09-23 照草图从 IP 行挪上来的）。
  ///
  /// **没配对就说「未连接」，不说「离线」。** 「离线」会让人以为
  /// 「配对过、只是没连上」，而真实情况是**根本没配过对** ——
  /// 这两件事要修的东西不一样。草图这里写的是「未连接」，正是这个意思，
  /// 所以这个标从「什么都不显示」改成了照写。
  Widget _hostBadge(bool hasHost, bool paired) {
    if (!hasHost || !paired) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link_off, size: 14, color: Colors.grey),
          SizedBox(width: 4),
          Text('未连接', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );
    }

    if (_probingHost) {
      return const Text('探测中…', style: TextStyle(fontSize: 12, color: Colors.black45));
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _hostOnline ? Icons.link : Icons.link_off,
          size: 14,
          color: _hostOnline ? Colors.green : Colors.grey,
        ),
        const SizedBox(width: 4),
        Text(
          _hostOnline ? '连接' : '离线',
          style: TextStyle(
            fontSize: 12,
            color: _hostOnline ? Colors.green : Colors.grey,
          ),
        ),
      ],
    );
  }

  /// 一条录像的备份状态。
  ///
  /// **六段传到五段也是「备份失败」** —— 列表上写「已备份」而实际缺一段，
  /// 正是这一页要防的那种假话（见 `summarizeUploadState`）。
  Widget _uploadChip(RecordingSession session) {
    final state = summarizeUploadState(session.evidenceIds, _archiveRecords);
    final look = _uploadLook(state);

    // 失败的那一格**可以点**：点开是「为什么没传上去」和一个【再试一次】。
    // 规格 §3.4.3 ★：失败必须可见，而且必须有个能救回来的入口 ——
    // 一个只报错、不给出口的界面，故障照旧收不了场。
    if (state == UploadState.failed) {
      return ActionChip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(Icons.error_outline, size: 16, color: look.color),
        label: Text(look.text, style: TextStyle(color: look.color)),
        onPressed: () => _showUploadFailure(session),
      );
    }

    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text(look.text, style: TextStyle(color: look.color)),
    );
  }

  /// 手动删除这一条（规格 §3.5.6）。
  ///
  /// ## 顺序是刻意的：**先回查，再弹窗**
  ///
  /// 规格 ③ 要求「删之前必须回查归档层」，而回查的结果**决定了**弹哪一种窗：
  /// 查不到 / 查不了时**根本不该弹「确认删除」** —— 弹了就等于把一个
  /// 系统已经知道不该做的动作交给用户去点。所以顺序是：
  ///
  /// ```
  /// 已备份 ⇒ 逐段回查 ⇒ 都还在 ⇒ 两选一窗
  ///                  ⇒ 有查不到 / 查不了 ⇒ **不弹删除窗**，只告诉他为什么不能删
  /// 未备份 ⇒ 三选一窗（没有那份可查，需求方裁决过：这种也给删）
  /// ```
  /// 这一次录制锁着没有（规格 §3.6.5）。
  ///
  /// ⚠️ 判据用 `label_store.isEvidenceLocked` —— **与清理判定同一个函数**。
  /// 在界面里另写一个（比如直接比 `== 'true'`）会漏掉判据里的第三条
  /// 「**认不出来的值当锁着**」，于是出现「界面显示没锁、清理却把它保留了」
  /// —— 那个状态用户没机会理解。
  bool _isSessionLocked(RecordingSession session) =>
      session.evidenceIds.any((id) => isEvidenceLocked(_labelsByEvidence[id]));

  /// 锁定 / 解锁这一条（规格 §3.6.5）。
  ///
  /// ⚠️ **每一段都要写**：清理的候选是按**分段**算的（`planCleanup` 吃的是
  /// `RecordingEntry`），只锁第一段的话后面几段照样会被清掉 ——
  /// 而界面上那一条看起来是「已锁定」。这种不一致比没有锁定更糟。
  Future<void> _toggleLock(RecordingSession session) async {
    final locked = _isSessionLocked(session);
    final now = DateTime.now();

    for (final id in session.evidenceIds) {
      await _labels.setLocked(evidenceId: id, locked: !locked, now: now);
    }

    // 重新读一遍标签 —— 界面上的图标与 tooltip 才会跟着变。
    await _refreshDiagnostics();

    _log(locked
        ? '已解锁 ${session.waybill.value}'
        : '已锁定 ${session.waybill.value}（不会被自动清理）');
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
      audit: CleanupAuditLog('$root/cleanup-audit.jsonl'),
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
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('这条现在不能删'),
          content: Text(plan.reason),
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
        audit: CleanupAuditLog('$root/cleanup-audit.jsonl'),
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

  /// 备份页里的一行 —— **规格 §3.4.3 点名的七项**。
  ///
  /// | # | 那一项 | 落点 |
  /// |---|---|---|
  /// | ① | 标签（发货 / 退货） | 行首那个小胶囊 |
  /// | ② | 缩略图 | 左边 48×48 的方块，抽帧失败时是占位图标 |
  /// | ③ | 播放按钮 | 缩略图上那个 ▶ 覆盖层 |
  /// | ④ | `快递单号.mp4` | 标题 |
  /// | ⑤ | 录制时间 | 副标题前半 |
  /// | ⑥ | 时长 | 副标题后半 |
  /// | ⑦ | 已上传 / 未上传 | 右边那个状态小标（**与总览共用同一个归并规则**） |
  ///
  /// ⚠️ **④ 是「列表里显示的名字」，不是磁盘文件名** ——
  /// 磁盘名与归档路径**一律不动**（改了会波及索引、检索、归档回查，
  /// 还要迁移已经录好的那些）。
  Widget _recordTile(RecordingSession session) {
    final label = _businessTypeOf(session);

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      // ① 标签
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label != null) _typeBadge(label),
          const SizedBox(width: 6),
          _thumbnail(session),
        ],
      ),
      // ④ 显示名
      title: Text(
        session.waybill.value.isEmpty
            ? session.sessionId
            : '${session.waybill.value}.mp4',
        style: const TextStyle(fontWeight: FontWeight.w600),
        overflow: TextOverflow.ellipsis,
      ),
      // ⑤ 时间 ⑥ 时长
      subtitle: Text(
        '${_stamp(session.startedAt)} · ${_durationLabel(session.duration)}'
        '${session.bytes > 0 ? ' · ${_sizeLabel(session.bytes)}' : ''}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ⑦ 上传状态
          _uploadChip(session),
          // 手动删除（规格 §3.5.6，需求方 2026-09-24 要的）。
          // ⚠️ 删之前要回查归档层，所以它是个**异步**动作 ——
          // 这里只负责发起，判定与安全都在 `_askDelete` 里。
          // 争议锁定（规格 §3.6.5：**锁定后永不被自动清理**）。
          //
          // ⚠️ 在本次之前，这条硬豁免是**结构性走不到**的：两端都读 `locked`
          // 标签，而**两端都没有任何地方写它** —— 用户没有任何办法把一条
          // 纠纷录像保住（保留期一到就会被清掉本机那份）。
          // 写的那一半是本批补的（`LabelStore.setLocked`）。
          IconButton(
            key: Key('lock-${session.sessionId}'),
            icon: Icon(
              _isSessionLocked(session) ? Icons.lock : Icons.lock_open,
              size: 20,
              // 锁着的时候给点颜色 —— 这个状态**必须一眼看得见**：
              // 用户要能分清「这条我锁过」和「这条只是还没到期」。
              color: _isSessionLocked(session) ? Theme.of(context).colorScheme.primary : null,
            ),
            tooltip: _isSessionLocked(session)
                ? '已锁定：不会被自动清理'
                : '锁定这一条（锁定后不会被自动清理）',
            onPressed: _settingsReady ? () => _toggleLock(session) : null,
          ),
          // 交付原视频（规格 §3.7）：存进系统相册 + 弹系统分享面板。
          IconButton(
            key: Key('share-${session.sessionId}'),
            icon: const Icon(Icons.ios_share, size: 20),
            tooltip: '交付这一段（存相册并分享）',
            onPressed: () => _shareSession(session),
          ),
          IconButton(
            key: Key('delete-${session.sessionId}'),
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: '删除这一条',
            onPressed: _settingsReady ? () => _askDelete(session) : null,
          ),
        ],
      ),
    );
  }

  /// 这一条是发货还是退货。判不出来时为 null（**不猜**）。
  BusinessType? _businessTypeOf(RecordingSession session) {
    for (final evidenceId in session.evidenceIds) {
      final raw = _labelsByEvidence[evidenceId]?[BusinessType.labelKey];
      final parsed = BusinessType.tryParse(raw);
      if (parsed != null) return parsed;
    }

    return null;
  }

  Widget _typeBadge(BusinessType type) {
    final returning = type == BusinessType.returning;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (returning ? Colors.orange : Colors.blue).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        returning ? '退货' : '发货',
        style: TextStyle(
          fontSize: 11,
          color: returning ? Colors.deepOrange : Colors.blue.shade700,
        ),
      ),
    );
  }

  /// ② 缩略图 + ③ 播放按钮。
  ///
  /// ⚠️ **抽帧是异步的、而且会缓存**（规格：不得每次进页面都重新抽帧）——
  /// 所以这里用 `FutureBuilder`：第一帧是占位，抽好了自动换成图。
  Widget _thumbnail(RecordingSession session) {
    final evidenceId = session.evidenceIds.first;
    final videoPath = '$_rootPath/${_locationByEvidenceId[evidenceId] ?? ''}';

    return FutureBuilder<String?>(
      future: _thumbnails.thumbnailFor(evidenceId, videoPath),
      builder: (context, snapshot) {
        final path = snapshot.data;

        return InkWell(
          // ③ 播放：交给**系统播放器**（不自己写播放器、不引 video_player）。
          onTap: path == null ? null : () => _play(session, videoPath),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: path == null
                      ? Container(
                          color: Colors.black12,
                          child: const Icon(Icons.movie_outlined,
                              size: 20, color: Colors.black38),
                        )
                      : Image.file(File(path), fit: BoxFit.cover),
                ),
                if (path != null)
                  const Center(
                    child: Icon(Icons.play_circle_fill,
                        size: 20, color: Colors.white70),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 交付这一段（规格 §3.7）：**原样**存进系统相册 + 弹系统分享面板。
  ///
  /// ## 「只在归档层就先取回本地」
  ///
  /// 规格原话：「如视频不在电脑端或者手机端本地，那么……需要从存储中下载视频到本地，
  /// 然后分享」。所以本地副本不在时，先从电脑端取回来（`/media/{evidenceId}`，
  /// 就是回放页用的那个端点 —— 它已经在了，不必另开一个下载接口）。
  ///
  /// ⚠️ **不转码、不压缩、不裁剪**（§3.7.1）：整条路上没有任何处理视频的代码。
  ///
  /// ⚠️ §3.6.6：**打码整条不做**。交出去的成品里面单上的姓名电话地址**会原样跟出去**，
  /// 界面不许暗示做过隐私处理。
  Future<void> _shareSession(RecordingSession session) async {
    final root = _rootPath;
    final evidenceId = session.evidenceIds.first;
    var path = '$root/${_locationByEvidenceId[evidenceId] ?? ''}';

    try {
      if (!await File(path).exists()) {
        final fetched = await _fetchFromArchive(session, evidenceId);
        if (fetched == null) return;
        path = fetched;
      }

      final problem = await _gateway.shareVideo(path);

      if (problem != null) {
        // I3：交付失败必须说出来 —— 用户以为发出去了，而对方什么都没收到。
        _log('⚠️ 交付没成功：$problem');
        if (mounted) setState(() => _status = problem);
        return;
      }

      _log('📤 已交付 ${session.waybill.value}（存进相册并弹出分享）');
    } on Object catch (error) {
      _log('⚠️ 交付没能进行：$error');
      if (mounted) setState(() => _status = '交付没能进行：$error');
    }
  }

  /// 本地副本不在时，从归档层（电脑端）取回这一段。
  ///
  /// 取回来的那份落在 `<root>/` 下的临时位置 —— 它**不进索引**：
  /// 交付件不是录像（I7 改写后的落点），而索引只增不减。
  Future<String?> _fetchFromArchive(RecordingSession session, String evidenceId) async {
    final client = _client;
    final root = _rootPath;

    if (client == null) {
      if (mounted) setState(() => _status = '本地副本不在了，而电脑端还没配对 —— 没法取回来交付。');
      return null;
    }

    if (mounted) setState(() => _status = '本地副本不在了，正在从电脑端取回来…');

    final target = '$root/share/${session.waybill.value}.mp4';

    try {
      await client.downloadEvidence(evidenceId, target);
      _log('⬇️ 从电脑端取回了 ${session.waybill.value}');
      return target;
    } on Object catch (error) {
      if (mounted) setState(() => _status = '取不回来：$error');
      return null;
    }
  }

  /// 交给系统播放器。**播不了要当场说清楚**（I3）。
  Future<void> _play(RecordingSession session, String videoPath) async {
    try {
      await _gateway.playVideo(videoPath);
    } on Object catch (error) {
      _log('⚠️ 这一段打不开：$error');
    }
  }

  /// 归档状态 → 那一格的字与色。
  ///
  /// 用词与 `ArchiveRecord` 的状态名**一一对应**，不另起一套：
  /// 界面上一套、落盘一套的话，对着日志排查的人会先怀疑自己看错了哪一套。
  ({String text, Color color}) _uploadLook(UploadState state) => switch (state) {
        UploadState.archived => (text: '已备份', color: Colors.green),
        UploadState.uploading => (text: '备份中…', color: Colors.blue),
        UploadState.backoff => (text: '待重试', color: Colors.orange),
        UploadState.failed => (text: '备份失败', color: Colors.red),
        UploadState.pending => (text: '未备份', color: Colors.grey),
      };

  // ── ④ 视频记录 ───────────────────────────────

  /// 视频记录列表：搜索 + 筛选 + 分页。
  ///
  /// 分页是需求方 2026-09-22 定的（每页 5/10/15，左右箭头换页）——
  /// 不是为了性能，是因为手机一屏放不下，而**总页数得看得见**。
  ///
  /// 列的是 `_sessions`（一次录制一条），**不是索引行** —— 索引是按分段记的，
  /// 一段 30 分钟的录制会列出 6 行来，用户数不出那个数字是哪来的。
  Widget _recordsCard() {
    // 「今日」的判据与上面那个统计**共用 `isSameDay`** —— 两处各写一套，
    // 迟早会出现「上面写 3 条、下面列 2 条」而用户无从判断谁对。
    //
    // 搜索是**纯本地筛选**：不查网、不查许可（文档 §04 的 L8 ——
    // 未激活 / 试用到期 / 校验失败都不得挡住检索与回放）。
    // 判定在 `recording_totals.dart` 的 `matchesQuery`，那里有测试。
    final query = _recordsQuery.trim();
    final filtered = [
      for (final session in _sessions)
        if ((!_recordsTodayOnly || isSameDay(session.startedAt, DateTime.now())) &&
            matchesQuery(session, query))
          session,
    ];

    final pageCount = filtered.isEmpty
        ? 1
        : (filtered.length + _recordsPageSize - 1) ~/ _recordsPageSize;

    // 夹在**本地变量**里、不改状态：条数变少（换了筛选、删了录像）时
    // `_recordsPage` 可能越界，而在 build 里改状态 Flutter 会直接报错。
    final page = _recordsPage.clamp(0, pageCount - 1);
    final rows = filtered
        .skip(page * _recordsPageSize)
        .take(_recordsPageSize)
        .toList();

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '视频记录（共 ${filtered.length} 条）',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: false, label: Text('全部')),
                    ButtonSegment(value: true, label: Text('今日')),
                  ],
                  selected: {_recordsTodayOnly},
                  onSelectionChanged: (selection) => setState(() {
                    _recordsTodayOnly = selection.first;
                    // 换了筛选就必须回第一页 —— 停在第 7 页上多半是空的，
                    // 看起来像「今天什么都没录」。
                    _recordsPage = 0;
                  }),
                ),
              ],
            ),
          ),
          // 搜索框（需求方 2026-09-23 照草图加）：单号或日期，**纯本地筛**。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _recordsSearch,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索单号或日期',
                hintStyle: const TextStyle(fontSize: 13),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(() {
                          _recordsSearch.clear();
                          _recordsQuery = '';
                          _recordsPage = 0;
                        }),
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() {
                _recordsQuery = value;
                // 和换筛选同一个理由：换了搜索词就回第一页。
                _recordsPage = 0;
              }),
            ),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                // 搜不到时**必须说出来搜的是什么**：一片空白看起来像这一页坏了，
                // 而不是「手机上确实没有这个单号」（踩坑 #13）。
                query.isNotEmpty
                    ? '没有找到和「$query」有关的录像。'
                    : (_recordsTodayOnly ? '今天还没有录完的录像。' : '本机还没有收尾入库的录像。'),
                style: const TextStyle(fontSize: 13, color: Colors.black54),
              ),
            )
          else
            for (final session in rows) ...[
              const Divider(height: 1),
              // 规格 §3.4.3 的七项：标签 / 缩略图 / 播放 / `单号.mp4` / 时间 / 时长 / 上传状态。
              _recordTile(session),
            ],
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                const Text('每页', style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _recordsPageSize,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 5, child: Text('5')),
                    DropdownMenuItem(value: 10, child: Text('10')),
                    DropdownMenuItem(value: 15, child: Text('15')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _recordsPageSize = value;
                      // 每页条数变了，原来的页码对应的内容已经不是同一批了。
                      _recordsPage = 0;
                    });
                  },
                ),
                const Spacer(),
                IconButton(
                  tooltip: '上一页',
                  icon: const Icon(Icons.chevron_left),
                  onPressed:
                      page > 0 ? () => setState(() => _recordsPage = page - 1) : null,
                ),
                Text('${page + 1}/$pageCount', style: const TextStyle(fontSize: 13)),
                IconButton(
                  tooltip: '下一页',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: page < pageCount - 1
                      ? () => setState(() => _recordsPage = page + 1)
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 标签 + 值的一行。用固定宽度的标签列，几行数字才对得齐。
  ///
  /// [trailing] 贴右端（「连接 / 离线」那个小标在 IP 那一行）。
  Widget _kv(String label, String value, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            // 84 而不是 72：「局域网 IP」「电脑端名字」在 72 里会折行。
            width: 84,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          Expanded(child: Text(value)),
          ?trailing,
        ],
      ),
    );
  }

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
                    style: TextStyle(
                      fontSize: 12,
                      color: full ? Colors.orange : Colors.black54,
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

    // 空名会退回默认名（见 `DeviceIdentity.rename`）—— 允许名字变空
    // 等于允许这台手机在电脑端消失。
    await identity.rename(name);
    if (mounted) setState(() {});
  }

  /// 填 / 改电脑端的地址与名字。
  ///
  /// 地址既用于探测、也用于**入网配对**（M5：`_pairHost` 拿它发
  /// `enrollRequest`）；名字只用于显示 —— 真连没连上由探测决定，不由名字决定。
  Future<void> _editHost() async {
    final identity = _identity;
    if (identity == null) return;

    final nameController = TextEditingController(text: identity.hostName);
    final addressController = TextEditingController(text: identity.hostAddress);

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('电脑端'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '电脑端名字',
                hintText: '打包间电脑',
              ),
            ),
            TextField(
              controller: addressController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '局域网 IP',
                hintText: '192.168.1.10',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '填电脑端那台机器的局域网 IP。填完还要**配对**一次它才会收下'
              '这台手机的录像。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    final address = addressController.text;
    final hostName = nameController.text;
    nameController.dispose();
    addressController.dispose();

    if (saved != true) return;

    // ⚠️ `setHost` 在**地址变了**的时候会把凭据清掉（凭据是某一台电脑端签发的，
    // 换一台它认不出来）。所以这里必须重建上传器 —— 拿着旧地址或旧凭据去传，
    // 表现是「一直传不上去」，而用户刚改完地址，最自然的结论是「地址填错了」。
    await identity.setHost(address: address, name: hostName);
    if (!mounted) return;

    _buildUploader();
    setState(() {});
    await _probeHost(); // 存完立刻探一次：改了地址却还显示旧状态最误导人

    if (!mounted) return;
    if (identity.credential.isEmpty) {
      _snack('地址存好了。还要【配对电脑】一次，它才会收下这台手机的录像。');
    }
  }

  /// 采集页：**取景铺满整页**，状态与操作是压在上面的浮层。
  ///
  /// ## 为什么从「取景钉住 + 其余滚动」改成全屏
  ///
  /// 需求方 2026-09-22：**页面全屏显示手机摄像头画面**。
  ///
  /// 改完全屏，原来那套 `CustomScrollView` + pinned 头**反而可以扔掉了** ——
  /// 它是为了绕开一个坑才存在的：「原生预览视图（`UiKitView`）不能放进滚动容器，
  /// iOS 上平台视图会逐帧重组，真机上的表现就是上下滑发卡」。
  /// 全屏之后取景是**底层铺满**、控件叠在上面（`Stack`），
  /// 滚动容器里压根没有平台视图了，那个坑自动消失。
  ///
  /// ## 三层，从下往上
  ///
  /// 1. **画面** —— 黑底 + 居中按 9:16 摆的预览
  /// 2. **顶部浮层** —— 状态、单号、已录时长、发货/退货标签、诊断计数
  /// 3. **底部浮层** —— 刻度盘、时长兜底询问、抽屉面板、操作按钮、抽屉入口
  ///
  /// ## ⚠️ 黑边是**故意留的**，不是没铺满
  ///
  /// 录像按生效的录制规格摆（竖屏 9:16、横屏 16:9）。
  /// `CameraPreview` 用的是 `Center` + `AspectRatio`，**不是 `BoxFit.cover`** ——
  /// 因为框的判定范围与画出来的框**共用同一份归一化坐标**（见 `camera_preview.dart`）。
  /// 裁掉两边会让「框内 / 框外」的口径跟着变，而用户看到的框会**骗人**。
  /// 需求方 2026-09-22 选了「保留黑边，不动判定」。
  ///
  /// 长屏（20:9）上下各约 75px 黑边；黑边本来就是黑的，远看就是满屏。
  Widget _workPage(bool recording, bool working) {
    final gate = _coordinator?.scanGate;

    // ⚠️ **判的是相机开没开，不是工作没工作**（2026-09-22 改）。
    // 「进栏就自动开相机、但还没开始工作」是现在的常态 —— 沿用
    // `working` 的话，用户进栏只会看到「相机还没开」那块提示，
    // 而相机其实开着、表盘也划不动。画的与判的仍是**同一份** `gate`。
    final showPreview = _coordinator?.isCameraOpen == true && gate != null;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 全屏取景是黑底，状态栏默认的深色字压在上面看不见。
      value: SystemUiOverlayStyle.light,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── ① 画面：铺满整页 ──
          ColoredBox(
            color: Colors.black,
            child: showPreview
                ? CameraPreview(
                    viewfinder: gate.viewfinder,
                    // 画面比例取自**实际**那一档（编排器探测之后的结论）——
                    // 与取景框同一份来源，两者才不会各自歪一点。
                    aspectRatio: _coordinator!.effectiveSpec.aspectRatio,
                  )
                // ⚠️ 未校准时**换掉整块画面**（规格 §3.6.4）。
                // 只把那句「相机还没开」留在原地的话，用户看到的是一个
                // **看着一切正常**的界面，而按【开始】什么都不发生。
                : (_clockBlockedReason != null ? _clockBlockedScreen() : _idleScreen()),
          ),

          // ── ② 顶部浮层：状态与诊断计数 ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _statusOverlay(recording, working),
          ),

          // ── ③ 底部浮层：刻度盘 + 询问 + 抽屉 + 操作 ──
          //
          // ⚠️ **不能写成 `Positioned(bottom: 0)`**，虽然只差这一层 `Align`。
          //
          // 只给 `bottom` 的 `Positioned` 传下来的是**无界高度**
          // （`RenderStack` 只在 top/bottom 都给、或给了 height 时才约束高度）。
          // 无界高度下 `RenderFlex` 走不到弹性分支 —— 于是列里的 `Flexible`
          // **完全不生效**，`_sheetBody()` 那个 `Flexible` 就是个摆设，
          // 键盘弹起来时面板顶部依旧从屏幕顶上冒出去（实测 y = -38）。
          //
          // `Positioned.fill` + `Align(bottomCenter)` 先把高度**框死在正文高度**内，
          // 再由 `Align` 松约束给孩子，`Flexible` 才真的能把面板压扁。
          Positioned.fill(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: _actionOverlay(recording, working, showPreview),
            ),
          ),
        ],
      ),
    );
  }

  /// 相机还没开时铺在底层的提示。
  ///
  /// **不画一块假的取景框**：没开相机就没有画面，画个框在那儿等于告诉用户
  /// 「把面单放进去」，而他放进去什么都不会发生。
  Widget _idleScreen() => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '相机还没开。\n点下面的【开始】重试。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 14, height: 1.6),
          ),
        ),
      );

  /// 未校准时的整块画面（规格 §3.6.4）。
  ///
  /// **说清三件事**（规格对界面的要求）：为什么不能录 / 怎么办 /
  /// **已有的录像照常**（检索、回放、导出、交付都不受影响）——
  /// 最后那句不能省：不说的话，用户会以为「整个应用废了」，
  /// 而其实只是**不能再录新的**。
  Widget _clockBlockedScreen() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.schedule, color: Colors.orangeAccent, size: 40),
              const SizedBox(height: 12),
              Text(
                _clockBlockedReason!,
                key: const Key('clock-blocked-reason'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.6),
              ),
              const SizedBox(height: 8),
              const Text(
                '视频里的时间必须能追溯到本机之外的某个来源 —— 否则改一下系统时间就能伪造'
                '「更早的证据」。联一次网取到时间之后，以后一直断网也能照常录。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 4),
              const Text(
                '⚠️ 只挡住**新录**：已有的录像照常可以检索、回放、导出、交付。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('clock-recalibrate'),
                onPressed: _starting ? null : _recalibrate,
                child: const Text('重新校准'),
              ),
            ],
          ),
        ),
      );

  /// 顶部浮层：谁在这儿、在录什么、录了多久、盘上什么情况。
  ///
  /// 前三项给操作员看，最后那行**诊断计数给真机验收看** ——
  /// 「打点 N 条」是打点那条验收唯一的当场凭据（打点与收尾是两条独立的链，
  /// 各要各的数字），所以它必须**不用点开任何东西**就能看见。
  Widget _statusOverlay(bool recording, bool working) {
    return _scrim(
      top: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 画面**正上方**：实时时间 → 完整单号（规格 §3.2.6）──
            //
            // 居中、两行，压在状态行**上面**。放在这儿是因为它俩是同一类东西：
            // 都是给「事后对着录像核时间、核单号」用的当场凭据，
            // 而状态行讲的是「这台设备现在在干什么」，不是同一件事。
            Center(
              child: _strokedText(
                _clockStamp(_now),
                key: const Key('recorder-clock'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                  // ⚠️ 两个 Text 叠出来的是**同一个字符串**，行高必须一致，
                  // 否则描边层与填充层会错开半个像素、字看起来是糊的。
                  height: 1.1,
                ),
              ),
            ),

            // 第二行只在**录制中**才有内容（规格 §3.2.6）。
            //
            // 没在录时不放占位符、也不拿上一件的号凑数：那一行是「这一段录的
            // 是哪一件」，空着时它没有答案 —— 填一个进去，用户会以为录上了。
            if (recording && (_coordinator?.currentWaybill?.value.isNotEmpty ?? false)) ...[
              const SizedBox(height: 2),
              Center(child: _waybillLine(_coordinator!.currentWaybill!.value)),
            ],

            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  recording
                      ? Icons.fiber_manual_record
                      : (working ? Icons.photo_camera : Icons.stop_circle_outlined),
                  color: recording ? Colors.redAccent : Colors.white70,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    // 「在工作（相机开着）」和「在录」是两回事，界面上要分得清。
                    //
                    // ⚠️ 单号**不在这儿**了（2026-09-22 晚些）：它挪到上面自成
                    // 一行 —— 挤在这一行里只能省略号收尾，而截断的单号
                    // 看起来仍然像个完整单号，抄下来就是错的。
                    recording ? '录制中' : _status,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (recording) ...[
                  const SizedBox(width: 8),
                  Text(
                    '已录 ${_two(_elapsed.inMinutes)}:${_two(_elapsed.inSeconds % 60)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                // 这一件是发货还是退货。两栏的采集流程一模一样，
                // 操作员得能一眼看出自己在哪一栏 —— 否则录完了才发现归类错了。
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(_isReturn ? '退货' : '发货'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '工作区 $_sessionCount（未收尾 $_pendingCount）'
              ' · 索引 $_entryCount · 打点 $_punchCount',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// 白色描边字：**画两层** —— 底下那层只描边，上面那层只填充。
  ///
  /// 为什么不直接给白字加个阴影：取景画面是**实景**，底色不可控。
  /// 仓库顶灯、白墙、白面单 —— 整片白的时候纯白字就是看不见。
  /// 而看不见的时间比没有时间更糟：用户会以为设备卡死了。
  /// 深色描边在任何底色上都留得住字的轮廓。
  ///
  /// `clipBehavior: Clip.none` 是必须的：`Stack` 默认会把内容裁到自己的尺寸，
  /// 而描边有一半在字形轮廓**外面**，裁掉就变成了细一圈的填充字。
  Widget _strokedText(
    String text, {
    required Key key,
    required TextStyle style,
    Color strokeColor = Colors.black,
    double strokeWidth = 3,
  }) {
    return Stack(
      key: key,
      clipBehavior: Clip.none,
      children: [
        Text(
          text,
          style: style.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..color = strokeColor,
          ),
        ),
        Text(text, style: style),
      ],
    );
  }

  /// 当前这一件的**完整**单号（规格 §3.2.6）。
  ///
  /// ⚠️ **不许省略、不许截断**：这里刻意**没有** `maxLines`、**没有**
  /// `overflow: ellipsis`。一个被截掉尾巴的单号看起来仍然像一个完整单号 ——
  /// 操作员照着抄就会抄下一个错的，而这种错当场看不出来（这正是这条要求
  /// 存在的理由）。太长就让它换行，宁可占两行也不给一个假的完整。
  Widget _waybillLine(String waybill) => Text(
        waybill,
        key: const Key('recorder-waybill'),
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.redAccent,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
        ),
      );

  /// 底部浮层：刻度盘 → 时长兜底询问 → 抽屉面板 → 操作按钮 → 抽屉入口。
  ///
  /// ## 为什么刻度盘在**这一列里**、而不是 `Positioned` 贴边
  ///
  /// 这一列的高度是变的（抽屉开合、询问弹不弹）。刻度盘如果按固定 `bottom`
  /// 贴边，迟早会被某个高度的抽屉盖住 —— 而「盖住」在真机上表现为
  /// **表盘突然消失**，看起来像坏了。
  /// 放进这一列就永远不会重叠，它自己会被推上去。
  ///
  /// 位置仍然在**右下、贴右缘**，与规格 §3.1.2 的「屏幕边缘的半圆刻度盘」一致：
  /// 右手拇指从边缘划过来顺手，也不挡取景框中心（面单必须放进中心框才认）。
  Widget _actionOverlay(bool recording, bool working, bool showPreview) {
    return _scrim(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 表盘摊开时占**最上面**，整块压住取景画面上方。
            //
            // ⚠️ 它必须留在这一列里、**不能改成叠在画面上的浮层**：
            // 压在取景框正中会挡住条码（面单必须放进中心框才认得到），
            // 而挡住的后果用户只会看到「扫不出来」，看不出是界面盖的。
            // ⚠️ 门控是 `working`（点了【结束】就消失），不是 [showPreview]。
            // 需求方 2026-09-22 晚些：「对焦功能只在发货或者退货页面点开始后
            // 点结束前才触发对焦」。相机开着、却没开始工作时把【对焦】按钮
            // **整个藏掉** —— 留一个点了不生效的按钮，用户只会当成坏了。
            if (showPreview && working && _dialOpen)
              Align(
                alignment: Alignment.centerRight,
                child: ZoomDial(
                  ratio: _zoom,
                  minZoom: _minZoom,
                  maxZoom: _maxZoom,
                  onChanged: _onZoomChanged,
                  onEnd: _onZoomEnd,
                ),
              ),

            // 时长兜底询问。**放在抽屉面板上面**，这样抽屉开着它也看得见 ——
            // 一个会被抽屉挡住的「是否停止」问询，用户会当它不存在。
            if (_askingToContinue) _durationPrompt(),

            // `Flexible` 是为了小屏 / 键盘弹起来时**面板先让位**，而不是整列溢出。
            // 下面那排按钮和抽屉入口必须一直够得着 —— 它们一没，页面上就没有
            // 任何出口了（`mainAxisSize: min` 的列溢出时是直接从底部裁掉）。
            if (_workSheet != null) Flexible(child: _sheetBody()),

            // ── **底部只有一个操作按钮**（需求方 2026-09-22 裁决 #6）──
            //
            // 绿【开始】↔ 红【结束】，一个控件两副面孔。以前这里是两个并排的
            // 按钮，外加一个「停止当前录制（相机继续开着）」——
            // 那个是规格 §3.3.2:183 **明文禁止**的「手动结束当前单」按钮，
            // 之前一直挂在页面上。连续扫改成换段式之后它更没有任何存在理由了。
            //
            // 时长兜底那个【停止】/【继续】问询还在（规格 §3.3.4），
            // 但它只在问询时出现，不是常驻按钮。
            // 【对焦】按钮 —— **底部【开始】按钮的右上方**（需求方 2026-09-22 裁决）。
            //
            // 它就摆在这一列里、【开始】的正上方且靠右，于是天然落在那个角落上，
            // 不用 Stack、不会重叠、也不会在小屏上把【开始】挤出去。
            //
            // 只在**相机开着、而且在工作**时出现：没画面时调焦没意义，
            // 而没在工作时按需求方的裁决就是不该能调（见上面表盘那一处）。
            if (showPreview && working)
              Align(
                alignment: Alignment.centerRight,
                child: _focusButton(),
              ),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: working ? _stopWorking : (_starting ? null : _startWorking),
                icon: Icon(working ? Icons.stop : Icons.play_arrow),
                label: Text(working ? '结束' : '开始'),
                style: FilledButton.styleFrom(
                  backgroundColor: working ? Colors.red.shade600 : Colors.green.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            _sheetTabs(),
          ],
        ),
      ),
    );
  }

  /// 【对焦】按钮：**方形、半透明**，点一下摊开表盘、再点一下收起。
  ///
  /// 需求方 2026-09-22 点名的形状是「方形半透明按钮」。颜色用中性的
  /// 半透明黑而不是主题色：它压在**取景画面**上，主题色在浅色主题下
  /// 会是一块浅底、白图标看不见（表盘读数那边踩过同一个坑）。
  ///
  /// **摊开与否是它自己说出来的**（图标与底色都变）：表盘占的那块地方
  /// 在收起时是空的，如果按钮本身毫无变化，用户会怀疑刚才那下点没点上。
  Widget _focusButton() {
    final open = _dialOpen;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        width: 56,
        height: 56,
        child: Material(
          color: open ? Colors.black.withValues(alpha: 0.55)
                      : Colors.black.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            key: const Key('recorder-focus-button'),
            borderRadius: BorderRadius.circular(8),
            // 收起时把三个字段一起清掉（见 `_closeDial` 的说明）。
            // 摊开时不清：那样每次点开都从「没响过」开始，第一下滑动必定响一声，
            // 而用户只是把面板收了又开。
            onTap: () => setState(() {
              if (_dialOpen) {
                _closeDial();
              } else {
                _dialOpen = true;
              }
            }),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.center_focus_strong,
                  size: 22,
                  color: Colors.white.withValues(alpha: open ? 1.0 : 0.85),
                ),
                const SizedBox(height: 2),
                const Text(
                  '对焦',
                  style: TextStyle(fontSize: 11, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 压在画面上的一层：上/下两端深、中间透明。
  ///
  /// 用渐变而不是整块纯色，是为了**中间那段取景尽可能干净** ——
  /// 操作员是透过这块屏看面单的。
  ///
  /// [top] 为真时方向反过来（顶部浮层用）。
  Widget _scrim({required Widget child, bool top = false}) {
    const solid = 0.72;
    const clear = 0.0;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: top ? Alignment.bottomCenter : Alignment.topCenter,
          end: top ? Alignment.topCenter : Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: clear),
            Colors.black.withValues(alpha: solid),
          ],
        ),
      ),
      child: SafeArea(top: top, bottom: !top, child: child),
    );
  }

  /// 时长兜底询问（规格 §3.3.4）。
  Widget _durationPrompt() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          const Text(
            '录制时间即将超时，是否需要停止录制？',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              FilledButton(
                onPressed: () =>
                    _coordinator?.onDurationPromptAnswered(continueRecording: false),
                child: const Text('停止'),
              ),
              OutlinedButton(
                onPressed: () =>
                    _coordinator?.onDurationPromptAnswered(continueRecording: true),
                child: const Text('继续'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 抽屉入口。展开的那一块显示 `▾`，其余显示 `▸`。
  ///
  /// 每个入口带 `Key`：面板标题里也含「手动输入」这四个字，按下之后
  /// `find.textContaining` 会同时命中入口和面板，测试没法点。
  Widget _sheetTabs() {
    Widget tab(_WorkSheet sheet, String label) => Expanded(
          child: TextButton(
            key: Key('work-sheet-${sheet.name}'),
            onPressed: () => setState(
              () => _workSheet = _workSheet == sheet ? null : sheet,
            ),
            child: Text(
              '$label ${_workSheet == sheet ? '▾' : '▸'}',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        );

    return Row(
      children: [
        tab(_WorkSheet.manual, '手动输入'),
        // 条数跟着日志走，所以只有这一个入口需要订阅 ——
        // 整页 `setState` 换成这一个 `TextButton` 重建。
        ValueListenableBuilder<List<String>>(
          valueListenable: AppLog.instance.tail,
          builder: (context, events, child) =>
              tab(_WorkSheet.events, '事件 ${events.length}'),
        ),
        tab(_WorkSheet.diagnostics, '诊断'),
      ],
    );
  }

  Widget _sheetBody() {
    return _panel(
      switch (_workSheet!) {
        _WorkSheet.manual => _manualEntrySheet(),
        // 固定高度 + 内部自滚：这块**不能**用 `SingleChildScrollView` 包，
        // 里面是 `ListView`，两个都可滚会直接报「高度无界」。
        _WorkSheet.events => SizedBox(height: 140, child: _eventsList()),
        _WorkSheet.diagnostics => ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(child: _diagnosticsBody()),
          ),
      },
    );
  }

  /// 抽屉面板：**不透明**的浅色卡片。
  ///
  /// 操作条可以半透明（那是按钮，认得形状就行），**正文不行** ——
  /// 12 号字压在一幅画面很乱的取景上根本读不出来。
  Widget _panel(Widget child) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  /// 「手动输入单号」—— 规格 §3.2.2 要求的兜底。
  ///
  /// > 框内始终识别不到时，用户必须能手动输入单号兜底，**且不打断当前录制**。
  ///
  /// 「不打断」指的是**不经过停录**：这个面板是叠在画面上的，录制一直在跑。
  Widget _manualEntrySheet() {
    // 自己可滚：外面那层 `Flexible` 会给它一个上界，内容超过就内部滚，
    // 而不是把下面那排按钮顶出屏幕。
    return SingleChildScrollView(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('手动输入（扫码失灵时的兜底）',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          '规格 §3.2.2：框内始终识别不到时，用户必须能手动输入单号兜底，'
          '且不打断当前录制。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _waybillController,
          decoration: const InputDecoration(
            labelText: '单号',
            helperText: '在录时输入并点下面按钮 = 复扫；未录时 = 开一段新的。',
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _coordinator?.isWorking == true ? _simulateScan : null,
          icon: const Icon(Icons.keyboard),
          label: const Text('当作扫到了这个单号'),
        ),
      ],
      ),
    );
  }

  /// 事件列表。
  ///
  /// **它内部没有平台视图，滚起来是顺的** —— 这也是它敢放在取景画面上的原因。
  Widget _eventsList() {
    return ValueListenableBuilder<List<String>>(
      valueListenable: AppLog.instance.tail,
      builder: (context, events, child) {
        if (events.isEmpty) {
          return const Center(child: Text('（还没有事件）', style: TextStyle(fontSize: 12)));
        }

        return ListView.builder(
          itemCount: events.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(events[index], style: const TextStyle(fontSize: 12)),
          ),
        );
      },
    );
  }

  /// 诊断：盘上的实况与收尾结果。
  ///
  /// 这些数字真机验收时**要盯着看**，所以给它们一个固定的去处，
  /// 而不是散在各处等人找。
  Widget _diagnosticsBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('工作区 $_sessionCount 个会话（未收尾 $_pendingCount）'),
        Text('索引 $_entryCount 条 · 打点 $_punchCount 条'),
        const SizedBox(height: 8),
        Text(
          '单段时长 ${RecordingCoordinator.defaultSegmentDuration.inMinutes} 分钟 —— '
          '崩溃最多丢这一段，所以每录满一段就自动封一个文件',
          style: const TextStyle(fontSize: 12),
        ),
        if (_recovered.isNotEmpty) ...[
          const Divider(height: 20),
          _recoveredBody(),
        ],
        const Divider(height: 20),
        // 一键诊断包（`AGENTS.md` §6：日志要能导出为诊断包，用户一键打包发回）。
        // 放在**已有的**诊断抽屉里，不新增界面面。
        FilledButton.tonal(
          onPressed: _exportDiagnostics,
          child: const Text('导出诊断包'),
        ),
        const SizedBox(height: 4),
        Text(
          _diagnosticsNote ?? '遇到问题时点它，然后把生成的那个文件发回来。',
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  /// 生成诊断包并说清**它落在哪**。
  ///
  /// ⚠️ iOS 上路径不用解释：`Info.plist` 里已有 `UIFileSharingEnabled`，
  /// 那个目录就是「文件 → 我的 iPhone → VidLog」。Android 是弱侧，
  /// 所以顺带把路径**显示出来并可复制**（用户能自己去找）。
  Future<void> _exportDiagnostics() async {
    final root = _rootPath;
    if (root.isEmpty) {
      setState(() => _diagnosticsNote = '还没读出数据目录，稍等一下再点。');
      return;
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
        sessionCount: _sessionCount,
        orphanCount: _pendingCount,
        entries: entries,
        now: DateTime.now(),
      );

      if (!mounted) return;
      setState(() => _diagnosticsNote =
          describeDiagnosticsPackage(path, hasScanErrors: errors.isNotEmpty));
    } on Object catch (error) {
      if (mounted) setState(() => _diagnosticsNote = '导出失败：$error');
    }
  }

  /// 诊断包那行提示（生成之后写路径，之前写用法）。
  String? _diagnosticsNote;


  /// 改设置：**先落盘，再刷界面**。
  ///
  /// [RecordingSettings] 只在 `_bootstrap` 里读过一次，之后每次改动都由这里
  /// 同步进去并写回盘。
  ///
  /// `_settings == null` 表示盘上的设置还没读出来。这时**直接不动** ——
  /// 改了也会被随后读出来的盘上值覆盖，等于改了没反应还看不出来。
  /// 设置页的控件在这一小段时间里是禁用的，见 [_settingsReady]。
  void _updateSettings({
    WorkMode? mode,
    StaticStopSetting? staticStop,
    DurationFallbackSetting? durationFallback,
    bool? voiceEnabled,
    RetentionSetting? retentionArchivedOutbound,
    RetentionSetting? retentionArchivedReturn,
    RetentionSetting? retentionUnarchivedOutbound,
    RetentionSetting? retentionUnarchivedReturn,
    VideoCodec? codec,
    VideoResolution? resolution,
    RecordingOrientation? orientation,
  }) {
    final settings = _settings;
    if (settings == null) return;

    setState(() {
      if (mode != null) _mode = mode;
      if (staticStop != null) _staticStop = staticStop;
      if (durationFallback != null) _durationFallback = durationFallback;
      if (voiceEnabled != null) settings.voiceEnabled = voiceEnabled;
      if (retentionArchivedOutbound != null) {
        _retentionArchivedOutbound = retentionArchivedOutbound;
      }
      if (retentionArchivedReturn != null) {
        _retentionArchivedReturn = retentionArchivedReturn;
      }
      if (retentionUnarchivedOutbound != null) {
        _retentionUnarchivedOutbound = retentionUnarchivedOutbound;
      }
      if (retentionUnarchivedReturn != null) {
        _retentionUnarchivedReturn = retentionUnarchivedReturn;
      }
      if (codec != null) _codec = codec;
      if (resolution != null) _resolution = resolution;
      if (orientation != null) _orientation = orientation;

      settings.mode = _mode;
      settings.staticStop = _staticStop;
      settings.durationFallback = _durationFallback;
      settings.retentionArchivedOutbound = _retentionArchivedOutbound;
      settings.retentionArchivedReturn = _retentionArchivedReturn;
      settings.retentionUnarchivedOutbound = _retentionUnarchivedOutbound;
      settings.retentionUnarchivedReturn = _retentionUnarchivedReturn;
      settings.codec = _codec;
      settings.resolution = _resolution;
      settings.orientation = _orientation;
    });

    // ⚠️ **播报是唯一立刻生效的一项。** 它不参与任何判定（只出声），
    // 而人是嫌吵才关的 —— 让他「先结束工作再开始」是不合理的。
    // 其余三项等下次「开始工作」，理由见设置页底部那块提示与 `实现决策.md` §17.3。
    if (voiceEnabled != null) _applyVoice();

    // **不等它写完。** 写盘是几十毫秒的 I/O，而这是点一下开关就要走的路；
    // 失败了也不该拦住任何事 —— 设置读不出来/写不进去都不影响录制（I4）。
    unawaited(settings.save());
  }

  /// 盘上的设置读出来了没有。没读出来时设置页的控件全部禁用。
  bool get _settingsReady => _settings != null;

  /// 播报开没开。设置没读出来时按**开**算 —— 读不出来不该静默把提示功能关掉，
  /// 理由见 `RecordingSettings.voiceEnabled` 的注释。
  bool get _voiceOn => _settings?.voiceEnabled ?? true;

  /// **用户选的**录制规格（设置还没读出来时用默认档）。
  ///
  /// ⚠️ 与「实际用的那一档」不是一回事 —— 后者由编排器探测之后给出
  /// （[_coordinator]`.effectiveSpec`）。界面显示、索引记录都用后者。
  RecordingSpec _requestedSpec() =>
      _settings?.requestedSpec ?? RecordingSpec.standard;

  /// 设置页：工作模式 → 两个兜底档位 → 验收工具。
  ///
  /// ## 这一页的两条规矩
  ///
  /// ① **改了立刻落盘。** 落盘之前这些值只活在内存里，重启就回默认档位 ——
  ///    而「时长兜底档位交给用户自己选」是需求方 2026-09-21 特意要的，
  ///    每次开 App 都抹掉等于没做。
  ///
  /// ② **验收工具必须长得不像产品设置。** 「时长兜底加速」会把**真实录制**的
  ///    首次询问压到 20 秒。它要是和别的开关长一样，验收完忘了关，
  ///    正常录 4 分钟的活 20 秒就被问一次「是否停止」。
  Widget _settingsPage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _modeCard(),
        const SizedBox(height: 12),
        _specCard(),
        const SizedBox(height: 12),
        _fallbackCard(),
        const SizedBox(height: 12),
        _retentionCard(),
        const SizedBox(height: 12),
        _voiceCard(),
        const SizedBox(height: 12),
        _acceptanceCard(),
        const SizedBox(height: 12),
        _whenCard(),
      ],
    );
  }

  // ── ②b 语音播报 ──────────────────────────────

  /// 语音播报开关（需求方 2026-09-22 点名的）。
  ///
  /// ⚠️ **关掉的只是声音，不是提示。** 「单号不同，请核对」那类提示在屏幕上
  /// 照旧出现、事件日志照旧记（日志图标从 🔊 变 🔇）。关播报不等于关提示 ——
  /// 否则用户关掉声音的同时也把错码保护的唯一线索关掉了。
  Widget _voiceCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const Key('settings-voice-switch'),
              contentPadding: EdgeInsets.zero,
              value: _voiceOn,
              onChanged: _settingsReady
                  ? (value) => _updateSettings(voiceEnabled: value)
                  : null,
              title: const Text('语音播报'),
              subtitle: const Text(
                '扫到不是同一件的包裹时出声提醒（规格 §3.3.2 错码保护），'
                '表盘滑过刻度时的「咔哒」声也归它管。旁边有人、或者嫌吵时关掉。',
              ),
            ),
            const Text(
              '关掉只是不出声：屏幕上的提示和事件日志照旧，'
              '日志前面的图标会从 🔊 变成 🔇。立刻生效，不用重新开始工作。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // ── ① 工作模式 ───────────────────────────────

  Widget _modeCard() {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('工作模式', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('决定这一件什么时候算录完（规格 §3.3.1）。',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            SegmentedButton<WorkMode>(
              segments: const [
                ButtonSegment(value: WorkMode.continuousScan, label: Text('连续扫')),
                ButtonSegment(value: WorkMode.sameWaybillStop, label: Text('同码停')),
                ButtonSegment(
                    value: WorkMode.scanThenStaticStop, label: Text('扫码静止')),
              ],
              selected: {_mode},
              onSelectionChanged: _settingsReady
                  ? (value) => _updateSettings(mode: value.first)
                  : null,
            ),
            const SizedBox(height: 12),

            // 只讲**选中的那一个**。三个模式的说明同时铺出来，用户得先自己
            // 对号入座；而人真正要回答的问题是「我现在这个会怎么停」。
            Container(
              key: const Key('settings-mode-blurb'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_modeTitle(_mode),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(_modeBlurb(_mode), style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '三个模式都一样：扫到别的单号不会停 —— 二次扫描只有单号相同才停'
              '（§3.3.2 错码保护）。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  static String _modeTitle(WorkMode mode) => switch (mode) {
        WorkMode.continuousScan => '连续扫 —— 换件换段',
        WorkMode.sameWaybillStop => '同码停 —— 复扫同码就停',
        WorkMode.scanThenStaticStop => '扫码静止 —— 静止够时长才停',
      };

  static String _modeBlurb(WorkMode mode) => switch (mode) {
        WorkMode.continuousScan =>
          '扫一张面单就开录；扫到「另一张」面单时，上一段立刻入库、'
              '紧接着为新面单开下一段，如此往复。\n'
              '停只能靠手动按【结束】，或者下面两个兜底机制。\n'
              '注意：这个模式没有错码保护 —— 画面里扫到别的条码会当场换段，'
              '一件包裹可能被切成两段。',
        WorkMode.sameWaybillStop =>
          '识别到单号就开录，复扫到同一个单号就停。'
              '三个模式里只有它不用人额外做什么就能自己停。',
        WorkMode.scanThenStaticStop =>
          '识别到单号就开录。包裹要先离开画面、再回到画面，'
              '并且静止够下面设的时长才停。\n'
              '注意：这个模式下复扫同码不停，只认静止 —— '
              '这就是它和「同码停」的区别。',
      };

  // ── ①b 录制规格（规格 §3.1.7）─────────────────

  /// 编码 / 分辨率 / 方向。**三项都横排单选**（规格点名不要下拉）。
  ///
  /// ## 三条界面规矩
  ///
  /// ① 编码名**只写「H.265」**，不许出现 HEVC —— 名字由
  ///    `RecordingSpec.codecLabel` 一处产出（规格原话：两个名字混用会让用户
  ///    以为是两种不同的编码）。
  /// ② 帧率**没有选项**：规格是「上限 30、不提供选择」，所以界面上只是一句话。
  ///    摆一个只有一个选项的下拉是骗人的。
  /// ③ **实际用哪一档必须说出来**（规格：**回落必须可见**、**不得静默回落**）。
  ///    那一行读的是编排器探测之后的结论 —— 用户选的那一档跑不通时，
  ///    这里要**连原因一起**说清楚，否则用户会以为自己选错了。
  Widget _specCard() {
    final scheme = Theme.of(context).colorScheme;
    final effective = _coordinator?.effectiveSpec;
    final reason = _coordinator?.specFallbackReason;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('录制规格', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
              '录制前可选，**录制中不可改**（改了要等下次「开始工作」）。帧率固定 30 帧 —— '
              '它是上限，不提供选择。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),

            _settingTitle('编码', 'H.265 同画质下体积小一半左右。'),
            const SizedBox(height: 8),
            SegmentedButton<VideoCodec>(
              key: const Key('settings-codec'),
              segments: const [
                ButtonSegment(value: VideoCodec.h264, label: Text('H.264')),
                ButtonSegment(value: VideoCodec.h265, label: Text('H.265')),
              ],
              selected: {_codec},
              onSelectionChanged: _settingsReady
                  ? (value) => _updateSettings(codec: value.first)
                  : null,
            ),
            const SizedBox(height: 6),
            const Text(
              '⚠️ 电脑端的**网页回放**对 H.265 的支持不一致，可能播不了 —— '
              '那时用系统播放器打开就行，录像本身没问题。所以这里不砍掉 H.265。',
              style: TextStyle(fontSize: 12),
            ),

            const Divider(height: 28),

            _settingTitle('分辨率', '越大越清楚、也越占地方。清理时的容量预告按这一档算。'),
            const SizedBox(height: 8),
            SegmentedButton<VideoResolution>(
              key: const Key('settings-resolution'),
              segments: const [
                ButtonSegment(value: VideoResolution.uhd4K, label: Text('4K')),
                ButtonSegment(value: VideoResolution.p1080, label: Text('1080P')),
                ButtonSegment(value: VideoResolution.p720, label: Text('720P')),
              ],
              selected: {_resolution},
              onSelectionChanged: _settingsReady
                  ? (value) => _updateSettings(resolution: value.first)
                  : null,
            ),

            const Divider(height: 28),

            _settingTitle('方向', '手机怎么拿就选哪个 —— 取景框和画面比例都跟着它走。'),
            const SizedBox(height: 8),
            SegmentedButton<RecordingOrientation>(
              key: const Key('settings-orientation'),
              segments: const [
                ButtonSegment(
                    value: RecordingOrientation.landscapeLeft, label: Text('横左')),
                ButtonSegment(
                    value: RecordingOrientation.portrait, label: Text('竖屏')),
                ButtonSegment(
                    value: RecordingOrientation.landscapeRight, label: Text('横右')),
              ],
              selected: {_orientation},
              onSelectionChanged: _settingsReady
                  ? (value) => _updateSettings(orientation: value.first)
                  : null,
            ),

            const SizedBox(height: 16),

            // 「实际按 X 录制」—— 规格那句「不得静默回落」的落点。
            Container(
              key: const Key('settings-effective-spec'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: reason == null
                    ? scheme.surfaceContainerHighest
                    : Colors.orange.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                effective == null
                    ? '实际用哪一档还没检查过。点【开始工作】时会真开一次相机试。'
                    : reason == null
                        ? '实际按 ${effective.label} 录制。'
                        : '⚠️ 实际按 ${effective.label} 录制 —— 你选的是 ${_requestedSpec().label}。'
                            '$reason',
                style: TextStyle(
                  fontSize: 12,
                  color: reason == null ? null : Colors.deepOrange.shade900,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── ② 两个兜底档位 ───────────────────────────

  Widget _fallbackCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('防忘停录', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
              '两个兜底互相独立：关掉一个不影响另一个。任何一个到点，录制就停。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),

            _settingTitle('静止停录', '画面一直不动、够这个时长就停（§3.3.3）。'),
            const SizedBox(height: 8),
            SegmentedButton<StaticStopSetting>(
              segments: const [
                ButtonSegment(value: StaticStopSetting.off, label: Text('关闭')),
                ButtonSegment(value: StaticStopSetting.minutes2, label: Text('2 分')),
                ButtonSegment(value: StaticStopSetting.minutes3, label: Text('3 分')),
                ButtonSegment(value: StaticStopSetting.minutes4, label: Text('4 分')),
                ButtonSegment(value: StaticStopSetting.minutes5, label: Text('5 分')),
              ],
              selected: {_staticStop},
              onSelectionChanged: _settingsReady
                  ? (value) => _updateSettings(staticStop: value.first)
                  : null,
            ),

            const Divider(height: 28),

            _settingTitle(
              '时长兜底',
              '不管画面动不动，录满这个分钟数就弹一次「是否停止」；'
                  '不操作 1 分钟后自动停（§3.3.4）。',
            ),
            const SizedBox(height: 8),
            SegmentedButton<DurationFallbackSetting>(
              segments: const [
                ButtonSegment(value: DurationFallbackSetting.off, label: Text('关闭')),
                ButtonSegment(value: DurationFallbackSetting.minutes4, label: Text('4 分')),
                ButtonSegment(value: DurationFallbackSetting.minutes5, label: Text('5 分')),
                ButtonSegment(value: DurationFallbackSetting.minutes6, label: Text('6 分')),
              ],
              selected: {_durationFallback},
              onSelectionChanged: _settingsReady
                  ? (value) => _updateSettings(durationFallback: value.first)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  // ── ②c 本地保留期：四个数 ─────────────────────

  /// 本地留多久 —— **发货 / 退货 × 已备份 / 未备份 = 四个数**（规格 §3.5.2.1）。
  ///
  /// 需求方 2026-09-24 点名要的摆法是「**一张两行两列的表**（行 = 已备份 / 未备份，
  /// 列 = 发货 / 退货）」。用下拉而不是分段按钮，是因为有 9 个档位 ——
  /// 分段按钮铺不下，会挤成一行看不清的字。
  ///
  /// ## ⚠️ 两列语义**相反**（这一块最要紧的一句话）
  ///
  /// - **已备份**：到期**真删本地副本**（先过 §3.5.4 回查），起算点 = 备份成功时刻；
  /// - **未备份**：到期**只标红、只催上传，永不自动删**，起算点 = 录完时刻。
  ///
  /// 后者是**唯一副本**（I2），删了就永久没了。这段话必须写在界面上 ——
  /// 不写的话，用户要么以为「选了不保留却没反应」是坏了（踩坑 #13），
  /// 要么以为自己选了「马上删」而**不敢选**。
  ///
  /// ## 为什么手机端没有「归档层」那个下拉（电脑端有）
  ///
  /// 规格 §3.5.1 要求：归档层就是本机磁盘时**不提供**清理选项，
  /// 因为那时本地这份是唯一副本。**那个危险在手机上不存在** ——
  /// 手机的归档层是电脑端（局域网）/ NAS / 网盘，三者都在**别的设备**上。
  /// 所以这里不摆一个「归档层」下拉：它在这台机器上没有第二种可能，
  /// 摆上去就是个改了没反应的开关（踩坑 #13）。
  Widget _retentionCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('本地保留期', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
              '四个数互相独立，改一个不动另一个。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                const SizedBox(width: 64),
                Expanded(
                  child: Text('发货',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                Expanded(
                  child: Text('退货',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 4),

            _retentionTableRow(
              title: '已备份',
              outboundKey: 'settings-retention-archived-outbound',
              outbound: _retentionArchivedOutbound,
              onOutbound: (value) =>
                  _updateSettings(retentionArchivedOutbound: value),
              returnKey: 'settings-retention-archived-return',
              returning: _retentionArchivedReturn,
              onReturn: (value) =>
                  _updateSettings(retentionArchivedReturn: value),
            ),
            const SizedBox(height: 8),
            _retentionTableRow(
              title: '未备份',
              outboundKey: 'settings-retention-unarchived-outbound',
              outbound: _retentionUnarchivedOutbound,
              onOutbound: (value) =>
                  _updateSettings(retentionUnarchivedOutbound: value),
              returnKey: 'settings-retention-unarchived-return',
              returning: _retentionUnarchivedReturn,
              onReturn: (value) =>
                  _updateSettings(retentionUnarchivedReturn: value),
            ),

            const SizedBox(height: 12),
            const Text(
              '⚠️「已备份」那一列：备份成功后，手机上的原片再留多久。'
              '从「备份成功那一刻」起算，不是从录完起算。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            const Text(
              '⚠️「未备份」那一列**永不自动删除** —— 那是唯一一份，删了就没了。'
              '它到期的动作只有提醒（列表标红 + 催上传），从「录完那一刻」起算。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            const Text(
              '⚠️「不保留」不是立刻删：最近 24 小时内录的一律不动'
              '（硬性豁免，关不掉），所以它实际是「备份成功后最快 24 小时清理」。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            const Text(
              '⚠️ 这一块记的是**到期之后该怎么做**，而手机端的自动清理还没接通 —— '
              '今天不会有任何文件**自动**被删。想现在删就用备份页每一条右边的垃圾桶图标'
              '（那会先跟电脑端核对，核对不上就不删）。另外【被锁定】的证据永远不清。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// 两行两列表里的一行：一个行首标签 + 两个下拉。
  Widget _retentionTableRow({
    required String title,
    required String outboundKey,
    required RetentionSetting outbound,
    required ValueChanged<RetentionSetting> onOutbound,
    required String returnKey,
    required RetentionSetting returning,
    required ValueChanged<RetentionSetting> onReturn,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        Expanded(child: _retentionDropdown(outboundKey, outbound, onOutbound)),
        const SizedBox(width: 8),
        Expanded(child: _retentionDropdown(returnKey, returning, onReturn)),
      ],
    );
  }

  Widget _retentionDropdown(
    String key,
    RetentionSetting value,
    ValueChanged<RetentionSetting> onChanged,
  ) {
    // ⚠️ 「自定义」不在列表里，而下拉的 `value` 必须能在 `items` 里找到 ——
    // 找不到会直接断言失败。所以自定义值临时补一个条目进去（显示成「45 天」），
    // 用户点开下拉再选就是换成了标准档位。
    final items = <RetentionSetting>[
      ...RetentionSetting.standard,
      if (value.isCustom) value,
    ];

    return DropdownButton<RetentionSetting>(
      key: Key(key),
      value: value,
      isDense: true,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      items: [
        for (final setting in items)
          DropdownMenuItem(value: setting, child: Text(setting.label)),
        // 「自定义」这一项不是一个值，是一个入口 —— 选中它只是打开输入框。
        DropdownMenuItem(
          value: _customSentinel,
          child: Text('自定义…', style: TextStyle(fontSize: 13)),
        ),
      ],
      // `_settingsReady`：盘上的设置还没读出来时不给改 ——
      // 改了会被随后读出来的盘上值覆盖，等于改了没反应还看不出来。
      onChanged: _settingsReady
          ? (v) async {
              if (v == null) return;
              if (identical(v, _customSentinel)) {
                final days = await _askCustomDays(value);
                if (days != null) onChanged(RetentionSetting.fromConfig(days));
                return;
              }
              onChanged(v);
            }
          : null,
    );
  }

  /// 「自定义」在下拉里的哨兵值。**不会落盘** —— 选中它只是打开输入框。
  static const _customSentinel = RetentionSetting(-1);

  /// 问一个天数。返回 null 表示用户取消。
  Future<int?> _askCustomDays(RetentionSetting current) async {
    final controller = TextEditingController(
      text: current.days != null && current.isCustom ? '${current.days}' : '',
    );

    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义保留天数'),
        content: TextField(
          key: const Key('retention-custom-days'),
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            suffixText: '天',
            helperText: '填一个正整数天数（最多 3650 天）',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('retention-custom-ok'),
            onPressed: () {
              final days = int.tryParse(controller.text.trim());
              // ⚠️ 认不出的输入**不关窗也不猜** —— 关掉就等于「改了没反应」。
              if (days == null || days < 0 || days > RetentionSetting.maxDays) {
                return;
              }
              Navigator.of(context).pop(days);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );

    controller.dispose();
    return result;
  }

  Widget _settingTitle(String title, String blurb) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(blurb, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  // ── ③ 验收工具 ───────────────────────────────

  /// 真机验收用的开关。**故意做成一眼能看出不是产品设置的样子**：
  /// 琥珀底 + ⚠️ 标题 + 明说「不落盘」。
  ///
  /// 它不落盘这件事要在界面上说出来 —— 否则验收的人会以为「我上次开了」
  /// 而这次没开，或者反过来以为「我关了它就永久关了」。
  Widget _acceptanceCard() {
    return Card(
      color: Colors.amber.withValues(alpha: 0.18),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const Key('settings-accelerated-switch'),
              contentPadding: EdgeInsets.zero,
              value: _accelerated,
              onChanged: (value) => setState(() => _accelerated = value),
              title: const Text('⚠️ 时长兜底加速（验收用，不是产品设置）'),
              subtitle: const Text(
                '把时长兜底的首次询问压到 20 秒、宽限 10 秒，免得验收真的等 4 分钟。'
                '只压询问时机，不动档位本身，也不碰静止停录。',
              ),
            ),
            const Text(
              '重启 App 自动归位（关）—— 它不写进配置。'
              '所以做完验收记得自己也关掉：开着它，真实录制会在开录 20 秒后就被问一次。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // ── ④ 什么时候生效 ───────────────────────────

  /// 说清「现在改的东西什么时候起作用」。
  ///
  /// ⚠️ **这不是一句客套提示，是在补一个真实的静默。** 模式与档位是
  /// [RecordingCoordinator] 的**构造参数**（没有 setter），编排器只在
  /// 「开始工作」时重建（`_startWorking` 里的 `_buildCoordinator`）。
  /// 所以在工作中改设置，当前这一段仍然按旧设置走 —— 界面不说明的话，
  /// 用户改完看到没反应，只会以为开关坏了。
  ///
  /// **不改成「立刻生效」是有意的**：工作途中换编排器会把相机会话和界面状态
  /// 拆开（新编排器的 `isWorking` 是 false，而相机是真开着的），
  /// 那个态下「结束工作」也关不掉相机 —— 用一次模式切换换一个相机泄漏不值。
  ///
  /// ⚠️ 语音播报是**例外**，而且必须在这里写明 —— 否则这块提示本身就成了假话。
  /// 它不参与判定（只出声），关它是「现在太吵」而不是「下一段想这样录」。
  Widget _whenCard() {
    final working = _coordinator?.isWorking ?? false;

    return Card(
      color: working ? Colors.amber.withValues(alpha: 0.18) : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          working
              ? '⚠️ 正在工作中。上面【工作模式】【防忘停录】【录制规格】改了这一段不生效 —— '
                  '等下次「开始工作」重建编排器时才按新设置走。'
                  '【语音播报】不受这条限制，它立刻生效。'
              : '【工作模式】【防忘停录】【录制规格】在点「开始工作」时生效。'
                  '改完直接去发货栏开始工作就行，不用退出去重进。\n'
                  '【语音播报】是立刻生效的。\n'
                  '【归档后的本地保留期】落在盘上就算数，但它今天还没有执行者 ——'
                  '要等清理执行层接通（M6），在那之前任何文件都不会被删。',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  /// 孤儿收尾结果的正文，收进「诊断」抽屉里。
  ///
  /// 原来它是一张常驻的琥珀色卡片。改成抽屉之后**没有降级**：
  /// 抽屉入口上的「诊断」两个字是常驻的，展开就在；而这张卡片的出现是
  /// 小概率事件（只有上次被杀过才有），常驻占着取景画面不值得。
  Widget _recoveredBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('启动时收尾的孤儿分段', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          '这些是上次没录完就被中断的会话。它们已经封文件、算哈希、写进索引。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        for (final outcome in _recovered)
          Text(
            '· ${outcome.succeeded ? "已收尾" : "失败"} · '
            '${outcome.segments.length} 段 · ${_triggerLabel(outcome.reason)}',
          ),
      ],
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// `MM-DD HH:mm`。备份页一行里塞得下，且不需要年份 —— 手机上的东西都是最近的。
  ///
  /// 日期那一段走 [dayStamp]：搜索框要按**屏幕上真有的字**匹配，
  /// 两处各写一套的话，写着 `09-23` 却搜不出来（见 `matchesQuery`）。
  static String _stamp(DateTime at) =>
      '${dayStamp(at)} ${_two(at.hour)}:${_two(at.minute)}';

  /// `年/月/日/时/分/秒`，六段都要带（规格 §3.2.6）。
  ///
  /// 与 [_stamp] 的区别不只是多几段：这是采集页正上方那个钟，
  /// 它要能被**逐字念出来对着录像核**，所以年月日时分秒一段都不能省
  /// （少一段就得靠猜是今年还是去年）。月/日/时/分/秒各补零到两位 ——
  /// 不等宽的话这个钟每秒都在左右晃。
  static String _clockStamp(DateTime at) => '${at.year}/${_two(at.month)}/'
      '${_two(at.day)} ${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}';

  /// `mm:ss`（超过一小时就是三位数的分钟，不折成小时 —— 一段录像不会是几小时）。
  static String _durationLabel(Duration d) =>
      '${_two(d.inMinutes)}:${_two(d.inSeconds % 60)}';

  static String _sizeLabel(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;

    if (bytes < kb) return '$bytes B';
    if (bytes < mb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / gb).toStringAsFixed(2)} GB';
  }

  static String _modeLabel(WorkMode mode) => switch (mode) {
        WorkMode.continuousScan => '连续扫',
        WorkMode.sameWaybillStop => '同码停',
        WorkMode.scanThenStaticStop => '扫码静止停录',
      };

  static String _triggerLabel(StopTrigger trigger) => switch (trigger) {
        StopTrigger.manual => '手动',
        StopTrigger.sameWaybillRescan => '同码复扫',
        StopTrigger.sceneStatic => '画面静止',
        StopTrigger.durationFallback => '时长兜底',
        StopTrigger.resourceCritical => '资源告警',
        StopTrigger.processKilled => '进程被杀',
        StopTrigger.nextWaybill => '换件',
      };
}

