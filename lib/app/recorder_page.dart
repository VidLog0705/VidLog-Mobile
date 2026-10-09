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
import 'cleanup_log_page.dart';
import 'corners.dart';
import 'netdisk_page.dart';
import 'palette.dart';
import 'record_detail_page.dart';
import 'scan_connect_page.dart';
import 'scan_waybill_page.dart';
import 'text_scale.dart';
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
part 'recorder_settings.dart';
part 'recorder_settings_spec.dart';
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
///
/// ⚠️ **这一层冻的是配色，不是字号**（2026-10-09 起）。字号读 `TextScale`
/// —— 全应用唯一那一份定义。它包的是**整个工作页**（`recorder_view_work.dart`
/// 的 `_workPage`，`Theme(data: _cameraOverlayTheme, ...)`），所以工作页上
/// 每一句说明、每一个小标都在这一层里；不跟着读的话，同一句说明在设置页
/// 是 13、在采集页还是 12。
/// 这里读进去的**只有字号与字重**（那一份只定义了这两样），字色仍由这一层
/// 自己的亮色默认给 —— 所以暗色下不会变成白字压白底。
final _cameraOverlayTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: Color(0xFF1565C0)),
  textTheme: TextScale.theme,
);

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

class _RecorderPageState extends State<RecorderPage>
    with WidgetsBindingObserver {
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

  /// 系统那一套是亮是暗。`ThemeMode.system` 挑的就是它（`main.dart`）。
  ///
  /// ⚠️ 只给日志用。**界面里不许拿它判自己该是什么色** —— 那样写出来的控件
  /// 在主题里就是死色（`palette.dart` 那份说明里的同一条）。
  String get _themeName =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark
          ? '暗色'
          : '亮色';

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

    // 系统换配色时界面会跟着整套换 —— 那一刻要留一条。
    // 挂在这一页上（而不是 `main.dart` 那个 `VidLogApp`）：应用只有这一屏，
    // 而且**日志要等 `_bootstrap` 里 `AppLog.init` 之后才落得了盘**，
    // 那是这一页的生命周期里发生的事。启动时那一条在 `_bootstrap` 里记。
    WidgetsBinding.instance.addObserver(this);
  }

  /// ⚠️ 这条只在**系统配色真的换了**时被调（同一个值不会重放）。
  ///
  /// 记它的理由与启动那一条不同：用户在暗色下待一会儿再报「看不清」时，
  /// 光看启动那一条会以为整套是亮色的 —— 而**中间换过一次**这件事
  /// 只有这里说得出来。
  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    _log('系统配色换了：$_themeName');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
            Text(
              '填电脑端那台机器的局域网 IP。填完还要配对一次它才会收下'
              '这台手机的录像。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.palette.muted),
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

