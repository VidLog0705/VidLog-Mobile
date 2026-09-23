import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/recording/recorder_config.dart';
import 'package:vidlog_mobile/recording/recording_settings.dart';
import 'package:vidlog_mobile/recording/retention_setting.dart';
import 'package:vidlog_mobile/recording/work_mode.dart';

/// 用户设置落盘（工作模式 + 两个兜底档位）。
///
/// 这份配置在 2026-09-22 之前**一项都不落盘**，重启就回默认 ——
/// 而「时长兜底档位交给用户自己选」是需求方特意要的功能，每次开 App 抹掉
/// 等于没做。所以这里测的是**改完真的还在**。
///
/// 另一半是 I4：设置文件坏掉**不能拦住录制**，一律回落硬兜底值。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vidlog-settings-');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  String path() => '${temp.path}/settings.json';

  test('没有文件 → 各项都是硬兜底值，而且**不建文件**', () async {
    final settings = await RecordingSettings.load(path());

    expect(settings.mode, WorkMode.fallback);
    expect(settings.staticStop, StaticStopSetting.fallback);
    expect(settings.durationFallback, DurationFallbackSetting.fallback);
    expect(settings.voiceEnabled, isTrue, reason: '读不出来时播报按**开**算');
    expect(settings.retentionOutbound, RetentionSetting.fallback);
    expect(settings.retentionReturn, RetentionSetting.fallback);

    // 没改过就不写盘：默认值本来就是对的，没必要替一件没发生的事写一次。
    expect(File(path()).existsSync(), isFalse);
  });

  test('★ 改了要落盘，重开还在', () async {
    final settings = await RecordingSettings.load(path());
    settings.mode = WorkMode.scanThenStaticStop;
    settings.staticStop = StaticStopSetting.minutes5;
    settings.durationFallback = DurationFallbackSetting.off;
    settings.voiceEnabled = false;
    await settings.save();

    final reloaded = await RecordingSettings.load(path());

    expect(reloaded.mode, WorkMode.scanThenStaticStop);
    expect(reloaded.staticStop, StaticStopSetting.minutes5);
    // off 的分钟数是 0 —— 它必须和「没配过」区分得开，所以这里单独钉一条：
    // 真要写成「缺字段」的话，读回来会是默认的 4 分钟而不是关。
    expect(reloaded.durationFallback, DurationFallbackSetting.off);
    // 同理：false 也必须和「没配过」区分得开。若哪天把「默认 true」实现成
    // 「缺省就当 true」，这一条会红 —— 而那个 bug 在真机上表现为
    // 「关了播报，重开 App 又自己响了」。
    expect(reloaded.voiceEnabled, isFalse);
  });

  test('⚠️ 播报开关：垃圾值一律当**开**，不是当关', () async {
    // 这一项的兜底方向与别项相反，值得钉住：规格 §3.3.2 的错码保护就靠播报，
    // **静默关掉一个提示功能，比静默开着吵一点严重得多**。
    for (final garbage in <Object?>['false', 0, '', <int>[], null]) {
      File(path()).writeAsStringSync(
        jsonEncode({'voiceEnabled': garbage}),
      );

      final settings = await RecordingSettings.load(path());

      expect(settings.voiceEnabled, isTrue, reason: '「$garbage」不该被当成「关」');
    }
  });

  test('静置档位与时长兜底**互不影响**：关一个，另一个照旧', () async {
    final settings = await RecordingSettings.load(path());
    settings.staticStop = StaticStopSetting.off;
    await settings.save();

    final reloaded = await RecordingSettings.load(path());

    expect(reloaded.staticStop, StaticStopSetting.off);
    expect(reloaded.durationFallback, DurationFallbackSetting.fallback,
        reason: '关掉静止档位不该把时长兜底也一起关掉，反之亦然');
  });

  // I4：设置读不出来绝不能拦住录制。这里把三种坏法各试一遍。
  group('坏文件一律回落，绝不抛（不变量 I4）', () {
    test('半个 JSON', () async {
      File(path()).writeAsStringSync('{ "mode": "sameWayb');

      final settings = await RecordingSettings.load(path());

      expect(settings.mode, WorkMode.fallback);
      expect(settings.staticStop, StaticStopSetting.fallback);
      expect(settings.durationFallback, DurationFallbackSetting.fallback);
    });

    test('顶层不是对象（是个数组）', () async {
      File(path()).writeAsStringSync('[1, 2, 3]');

      final settings = await RecordingSettings.load(path());

      expect(settings.mode, WorkMode.fallback);
    });

    test('认不出的模式名 → 回落，不是崩', () async {
      File(path()).writeAsStringSync(jsonEncode({'mode': '飛天模式'}));

      final settings = await RecordingSettings.load(path());

      expect(settings.mode, WorkMode.fallback);
    });

    // 档位超范围**回落不夹取** —— 夹取会悄悄改变用户配置的语义（例如把 999
    // 变成 5 分钟），回落至少是「这个值不认，用默认的」。
    test('档位超范围（999）→ 回落，不夹到 5', () async {
      File(path()).writeAsStringSync(
        jsonEncode({'staticStop': 999, 'durationFallback': -1}),
      );

      final settings = await RecordingSettings.load(path());

      expect(settings.staticStop, StaticStopSetting.fallback);
      expect(settings.durationFallback, DurationFallbackSetting.fallback);
    });
  });

  // ⚠️ 存的是名字不是序号。这条钉住它：序号一旦被当格式，枚举重排就会把老文件
  // **静默**解析成另一个模式 —— 录制行为当场变了而没人知道。
  test('★ 模式按名字存，不按序号存', () async {
    final settings = await RecordingSettings.load(path());
    settings.mode = WorkMode.scanThenStaticStop;
    await settings.save();

    final raw = jsonDecode(File(path()).readAsStringSync()) as Map<String, Object?>;

    expect(raw['mode'], 'scanThenStaticStop');
  });

  // ─────────────────────────────────────────────
  // 归档后的本地保留期（规格 §3.5.2.1）
  // ─────────────────────────────────────────────

  group('保留期：发货与退货各一份', () {
    test('★ 两份分开存，改一份不动另一份', () async {
      final settings = await RecordingSettings.load(path());
      settings.retentionOutbound = RetentionSetting.days7;
      settings.retentionReturn = RetentionSetting.days30;
      await settings.save();

      final reloaded = await RecordingSettings.load(path());

      expect(reloaded.retentionOutbound, RetentionSetting.days7);
      expect(reloaded.retentionReturn, RetentionSetting.days30);
    });

    test('⚠️「全部保留」与「不保留」必须是两个值，不能都读成缺字段', () async {
      // `keepAll.days == null`、`none.days == 0`。若哪天把「全部保留」
      // 实现成「缺字段就当 0」，这一条会红 —— 而那个 bug 在真机上表现为
      // **用户选了「全部保留」，东西却在备份后第二天被删掉**。
      final settings = await RecordingSettings.load(path());
      settings.retentionOutbound = RetentionSetting.keepAll;
      settings.retentionReturn = RetentionSetting.none;
      await settings.save();

      final reloaded = await RecordingSettings.load(path());

      expect(reloaded.retentionOutbound, RetentionSetting.keepAll);
      expect(reloaded.retentionReturn, RetentionSetting.none);
      expect(reloaded.retentionOutbound.days, isNull);
      expect(reloaded.retentionReturn.days, 0);
    });

    test('垃圾值一律回落到「全部保留」—— 朝**少删**的那头落', () async {
      for (final garbage in <Object?>['7 天', '', <int>[], true, 999, -1]) {
        File(path()).writeAsStringSync(
          jsonEncode({'retentionOutbound': garbage, 'retentionReturn': garbage}),
        );

        final settings = await RecordingSettings.load(path());

        expect(settings.retentionOutbound, RetentionSetting.keepAll,
            reason: '「$garbage」不该被当成任何一个真实档位');
        expect(settings.retentionReturn, RetentionSetting.keepAll);
      }
    });

    test('档位超范围回落不夹取（999 不会变成 30 天）', () async {
      File(path()).writeAsStringSync(jsonEncode({'retentionOutbound': 999}));

      final settings = await RecordingSettings.load(path());

      expect(settings.retentionOutbound, RetentionSetting.keepAll);
    });
  });

  group('RetentionSetting.fromConfig', () {
    test('认天数，前后空白修掉，也认 num 与数字串', () {
      expect(RetentionSetting.fromConfig(' 7 '), RetentionSetting.days7);
      expect(RetentionSetting.fromConfig(7.0), RetentionSetting.days7);
      expect(RetentionSetting.fromConfig(0), RetentionSetting.none);
    });

    test('认不出的一律回落到 fallback（全部保留）', () {
      expect(RetentionSetting.fromConfig(null), RetentionSetting.fallback);
      expect(RetentionSetting.fromConfig('days7'), RetentionSetting.fallback,
          reason: '存的是天数不是名字');
      expect(RetentionSetting.fromConfig(<String>[]), RetentionSetting.fallback);
    });

    test('下拉里的名字与需求方列举的一致', () {
      // 需求方原话是「不保留/3/5/7/10/15/30/」；**「全部保留」是规格 §3.5.2
      // 本来就规定的默认**，所以多这一项 —— 这个偏差要跟他确认（交接.md §5）。
      expect(
        RetentionSetting.values.map((s) => s.label).toList(),
        ['全部保留', '不保留', '3 天', '5 天', '7 天', '10 天', '15 天', '30 天'],
      );
    });
  });

  group('WorkMode.fromConfig', () {
    test('认名字，前后空白修掉', () {
      expect(WorkMode.fromConfig(' continuousScan '), WorkMode.continuousScan);
      expect(WorkMode.fromConfig('sameWaybillStop'), WorkMode.sameWaybillStop);
    });

    test('认不出的一律回落到 fallback', () {
      expect(WorkMode.fromConfig(null), WorkMode.fallback);
      expect(WorkMode.fromConfig(1), WorkMode.fallback, reason: '序号不是格式');
      expect(WorkMode.fromConfig(''), WorkMode.fallback);
      expect(WorkMode.fromConfig(<String>[]), WorkMode.fallback);
    });
  });
}
