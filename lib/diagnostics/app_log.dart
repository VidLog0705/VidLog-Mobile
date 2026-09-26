import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'redact.dart';

/// 日志级别。**顺序有意义**（`debug < info < warn < error`），阈值靠它比大小。
///
/// 与电脑端 `LogLevel` 同一套顺序与名字 —— 两端读同一份诊断包时不必换脑子。
enum AppLogLevel {
  debug,
  info,
  warn,
  error;

  /// 写进 JSON 的形式。**大写、与电脑端逐字相同** —— 它是协议的一部分，
  /// 换个大小写就等于让两端的日志没法用同一个查询去筛。
  String get wire => name.toUpperCase();

  static AppLogLevel? tryParse(String value) {
    final lower = value.trim().toLowerCase();
    for (final level in AppLogLevel.values) {
      if (level.name == lower) return level;
    }
    return null;
  }
}

/// 一行日志。给人看的那一份（`text`）与落盘的那一份（`toJson`）**是同一个来源**。
@immutable
class AppLogLine {
  const AppLogLine({
    required this.at,
    required this.level,
    required this.tag,
    required this.message,
    this.data = const {},
    this.stack,
  });

  final DateTime at;
  final AppLogLevel level;
  final String tag;
  final String message;
  final Map<String, Object?> data;

  /// 未捕获异常的堆栈。**只有异常那几条有** —— 「哪一行」正是事后最想知道的。
  final String? stack;

  /// 落盘用的 JSON。
  ///
  /// `ts` 带偏移量：不带的话，同一个诊断包里两台手机的 `17:10` 是歧义的，
  /// 而排事件顺序正是要拿它。
  Map<String, Object?> toJson() => {
        'ts': at.toIso8601String(),
        'lvl': level.wire,
        'cat': tag,
        'msg': message,
        if (data.isNotEmpty) 'data': data,
        if (stack != null && stack!.isNotEmpty) 'stack': stack,
      };

  /// 界面那一行（「事件 ▸」抽屉）。**不是**落盘格式 —— 抽屉里要的是能一眼扫过的。
  String get text =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}  $message';
}

/// 手机端的日志：**结构化、落盘、按文件名轮转、脱敏**。
///
/// ## 为什么是单例（与电脑端相反）
///
/// 两个理由，都是这个仓的具体形状：
/// 1. `main()` 里的全局异常钩子在**任何一个 widget 存在之前**就要有个落点；
/// 2. `recorder_page.dart` 的 `ChannelRecorderGateway()` 是**字段初始化器**，
///    不是构造参数 —— 传不进去。
///
/// ## 早缓冲
///
/// `main()` 跑的时候还不知道数据目录（要 `path_provider`，只能异步拿）。
/// 所以 [init] 之前它处在**缓冲模式**：照记不误，只是先在内存里排着；
/// [init] 一到就冲掉。**没有这一步的话，启动那几秒的日志全部丢失**，
/// 而那几秒恰恰是最容易出事的。
///
/// ## 落盘怎么不拖累录制
///
/// 1. `log()` 是 `void`、**永不 await** —— 录制路径上不碰磁盘；
/// 2. **按时间合并突发**（200ms 一批）：200ms 内的 N 条 = 一次 append + 一次界面通知。
///    逐条写的话，一次心跳风暴就是 N 次磁盘 IO；
/// 3. **有界**：排队的行数封顶，丢最旧的并**把丢了几条写进下一条** ——
///    让看日志的人知道「这份日志是有损的」，而不是被静默骗。
///
/// ## ⚠️ 不走 `writeFileAtomically`
///
/// 那个是 `.tmp` + rename + 最多 5 次退避重试，对 manifest 是对的
/// （丢了就没有孤儿收尾），对**一行日志**是错的（丢了不损失什么，
/// 而重试会把录制线程拖住）。这里直接 append，不逐条 flush。
class AppLog {
  AppLog._();

  /// 进程级唯一实例。
  static final AppLog instance = AppLog._();

  /// 界面镜像：最近若干行的**人读形式**（「事件 ▸」抽屉）。
  ///
  /// ⚠️ 界面**只从这里读**，不要每来一条就 `setState` 整个页面 ——
  /// 那个页面挂着平台视图（相机预览），每 200ms 重建它一次是纯浪费。
  final ValueNotifier<List<String>> tail = ValueNotifier(const []);

  /// 界面留几行。
  static const tailLines = 60;

  /// 排队上限。超了丢最旧的（与电脑端 `DropOldest` 同一条规矩）。
  static const pendingLimit = 2000;

  /// 攒多久写一次盘。
  static const flushInterval = Duration(milliseconds: 200);

