/// 未校准不得录制 + 跳变检测（规格 §3.6.3 / §3.6.4）。
///
/// 规格 2026-09-24 的需求变更，也是 I10 被**主动收窄**的那一条：
/// 原文是绝对的「无网可用」，现在改成「**已校准之后**的无网可用」。
///
/// ## 时间线 = 锚 + 单调读数，与墙钟无关
///
/// 规格 §3.6.3：「**水印与时长都不得取自墙钟** —— 用户改系统时间**不得**改变
/// 视频里的时间」。所以录制的时刻由「外部时间锚 + 之后走了多久」推出来。
///
/// ## 两个来源，取到任何一个即算校准（规格 §3.6.4）
///
/// | 来源 | 什么时候拿得到 |
/// |---|---|
/// | 公网时间服务（HTTP Date） | 这台设备自己能上网时 —— **手机端可以绕开电脑端直接用它** |
/// | 归档回执里的外部时间锚 | 与电脑端归档成功一次之后（局域网即可，不需要公网） |
///
/// 与电脑端 `VidLog.Desktop.Core/Clock/TrustedClock.cs` 是**同一份规格的两半**：
/// 时间线、跳变判据、容差、落盘形态都逐个对齐。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../diagnostics/app_log.dart';
import 'recording_workspace.dart' show writeFileAtomically;

/// 校准的来源。枚举值**与电脑端同一个顺序**（落进 JSON 的就是它）。
enum CalibrationSource {
  /// 公网时间服务（HTTP `Date` 头）。
  publicTime,

  /// 归档回执里的时间锚（`Receipt.timeAnchor`）。
  archiveReceipt,
}

/// 一次墙钟跳变。
class JumpRecord {
  const JumpRecord({
    required this.detectedAt,
    required this.wallClockDeltaSeconds,
    required this.monotonicDeltaSeconds,
    required this.backwards,
  });

  final DateTime detectedAt;
  final double wallClockDeltaSeconds;
  final double monotonicDeltaSeconds;

  /// 是不是「往回调」—— 伪造更早的证据，I11 点名的那一种。
  final bool backwards;

  Map<String, Object?> toJson() => {
        'DetectedAtUtc': detectedAt.toUtc().toIso8601String(),
        'WallClockDeltaSeconds': wallClockDeltaSeconds,
        'MonotonicDeltaSeconds': monotonicDeltaSeconds,
        'Backwards': backwards,
      };

  static JumpRecord? tryFromJson(Map<String, Object?> json) {
    final at = DateTime.tryParse(json['DetectedAtUtc'] as String? ?? '');
    if (at == null) return null;

    return JumpRecord(
      detectedAt: at.toLocal(),
      wallClockDeltaSeconds: (json['WallClockDeltaSeconds'] as num?)?.toDouble() ?? 0,
      monotonicDeltaSeconds: (json['MonotonicDeltaSeconds'] as num?)?.toDouble() ?? 0,
      backwards: json['Backwards'] == true,
    );
  }
}

/// 落盘的校准状态。**键名与电脑端逐字一致**（PascalCase）。
class CalibrationState {
  const CalibrationState({
    this.anchorUtc,
    this.monotonicAtAnchor,
    this.source = CalibrationSource.publicTime,
    this.calibratedAt,
    this.lastSeenWallClockUtc,
    this.lastSeenMonotonic,
    this.jumps = const [],
    this.needsRecalibration = false,
  });

  /// 外部时间锚（用户改不了）。
  final DateTime? anchorUtc;

  /// 拿到锚那一刻的**单调**读数（秒）。
  final double? monotonicAtAnchor;

  final CalibrationSource source;
  final DateTime? calibratedAt;

  /// 上次核对时的墙钟与单调读数 —— 与 [monotonicAtAnchor] 一起用来判跳变。
  final DateTime? lastSeenWallClockUtc;
  final double? lastSeenMonotonic;

  final List<JumpRecord> jumps;

  /// 上次核对发现跳变、因此**要求重新校准**。
  final bool needsRecalibration;

  static const empty = CalibrationState();

