import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/punch_log.dart';

/// 打点持久化（规格 §3.2.4 / 母仓 `docs/02-数据模型.md` §1.3）。
///
/// 重点不是「能写进去」，而是两条容易悄悄坏掉的东西：
/// **落盘形态与电脑端逐字一致**（两端的 `punches.jsonl` 是同一份格式），
/// 以及**掉电时写坏的那一行不倒拖累已写好的那些**。
void main() {
  late Directory temp;
  late PunchLog log;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vidlog-punch-');
    log = PunchLog('${temp.path}/punches.jsonl');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Punch punch({
    String id = 'punch-1',
    String sessionId = 'sess-1',
    String waybill = 'SF1000000001',
    int offsetMs = 0,
    PunchSource source = PunchSource.cameraDecoder,
  }) =>
      Punch(
        punchId: id,
        sessionId: sessionId,
        waybill: WaybillNumber.parse(waybill),
        punchedAt: DateTime.utc(2026, 9, 21, 10, 30),
        monotonicOffsetMilliseconds: offsetMs,
        source: source,
      );

  group('★ 落盘形态与电脑端一致', () {
    test('键名与取值逐字相同', () async {
      // 电脑端 `PunchDto` 的 6 个属性名就是这 6 个键，枚举用 ToString()。
      // 改了这里，两端的打点日志就不是同一份格式了 —— 那正是这个测试要拦的。
      await log.append(punch(source: PunchSource.manualEntry));

      final line = (await File(log.path).readAsLines()).single;
      final json = jsonDecode(line) as Map<String, Object?>;

      expect(json.keys, [
        'PunchId',
        'SessionId',
        'WaybillNumber',
        'PunchedAt',
        'MonotonicOffsetMilliseconds',
        'Source',
      ]);
      expect(json['Source'], 'ManualEntry');
      expect(json['WaybillNumber'], 'SF1000000001');
      expect(json['MonotonicOffsetMilliseconds'], 0);
    });

    test('三个来源的拼法与电脑端枚举同名', () {
      expect(PunchSource.keyboardScanner.wire, 'KeyboardScanner');
      expect(PunchSource.cameraDecoder.wire, 'CameraDecoder');
      expect(PunchSource.manualEntry.wire, 'ManualEntry');
    });

    test('认不出来的来源当成手动输入，不是抛异常', () {
      expect(PunchSource.fromWire('FutureThing'), PunchSource.manualEntry);
      expect(PunchSource.fromWire(null), PunchSource.manualEntry);
    });
  });

  group('追加与读取', () {
    test('一次一条，行数就是打点数', () async {
      await log.append(punch(id: 'p1'));
      await log.append(punch(id: 'p2'));

      expect(await File(log.path).readAsLines(), hasLength(2));
    });

    test('文件还不存在时读出空表，不报错', () async {
      expect(await PunchLog('${temp.path}/never.jsonl').loadAll(), isEmpty);
    });

    test('读回来与写进去相同（含墙钟的时区往返）', () async {
      final original = punch(offsetMs: 12345, source: PunchSource.keyboardScanner);
      await log.append(original);

      final read = (await log.loadAll()).single;

      expect(read.punchId, original.punchId);
      expect(read.sessionId, original.sessionId);
      expect(read.waybill, original.waybill);
      expect(read.monotonicOffsetMilliseconds, 12345);
      expect(read.source, PunchSource.keyboardScanner);
      expect(read.punchedAt.toUtc(), original.punchedAt.toUtc());
    });

    test('★ 目录不存在也能写 —— 第一次打点就撞上这个', () async {
      final deep = PunchLog('${temp.path}/a/b/c/punches.jsonl');
      await deep.append(punch());

      expect(await deep.loadAll(), hasLength(1));
    });

    test('★ 掉电写坏的最后一行不倒拖累前面的', () async {
      await log.append(punch(id: 'good-1'));
      await log.append(punch(id: 'good-2'));

      // 模拟写到一半掉电：追加一段没有收尾的 JSON。
      await File(log.path).writeAsString('{"PunchId":"hal', mode: FileMode.append);

      final read = await log.loadAll();
      expect(read.map((p) => p.punchId), ['good-1', 'good-2']);
    });

    test('★ 并发追加不会写出交错的行', () async {
      // 两个 `writeAsString(append)` 撞在一起会交错，产出的行整条读不出来。
      await Future.wait([
        for (var i = 0; i < 20; i++) log.append(punch(id: 'p$i')),
      ]);

      final lines = await File(log.path).readAsLines();
      expect(lines, hasLength(20));
      for (final line in lines) {
        expect(() => jsonDecode(line), returnsNormally);
      }
    });
  });

  group('按会话取', () {
    test('只取本会话的，并按偏移排序', () async {
      await log.append(punch(id: 'b', sessionId: 'other'));
      await log.append(punch(id: 'late', offsetMs: 5000));
      await log.append(punch(id: 'early', offsetMs: 10));

      final mine = await log.forSession('sess-1');

      expect(mine.map((p) => p.punchId), ['early', 'late']);
    });
  });
}