  /// 保留几天。与电脑端默认值一致。
  static const defaultRetainDays = 14;

  final Redactor _redactor = Redactor();
  final List<String> _pending = [];
  final List<AppLogLine> _buffer = [];

  /// 写入串行闸 —— 本仓惯用法（`archive_store.dart` / `punch_log.dart`）。
  ///
  /// ⚠️ 闸门**要吞掉异常继续放行**，否则一次写失败会把后续所有写入都堵死。
  Future<void> _gate = Future<void>.value();

  Timer? _timer;
  String? _directory;
  AppLogLevel _minLevel = AppLogLevel.info;
  int _dropped = 0;

  /// 当前日志文件。**每次 init 一个新文件**（文件名带时间戳）。
  String? _path;

  /// 队列里已经排了多少（测试用）。
  @visibleForTesting
  int get pendingCount => _pending.length;

  /// 还没 init 时也能记（缓冲模式）。
  bool get isReady => _directory != null;

  /// 目录（测试与诊断包用）。
  String? get directory => _directory;

  /// 当前日志文件路径；没 init 时为 null。
  String? get path => _path;

  /// 启动日志。
  ///
  /// [directory] 是日志根目录（`<docs>/vidlog/logs`）。
  /// 目录建不起来时**退化成纯内存**（照记，只在界面看得见）——
  /// 与电脑端 `FileLogger` 吞 IO 异常是同一条规矩：
  /// **日志坏了绝不能拖垮录制**（I4 的同一条精神）。
  void init({
    required String directory,
    int retainDays = defaultRetainDays,
    AppLogLevel minLevel = AppLogLevel.info,
    DateTime Function() clock = DateTime.now,
  }) {
    _minLevel = minLevel;

    try {
      Directory(directory).createSync(recursive: true);
      _directory = directory;
      _path = '$directory/app-${_stamp(clock())}.jsonl';
      _purgeExpired(retainDays, clock());
    } on Object {
      // 建不出目录（权限、只读盘）—— 退化成纯内存，不抛。
      _directory = null;
    }

    // 缓冲模式里攒下的那些，现在冲掉。
    if (_buffer.isNotEmpty) {
      final buffered = List<AppLogLine>.from(_buffer);
      _buffer.clear();
      for (final line in buffered) {
        _enqueue(line);
      }
    }

    if (_directory != null) {
      _schedule();
    }
  }

  /// 记一条。
  ///
  /// **它不 await、也不该被 await** —— 录制路径上不该有人等磁盘。
  void log(
    AppLogLevel level,
    String tag,
    String message, {
    Map<String, Object?> data = const {},
    String? stack,
  }) {
    // 低于阈值直接丢在**调用线程**上，连排队都不必（生产上开着 debug 会被淹掉，
    // 而淹掉的日志等于没有日志）。
    if (level.index < _minLevel.index) return;

    final line = AppLogLine(
      at: DateTime.now(),
      level: level,
      tag: tag,
      // 消息也要过值层脱敏：一个叫「内容」的字段里插值了凭据，键名看不出来。
      message: _redactor.redact(message),
      data: {
        for (final entry in data.entries)
          entry.key: _redactor.redactValue(entry.key, entry.value),
      },
      stack: stack,
    );

    if (!isReady && _buffer.length < pendingLimit) {
      _buffer.add(line);
      _publishTail(line);
      return;
    }

    _enqueue(line);
    _schedule();
  }

  void debug(String tag, String message, {Map<String, Object?> data = const {}}) =>
      log(AppLogLevel.debug, tag, message, data: data);

  void info(String tag, String message, {Map<String, Object?> data = const {}}) =>
      log(AppLogLevel.info, tag, message, data: data);

  void warn(String tag, String message, {Map<String, Object?> data = const {}}) =>
      log(AppLogLevel.warn, tag, message, data: data);

  void error(
    String tag,
    String message, {
    Map<String, Object?> data = const {},
    Object? error,
    StackTrace? stackTrace,
  }) =>
      log(
        AppLogLevel.error,
        tag,
        message,
        data: {
          ...data,
          // ⚠️ **完整堆栈**，不是只有一句 message ——
          // 「哪个文件哪一行」正是事后唯一想知道的东西。
          if (error != null) '异常': error.toString(),
        },
        stack: stackTrace?.toString(),
      );

  /// 登记一个「永远不该出现在日志里」的值（入网拿到的凭据等）。
  void registerSecret(String? value) => _redactor.registerSecret(value);