  CalibrationState copyWith({
    DateTime? anchorUtc,
    double? monotonicAtAnchor,
    CalibrationSource? source,
    DateTime? calibratedAt,
    DateTime? lastSeenWallClockUtc,
    double? lastSeenMonotonic,
    List<JumpRecord>? jumps,
    bool? needsRecalibration,
  }) =>
      CalibrationState(
        anchorUtc: anchorUtc ?? this.anchorUtc,
        monotonicAtAnchor: monotonicAtAnchor ?? this.monotonicAtAnchor,
        source: source ?? this.source,
        calibratedAt: calibratedAt ?? this.calibratedAt,
        lastSeenWallClockUtc: lastSeenWallClockUtc ?? this.lastSeenWallClockUtc,
        lastSeenMonotonic: lastSeenMonotonic ?? this.lastSeenMonotonic,
        jumps: jumps ?? this.jumps,
        needsRecalibration: needsRecalibration ?? this.needsRecalibration,
      );

  Map<String, Object?> toJson() => {
        'AnchorUtc': anchorUtc?.toUtc().toIso8601String(),
        'MonotonicAtAnchor': monotonicAtAnchor,
        'Source': source.index,
        'CalibratedAtUtc': calibratedAt?.toUtc().toIso8601String(),
        'LastSeenWallClockUtc': lastSeenWallClockUtc?.toUtc().toIso8601String(),
        'LastSeenMonotonic': lastSeenMonotonic,
        'Jumps': [for (final jump in jumps) jump.toJson()],
        'NeedsRecalibration': needsRecalibration,
      };

  /// 宽容地读。**读坏了当作「没校准过」**（保守那头）——
  /// 两个方向的代价不对称：当作没校准只是录不了像（看得见、说得清），
  /// 当作已校准会让录出来的东西时间不可信。
  static CalibrationState fromJson(Map<String, Object?> json) {
    final jumps = <JumpRecord>[];
    for (final raw in (json['Jumps'] as List?) ?? const []) {
      if (raw is Map) {
        final jump = JumpRecord.tryFromJson(raw.cast<String, Object?>());
        if (jump != null) jumps.add(jump);
      }
    }

    return CalibrationState(
      anchorUtc: DateTime.tryParse(json['AnchorUtc'] as String? ?? '')?.toLocal(),
      monotonicAtAnchor: (json['MonotonicAtAnchor'] as num?)?.toDouble(),
      source: switch ((json['Source'] as num?)?.toInt()) {
        1 => CalibrationSource.archiveReceipt,
        _ => CalibrationSource.publicTime,
      },
      calibratedAt: DateTime.tryParse(json['CalibratedAtUtc'] as String? ?? '')?.toLocal(),
      lastSeenWallClockUtc:
          DateTime.tryParse(json['LastSeenWallClockUtc'] as String? ?? '')?.toLocal(),
      lastSeenMonotonic: (json['LastSeenMonotonic'] as num?)?.toDouble(),
      jumps: jumps,
      needsRecalibration: json['NeedsRecalibration'] == true,
    );
  }
}

/// 判定容差（秒）。
///
/// ⚠️ **这个数是本仓标定的，不是规格里写的** —— 规格 §3.6.3 明说「这类阈值要真机
/// 标定……由实现标定并记进该仓的 `docs/实现决策.md`」。取 **120 秒**的理由与电脑端
/// 逐字相同：NTP 校正是毫秒到秒级、时区变更与用户改时间是小时级。
const double jumpThresholdSeconds = 120;

/// 校准状态的读写（`<root>/calibration.json`）。
class CalibrationStore {
  CalibrationStore(this.path);

  final String path;

  Future<CalibrationState> load() async {
    final file = File(path);
    if (!await file.exists()) return CalibrationState.empty;

    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      return CalibrationState.fromJson(json);
    } on Object {
      // 读坏了**当作没校准过**（见 `CalibrationState.fromJson` 的说明）。
      return CalibrationState.empty;
    }
  }

  Future<void> save(CalibrationState state) async {
    final file = File(path);
    await file.parent.create(recursive: true);

    await writeFileAtomically(path, jsonEncode(state.toJson()));
  }
}

/// 一个外部时间源 —— 问它「现在几点」。
abstract interface class ClockSource {
  /// 取一个外部时刻。取不到就抛（由调用方决定怎么告诉用户）。
  Future<DateTime> query();

  String get description;
}

/// 公网时间：读 HTTP 响应的 `Date` 头。
///
/// ⚠️ **用 HTTP Date 而不是 NTP**（规格允许两者取一）：NTP 要走 UDP 123，
/// 在手机的网络环境里更容易被拦；HTTP 走 443，**与这台手机上用的是同一条路**。
/// 精度是**秒级**，而且信任中间那段网络 —— 对这份用途够用：要挡的是
/// 「用户手动改系统时间」，不是国家级对手（规格也明令**不得宣传「不可篡改的时间」**）。
class HttpDateClockSource implements ClockSource {
  HttpDateClockSource({
    List<String>? urls,
    this.timeout = const Duration(seconds: 5),
    HttpClient Function()? httpFactory,
  })  : urls = urls ?? const ['https://www.baidu.com/', 'https://www.aliyun.com/'],
        _httpFactory = httpFactory ?? HttpClient.new;

