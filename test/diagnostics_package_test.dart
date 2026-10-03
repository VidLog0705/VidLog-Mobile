import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/diagnostics/app_log.dart';
import 'package:vidlog_mobile/diagnostics/diagnostics_package.dart';
import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/recording_index.dart';
import 'package:vidlog_mobile/recording/scan_error_log.dart';

/// 一键诊断包（`AGENTS.md` §6）。
///
/// ⚠️ 这个文件是**要发出去的**，所以这里最要紧的两条是：
/// 该在的都在（不然发回来没用）、**不该在的不在**（凭据、以及与它无关的隐私）。
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('vidlog-diag-');
    // 外部目录那份只在 Android 上写，测试里不设 —— 设了也不会走到。
    DiagnosticsPackage.externalDirectory = null;
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  RecordingEntry entry(String id, String waybill, DateTime at) => RecordingEntry(
        evidenceId: id,
        sessionId: 'sess-$id',
        waybill: WaybillNumber.parse(waybill),
        startedAt: at,
        endedAt: at.add(const Duration(minutes: 1)),
        duration: const Duration(minutes: 1),
        location: RelativePath.parse('2026/09/26/$waybill/$id.mp4'),
        contentHash: ContentHash.parse('a' * 64),
        sourceDeviceId: 'phone-1',
      );

  Future<List<Map<String, Object?>>> build({List<RecordingEntry> entries = const []}) async {
    final path = await DiagnosticsPackage.build(
      rootPath: root.path,
      settings: {'mode': 'sameWaybillStop', 'voiceEnabled': true},
      deviceName: '打包手机-1',
      appVersion: '1.0.0+4',
      sessionCount: 3,
      orphanCount: 1,
      entries: entries,
      now: DateTime(2026, 9, 26, 13, 10, 11),
    );

    return File(path)
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .toList();
  }

  Map<String, Object?> section(List<Map<String, Object?>> lines, String kind) =>
      lines.firstWhere((l) => l['kind'] == kind);

  test('★ 该在的四节都在', () async {
    final lines = await build();

    expect(section(lines, 'header')['app'], 'vidlog-mobile');

    // ⚠️ **版本号**：手上两份日志分不出哪份是哪版时，「这个缺陷还在不在」就答不上来
    //（2026-10-03 就真栽过这一次，`+3` 与 `+4` 同一天同一台手机）。
    expect(section(lines, 'header')['version'], '1.0.0+4');

    expect(section(lines, 'settings')['deviceName'], '打包手机-1');
    expect(section(lines, 'index-summary')['sessions'], 3);
    expect(section(lines, 'index-summary')['orphans'], 1);
    expect(section(lines, 'logs'), isNotNull);
    expect(section(lines, 'scan-errors'), isNotNull);
  });

  test('★ 索引摘要只给条数与日期范围_不给单号', () async {
    // 与电脑端 `DiagnosticsPackage` 同一个取舍：索引里每行都带单号（PII），
    // 而诊断要回答的是「有没有在录、录了多少」。
    final lines = await build(entries: [
      entry('e1', 'SF1000000001', DateTime(2026, 9, 26, 10)),
      entry('e2', 'YT9999999999', DateTime(2026, 9, 26, 12)),
    ]);

    final summary = section(lines, 'index-summary');

    expect(summary['count'], 2);
    expect(summary['first'], contains('2026-09-26'));
    expect(summary.toString(), isNot(contains('SF1000000001')));
    expect(summary.toString(), isNot(contains('YT9999999999')));
  });

  test('★ 设置里没有凭据 —— 传进来的零件本来就不该带它', () async {
    final lines = await build();
    final whole = lines.toString();

    // `device.json` 里那份凭据绝不能出现在包里（诊断包是要发出去的）。
    expect(whole, isNot(contains('credential')));
    expect(whole, isNot(contains('凭据')));
  });

  test('★ 错误扫描那一节带单号_而且明说了', () async {
    // 与上面那节相反是有意的：错误扫描的价值**就在**「该扫的是哪个、
    // 实际扫到了哪个」，抽掉单号就只剩一句「扫错过」。
    await ScanErrorLog('${root.path}/scan-errors.jsonl').record(ScanErrorEvent(
      sessionId: 'sess-1',
      expectedWaybill: WaybillNumber.parse('SF1000000001'),
      scannedWaybill: WaybillNumber.parse('YT9999999999'),
      occurredAt: DateTime(2026, 9, 26, 13),
    ));

    final lines = await build();
    final section_ = section(lines, 'scan-errors');

    // 头部与界面上都要写明「包含单号」—— 用户发出去之前有权知道。
    expect(section_['含单号'], isTrue);
    expect(section_.toString(), contains('SF1000000001'));
  });

  test('没有错误扫描时_那一节是空的而且标明不含单号', () async {
    final lines = await build();

    expect(section(lines, 'scan-errors')['含单号'], isFalse);
    expect(section(lines, 'scan-errors')['total'], 0);
  });

  test('日志尾巴真的带上了', () async {
    // 用 AppLog 写一条真日志，再确认它在包里。
    final log = AppLog.instance;
    await log.resetForTesting();
    log.init(directory: '${root.path}/logs', minLevel: AppLogLevel.debug);
    log.info('录制', '这一行应当出现在诊断包里');
    await log.flush();
    await log.resetForTesting();

    final path = await DiagnosticsPackage.build(
      rootPath: root.path,
      settings: const {},
      deviceName: 'x',
      appVersion: '1.0.0+4',
      sessionCount: 0,
      orphanCount: 0,
      entries: const [],
      now: DateTime(2026, 9, 26, 13, 10, 11),
    );

    expect(File(path).readAsStringSync(), contains('这一行应当出现在诊断包里'));
  });

  test('提示语在有单号时会说出来', () {
    expect(describeDiagnosticsPackage('/x/diagnostics-1.jsonl', hasScanErrors: true),
        contains('包含扫错过的单号'));
    expect(describeDiagnosticsPackage('/x/diagnostics-1.jsonl', hasScanErrors: false),
        isNot(contains('单号')));
  });
}