  /// 把排队的都写下去。**给生命周期暂停与测试用**。
  ///
  /// 只保证「调用这一刻**已经排队**的都写下去了」。
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    return _flush();
  }

  /// 清掉一切（只给测试用 —— 它是个单例，状态会跨用例）。
  @visibleForTesting
  Future<void> resetForTesting() async {
    await flush();
    _pending.clear();
    _buffer.clear();
    _dropped = 0;
    _directory = null;
    _path = null;
    _minLevel = AppLogLevel.info;
    _redactor.resetForTesting();
    tail.value = const [];
  }

  // ─────────────────────────────────────────────
  // 内部
  // ─────────────────────────────────────────────

  void _enqueue(AppLogLine line) {
    // 超上限就丢最旧的，并记账 —— 丢了不吭声的话，
    // 看日志的人会以为「那段时间什么都没发生」。
    while (_pending.length >= pendingLimit) {
      _pending.removeAt(0);
      _dropped++;
    }

    var text = jsonEncode(line.toJson());

    if (_dropped > 0) {
      text = jsonEncode(line.toJson()
        ..['data'] = {
          ...(line.toJson()['data'] as Map<String, Object?>? ?? {}),
          '丢弃条数': _dropped,
        });
      _dropped = 0;
    }

    _pending.add(text);
    _publishTail(line);
  }

  void _publishTail(AppLogLine line) {
    final next = [line.text, ...tail.value];
    tail.value = next.length <= tailLines ? next : next.sublist(0, tailLines);
  }

  void _schedule() {
    if (!isReady || _timer != null) return;
    _timer = Timer(flushInterval, () {
      _timer = null;
      unawaited(_flush());
    });
  }

  Future<void> _flush() {
    if (_pending.isEmpty) return Future<void>.value();

    final batch = _pending.join('\n');
    _pending.clear();

    final result = _gate.then((_) async {
      final path = _path;
      if (path == null) return;

      final file = File(path);
      await file.parent.create(recursive: true);

      // flush: false —— 一行日志不值得每条都等一次 fsync。
      // 真掉了也只是一行；而 `flush()` 与生命周期暂停那两处会强制刷。
      await file.writeAsString('$batch\n', mode: FileMode.append);
    });

    // 闸门吞掉异常继续放行（见 `_gate` 的说明）。
    _gate = result.then((_) {}, onError: (_) {});
    return _gate;
  }

  /// 删掉超过 [retainDays] 天的日志。
  ///
  /// ⚠️ **按文件名里的时间戳挑，不按字符串排**（`AGENTS.md` §6 点名的坑：
  /// 按名字倒序会把 `app-2` 当成比 `app-10` 更新，于是删掉最新的、留下最旧的）。
  /// 解析不出的文件**不动** —— 不知道它是什么就删，那是赌。
  void _purgeExpired(int retainDays, DateTime now) {
    if (retainDays < 1) return;

    final directory = _directory;
    if (directory == null) return;

    final cutoff = now.subtract(Duration(days: retainDays));

    try {
      for (final entity in Directory(directory).listSync()) {
        if (entity is! File) continue;

        final name = entity.uri.pathSegments.last;
        final at = parseLogTimestamp(name);
        if (at == null || !at.isBefore(cutoff)) continue;

        try {
          entity.deleteSync();
        } on Object {
          // 删不动就留着，下次启动再试。
        }
      }
    } on Object {
      // 列目录失败不是错误。
    }
  }

  static String _stamp(DateTime at) =>
      '${at.year.toString().padLeft(4, '0')}'
      '${at.month.toString().padLeft(2, '0')}'
      '${at.day.toString().padLeft(2, '0')}-'
      '${at.hour.toString().padLeft(2, '0')}'
      '${at.minute.toString().padLeft(2, '0')}'
      '${at.second.toString().padLeft(2, '0')}';
}

/// 从 `app-yyyyMMdd-HHmmss.jsonl` 里取出时间戳；解析不出返回 null。
///
/// 与电脑端 `LogRetention.TryParseTimestamp` 同一套口径 —— 两端的日志文件
/// 命名规则一致，诊断包里一眼能对上。
DateTime? parseLogTimestamp(String fileName) {
  if (!fileName.startsWith('app-') || !fileName.endsWith('.jsonl')) return null;

  final stem = fileName.substring(4, fileName.length - '.jsonl'.length);
  if (stem.length != 15 || stem[8] != '-') return null;

  final digits = stem.replaceAll('-', '');
  if (digits.length != 14 || int.tryParse(digits) == null) return null;

  final year = int.parse(digits.substring(0, 4));
  final month = int.parse(digits.substring(4, 6));
  final day = int.parse(digits.substring(6, 8));
  final hour = int.parse(digits.substring(8, 10));
  final minute = int.parse(digits.substring(10, 12));
  final second = int.parse(digits.substring(12, 14));

  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;

  return DateTime(year, month, day, hour, minute, second);
}