  final List<String> urls;
  final Duration timeout;
  final HttpClient Function() _httpFactory;

  @override
  String get description => '公网时间服务（HTTP Date）';

  @override
  Future<DateTime> query() async {
    Object? last;

    for (final url in urls) {
      final client = _httpFactory();
      client.connectionTimeout = timeout;

      try {
        final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
        final response = await request.close().timeout(timeout);

        // ⚠️ **只读头、不读体**：要的是 `Date` 头，把整个页面收下来
        // 只是白花流量（而且那上面可能有几百 KB）。
        await response.drain<void>();

        final header = response.headers.value(HttpHeaders.dateHeader);
        final parsed = _parseHttpDate(header);
        if (parsed != null) return parsed;

        last = '响应里没有可用的 Date 头';
      } on Object catch (error) {
        last = error;
      } finally {
        client.close(force: true);
      }
    }

    throw StateError('取不到公网时间（试过 ${urls.length} 个地址）。最后一次失败：$last');
  }
}

/// 解析 HTTP 的 `Date` 头（RFC 1123）。
///
/// ⚠️ **只认这一种格式**：放宽成 `DateTime.parse` 会把本机区域格式卷进来，
/// 而这条路径要的是一个**外部**时刻，不该受本机设置影响。
DateTime? _parseHttpDate(String? value) {
  if (value == null || value.trim().isEmpty) return null;

  // Dart 没有现成的 RFC 1123 解析，手写一个（形态固定：`Tue, 15 Nov 1994 08:12:31 GMT`）。
  final match = RegExp(
    r'^[A-Za-z]{3}, (\d{1,2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  ).firstMatch(value.trim());

  if (match == null) return null;

  const months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };

  final month = months[match.group(2)!];
  if (month == null) return null;

  return DateTime.utc(
    int.parse(match.group(3)!),
    month,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
  ).toLocal();
}

/// 可信时钟 —— 录制的**唯一**时间来源。
class TrustedClock {
  TrustedClock({
    required CalibrationState initialState,
    required CalibrationStore store,
    Duration Function()? monotonic,
    ClockSource? publicSource,
    AppLog? log,
  }) {
    _state = initialState;
    _store = store;
    _monotonic = monotonic ?? _defaultMonotonic();
    _publicSource = publicSource;
    _log = log;
  }

  late final CalibrationStore _store;
  late final Duration Function() _monotonic;
  late final ClockSource? _publicSource;
  late final AppLog? _log;

  late CalibrationState _state;

  /// 进程内一个从构造时开始走的秒表 —— 与电脑端 `TrustedClock` 同一手法。
  static Duration Function() _defaultMonotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  CalibrationState get state => _state;

  bool get isCalibrated =>
      !_state.needsRecalibration &&
      _state.anchorUtc != null &&
      _state.monotonicAtAnchor != null;

  /// 可信的当前时刻。
  ///
  /// ⚠️ 未校准时**不要用它** —— 调用方要先看 [isCalibrated]。
  DateTime get now {
    final anchor = _state.anchorUtc;
    final origin = _state.monotonicAtAnchor;

    if (anchor == null || origin == null) return DateTime.now();

    return anchor.add(_monotonic() - Duration(milliseconds: (origin * 1000).round()));
  }

  /// 不能录时的原因（给用户看的那句话）；能录时为 null。
  String? get blockedReason {
    if (isCalibrated) return null;

    return _state.needsRecalibration
        ? '这台手机的系统时间被改过，需要联一次网（或者跟电脑端成功备份一次）重新校准。'
        : '这台手机还没有过一次可信的时间校准，按规格 §3.6.4 不能开始录制。';
  }

