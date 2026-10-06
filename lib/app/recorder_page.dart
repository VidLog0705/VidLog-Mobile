import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../diagnostics/app_log.dart';
import '../diagnostics/diagnostics_package.dart';
import '../diagnostics/error_handlers.dart';
import '../live/live_counts.dart';
import '../live/live_gateway.dart';
import '../live/live_service.dart';
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
import 'about_page.dart';
import 'camera_preview.dart';
import 'netdisk_page.dart';
import 'palette.dart';
import 'record_detail_page.dart';
import 'scan_connect_page.dart';
import 'scan_waybill_page.dart';
import 'video_player_page.dart';
import 'zoom_dial.dart';

// ─────────────────────────────────────────────────────────────────────
// ⚠️ 这一行往下的文件是**同一个 library**，不是几个独立的库。
//
// T26③ 第 2 轮拆的：这个文件原来 6400 行、`_RecorderPageState` 一个类就占
// 6200 行，破了 `AGENTS.md` §5「超过 1500 行必须拆」。
//
// 为什么用 `part` 而不是「抽成独立类 + 传参」：非控件成员里 **13 个被几乎
// 每一堆引用**（`_gateway` / `_coordinator` / `_rootPath` / `_settings` /
// `_identity` / `_client` / `_archiveRecords` / `_locationByEvidenceId` /
// `_sessions` / `_entries` / `_log` / `_snack` / `_finalizer`），另有 3 个
// 横跨两三个职责。抽类就得先给这 198 个成员重新布线，而 `test/` 里盖着这
// 3800 行 UI 的用例只有 11 条 —— 接错一个字段不会有任何测试喊。
// `part` **一个标识符都不用改**（按行区间剪下来贴走），所以可以拿 `diff`
// 证明每一步都是纯搬家。证明比抽样测试强。
//
// ⚠️ 已知代价：这**不治那个类**。真正的病是 6200 行的 `_RecorderPageState`，
// 要等第 3 轮（抽类），而第 3 轮要等测试底座加厚。这一轮只承诺三件事：
// 不再违规、T7 解锁、每一步可 diff 证明。
//
// 搬家的两种形态（2026-10-06 用真编译器验过，别照直觉改）：
//   · 实例方法/getter → `extension on _RecorderPageState`（同 library 的
//     extension 读得到私有成员，且**跨 extension 不带前缀就能调**）
//   · static 方法/常量 → **顶层**声明（匿名 extension 的 `static` 成员
//     没有名字可当前缀，等于不可达 ⇒ 只能走顶层）
// ─────────────────────────────────────────────────────────────────────
part 'recorder_format.dart';
part 'recorder_view_backup.dart';
part 'recorder_view_records.dart';
part 'recorder_view_work.dart';
part 'recorder_view_sheets.dart';
part 'recorder_bootstrap.dart';
part 'recorder_live.dart';
part 'recorder_enroll.dart';
part 'recorder_capture.dart';
part 'recorder_upload.dart';
part 'recorder_events.dart';
part 'recorder_records_ops.dart';

/// 采集页底部抽屉里正在展开哪一块。`null` = 三块都收着。
///
/// 需求方 2026-09-22 定的布局：**取景铺满整页**，控件是压在上面的浮层；
/// 「手动输入」与「事件」收进抽屉，点开才占屏。
///
/// ⚠️ 这是**页面本地的界面状态**，不是业务状态 —— 它不参与任何判定，
/// 也不落盘。切栏、停录都不需要动它。
enum _WorkSheet { manual, events, diagnostics }

