import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/scan_error_log.dart';

/// 错误扫描记录（规格 §6.1「必须保存的事实」，母仓 `02-数据模型.md` §1.7）。
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('vidlog-scanerr-'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  ScanErrorLog open() => ScanErrorLog('${temp.path}/scan-errors.jsonl');

  ScanErrorEvent sample() => ScanErrorEvent(
        sessionId: 'sess-1',
        expectedWaybill: WaybillNumber.parse('SF1000000001'),
        scannedWaybill: WaybillNumber.parse('YT9999999999'),
        occurredAt: DateTime(2026, 9, 26, 13, 10, 11),
      );

  test('★ 落盘的键名与母仓 §1.7 那张表逐字一致', () async {
    // 两端要能读同一份记录 —— 键名对不上就是「两边各自自洽、合起来不通」。
    final log = open();
    await log.record(sample());

    final json = jsonDecode(
      File('${temp.path}/scan-errors.jsonl').readAsLinesSync().single,
    ) as Map<String, Object?>;

    expect(json.keys.toSet(), {'SessionId', 'ExpectedWaybill', 'ScannedWaybill', 'OccurredAt'});
  });

  test('读回来是同一件事', () async {
    final log = open();
    await log.record(sample());

    final event = (await log.loadAll()).single;

    expect(event.sessionId, 'sess-1');
    expect(event.expectedWaybill.value, 'SF1000000001');
    expect(event.scannedWaybill.value, 'YT9999999999');
    expect(event.occurredAt, DateTime(2026, 9, 26, 13, 10, 11));
  });

  test('时刻按 UTC 落盘_读回来是本地时刻', () async {
    // 存 UTC 是这一仓的既定规矩（与打点同一句注释）：
    // 墙钟时刻落盘必须带时区，否则换时区读回来就错了几小时。
    final log = open();
    await log.record(sample());

    final raw = File('${temp.path}/scan-errors.jsonl').readAsLinesSync().single;
    expect(raw, contains('Z'));
  });

  test('文件不存在时读回空表_不抛', () async {
    expect(await open().loadAll(), isEmpty);
  });

  test('坏行跳过_不让整份记录读不出来', () async {
    final log = open();
    await log.record(sample());
    File('${temp.path}/scan-errors.jsonl')
        .writeAsStringSync('{这不是 JSON\n', mode: FileMode.append);
    await log.record(sample());

    // 与索引、打点、标签同一条规矩：一行坏掉不该让整份读不出来。
    expect(await log.loadAll(), hasLength(2));
  });
}