  /// 启动时核对一次：挂钟与上次退出时留下的记录自不自洽（规格 §3.6.3）。
  ///
  /// 返回 true 表示发现跳变（那时 [isCalibrated] 会变成 false）。
  Future<bool> checkStartup() async {
    final wall = DateTime.now();
    final monotonic = _monotonic();

    final verdict = _judge(_state, wall, monotonic);

    if (verdict == null) {
      _state = _state.copyWith(
        lastSeenWallClockUtc: wall,
        lastSeenMonotonic: monotonic.inMilliseconds / 1000,
      );

      await _store.save(_state);
      return false;
    }

    final (delta, monotonicDelta, backwards) = verdict;

    _state = _state.copyWith(
      needsRecalibration: true,
      lastSeenWallClockUtc: wall,
      lastSeenMonotonic: monotonic.inMilliseconds / 1000,
      jumps: [
        ..._state.jumps,
        JumpRecord(
          detectedAt: wall,
          wallClockDeltaSeconds: delta.inMilliseconds / 1000,
          monotonicDeltaSeconds: monotonicDelta.inMilliseconds / 1000,
          backwards: backwards,
        ),
      ].take(20).toList(),
    );

    await _store.save(_state);

    _log?.warn('校时',
        '检测到墙钟跳变（${backwards ? '往回调' : '往前调'} ${delta.inMinutes} 分钟），要求重新校准');

    return true;
  }

  /// 判定一次「自洽吗」；返回 null 表示自洽。
  ///
  /// ⚠️ 跨重启（单调读数比上次记录的小）时**只判「往回调」那一半** ——
  /// 理由见下面那条能力边界。不这么分的话，一台每晚关机的手机
  /// 天天早上都要重新校准，而它的时间其实一直都是准的。
  static (Duration, Duration, bool)? _judge(
    CalibrationState state, DateTime wall, Duration monotonic) {
    final lastWall = state.lastSeenWallClockUtc;
    final lastMonotonic = state.lastSeenMonotonic;

    if (lastWall == null || lastMonotonic == null) return null;

    final wallDelta = wall.difference(lastWall);
    final monotonicDelta =
        monotonic - Duration(milliseconds: (lastMonotonic * 1000).round());

    if (wallDelta.isNegative) {
      // 墙钟比上次记录的还早 —— 时间被调回去了。**无论跨没跨重启都算跳变。**
      return (wallDelta, monotonicDelta, true);
    }

    // 单调钟倒退 ⇒ 这一次跨了重启 ⇒ 往前调的那一半分辨不出来，放行。
    if (monotonicDelta.isNegative) return null;

    // 同一次开机内：两者的差超过容差就是跳变。
    final drift = wallDelta - monotonicDelta;
    return drift.abs() > Duration(milliseconds: (jumpThresholdSeconds * 1000).round())
        ? (drift, monotonicDelta, false)
        : null;
  }

  /// 用一个外部时间锚校准（或重新校准）。
  Future<void> calibrate(DateTime anchor, CalibrationSource source) async {
    final monotonic = _monotonic();

    _state = _state.copyWith(
      anchorUtc: anchor,
      monotonicAtAnchor: monotonic.inMilliseconds / 1000,
      source: source,
      calibratedAt: DateTime.now(),
      lastSeenWallClockUtc: DateTime.now(),
      lastSeenMonotonic: monotonic.inMilliseconds / 1000,
      // ⚠️ 重新校准**清掉**「要重新校准」那个标记，但不清历史跳变记录
      // （那些是事实，留着对诊断有用）。
      needsRecalibration: false,
    );

    await _store.save(_state);

    _log?.info('校时', '已校准（来源：${source.name}）');
  }

  /// 试着用**公网时间**校准一次。失败时保持原状（不猜一个时刻）。
  Future<bool> tryCalibrateFromPublicTime() async {
    final source = _publicSource;
    if (source == null) return false;

    try {
      await calibrate(await source.query(), CalibrationSource.publicTime);
      return true;
    } on Object catch (error) {
      // ⚠️ 不猜：猜出来的锚比没有锚更糟 —— 它看起来是校准过的。
      _log?.warn('校时', '取不到公网时间：$error');
      return false;
    }
  }

  /// 用**归档回执里的时间锚**校准（规格 §3.6.4 的第二个来源）。
  ///
  /// 手机端特有的那一半：与电脑端成功归档一次之后，回执上的 `timeAnchor`
  /// 就是一个用户改不了的外部时刻 —— **局域网即可，不需要公网**。
  ///
  /// ⚠️ 只在**还没校准**或**被要求重新校准**时才用它：已经有一个更早的锚时，
  /// 换锚会让时间线在两条线之间跳一下（而那正是跳变检测要防的事）。
  Future<bool> calibrateFromReceipt(DateTime timeAnchor) async {
    if (isCalibrated) return false;

    await calibrate(timeAnchor, CalibrationSource.archiveReceipt);
    return true;
  }
}
