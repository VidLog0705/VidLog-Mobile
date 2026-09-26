import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../recording/recording_index.dart';
import '../recording/scan_error_log.dart';
import 'redact.dart';

/// 诊断包：**一个文件**，用户从「文件」App 里取出来发回来。
///
/// ## 为什么是一个文件，而不是 zip
///
/// `AGENTS.md` §6 要的是「日志能导出为诊断包，用户遇到问题一键打包发回」。
/// 打 zip 要引一个依赖（`archive`），而**手机上 zip 也还是得靠文件 App 取出来** ——
/// 多一个依赖只买到「格式一致」。
///
/// ⚠️ **iOS 这边不用改任何东西**：`ios/Runner/Info.plist` 里本来就有
/// `UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace`，
/// 所以写进 `<docs>/vidlog/` 就出现在「文件 → 我的 iPhone → VidLog」里。
///
/// ⚠️ **Android 是弱侧，如实说**：`getApplicationDocumentsDirectory()` 落在
/// app 私有目录，Android 11+ 的文件 App 看不到。所以额外写一份到
/// `getExternalStorageDirectory()`（USB 与部分文件管理器可达），
/// 界面上另给一个「复制路径」—— **这条路径没有任何测试能证明用户取得到**，
/// 只能真机验（`docs/真机验收清单.md`）。
class DiagnosticsPackage {
  const DiagnosticsPackage._();

  /// 日志最多带多少行。
  static const logLines = 500;

  /// 错误扫描最多带多少条。
  ///
  /// ⚠️ 这一节**包含单号**（见 [build] 的说明），所以封顶 ——
  /// 诊断包是拿来发回来的，几百条单号既没用又更重。
  static const scanErrorLines = 50;

  /// 生成一份诊断包，返回落盘路径。
  ///
  /// [rootPath] 是数据根（`<docs>/vidlog`），包写在它下面 ——
  /// 与日志、索引同一层，用户在一个地方就能全找到。
  ///
  /// ⚠️ **本函数只收「安全的零件」**（设置、摘要、条数），
  /// **不收 `DeviceIdentity`**：那里面有凭据，而诊断包是要发出去的。
  /// 要显示设备名就单独传 `deviceName`。
  static Future<String> build({
    required String rootPath,
    required Map<String, Object?> settings,
    required String deviceName,
    required int sessionCount,
    required int orphanCount,
    required List<RecordingEntry> entries,
    required DateTime now,
  }) async {
    final buffer = StringBuffer();

    void write(Object? json) => buffer.writeln(jsonEncode(json));

    // ── 头部 ─────────────────────────────────────────────
    write({
      'kind': 'header',
      'schema': 1,
      'app': 'vidlog-mobile',
      'generatedAt': now.toUtc().toIso8601String(),
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      // 机型名在 Dart 侧拿不到（要平台通道），如实留空而不是编一个。
    });

    // ── 设置 ─────────────────────────────────────────────
    // 走与日志同一套键名脱敏：`settings` 里今天没有密钥字段，
    // 但这一层是给「将来有人往里塞了凭据」兜底的。
    write({
      'kind': 'settings',
      'deviceName': deviceName,
      'settings': {
        for (final entry in settings.entries)
          entry.key: isSensitiveName(entry.key) ? redactedPlaceholder : entry.value,
      },
    });

    // ── 索引摘要（**只给条数与日期范围，不给单号**）──────────
    //
    // 与电脑端 `DiagnosticsPackage` 同一个取舍：索引里每一行都带单号（PII），
    // 而诊断要的是「有没有在录、录了多少」。
    final sorted = [...entries]..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    write({
      'kind': 'index-summary',
      'count': entries.length,
      'first': sorted.isEmpty ? null : sorted.first.startedAt.toUtc().toIso8601String(),
      'last': sorted.isEmpty ? null : sorted.last.startedAt.toUtc().toIso8601String(),
      'sessions': sessionCount,
      'orphans': orphanCount,
    });

    // ── 错误扫描（规格 §6.1）─────────────────────────────
    //
    // ⚠️ **这一节带单号**，与上面那节的取舍相反是有意的：
    // 错误扫描的价值**就在**「当时该扫的是哪个、实际扫到了哪个」，
    // 抽掉单号就只剩一句「扫错过」。所以带上，但**封顶**，
    // 而且在头部与界面上都写明「包含单号」。
    final scanErrors = await ScanErrorLog('$rootPath/scan-errors.jsonl').loadAll();
    write({
      'kind': 'scan-errors',
      '含单号': scanErrors.isNotEmpty,
      'total': scanErrors.length,
      'events': [
        for (final event in scanErrors.take(scanErrorLines)) event.toJson(),
      ],
    });

    // ── 日志尾巴 ──────────────────────────────────────────
    write({'kind': 'logs', 'note': '最近 $logLines 行，一行一个 JSON 对象'});
    buffer.write(_tailLogs(rootPath));

    final stamp = _stamp(now);
    final path = '$rootPath/diagnostics-$stamp.jsonl';
    await File(path).writeAsString(buffer.toString(), flush: true);

    // Android 上再写一份到外部目录（见类注释：那条路径是弱侧）。
    await _mirrorToExternal(rootPath, buffer.toString(), stamp);

    return path;
  }

