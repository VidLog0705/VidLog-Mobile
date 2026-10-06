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

  /// 实时共享开着没有（设置里那一项；读不出来时按**关**算）。
  bool get _liveShareOn => _settings?.liveShareEnabled ?? false;

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

  Future<void> _applyLiveShare() async {
    if (_applyingLiveShare) {
      _liveShareAgain = true;
      return;
    }

    _applyingLiveShare = true;
    try {
      do {
        _liveShareAgain = false;
        await _applyLiveShareOnce();
      } while (_liveShareAgain);
    } finally {
      _applyingLiveShare = false;
    }
  }

  Future<void> _applyLiveShareOnce() async {
    final wanted = _liveShareOn && (_coordinator?.isWorking ?? false);

    if (!wanted) {
      await _liveShare?.stop();
      return;
    }

    final service = _liveShare ??= LiveService(
      gateway: ChannelLiveGateway(),
      counts: () => _liveCounter.counts(),
      announce: _announceToDesktop,
    );

    if (service.isRunning) return;

    final failure = await service.start();
    if (failure != null) {
      _reportLiveShareProblem(failure);
      return;
    }

    _reportLiveShareProblem(null);
  }

  /// 推流出事时**当场说一句**（起不来、被录制压力停掉）。
  ///
  /// ⚠️ 2026-10-03（需求方）：设置页那张「实时共享」卡整个删掉了 ——
  /// 那句话原先只有那张卡说得出口。改成**出事那一刻弹一条**，
  /// 采集页右上角那颗图标继续用变色表示「它现在有事」（按下去也还会再说一遍）。
  ///
  /// ⚠️ 删了卡还不出声，就成了规格 §3.8 第 3 条明禁的那种：
  /// 「刚才还有画面，怎么没了」而界面上一个字都没有。
  void _reportLiveShareProblem(String? problem) {
    if (!mounted) return;

    // 没变就别刷 —— 这条在每次「开始工作」上都会走一遍。
    if (_liveShareProblem != problem) {
      setState(() => _liveShareProblem = problem);
    }

    // 自愈了不打扰（图标自己会恢复）；出事才说。
    if (problem != null) _snack(problem);
  }

  /// 向电脑端报到（规格 §3.8 的机位发现）。
  ///
  /// ⚠️ **读的是当前那个 `_client`，不是建服务时捕获的那个** ——
  /// 重新配对 / 改地址之后上传器会整个重建，捕获旧的那个会把报到打到
  /// 一台已经不用的电脑上。
  Future<String?> _announceToDesktop(int port) async {
    final client = _client;
    if (client == null) return '还没配好电脑端';

    return client.announceLive(port);
  }

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
    // 相机开着的话，**连「它是按什么开的」一起继承**（`dispose` 之前读）。
    //
    // 只传「开着」是不够的：新编排器如果以为「从来没开过」，它开相机那一步
    // 就判不出「录音开关变了没有」，于是那一趟 `gateway.openCamera` 带着新的
    // 开关过去、原生却因为会话已经开着直接早退 —— 麦克风根本没加进去。
    // 结果是开关打开、文件里没有声音，而且一句话都不报（踩坑 #13）。
    final cameraWasOpen = _coordinator?.isCameraOpen ?? false;
    final appliedSpec = _coordinator?.appliedSpec;
    final appliedAudio = _coordinator?.appliedAudio;
    final appliedLive = _coordinator?.appliedLive;
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
      appliedSpec: appliedSpec,
      appliedAudio: appliedAudio,
      appliedLive: appliedLive,
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
    )
      ..onBarcodeAccepted = _onBarcodeAccepted
      ..onBarcodeTooShort = _onBarcodeTooShort;

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

      case WarnResource(:final reason):
        // 设备资源告警（规格 §3.1.1）—— 让用户看见「为什么突然停了」。
        //
        // ⚠️ 与 `Speak` 那条**不是一回事**：语音说过就没了，而这一条要在屏幕上
        // **留着**（它是 `_status`，会一直显示到下一次状态变化）——
        // 操作员错过那一句语音时，至少能从界面上看出是过热/电量/存储。
        setState(() => _status = '资源告警（$reason）· 正在收尾');
        _log('⚠️ 资源告警 · $reason');

        // 规格 §3.8 第 3 条（该让就让）：录制侧报压力 ⇒ **自动停掉推流**。
        //
        // ⚠️ 前两条（不阻塞、不传染）只挡得住**代码层面**的互相拖累；
        // 推流白耗的 CPU 与热量是**整机共享**的，那会实打实地让录制掉帧。
        // 这一条是三条里最后一道闸。**录制是证据，推流是便利。**
        if (_liveShare?.isRunning ?? false) {
          _reportLiveShareProblem('录制吃紧（$reason），已自动停掉实时共享。');
          unawaited(_liveShare?.notifyRecordingPressure(reason));
        }

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

    // 多画面每格下面那对 `F` / `T`（规格 §3.8 ⑥）。
    //
    // ⚠️ 用的是**粘性的** `_businessType`（跟着 `_workTab` 走），不是 `_tab`：
    // 人切到设置页翻一眼时换件也会开新段，那个新段落的标签用的就是 `_workTab`
    // —— 计数必须与**这段录像最后被打上什么标签**是同一个来源，
    // 否则屏幕上那个 `F` 会比录像里的标签多一件或少一件。
    _liveCounter.record(_businessType);
  }

  /// 扫到了，但**太短**，于是没录。
  ///
  /// ⚠️ 这一行不是可有可无的装饰：不加的话，用户对着一张真面单扫了半天，
  /// 屏幕上什么都不会发生 —— 而「框外」「太短」「还在画面里」这三种在界面上
  /// 长得**一模一样**，都是毫无反应。人只会得出「相机坏了」这一个结论。
  /// 说清楚是哪一种，才知道该去改设置还是该挪一下手机。
  void _onBarcodeTooShort(String text, int minLength) {
    _log('📷 扫到 $text，只有 ${text.length} 位、短于设定的 $minLength 位 —— 不触发录制');
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

  /// 把系统那个麦克风授权框弹出来（录制声音开着时才问）。
  ///
  /// ⚠️ **结果故意不听**（不变量 I4）：没有麦克风权限只是「这一段没有音轨」，
  /// 绝不挡录像 —— 所以这里不设状态、不 return，与上面那段相机权限刚好相反。
  ///
  /// 唯一的目的是**让那个框出现**：不弹的话原生那边 `AVCaptureDeviceInput` /
  /// `AudioRecord` 会静静地失败，用户看到的就是一个「打开了却永远没声音」的
  /// 开关（踩坑 #13）。已经问过时两端原生都直接回当前答案、不再弹框。
  ///
  /// ⚠️ **必须在开相机会话之前**：麦克风是在配置会话那一步加进去的
  /// （`CameraSegmentRecorder.openCamera`），会话建好之后补不上。
  Future<void> _askForMicrophoneIfNeeded() async {
    if (!_recordAudio) return;
    await _gateway.requestMicrophonePermission();
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

      await _askForMicrophoneIfNeeded();

      await coordinator.openCamera();

      // 相机开起来之后才问得到设备范围（规格 §3.1.2）。
      await _readDeviceCapabilities();

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

      await _askForMicrophoneIfNeeded();

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

      // 计数器从这一刻起算（需求方 2026-10-01：「本次开始工作以来，到结束」）。
      // ⚠️ 在 `startWorking` **之后**归零：相机没开起来就不算开始工作，
      // 而那一条路径会 `return`（上面几处），不该把上一班的数字抹掉。
      _liveCounter.reset();

      // 实时共享（规格 §3.8）：相机刚开起来，现在才推得动。
      unawaited(_applyLiveShare());

      _log('开始工作 · 模式 ${_modeLabel(_mode)}');
      _startHeartbeat();

      // 相机开起来之后才问得到设备上限（规格 §3.1.2）——
      // 表盘的刻度要画到设备的真实上限，不然划到底是 8 倍、画面却停在 2 倍。
      await _readDeviceCapabilities();

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

  /// 相机开起来之后问一次设备能力：变焦范围（定表盘两端，规格 §3.1.2）
  /// 与**有没有闪光灯**（定右上角那个手电筒按钮画不画）。
  ///
  /// **拿不到就用默认值**：问了不代表问得到（Android 端的通道还没接上、
  /// 或者相机刚开、设备还没报能力）。为这个把「开始工作」弄失败是本末倒置。
  ///
  /// 范围的取舍与不变量收在 [zoomRangeFrom] 里（有测试）——
  /// 这里只负责把问到的两个数递过去。
  Future<void> _readDeviceCapabilities() async {
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

    // ⚠️ **单独一个 try**：闪光灯那一条在装的是旧包时必然抛
    // （通道上没这个方法），而那时变焦范围是问得到的 ——
    // 合成一个 try 会让「手电筒没有」连带把表盘刻度也打回默认值。
    bool? torch;
    try {
      torch = await _gateway.hasTorch();
    } on Object catch (error) {
      // 不留痕的话，「这台手机为什么没有手电筒按钮」就没有任何地方能回答
      //（旧包、通道没接上都走到这儿）。一次【开始工作】一条，淹不了日志。
      _log('⚠️ 问不到这台设备有没有闪光灯：$error');
      torch = null;
    }

    if (!mounted) return;
    setState(() {
      final (lower, upper) = zoomRangeFrom(min, max);
      _minZoom = lower;
      _maxZoom = upper;
      // ⚠️ 灯跟着相机设备：新会话起来时它**一定是灭的**，所以这里无条件归位。
      // 不归位的话，上一趟开着灯、这一趟图标亮着而灯不亮。
      _torchOn = false;
      _torchUsable = torch;
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

    // 实时共享跟着停：相机马上要关了，没有画面可推（规格 §3.8）。
    // ⚠️ **不等它**：推流的收尾（收编码器、关 HTTP）是几百毫秒的事，
    // 而用户按了【结束】要立刻听到那句播报 —— 等它就是把「滞」加到反馈上。
    unawaited(_liveShare?.stop());

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

      // 资源告警（规格 §3.1.1）：存储将满 / 低电量 / 过热 ⇒ 提前告警 + 主动收尾。
      //
      // ⚠️ **节流到 30 秒一次**：心跳是每秒的，而这三样变化的时间尺度是**分钟**
      // （电量、剩余空间、温度都不会一秒一变）。每秒过一趟原生通道是白花钱 ——
      // 而这个仓已经因为「白跑的定时器」吃过一次亏（§39.4 那条 flake）。
      final now = DateTime.now();
      final last = _resourcesReadAt;
      if (last == null || now.difference(last) >= _resourcePollInterval) {
        _resourcesReadAt = now;
        unawaited(_readResources());
      }
    });
  }

  /// 上一次读资源的时间（规格 §3.1.1）。见 `_startHeartbeat` 里的节流理由。
  DateTime? _resourcesReadAt;

  /// 资源读取的间隔。**30 秒**是本仓标定的（规格没给数）：
  /// 够快（电量从阈值掉到关机不止 30 秒），又不至于每秒过一趟通道。
  static const _resourcePollInterval = Duration(seconds: 30);

  /// 读一次资源并喂给状态机（规格 §3.1.1）。
  ///
  /// ⚠️ **缺失的项不填 0**：原生回的空 Map 或少数几项就是「那些项不参与判定」。
  /// 判据在 `StopController._onResource`（那里逐个判 `!= null`）。
  Future<void> _readResources() async {
    final Map<Object?, Object?> raw;

    try {
      raw = await _gateway.readResources();
    } on Object catch (error) {
      // 读不到不是错误（老包没有这个方法、平台异常）—— 这一轮就不喂。
      _log('读资源失败：$error');
      return;
    }

    if (!mounted) return;

    final thermal = raw['thermal'];

    await _coordinator?.onResourceReported(
      freeStorageBytes: raw['freeStorageBytes'] as int?,
      batteryPercent: raw['batteryPercent'] as int?,
      // ⚠️ 原生报的是**档位序号**（与 `ThermalLevel` 一一对齐，两边都由轻到重）。
      // 用 `fromConfig` 解析：它认得 int 与名字两种写法，越界回落 `nominal`。
      thermal: thermal == null ? null : ThermalLevel.fromConfig(thermal),
    );
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
          title: session.waybill.value.isEmpty ? session.sessionId : session.waybill.value,
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
          audit: CleanupAuditLog('$root/cleanup-audit.jsonl'),
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
                    style: TextStyle(
                      fontSize: 12,
                      color: full ? Palette.amber : Palette.muted,
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