/// 压在**实景画面**上那一块的主题 —— **冻结在改版前那一套**，故意不跟新配色。
///
/// 为什么不一起换：这一块的底不是页面色，是相机拍到的**实景**（仓库顶灯、
/// 白墙、白面单）。新配色是「浅蓝页 + 近白卡」的浅色体系，跟着换的话抽屉
/// 面板、输入框、胶囊会变成一片浅底，而它们背后可能是白墙。
/// 表盘读数与【对焦】按钮这两处已经各自踩过一次同一个坑
/// （见 `zoom_dial.dart` 与 `_focusButton` 上的两段注释），那两次是靠
/// **把颜色写死**躲过去的。
///
/// 这里用一层 `Theme` 把**整块**冻住，而不是给那七八个控件逐个补色：
/// 逐个补色要写死的正是 M3 从种子里算出来的那些色调值 —— 没人采样过、
/// 也没人验过，而且散在七八处之后下次换主题又是一轮。一层 `Theme` 是**一处**，
/// 它保的是「和今天一模一样」这个**可验证的事实**。
///
/// ⚠️ `#1565C0` 是改版前 `main.dart` 里那个种子色，**故意写成另一个常量**、
/// 不去引用 `Palette` —— 它不是配色的一部分，是一份**历史值**。
final _cameraOverlayTheme =
    ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Color(0xFF1565C0)));

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

  /// 诊断面板里那个日志级别的**界面镜像**（真正的档在 `AppLog` 里）。
  final _logLevel = ValueNotifier<AppLogLevel>(AppLog.instance.minLevel);

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

  /// 录像记录列表：来源筛 / 日期筛 / 搜索词 / 每页条数 / 当前页（0 起）。
  ///
  /// ⚠️ 2026-09-27 照草图改：「全部 / 今日」那个分段按钮换成了两个胶囊
  /// （[`_sourceChip`]、[`_dayChip`]，每个各管一维）。日期那一维不再是布尔 ——
  /// 胶囊点开能选**具体某一天**，所以它必须是一个可空的日期：
  /// 为 null = 不按日期筛（「全部日期」）。
  ///
  /// ⚠️ **三个筛选（来源 / 日期 / 搜索词）改动时一律走 [`_applyFilter`]** ——
  /// 它顺手回第一页并清空选中集，两件都不能漏（见那个函数的文档）。
  ///
  /// 三条判据合在 `filterSessions` 里（纯函数，有测试）——
  /// 写在 `build` 里的话这一页的逻辑就没有覆盖了（widget 测试里 `_sessions` 恒空）。
  BusinessType? _recordsSource;
  DateTime? _recordsDay;
  int _recordsPageSize = 5;
  int _recordsPage = 0;

  /// 【管理】模式（需求方 2026-09-27 照草图定的）：批量选、批量锁定、批量删除。
  bool _managing = false;

  /// 管理模式下选中的那些（`sessionId`）。
  ///
  /// 用 id 而不是下标：排序、筛选一变下标就指到别人身上了，而这一批操作里
  /// 有**删除** —— 选中集错了会删掉用户没打算删的那条。
  final Set<String> _selected = {};

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
    // 推流那一路也要收（HTTP 服务、编码器、报到定时器）——
    // 不收的话进程还在的时候，那一格在电脑端会一直挂着。
    unawaited(_liveShare?.dispose() ?? Future<void>.value());
    _waybillController.dispose();
    _recordsSearch.dispose();
    super.dispose();
  }

  RecorderConfig get _config => RecorderConfig(
        // 两个档位都**原样保留用户的选择** —— 加速只压时长兜底的首次询问时机。
        staticStop: _staticStop,
        durationFallback: _durationFallback,
        waybillMinLength: _waybillMinLength,
        recordAudio: _recordAudio,
        // 实时共享（规格 §3.8）：**开会话时读一次**，与录音同一条规矩 ——
        // 推流那一路是会话的第二路输出，中途补不上（补 = 断录制）。
        liveShare: _liveShareOn,
        promptAfterOverride: _accelerated ? const Duration(seconds: 20) : null,
        durationPromptRepeatEvery:
            _accelerated ? const Duration(seconds: 30) : const Duration(minutes: 5),
        durationPromptGrace:
            _accelerated ? const Duration(seconds: 10) : const Duration(minutes: 1),
      );

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

  /// 按设置与相机状态**对齐**推流那一路。
  ///
  /// 三条规矩：
  ///
  /// 1. **相机开着 + 开关开着 ⇒ 起**；任一条不成立 ⇒ 停。
  ///    相机是录制那边管的，推流只借它的画面（规格 §3.8：推流不得影响录制）。
  /// 2. **关掉立刻停**；**打开要等下次【开始工作】** —— 推流那一路是开会话时
  ///    挂上去的**第二路输出**，往一个跑着的会话里加输出会让它重新配置，
  ///    那一下断的是**正在录的证据**。宁可不热插拔。
  /// 3. 起不来**不影响录制**：原因记日志 + 显示在设置页那张卡上（I3 不静默）。
  ///
  /// ⚠️ **挡住重入、但不能把后来的那次丢掉**（2026-10-03）。两条叠着跑的话，
  /// 两边都会看到 `isRunning == false`，于是各起一个 HTTP 服务（各占一个端口、
  /// 各推一路），后一个把 `_server` 覆盖掉之后**前一个就没人收它了** ——
  /// 那是个一直跑着、一直在推流的孤儿。
  ///
  /// 所以后到的那次**排队**，等当前这次跑完再补一次 —— 直接 `return` 是不行的：
  /// 用户「开着的时候又按一下关」（第一条还在起服务、慢一点）会被丢掉，
  /// 结果是**设置写着关、推流还在推**，而且没人会再来对齐一次。
  bool _applyingLiveShare = false;
  bool _liveShareAgain = false;

  /// 当前那个客户端。**手动删除要拿它回查归档层**（规格 §3.5.6③）。
  ///
  /// 与 `_uploader` 同时建、同时换 —— 拿它自己再 new 一个的话，
  /// 地址或凭据一改就会出现「上传用的是新的、回查用的是旧的」那种错位。
  UploadClient? _client;

  /// 实时共享（规格 §3.8）：推流那一路的接线。
  ///
  /// ⚠️ **它不认识相机**。起停由这一页安排（开始工作后起、结束工作停），
  /// 因为它与录制共用同一台相机 —— 相机归编排器管。
  LiveService? _liveShare;

  /// 多画面每格下面那对 `F` / `T` 的来源（规格 §3.8）。
  ///
  /// 起算点是需求方 2026-10-01 定的：**本次开始工作以来，且按北京时间自然日重算**
  /// （见 [LiveCounter]）。所以开始工作那一刻要 `reset()`，
  /// 而扫码那一路要 `record(...)`。
  final _liveCounter = LiveCounter();

  /// 推流起不来 / 被录制压力停掉时，给用户看的那句话（null = 现在没事）。
  ///
  /// ⚠️ 一定要显示出来：规格 §3.8 第 3 条明写「自动把推流停掉**并在界面说明
  /// 为什么停**」—— 悄悄停掉的话，用户看到的就是「刚才还有画面，怎么没了」。
  String? _liveShareProblem;

  /// 手电筒（后置闪光灯常亮）开着没有。
  ///
  /// ⚠️ 它**只跟相机设备走**：相机关掉灯就灭了，所以每次开相机时都会被
  /// 强制归回 `false`（见 [_readDeviceCapabilities]）——
  /// 图标亮着而灯没亮，是最难解释的一种「坏了」。
  bool _torchOn = false;

  /// 这台设备的相机**有没有闪光灯**。
  ///
  /// `null` = 还不知道（相机没开、或者装的是没有这个方法的旧包）——
  /// 不知道就**不画**那个按钮（踩坑 #13：不画按下去什么都不发生的假开关）。
  bool? _torchUsable;

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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

  /// 现在能不能录 —— 不能的话把原因说清楚（规格 §3.6.4 的界面三件事之一）。
  ///
  /// 说得清的是三件：**为什么不能录 / 怎么办 / 已有录像照常**。
  String? get _clockBlockedReason => _clock?.blockedReason;

  /// 上一次读资源的时间（规格 §3.1.1）。见 `_startHeartbeat` 里的节流理由。
  DateTime? _resourcesReadAt;

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
      // ⚠️ **设置栏 2026-09-28 起也没有了** —— 需求方那张图上，页头是页面里
      // 自己的一块（蓝底齿轮方块 + 设置 + 一句说明，见 `_settingsHeader`）。
      // 留着 AppBar 就是两个「设置」上下叠着。
      //
      // 只有备份栏照旧留着：它是**读**的页面，没有理由让内容顶到状态栏上。
      appBar: _tab == 0 ? AppBar(title: Text(_tabTitle)) : null,
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
              '填电脑端那台机器的局域网 IP。填完还要配对一次它才会收下'
              '这台手机的录像。',
              style: TextStyle(fontSize: 12, color: Palette.muted),
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
    WaybillMinLength? waybillMinLength,
    bool? recordAudio,
    bool? liveShareEnabled,
    // 采集页右上角那个实时共享按钮**自己**去对齐推流那一路（它要在按完之后
    // 拿到结果说一句实话），所以它传 false 跳过这里那一跳 ——
    // 两条 `_applyLiveShare` 叠着跑会各起一个 HTTP 服务，第二个必然端口被占。
    bool applyLiveShare = true,
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

      // 这两项**不另立字段** —— 界面直接读 `_settings`（见 [_waybillMinLength]
      // 与 [_recordAudio]），所以这里只写回 settings 一处。
      if (waybillMinLength != null) settings.waybillMinLength = waybillMinLength;
      if (recordAudio != null) settings.recordAudio = recordAudio;
      if (liveShareEnabled != null) settings.liveShareEnabled = liveShareEnabled;

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

    // ⚠️ **播报是唯一立刻生效的一项。**
    // 它不参与任何判定（只出声），而人是嫌吵才关的 ——
    // 让他「先结束工作再开始」是不合理的。
    // 其余各项（含**实时共享**）等下次「开始工作」，
    // 理由见设置页底部那块提示与 `实现决策.md` §17.3。
    if (voiceEnabled != null) _applyVoice();

    // 实时共享：**关掉是立刻就停的**，打开要等下次【开始工作】
    // （推流那一路是开会话时挂上去的第二路输出）。这里叫一下是为了
    // 让「关掉」当场生效、「打开」当场得到那句实话 —— 而不是让用户
    // 对着一个没有反应的开关猜。
    if (liveShareEnabled != null && applyLiveShare) {
      unawaited(_applyLiveShare());
    }

    // **不等它写完。** 写盘是几十毫秒的 I/O，而这是点一下开关就要走的路；
    // 失败了也不该拦住任何事 —— 设置读不出来/写不进去都不影响录制（I4）。
    unawaited(settings.save());
  }

  /// 盘上的设置读出来了没有。没读出来时设置页的控件全部禁用。
  bool get _settingsReady => _settings != null;

  /// 播报开没开。设置没读出来时按**开**算 —— 读不出来不该静默把提示功能关掉，
  /// 理由见 `RecordingSettings.voiceEnabled` 的注释。
  bool get _voiceOn => _settings?.voiceEnabled ?? true;

  /// 面单条码最短长度。读完设置之前按默认档（11 位）算。
  ///
  /// ⚠️ 与 [_voiceOn] 同一个写法（**读穿 `_settings`**，不另立一个字段）：
  /// 另立字段就成两份真相，而这两项都只在「开始工作」重建编排器时被读一次。
  WaybillMinLength get _waybillMinLength =>
      _settings?.waybillMinLength ?? WaybillMinLength.fallback;

  /// 录像文件带不带声音。读完设置之前按**开**算，理由见
  /// `RecordingSettings.recordAudio`。
  bool get _recordAudio => _settings?.recordAudio ?? true;

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
        _settingsHeader(),
        const SizedBox(height: 16),
        _modeCard(),
        const SizedBox(height: 12),
        _retentionCard(outbound: true),
        const SizedBox(height: 12),
        _retentionCard(outbound: false),
        const SizedBox(height: 12),
        _codecCard(),
        const SizedBox(height: 12),
        _resolutionCard(),
        const SizedBox(height: 12),
        _orientationCard(),
        const SizedBox(height: 12),
        _recordAudioCard(),
        const SizedBox(height: 12),
        _fallbackCard(),
        const SizedBox(height: 12),
        _voiceCard(),
        const SizedBox(height: 12),
        _netdiskCard(),
        const SizedBox(height: 12),
        _aboutCard(),
        const SizedBox(height: 12),
        _acceptanceCard(),
        const SizedBox(height: 12),
        _whenCard(),
      ],
    );
  }

  // ── 设置页的通用件 ───────────────────────────

  /// 页头：**实心蓝圆角方块（白色齿轮）+ 设置 + 一句说明**，压在一块浅蓝底上。
  ///
  /// ⚠️ 有了它，设置栏就**不要 AppBar 了**（见 `build` 里那条）——
  /// 留着会有两个「设置」上下叠着。
  Widget _settingsHeader() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Palette.blueTint,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Palette.primary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.settings, color: Palette.onDark, size: 26),
          ),
          const SizedBox(width: 12),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('设置',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              SizedBox(height: 2),
              Text('系统配置与功能管理', style: TextStyle(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  /// 设置页那一列卡片的统一外壳：**实心蓝圆角方块 + 白色字形**，右边标题与说明。
  ///
  /// ⚠️ 与备份页的 `_statCard`（浅色**圆**底 + 彩色字形）**故意不一样**。
  /// 那不是疏漏：两页各照自己那张图做，谁也别去改谁。
  Widget _settingCard({
    required IconData icon,
    required String title,
    String? blurb,
    Widget? trailing,
    required List<Widget> children,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Palette.primary,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, color: Palette.onDark, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      if (blurb != null) ...[
                        const SizedBox(height: 2),
                        Text(blurb, style: const TextStyle(fontSize: 12)),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }

  /// 卡片里的一行：左边一个标签，右边一个控件。
  Widget _settingRow(String label, Widget control) {
    return Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
        const SizedBox(width: 8),
        Expanded(child: control),
      ],
    );
  }

  /// 档位下拉。**设置页现在一律用下拉**（需求方那张图上是下拉）——
  /// 三个档位类型共用一个，免得三处各写一遍 `DropdownButton` 的样板。
  ///
  /// `_settingsReady`：盘上的设置还没读出来时不给改 —— 改了会被随后读出来的
  /// 盘上值覆盖，等于改了没反应还看不出来。
  Widget _settingDropdown<T>({
    required String key,
    required T value,
    required List<T> values,
    required String Function(T) label,
    required ValueChanged<T> onChanged,
  }) {
    return DropdownButton<T>(
      key: Key(key),
      value: value,
      isDense: true,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      items: [
        for (final option in values)
          DropdownMenuItem(value: option, child: Text(label(option))),
      ],
      onChanged: _settingsReady
          ? (selected) {
              if (selected != null) onChanged(selected);
            }
          : null,
    );
  }

  // ── ②b 语音提示 ──────────────────────────────

  /// 语音播报开关（需求方 2026-09-22 点名的）。
  ///
  /// ⚠️ **关掉的只是声音，不是提示。** 「单号不同，请核对」那类提示在屏幕上
  /// 照旧出现、事件日志照旧记（日志图标从 🔊 变 🔇）。关播报不等于关提示 ——
  /// 否则用户关掉声音的同时也把错码保护的唯一线索关掉了。
  ///
  /// 卡片名照需求方那张图改成 `语音提示`（原来叫「语音播报」），并加上 `试听`。
  Widget _voiceCard() {
    return _settingCard(
      icon: Icons.volume_up_outlined,
      title: '语音提示',
      blurb: '离线自动使用系统语音 —— 不联网、不带音频素材（规格 §3.3.6）。',
      children: [
        Row(
          children: [
            TextButton.icon(
              key: const Key('settings-voice-preview'),
              onPressed:
                  (_settingsReady && _coordinator != null) ? _previewVoice : null,
              icon: const Icon(Icons.volume_up, size: 18),
              label: const Text('试听'),
            ),
            const Spacer(),
            Switch(
              key: const Key('settings-voice-switch'),
              value: _voiceOn,
              onChanged: _settingsReady
                  ? (value) => _updateSettings(voiceEnabled: value)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '管的是这台手机现在出不出声：扫到不是同一件的包裹时出声提醒'
          '（规格 §3.3.2 错码保护），表盘滑过刻度时的「咔哒」声也归它。'
          '旁边有人、或者嫌吵时关掉。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 4),
        const Text(
          '关掉只是不出声：屏幕上的提示和事件日志照旧，日志前面的图标会从 🔊 变成 🔇。'
          '立刻生效，不用重新开始工作 —— 它是唯一一项不用等的设置。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 4),
        // 这一行会随状态换内容：没有编排器时先说清「试听为什么按不动」，
        // 有编排器时改说最容易混的那件事（它管不到录像文件）。
        Text(
          _coordinator == null
              ? '⚠️ 试听暂时是灰的：语音通道要等第一次点【开始工作】才接上。'
              : '⚠️ 它管不到录像文件里有没有声音 —— 那是下面「录制声音」那一项。',
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  /// 试听：念那句真会播报的「开始录像」。
  ///
  /// ⚠️ **必须走编排器那一个发声漏斗**（`RecordingCoordinator.speak`），
  /// 不在这一页自己判一次 `_voiceOn` —— 那样就有了**第二道闸**，而
  /// `recording_coordinator.dart:679` 明确警告过：闸有两道、通路有两条的话，
  /// 「关掉播报」迟早会有一半失灵。
  ///
  /// ⚠️ 措辞**直接用 `VoicePrompt.startRecording`**，不为试听新造一个枚举值 ——
  /// 那个枚举存在的意义就是「措辞只有一处」，再抄一遍「开始录像」就是第二处。
  ///
  /// ⚠️ **不查许可。** 手机端整条链路没有任何许可判断（`04-许可设计.md`：手机端免费），
  /// 试听也不许是第一个。
  Future<void> _previewVoice() async {
    await _coordinator?.speak(VoicePrompt.startRecording);
  }

  // ── ②d 录制声音（需求方 2026-09-28 新增）──────

  /// 录像**文件里**带不带声音。
  ///
  /// ⚠️ 图标是**麦克风**不是喇叭 —— 需求方 2026-09-28 看过之后点名换的：
  /// 喇叭会和上面「语音提示」那张卡混起来，而这是**两件不同的事**
  /// （一个管这台手机出不出声，一个管录进去的文件里有没有音轨）。
  ///
  /// ⚠️ 它**等下次「开始工作」**才生效（跟着编排器重建走），见 [_whenCard]。
  Widget _recordAudioCard() {
    return _settingCard(
      icon: Icons.mic_none,
      title: '录制声音',
      blurb: '关闭后录像不带声音。',
      children: [
        SwitchListTile(
          key: const Key('settings-record-audio-switch'),
          contentPadding: EdgeInsets.zero,
          value: _recordAudio,
          onChanged: _settingsReady
              ? (value) => _updateSettings(recordAudio: value)
              : null,
          title: Text(_recordAudio ? '开启' : '关闭'),
          subtitle: const Text(
            '与「语音提示」是两件事：那一项管这台手机出不出声，'
            '这一项只管录像文件里有没有音轨。两个可以同时开 —— '
            '那时播报会被录进录像里。',
          ),
        ),
      ],
    );
  }

  // ── ②e 网盘视频 / 关于我们：两个二级页的入口 ───

  /// 一行 + 右箭头 → 二级页。**不改 `_tab` 那套** —— 照本页已有的先例
  /// `Navigator.push` 推上去，页里带 `AppBar` 返回。
  Widget _linkCard({
    required IconData icon,
    required String title,
    required String blurb,
    required VoidCallback onTap,
  }) {
    return _settingCard(
      icon: icon,
      title: title,
      blurb: blurb,
      children: [
        ListTile(
          key: Key('settings-link-$title'),
          contentPadding: EdgeInsets.zero,
          title: const Text('打开'),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: onTap,
        ),
      ],
    );
  }

  Widget _netdiskCard() => _linkCard(
        icon: Icons.cloud_outlined,
        title: '网盘视频',
        blurb: '把录像上传到网盘之后，按单号查回来播放。',
        onTap: _openNetdiskPage,
      );

  Widget _aboutCard() => _linkCard(
        icon: Icons.info_outline,
        title: '关于我们',
        blurb: '版本号、一句话介绍，以及把日志导出来发给我们。',
        onTap: _openAboutPage,
      );

  void _openNetdiskPage() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // ⚠️ 把 `_client` 与 `_rootPath` 带过去：借令牌要走前者（没配对时是
        // null，那一页会如实说明并只留「自己登录」），令牌与下载都落在后者下面。
        builder: (context) => NetdiskPage(
          client: _client,
          rootPath: _rootPath,
          // 扫面单复用同一个页面与同一套相机协调 —— 尤其
          // `closeCameraWhenDone`：录制中、或发货栏取景框开着时**不能关**相机，
          // 那会掐掉别人的会话。
          onScan: (pageContext) => ScanWaybillPage.open(
            pageContext,
            gateway: _gateway,
            closeCameraWhenDone: _coordinator?.isCameraOpen != true,
            spec: _coordinator?.effectiveSpec ?? _requestedSpec(),
          ),
        ),
      ),
    );
  }

  void _openAboutPage() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 导出那件事**借这里的 state 干**（包里那几样只有这一页有）。
        builder: (context) =>
            AboutPage(onExportLogs: () => _exportDiagnostics(share: true)),
      ),
    );
  }

  // ── ① 工作模式 ───────────────────────────────

  Widget _modeCard() {
    final scheme = Theme.of(context).colorScheme;

    return _settingCard(
      icon: Icons.check_box_outlined,
      title: '工作模式',
      blurb: '决定这一件什么时候算录完（规格 §3.3.1）。',
      children: [
        SegmentedButton<WorkMode>(
          segments: const [
            ButtonSegment(value: WorkMode.continuousScan, label: Text('连续扫码')),
            ButtonSegment(value: WorkMode.sameWaybillStop, label: Text('同码停录')),
            ButtonSegment(
                value: WorkMode.scanThenStaticStop, label: Text('扫码静止停录')),
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

        const Divider(height: 28),

        _settingRow(
          '面单条码最短长度',
          _settingDropdown<WaybillMinLength>(
            key: 'settings-waybill-min-length',
            value: _waybillMinLength,
            values: WaybillMinLength.values,
            label: (value) => value.label,
            onChanged: (value) => _updateSettings(waybillMinLength: value),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '相机扫到的条码短于这个位数就当成误识，不触发录制 —— '
          '挡的是货架条码、包装上的别的码、别家快递的面单这类东西。\n'
          '⚠️ 只管相机：手工敲进去的单号不受这一项限制。',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  static String _modeTitle(WorkMode mode) => switch (mode) {
        WorkMode.continuousScan => '连续扫码 —— 换件换段',
        WorkMode.sameWaybillStop => '同码停录 —— 复扫同码就停',
        WorkMode.scanThenStaticStop => '扫码静止停录 —— 静止够时长才停',
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
              '三个模式里只有它不用人额外做什么就能自己停。\n'
              '扫到别的单号不会停、也不会换段 —— 那是错码保护（§3.3.2），'
              '只出声提醒，直到扫回本件面单才停。',
        WorkMode.scanThenStaticStop =>
          '识别到单号就开录。包裹要先离开画面、再回到画面，'
              '并且静止够下面设的时长才停。\n'
              '注意：这个模式下复扫同码不停，只认静止 —— '
              '这就是它和「同码停录」的区别。\n'
              '扫到别的单号不会停、也不会换段 —— 那是错码保护（§3.3.2），'
              '只出声提醒。',
      };

  // ── ①b 录制规格（规格 §3.1.7）─────────────────

  /// 编码 / 分辨率 / 方向。
  ///
  /// ⚠️ 2026-09-28 起**拆成三张卡**（需求方那张图上是三张）。
  /// 在这之前它们是一张卡里三个 `Divider` 段。
  ///
  /// ## 三条界面规矩（拆卡后一条没松）
  ///
  /// ① 编码名**只写「H.265」**，不许出现 HEVC —— 名字由
  ///    `RecordingSpec.codecLabel` 一处产出（规格原话：两个名字混用会让用户
  ///    以为是两种不同的编码）。
  /// ② 帧率**没有选项**：规格是「上限 30、不提供选择」，所以每个档位的说明里
  ///    只把它写成一句话。摆一个只有一个选项的下拉是骗人的。
  /// ③ **实际用哪一档必须说出来**（规格：**回落必须可见**、**不得静默回落**），
  ///    见 [_resolutionCard] 底下那一块。
  Widget _codecCard() {
    return _settingCard(
      icon: Icons.code,
      title: '录像编码',
      blurb: '兼容优先，还是体积优先 —— 按播放环境和存储空间选。',
      children: [
        SegmentedButton<VideoCodec>(
          key: const Key('settings-codec'),
          segments: const [
            ButtonSegment(value: VideoCodec.h264, label: Text('H.264 兼容优先')),
            ButtonSegment(value: VideoCodec.h265, label: Text('H.265 更省空间')),
          ],
          selected: {_codec},
          onSelectionChanged: _settingsReady
              ? (value) => _updateSettings(codec: value.first)
              : null,
        ),
        const SizedBox(height: 8),
        Text(_codecBlurb(_codec), style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  /// 选中的那一档编码的一句话说明。
  ///
  /// ⚠️ H.265 那句里的**电脑端网页回放**限制是**必须留着**的：它是本机
  /// 真实存在的限制（见 `实现决策.md` 与母仓 §3.4），藏起来的话用户选了
  /// H.265、回头在电脑上播不了，只会以为录像坏了。
  static String _codecBlurb(VideoCodec codec) => switch (codec) {
        VideoCodec.h264 =>
          '兼容性最好，几乎所有手机都能播放；文件体积约增加 30-40%。',
        VideoCodec.h265 =>
          '同画质下体积小一半左右。⚠️ 电脑端的网页回放对 H.265 支持不一致，'
              '可能播不了 —— 那时用系统播放器打开就行，录像本身没问题。',
      };

  Widget _resolutionCard() {
    final scheme = Theme.of(context).colorScheme;
    final effective = _coordinator?.effectiveSpec;
    final reason = _coordinator?.specFallbackReason;

    return _settingCard(
      icon: Icons.hd_outlined,
      title: '录像规格',
      blurb: '越大越清楚、也越占地方。清理时的容量预告按这一档算。',
      children: [
        SegmentedButton<VideoResolution>(
          key: const Key('settings-resolution'),
          segments: const [
            ButtonSegment(value: VideoResolution.uhd4K, label: Text('4K')),
            ButtonSegment(value: VideoResolution.p1080, label: Text('1080p')),
            ButtonSegment(value: VideoResolution.p720, label: Text('720p')),
          ],
          selected: {_resolution},
          onSelectionChanged: _settingsReady
              ? (value) => _updateSettings(resolution: value.first)
              : null,
        ),
        const SizedBox(height: 8),
        Text(_resolutionBlurb(_resolution), style: const TextStyle(fontSize: 12)),

        const SizedBox(height: 16),

        // 「实际按 X 录制」—— 规格那句「不得静默回落」的落点。
        // ⚠️ 它说的是**整档规格**（编码 + 分辨率 + 方向），不只是分辨率 ——
        // 但它挂在三张卡里名字最对得上的这一张上。
        Container(
          key: const Key('settings-effective-spec'),
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: reason == null
                ? scheme.surfaceContainerHighest
                : Palette.amberTint,
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
              color: reason == null ? null : Palette.amber,
            ),
          ),
        ),
      ],
    );
  }

  /// 一档分辨率的一句话说明。句式照需求方那张图：`宽 × 高 · 30 帧 · 一句评价`。
  ///
  /// ⚠️ 写的**永远是横过来的那组尺寸**（`1280 × 720`），竖屏时也不换成
  /// `720 × 1280` —— 用户是按「720p」这个名字认档位的，需求方图上写的也是这组。
  static String _resolutionBlurb(VideoResolution resolution) => switch (resolution) {
        VideoResolution.uhd4K => '3840 × 2160 · 30 帧 · 最清楚，也最占地方。',
        VideoResolution.p1080 => '1920 × 1080 · 30 帧 · 清楚与体积之间的折中。',
        VideoResolution.p720 => '1280 × 720 · 30 帧 · 更省空间、更流畅。',
      };

  Widget _orientationCard() {
    return _settingCard(
      icon: Icons.screen_rotation_outlined,
      title: '录像方向',
      blurb: '手机怎么拿就选哪个 —— 取景框和画面比例都跟着它走。',
      children: [
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
        const SizedBox(height: 8),
        const Text(
          '水印随录像变换，成片始终位于视觉右上角并保持正向可读。',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  // ── ② 两个兜底档位 ───────────────────────────

  /// 卡片名照需求方那张图改成 `忘记停止录制时的自动兜底`（原来叫「防忘停录」）。
  /// 长了一截，但它把「这是干什么用的」直接说完了 —— 四个字的缩写说不完。
  ///
  /// ⚠️ **两个档位现在都是下拉**（图上就是下拉），`label` 由枚举自己给。
  Widget _fallbackCard() {
    return _settingCard(
      icon: Icons.timer_off_outlined,
      title: '忘记停止录制时的自动兜底',
      blurb: '两个兜底互相独立：关掉一个不影响另一个。任何一个到点，录制就停。',
      children: [
        _settingRow(
          '最长录制时长',
          _settingDropdown<DurationFallbackSetting>(
            key: 'settings-duration-fallback',
            value: _durationFallback,
            values: DurationFallbackSetting.values,
            label: (value) => value.label,
            onChanged: (value) => _updateSettings(durationFallback: value),
          ),
        ),
        const SizedBox(height: 6),

        // ⚠️ 这一段**必须是询问式**。需求方那张图上这里写的是
        // 「自动停止，到点前 30 秒语音提醒」，而裁决是**照规格 §3.3.4**
        // （先问、1 分钟没人理才停）。说明不跟着改的话，界面上就是一句假话 ——
        // 用户会站在原地等那句「还有 30 秒」，然后被直接停掉。
        const Text(
          '不管画面动不动，录满这个时长就语音问一次'
          '「录制时间即将超时，是否需要停止录制？」：\n'
          '· 点【停止】→ 立刻停；\n'
          '· 点【继续】→ 接着录，之后每隔 5 分钟再问一次；\n'
          '· 问完 1 分钟没人理 → 自动停。',
          style: TextStyle(fontSize: 12),
        ),

        const Divider(height: 28),

        _settingRow(
          '画面静止自动停止',
          _settingDropdown<StaticStopSetting>(
            key: 'settings-static-stop',
            value: _staticStop,
            values: StaticStopSetting.values,
            label: (value) => value.label,
            onChanged: (value) => _updateSettings(staticStop: value),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '画面一直不动、够这个时长就停（§3.3.3）。这条不出声 —— '
          '收尾时用户多半已经走开，补一句只会像设备在自言自语。',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  // ── ②c 本地保留期：四个数 ─────────────────────

  /// 本地留多久 —— **发货 / 退货 × 已备份 / 未备份 = 四个数**（规格 §3.5.2.1）。
  ///
  /// ## ⚠️ 2026-09-28 起拆成两张卡
  ///
  /// 需求方 2026-09-24 点名要的摆法是「一张两行两列的表」，2026-09-28 那张
  /// 自绘的图上把它**改成了两张卡**（发货录像清理 / 退货录像清理，各两个下拉），
  /// 照图走。**四个 `Key` 一个没改** —— 换了摆法但没换设置项。
  ///
  /// ## ⚠️ 两列语义**相反**（这一块最要紧的一句话）
  ///
  /// - **已备份**：到期**真删本地副本**（先过 §3.5.4 回查），起算点 = 备份成功时刻；
  /// - **未备份**：到期**只标红、只催上传，永不自动删**，起算点 = 录完时刻。
  ///
  /// 后者是**唯一副本**（I2），删了就永久没了。这段话**必须**让用户看得到 ——
  /// 不写的话，用户要么以为「选了不保留却没反应」是坏了（踩坑 #13），
  /// 要么以为自己选了「马上删」而**不敢选**。
  ///
  /// ⚠️ 拆卡之后它没地方铺了（两张卡各写一遍就是四段重复的⚠️），
  /// 于是收进标题右边那个 `?` 里 —— **图上正好有一个 `?`**，这就是它该待的地方。
  /// 四条一句没删，只是不再常驻。
  ///
  /// ## 为什么手机端没有「归档层」那个下拉（电脑端有）
  ///
  /// 规格 §3.5.1 要求：归档层就是本机磁盘时**不提供**清理选项，
  /// 因为那时本地这份是唯一副本。**那个危险在手机上不存在** ——
  /// 手机的归档层是电脑端（局域网）/ NAS / 网盘，三者都在**别的设备**上。
  /// 所以这里不摆一个「归档层」下拉：它在这台机器上没有第二种可能，
  /// 摆上去就是个改了没反应的开关（踩坑 #13）。
  Widget _retentionCard({required bool outbound}) {
    final side = outbound ? '发货' : '退货';

    return _settingCard(
      icon: outbound
          ? Icons.local_shipping_outlined
          : Icons.assignment_return_outlined,
      title: '$side录像清理',
      blurb: '$side那批在手机上留多久。两个数互相独立 —— 改一个不动另一个。',
      trailing: IconButton(
        key: const Key('settings-retention-help'),
        tooltip: '保留期说明',
        icon: const Icon(Icons.help_outline, size: 20),
        onPressed: _showRetentionHelp,
      ),
      children: [
        // ⚠️ 顺序照图：**未备份**在上。这一栏才是用户真正会踩的那个 ——
        // 它永不自动删，「选了半天没反应」的疑问只会出在这里。
        _settingRow(
          '未备份保留',
          _retentionDropdown(
            outbound
                ? 'settings-retention-unarchived-outbound'
                : 'settings-retention-unarchived-return',
            outbound ? _retentionUnarchivedOutbound : _retentionUnarchivedReturn,
            (value) => _updateSettings(
              retentionUnarchivedOutbound: outbound ? value : null,
              retentionUnarchivedReturn: outbound ? null : value,
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '⚠️ 这一栏永不自动删：还没备份上去的录像在手机上是唯一一份，'
          '删了就永久没了（不变量 I2）。它到期的动作只有提醒 —— '
          '列表标红 + 顶部催上传。',
          style: TextStyle(fontSize: 12),
        ),

        const Divider(height: 28),

        _settingRow(
          '备份后保留',
          _retentionDropdown(
            outbound
                ? 'settings-retention-archived-outbound'
                : 'settings-retention-archived-return',
            outbound ? _retentionArchivedOutbound : _retentionArchivedReturn,
            (value) => _updateSettings(
              retentionArchivedOutbound: outbound ? value : null,
              retentionArchivedReturn: outbound ? null : value,
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '备份成功后，手机上的原片再留多久 —— 从「备份成功那一刻」起算，'
          '不是从录完起算。这一栏到点会真的删手机上的那份。',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  /// 保留期的四条 ⚠️（需求方点名**必须保留**，只是收进 `?` 里）。
  ///
  /// 用对话框而不是展开/收起：这段字比卡片本身还长，铺在卡里会把两个
  /// 真正要改的下拉挤到屏幕外面去。
  Future<void> _showRetentionHelp() => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('settings-retention-help-dialog'),
          title: const Text('保留期怎么算'),
          content: const SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '⚠️「备份后保留」那一栏：备份成功后，手机上的原片再留多久。'
                  '从「备份成功那一刻」起算，不是从录完起算。',
                  style: TextStyle(fontSize: 13),
                ),
                SizedBox(height: 10),
                Text(
                  '⚠️「未备份保留」那一栏永不自动删除 —— 那是唯一一份，'
                  '删了就没了。它到期的动作只有提醒（列表标红 + 催上传），'
                  '从「录完那一刻」起算。',
                  style: TextStyle(fontSize: 13),
                ),
                SizedBox(height: 10),
                Text(
                  '⚠️「不保留」不是立刻删：最近 24 小时内录的一律不动'
                  '（硬性豁免，关不掉），所以它实际是「备份成功后最快 24 小时清理」。',
                  style: TextStyle(fontSize: 13),
                ),
                SizedBox(height: 10),
                Text(
                  '⚠️ 这一块记的是到期之后该怎么做，而手机端的自动清理还没接通 —— '
                  '今天不会有任何文件自动被删。想现在删就用备份页每一条右边的'
                  '垃圾桶图标（那会先跟电脑端核对，核对不上就不删）。'
                  '另外【被锁定】的证据永远不清。',
                  style: TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );

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

  // ── ③ 验收工具 ───────────────────────────────

  /// 真机验收用的开关。**故意做成一眼能看出不是产品设置的样子**：
  /// 琥珀底 + ⚠️ 标题 + 明说「不落盘」。
  ///
  /// 它不落盘这件事要在界面上说出来 —— 否则验收的人会以为「我上次开了」
  /// 而这次没开，或者反过来以为「我关了它就永久关了」。
  Widget _acceptanceCard() {
    return Card(
      color: Palette.amberTint,
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
  /// ⚠️ 语音提示是**例外**，而且必须在这里写明 —— 否则这块提示本身就成了假话。
  /// 它不参与判定（只出声），关它是「现在太吵」而不是「下一段想这样录」。
  ///
  /// ⚠️ 2026-09-28 加的两项（**面单条码最短长度 / 录制声音**）都归
  /// 「等下次『开始工作』」那一组：两者都是 `_buildCoordinator` 重建编排器时
  /// 才被读一次（条码下限进 `ScanGate`、录制声音进 `startRecording` 的参数）。
  /// 列在这里不是客套 —— 用户改完没反应，只会以为开关坏了。
  Widget _whenCard() {
    final working = _coordinator?.isWorking ?? false;

    return Card(
      color: working ? Palette.amberTint : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          // ⚠️ 全称句每加一个例外都要回头改一遍（踩坑 21）：2026-10-01 加
          // 【实时共享】时核对过一次 —— 它**属于**这一组（要等下次开始工作），
          // 不是例外，所以这两句只多列了一个名字，别的地方一个字没动。
          working
              ? '⚠️ 正在工作中。上面【工作模式】【忘记停止录制时的自动兜底】'
                  '【录像编码/规格/方向】【面单条码最短长度】【录制声音】'
                  '【实时共享】'
                  '改了这一段不生效 —— '
                  '等下次「开始工作」重建编排器时才按新设置走。'
                  '（【实时共享】改成「关」是立刻停的。）'
                  '【语音提示】不受这条限制，它立刻生效。'
              : '【工作模式】【忘记停止录制时的自动兜底】【录像编码/规格/方向】'
                  '【面单条码最短长度】【录制声音】【实时共享】'
                  '在点「开始工作」时生效。'
                  '改完直接去发货栏开始工作就行，不用退出去重进。\n'
                  '【语音提示】是立刻生效的。\n'
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

}

/// 「关于我们」那一页，以及 `appVersion` 这个常量，2026-10-05 搬到
/// `lib/app/about_page.dart`（T26③：这个文件已经 6500 行，先搬走**能整块搬、
/// 又有现成测试**的那一块）。
///
/// ⚠️ 搬走的是位置，**规矩一条没放松**：这一页只显示盘上真有的东西、
/// 不摆点不动的入口、不许出现任何许可相关的东西（L8）——
/// 那些断言还在 `test/about_page_test.dart` 里钉着。

/// 「网盘视频」这一页**已经真接上了**，实现搬到 `lib/app/netdisk_page.dart`
/// （`NetdiskPage`）。
///
/// 2026-10-01 之前它是这里的一个壳：入口照图画出来、控件全灰着、并明说
/// 「网盘那半在电脑端都还没做」。**那个理由已经过期** —— 电脑端批次 5 把网盘
/// 那半做完了，手机端也跟着接上了（登录 / 按后 6 位查 / 下载 / 播放）。
///
/// ⚠️ 有一条规矩**跟着搬过去了、没有放松**：这一页**不许出现任何许可相关的
/// 东西**（L8，手机端整条链路没有许可判断）。那条断言还在
/// `test/about_page_test.dart` 里钉着。