  /// 拼日志尾巴。
  ///
  /// 先按**文件名的字节序**排（`app-yyyyMMdd-HHmmss` 这个命名下字典序即时间序），
  /// 再从最新的往前取 —— 与 `AGENTS.md` §6 点名的那条规矩同一路数，
  /// 只是这里不需要删文件，所以不用解析时间戳。
  static String _tailLogs(String rootPath) {
    final directory = Directory('$rootPath/logs');
    if (!directory.existsSync()) return '';

    final files = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.endsWith('.jsonl'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final lines = <String>[];
    for (final file in files.reversed) {
      try {
        final rows = file.readAsLinesSync().where((l) => l.trim().isNotEmpty);
        lines.insertAll(0, rows);
      } on Object {
        // 读不动的那个文件跳过 —— 诊断包本身不该因为一个坏文件生不出来。
      }

      if (lines.length >= logLines) break;
    }

    final tail = lines.length <= logLines ? lines : lines.sublist(lines.length - logLines);
    return tail.isEmpty ? '' : '${tail.join('\n')}\n';
  }

  /// Android：同一份再写到外部目录。
  static Future<void> _mirrorToExternal(
      String rootPath, String content, String stamp) async {
    if (!Platform.isAndroid) return;

    try {
      // 外部目录由界面设一次（它才拿得到 `path_provider` 的路径），
      // 见 [externalDirectory] —— 本模块刻意不依赖 path_provider。
      final external = externalDirectory;
      if (external == null) return;

      final file = File('$external/diagnostics-$stamp.jsonl');
      await file.parent.create(recursive: true);
      await file.writeAsString(content, flush: true);
    } on Object {
      // 外部目录写不进去不是错误（权限、没插存储卡）——
      // 私有目录那份已经在盘上了。
    }
  }

  /// 外部可见目录。由 `main`/界面在拿到 `path_provider` 的路径后设一次。
  ///
  /// 为什么是这样一个可变字段而不是参数：诊断包**只有一个入口**
  /// （`build`），而外部目录只是个「顺手再写一份」的地方 ——
  /// 为它在每个调用点都传一遍参数，收益抵不上那一路的噪声。
  @visibleForTesting
  static String? externalDirectory;

  static String _stamp(DateTime at) =>
      '${at.year.toString().padLeft(4, '0')}'
      '${at.month.toString().padLeft(2, '0')}'
      '${at.day.toString().padLeft(2, '0')}-'
      '${at.hour.toString().padLeft(2, '0')}'
      '${at.minute.toString().padLeft(2, '0')}'
      '${at.second.toString().padLeft(2, '0')}';
}

/// 把一份诊断包的内容摊成给用户看的一句话（界面上那句提示）。
String describeDiagnosticsPackage(String path, {required bool hasScanErrors}) {
  final note = hasScanErrors
      // ⚠️ 明说：这一份里有单号。用户发出去之前有权知道。
      ? '（里面包含扫错过的单号）'
      : '';
  return '已生成：$path$note';
}
