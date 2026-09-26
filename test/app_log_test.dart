import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/diagnostics/app_log.dart';

/// 日志内核：结构化、落盘、级别、轮转、脱敏。
///
/// ⚠️ [AppLog] 是**单例**，状态会跨用例 —— 每条用例开头 `resetForTesting`，
/// 不然会出现「单跑必过、一起跑才红」，而那种失败最难查。
void main() {
  late Directory temp;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('vidlog-applog-');
    await AppLog.instance.resetForTesting();
  });

  tearDown(() async {
    await AppLog.instance.resetForTesting();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  List<Map<String, Object?>> readLines() {
    final path = AppLog.instance.path;
    if (path == null || !File(path).existsSync()) return [];

    return File(path)
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
  }

  group('落盘与结构化', () {
    test('一行一个 JSON 对象_字段都在', () async {
      final log = AppLog.instance;
      log.init(directory: temp.path, minLevel: AppLogLevel.debug);

      log.info('录制', '开始工作', data: {'模式': '发货'});
      await log.flush();

      final line = readLines().single;
      expect(line['lvl'], 'INFO');
      expect(line['cat'], '录制');
      expect(line['msg'], '开始工作');
      expect((line['data']! as Map)['模式'], '发货');

      // 时间戳带偏移量：不带的话，同一个诊断包里两台手机的 17:10 是歧义的。
      expect(line['ts'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')));
    });

    test('中文不被转义_日志要能读也能 grep', () async {
      // ⚠️ 用 `jsonEncode` 而不是手拼，但**编码器也要对**：
      // 默认把非 ASCII 转义之后，`grep 开始工作` 一条都搜不到，
      // 而这份文件是要人打开看的。
      final log = AppLog.instance;
      log.init(directory: temp.path, minLevel: AppLogLevel.debug);

      log.info('录制', '开始工作');
      await log.flush();

      final raw = File(log.path!).readAsStringSync();
      expect(raw, contains('开始工作'));
    });

    test('异常那条带完整堆栈', () async {
      final log = AppLog.instance;
      log.init(directory: temp.path, minLevel: AppLogLevel.debug);

      try {
        throw StateError('炸了');
      } on Object catch (error, stack) {
        log.error('上传', '传不上去', error: error, stackTrace: stack);
      }

      await log.flush();

      final line = readLines().single;
      expect(line['lvl'], 'ERROR');
      expect((line['data']! as Map)['异常'], contains('炸了'));
      // 「哪个文件哪一行」正是事后唯一想知道的东西。
      expect(line['stack'], contains('app_log_test.dart'));
    });

    test('一条日志就是一行_消息里的换行不被劈开', () async {
      final log = AppLog.instance;
      log.init(directory: temp.path, minLevel: AppLogLevel.debug);

      log.info('录制', '第一行\n第二行');
      await log.flush();

      expect(readLines(), hasLength(1));
    });
  });

  group('级别', () {
    test('低于阈值的一条都不写', () async {
      final log = AppLog.instance;
      log.init(directory: temp.path, minLevel: AppLogLevel.warn);

      log.debug('录制', '开发细节');
      log.info('录制', '普通信息');
      log.warn('录制', '值得看一眼');
      await log.flush();

      expect(readLines().single['msg'], '值得看一眼');
    });
  });

  group('早缓冲', () {
    test('init 之前记的不丢_init 之后冲掉', () async {
      // main() 里装钩子的时候还不知道数据目录（要 path_provider）。
      // 少了这一段，启动那几秒的日志全丢 —— 而那几秒最容易出事。
      final log = AppLog.instance;

      log.info('启动', '还没 init 就发生的这一条');
      expect(log.path, isNull);

      log.init(directory: temp.path, minLevel: AppLogLevel.debug);
      await log.flush();

      expect(readLines().single['msg'], '还没 init 就发生的这一条');
    });
  });

  group('界面镜像', () {
    test('尾部的行是给人看的形态_而且有上限', () async {
      final log = AppLog.instance;
      log.init(directory: temp.path, minLevel: AppLogLevel.debug);

      for (var i = 0; i < AppLog.tailLines + 10; i++) {
        log.info('录制', '第 $i 条');
      }

      expect(log.tail.value, hasLength(AppLog.tailLines));
      // 最新的在最前面
      expect(log.tail.value.first, contains('第 ${AppLog.tailLines + 9} 条'));
      expect(log.tail.value.first, matches(RegExp(r'^\d{2}:\d{2}:\d{2}')));
    });

    test('没 init 也能在界面上看见', () {
      AppLog.instance.info('启动', '缓冲模式也能记');

      expect(AppLog.instance.tail.value.single, contains('缓冲模式也能记'));
    });
  });

  group('目录用不了时降级', () {
    test('建不出目录也不抛_只是不落盘', () async {
      final log = AppLog.instance;

      // Windows 上路径里的非法字符 —— 建不出来。
      log.init(directory: 'Z:\\不存在的盘\\logs');

      expect(log.isReady, isFalse);
      log.info('录制', '这条落不了盘，但不该抛');
      expect(log.tail.value.single, contains('这条落不了盘'));
    });
  });

  group('背压', () {
    test('排队的行数封顶_而且把丢了几条写进下一条', () async {
      // 录制风暴时不能让内存无界增长；但也**不能丢了不吭声** ——
      // 看日志的人会以为「那段时间什么都没发生」，那比没有日志更误导。
      final log = AppLog.instance;
      log.init(directory: temp.path, minLevel: AppLogLevel.debug);

      for (var i = 0; i < AppLog.pendingLimit + 50; i++) {
        log.info('录制', '第 $i 条');
      }

      expect(log.pendingCount, lessThanOrEqualTo(AppLog.pendingLimit));

      await log.flush();

      final lines = readLines();
      expect(lines.last['msg'], contains('第 ${AppLog.pendingLimit + 49} 条'));
      expect((lines.last['data']! as Map)['丢弃条数'], greaterThan(0));
    });
  });

  group('轮转与保留', () {
    test('文件名的时间戳能解析', () {
      expect(parseLogTimestamp('app-20260926-131011.jsonl'),
          DateTime(2026, 9, 26, 13, 10, 11));
    });

    test('认不出的名字返回 null_不猜', () {
      for (final name in const [
        'app.jsonl',
        'app-2026.jsonl',
        'app-20260926.jsonl',
        'app-2026-09-26.jsonl',
        '别的-app-20260926-131011.jsonl',
        'app-20261326-131011.jsonl', // 13 月
        'app-20260926-251011.jsonl', // 25 点
      ]) {
        expect(parseLogTimestamp(name), isNull, reason: name);
      }
    });

    test('过期的删掉_近的留着_解析不出的不动', () async {
      final log = AppLog.instance;

      // init 会按「现在」算过期线，所以先用假时钟把旧文件造出来。
      final old = File('${temp.path}/app-20200101-120000.jsonl')..writeAsStringSync('{}');
      final fresh = File('${temp.path}/app-29991231-120000.jsonl')..writeAsStringSync('{}');
      final strange = File('${temp.path}/别的什么.jsonl')..writeAsStringSync('{}');

      log.init(directory: temp.path, minLevel: AppLogLevel.debug);

      expect(old.existsSync(), isFalse, reason: '过期了，该删');
      expect(fresh.existsSync(), isTrue, reason: '还在保留期内');
      expect(strange.existsSync(), isTrue, reason: '不知道它是什么就删，那是赌');
    });

    test('保留期小于一天时什么都不删', () async {
      final log = AppLog.instance;
      final old = File('${temp.path}/app-20200101-120000.jsonl')..writeAsStringSync('{}');

      log.init(directory: temp.path, retainDays: 0);

      expect(old.existsSync(), isTrue);
    });
  });

  group('脱敏', () {
    test('凭据塞进 credential 键里_落盘那一行读不到它', () async {
      final log = AppLog.instance;
      log.init(directory: temp.path, minLevel: AppLogLevel.debug);

      log.info('入网', '签发了凭据', data: {
        'credential': 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
        'deviceId': 'phone-1',
      });
      await log.flush();

      final raw = File(log.path!).readAsStringSync();
      expect(raw, isNot(contains('AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8')));
      expect(raw, contains('（已修改）'));
      // 同一行里别的字段照常写 —— 脱敏不该把整行变成一句空话。
      expect(raw, contains('phone-1'));
    });

    test('登记过的密钥值_出现在消息里也被抹掉', () async {
      // 这一层挡的是「键名很无辜」那种。
      final log = AppLog.instance;
      log.init(directory: temp.path, minLevel: AppLogLevel.debug);

      log.registerSecret('ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890');
      log.info('上传', '用的是 ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890 这把凭据');
      await log.flush();

      final raw = File(log.path!).readAsStringSync();
      expect(raw, isNot(contains('ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890')));
      expect(raw, contains('***'));
    });
  });
}
