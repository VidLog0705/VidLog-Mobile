import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/recorder_config.dart';
import 'package:vidlog_mobile/recording/recorder_events.dart';
import 'package:vidlog_mobile/recording/stop_controller.dart';
import 'package:vidlog_mobile/recording/work_mode.dart';

/// 规格 §3.3 停录 —— 「本系统行为最复杂、也最容易出错的部分」。
///
/// 三种停录机制（同码复扫 / 画面静止 / 时长兜底）**会同时生效**，
/// 所以验其中一种时必须把另外两种隔离掉，否则测到的是三种机制的合力。
/// 下面的 [isolated] 就是把时长兜底推到很远。
void main() {
  const minute = 60 * 1000;
  const t0 = 1000000;

  final waybillA = WaybillNumber.parse('SF1000000001');
  final waybillB = WaybillNumber.parse('YT9999999999');

  /// 完整配置（三机制都按默认值生效）。
  StopController full({
    WorkMode mode = WorkMode.continuousScan,
    RecorderConfig? config,
  }) =>
      StopController(mode: mode, config: config ?? const RecorderConfig());

  /// 隔离时长兜底 —— 单独验工作模式 / 错码保护 / 静止判定时用。
  ///
  /// 因为时长兜底现在是**独立可选档位**，这里直接把它关掉即可，
  /// 不用再靠「把询问时刻推到很远」那种 hack。
  StopController isolated({
    WorkMode mode = WorkMode.continuousScan,
    StaticStopSetting staticStop = StaticStopSetting.off,
    DurationFallbackSetting durationFallback = DurationFallbackSetting.off,
  }) =>
      StopController(
        mode: mode,
        config: RecorderConfig(
          staticStop: staticStop,
          durationFallback: durationFallback,
        ),
      );

  /// 隔离静止停录 —— 单独验时长兜底时用。
  /// 不关掉静止的话，画面一直没动，静止会在 3 分钟先把录制停掉。
  StopController durationOnly({
    DurationFallbackSetting setting = DurationFallbackSetting.minutes4,
  }) =>
      StopController(
        mode: WorkMode.continuousScan,
        config: RecorderConfig(
          staticStop: StaticStopSetting.off,
          durationFallback: setting,
        ),
      );

  List<RecorderAction> start(StopController controller, {int at = t0}) =>
      controller.handle(WaybillDetected(at, waybillA));

  List<StopRecording> stops(List<RecorderAction> actions) =>
      actions.whereType<StopRecording>().toList();

  // ─────────────────────────────────────────────
  // 工作模式（§3.3.1）
  // ─────────────────────────────────────────────

  group('工作模式', () {
    test('识别到单号就开录', () {
      final controller = isolated();

      expect(stops(start(controller)), isEmpty);
      expect(controller.isRecording, isTrue);
      expect(controller.currentWaybill, waybillA);
    });

    test('连续扫：复扫同码不停止', () {
      final controller = isolated(mode: WorkMode.continuousScan);
      start(controller);

      expect(stops(controller.handle(WaybillDetected(t0 + minute, waybillA))), isEmpty);
      expect(controller.isRecording, isTrue);
    });

    test('连续扫：手动停止', () {
      final controller = isolated(mode: WorkMode.continuousScan);
      start(controller);

      final actions = controller.handle(ManualStopRequested(t0 + minute));

      expect(stops(actions).single.trigger, StopTrigger.manual);
      expect(controller.isRecording, isFalse);
    });

    test('同码停：复扫到同一单号就停', () {
      final controller = isolated(mode: WorkMode.sameWaybillStop);
      start(controller);

      final actions = controller.handle(WaybillDetected(t0 + minute, waybillA));

      expect(stops(actions).single.trigger, StopTrigger.sameWaybillRescan);
      expect(controller.isRecording, isFalse);
    });

    test('停止之后可以重新开录', () {
      final controller = isolated(mode: WorkMode.sameWaybillStop);
      start(controller);
      controller.handle(WaybillDetected(t0 + minute, waybillA));

      final actions = start(controller, at: t0 + 2 * minute);

      expect(actions.whereType<StartRecording>(), hasLength(1));
      expect(controller.isRecording, isTrue);
    });
  });

  // ─────────────────────────────────────────────
  // 错码保护（§3.3.2）
  // ─────────────────────────────────────────────

  group('错码保护', () {
    test('扫到不同面单：不停录，只语音提示', () {
      final controller = isolated(mode: WorkMode.sameWaybillStop);
      start(controller);

      final actions = controller.handle(WaybillDetected(t0 + minute, waybillB));

      expect(stops(actions), isEmpty);
      expect(actions.whereType<Speak>().single.prompt, VoicePrompt.differentWaybill);
      expect(controller.isRecording, isTrue);
    });

    test('扫错多次也不会停 —— 不存在「连续扫多次视为切换」', () {
      // 规格 §3.3.2 明确禁止这个机制，所以断言的是「扫多少次都不停」。
      final controller = isolated(mode: WorkMode.sameWaybillStop);
      start(controller);

      for (var i = 1; i <= 5; i++) {
        final actions = controller.handle(WaybillDetected(t0 + i * 10 * 1000, waybillB));

        expect(stops(actions), isEmpty, reason: '第 $i 次扫错不该停止');
        expect(controller.isRecording, isTrue);
      }
    });

    test('扫错之后再扫回正确面单才停', () {
      final controller = isolated(mode: WorkMode.sameWaybillStop);
      start(controller);
      controller.handle(WaybillDetected(t0 + minute, waybillB));

      final actions = controller.handle(WaybillDetected(t0 + 2 * minute, waybillA));

      expect(stops(actions).single.trigger, StopTrigger.sameWaybillRescan);
    });

    test('扫码静止停录模式下同样启用错码保护', () {
      final controller = isolated(mode: WorkMode.scanThenStaticStop);
      start(controller);

      final actions = controller.handle(WaybillDetected(t0 + minute, waybillB));

      expect(stops(actions), isEmpty);
      expect(actions.whereType<Speak>(), isNotEmpty);
    });
  });

  // ─────────────────────────────────────────────
  // 静止停录 + 封顶（§3.3.3 / I12）
  // ─────────────────────────────────────────────

  group('画面静止停录', () {
    test('静止达到设定时长就停', () {
      final controller = isolated(staticStop: StaticStopSetting.minutes3);
      start(controller);

      final actions = controller.handle(Heartbeat(t0 + 3 * minute));

      expect(stops(actions).single.trigger, StopTrigger.sceneStatic);
    });

    test('默认档位是 3 分钟', () {
      expect(StaticStopSetting.fallback, StaticStopSetting.minutes3);
    });

    test('★ 封顶：架机很久无人后再开录，不得立刻停止', () {
      // 规格 §3.3.3 的强制约束 + 不变量 I12 + M4 验收项。
      // 不加封顶的话，采样一进来就会看到「画面已经静止了 30 分钟」而当场停掉。
      final controller = isolated(staticStop: StaticStopSetting.minutes3);

      // 开录前画面已静止很久 —— 控制器不该把这段时间算进来
      controller.handle(SceneSampled(t0 - 30 * minute, isStatic: true));

      start(controller);

      expect(controller.handle(Heartbeat(t0 + 1000)), isEmpty, reason: '开录 1 秒后不该停');
      expect(controller.handle(Heartbeat(t0 + 3 * minute - 1000)), isEmpty,
          reason: '差 1 秒满 3 分钟，不该停');
      expect(stops(controller.handle(Heartbeat(t0 + 3 * minute))), hasLength(1));
    });

    test('中途有活动则静止时钟重置', () {
      final controller = isolated(staticStop: StaticStopSetting.minutes3);
      start(controller);

      controller.handle(SceneSampled(t0 + 2 * minute, isStatic: false));

      expect(controller.handle(Heartbeat(t0 + 3 * minute)), isEmpty,
          reason: '2 分钟时有活动，3 分钟才静止了 1 分钟');
      expect(stops(controller.handle(Heartbeat(t0 + 5 * minute))), hasLength(1));
    });

    test('设为关闭时不因静止停止', () {
      final controller = isolated(staticStop: StaticStopSetting.off);
      start(controller);

      expect(controller.handle(Heartbeat(t0 + 60 * minute)), isEmpty);
      expect(controller.isRecording, isTrue);
    });

    test('各档位按各自时长触发', () {
      for (final setting in [
        StaticStopSetting.minutes2,
        StaticStopSetting.minutes3,
        StaticStopSetting.minutes4,
        StaticStopSetting.minutes5,
      ]) {
        final controller = isolated(staticStop: setting);
        start(controller);

        final early = (setting.minutes - 1) * minute;
        expect(controller.handle(Heartbeat(t0 + early)), isEmpty,
            reason: '${setting.minutes} 分钟档：第 $early 毫秒不该停');
        expect(stops(controller.handle(Heartbeat(t0 + setting.minutes * minute))),
            hasLength(1));
      }
    });

    group('扫码静止停录的门槛', () {
      test('包裹没离场时，静止也不停', () {
        final controller = isolated(
            mode: WorkMode.scanThenStaticStop, staticStop: StaticStopSetting.minutes3);
        start(controller);

        expect(controller.handle(Heartbeat(t0 + 10 * minute)), isEmpty,
            reason: '门槛未满足：包裹还没离场');
      });

      test('只离场不回来，也不停', () {
        final controller = isolated(
            mode: WorkMode.scanThenStaticStop, staticStop: StaticStopSetting.minutes3);
        start(controller);
        controller.handle(TrackedPackageLeft(t0 + minute));

        expect(controller.handle(Heartbeat(t0 + 10 * minute)), isEmpty);
      });

      test('离场后再入场才停，且静止从入场之后重新计', () {
        final controller = isolated(
            mode: WorkMode.scanThenStaticStop, staticStop: StaticStopSetting.minutes3);
        start(controller);

        controller.handle(TrackedPackageLeft(t0 + 4 * minute));
        controller.handle(TrackedPackageEntered(t0 + 5 * minute));

        expect(controller.handle(Heartbeat(t0 + 7 * minute)), isEmpty,
            reason: '入场后只静止了 2 分钟');
        expect(stops(controller.handle(Heartbeat(t0 + 8 * minute))).single.trigger,
            StopTrigger.sceneStatic);
      });

      test('入场之后又有活动，静止时钟继续往后推', () {
        final controller = isolated(
            mode: WorkMode.scanThenStaticStop, staticStop: StaticStopSetting.minutes3);
        start(controller);
        controller.handle(TrackedPackageLeft(t0 + minute));
        controller.handle(TrackedPackageEntered(t0 + 2 * minute));
        controller.handle(SceneSampled(t0 + 4 * minute, isStatic: false));

        expect(controller.handle(Heartbeat(t0 + 6 * minute)), isEmpty);
        expect(stops(controller.handle(Heartbeat(t0 + 7 * minute))), hasLength(1));
      });

      test('另外两个模式不要求这个门槛', () {
        for (final mode in [WorkMode.continuousScan, WorkMode.sameWaybillStop]) {
          final controller = isolated(mode: mode, staticStop: StaticStopSetting.minutes3);
          start(controller);

          expect(stops(controller.handle(Heartbeat(t0 + 3 * minute))), hasLength(1),
              reason: '$mode 不该要求包裹离场再入场');
        }
      });
    });
  });

  // ─────────────────────────────────────────────
  // 时长兜底（§3.3.4）
  // ─────────────────────────────────────────────

  group('时长兜底', () {
    test('关闭档：既不出询问，也不自动停', () {
      final controller = durationOnly(setting: DurationFallbackSetting.off);
      start(controller);

      for (final minutes in [5, 30, 120]) {
        expect(controller.handle(Heartbeat(t0 + minutes * minute)), isEmpty,
            reason: '关掉之后第 $minutes 分钟也不该有任何动静');
      }
      expect(controller.isRecording, isTrue);
    });

    test('各档位按各自的分钟数询问', () {
      for (final setting in [
        DurationFallbackSetting.minutes4,
        DurationFallbackSetting.minutes5,
        DurationFallbackSetting.minutes6,
      ]) {
        final controller = durationOnly(setting: setting);
        start(controller);

        final before = (setting.minutes - 1) * minute;
        expect(controller.handle(Heartbeat(t0 + before)), isEmpty,
            reason: '${setting.minutes} 分钟档：第 $before 毫秒不该问');

        expect(
          controller
              .handle(Heartbeat(t0 + setting.minutes * minute))
              .whereType<ShowDurationPrompt>(),
          hasLength(1),
          reason: '${setting.minutes} 分钟档：到点该问',
        );
      }
    });

    test('★ 两个防忘停录档位互相独立', () {
      // 需求方明确要求「让用户自己选」——所以关掉一个不该连带关掉另一个。

      // 静止关 + 兜底开 → 只有兜底生效
      final onlyFallback = isolated(
          durationFallback: DurationFallbackSetting.minutes4);
      start(onlyFallback);
      expect(
        onlyFallback
            .handle(Heartbeat(t0 + 4 * minute))
            .whereType<ShowDurationPrompt>(),
        hasLength(1),
      );

      // 静止开 + 兜底关 → 只有静止生效（3 分钟静止停，而不是 4 分钟被问）
      final onlyStatic = isolated(staticStop: StaticStopSetting.minutes3);
      start(onlyStatic);
      expect(onlyStatic.handle(Heartbeat(t0 + 2 * minute + 59000)), isEmpty);
      expect(stops(onlyStatic.handle(Heartbeat(t0 + 3 * minute))).single.trigger,
          StopTrigger.sceneStatic);
    });

    test('两个都关 → 录制不会因为任何一项自动停', () {
      final controller = isolated();
      start(controller);

      expect(controller.handle(Heartbeat(t0 + 180 * minute)), isEmpty);
      expect(controller.isRecording, isTrue);
    });

    test('4 分钟出现语音与按钮', () {
      final controller = durationOnly();
      start(controller);

      final actions = controller.handle(Heartbeat(t0 + 4 * minute));

      expect(actions.whereType<Speak>().single.prompt, VoicePrompt.durationTimeout);
      expect(actions.whereType<ShowDurationPrompt>(), hasLength(1));
      expect(stops(actions), isEmpty, reason: '问了不等于停');
    });

    test('不操作 → 5 分钟自动停止', () {
      final controller = durationOnly();
      start(controller);
      controller.handle(Heartbeat(t0 + 4 * minute));

      expect(controller.handle(Heartbeat(t0 + 5 * minute - 1000)), isEmpty);
      expect(stops(controller.handle(Heartbeat(t0 + 5 * minute))).single.trigger,
          StopTrigger.durationFallback);
    });

    test('点「停止」立即停止', () {
      final controller = durationOnly();
      start(controller);
      controller.handle(Heartbeat(t0 + 4 * minute));

      final actions = controller
          .handle(DurationPromptAnswered(t0 + 4 * minute + 1000, continueRecording: false));

      expect(actions.whereType<HideDurationPrompt>(), hasLength(1));
      expect(stops(actions).single.trigger, StopTrigger.durationFallback);
    });

    test('点「继续」则不停止，5 分钟后再次询问', () {
      final controller = durationOnly();
      start(controller);
      controller.handle(Heartbeat(t0 + 4 * minute));
      controller.handle(
          DurationPromptAnswered(t0 + 4 * minute + 1000, continueRecording: true));

      expect(controller.isRecording, isTrue);

      final askAt = t0 + 4 * minute + 1000 + 5 * minute;
      expect(controller.handle(Heartbeat(askAt - 1000)), isEmpty);
      expect(controller.handle(Heartbeat(askAt)).whereType<ShowDurationPrompt>(),
          hasLength(1));
      expect(controller.isRecording, isTrue);
    });

    test('点继续后这一轮的上限被取消（不会在原定的 5 分钟处停）', () {
      final controller = durationOnly();
      start(controller);
      controller.handle(Heartbeat(t0 + 4 * minute));
      controller.handle(
          DurationPromptAnswered(t0 + 4 * minute + 1000, continueRecording: true));

      expect(controller.handle(Heartbeat(t0 + 5 * minute)), isEmpty);
    });

    test('关闭静止档位后，时长兜底照样生效', () {
      // 规格 §3.3.4：**对所有档位生效（含「关闭」）**。
      final controller = full(
          config: const RecorderConfig(staticStop: StaticStopSetting.off));
      start(controller);

      expect(controller.handle(Heartbeat(t0 + 4 * minute)).whereType<Speak>(),
          isNotEmpty);
    });
  });

  // ─────────────────────────────────────────────
  // 机制之间的优先级
  // ─────────────────────────────────────────────

  group('多个机制同时满足时', () {
    test('静止优先于时长兜底', () {
      // 两个机制在 5 分钟同时到期（静止 5 分钟档 + 4 分钟问、1 分钟宽限）。
      // 静止先判 —— 它是更具体的信号，报出来的原因对用户更有用。
      final controller = full(
          config: const RecorderConfig(staticStop: StaticStopSetting.minutes5));
      start(controller);

      // 4 分钟：先问
      expect(
          controller.handle(Heartbeat(t0 + 4 * minute)).whereType<ShowDurationPrompt>(),
          hasLength(1));

      // 5 分钟：两者同时到期 → 静止赢，并且把询问收掉
      final actions = controller.handle(Heartbeat(t0 + 5 * minute));

      expect(stops(actions).single.trigger, StopTrigger.sceneStatic);
      expect(actions.whereType<HideDurationPrompt>(), hasLength(1),
          reason: '停下来时要把询问收掉，不能留个死按钮在屏幕上');
    });

  });

  // ─────────────────────────────────────────────
  // 配置坏值回落（I4）
  // ─────────────────────────────────────────────

  group('配置坏值回落', () {
    test('非法静止档位一律回落到默认 3 分钟', () {
      for (final bad in <Object?>[null, 'x', 999, -1, 7, 3.5, <String>[], true]) {
        expect(StaticStopSetting.fromConfig(bad), StaticStopSetting.fallback,
            reason: '输入 $bad 应当回落到默认值');
      }
    });

    test('合法档位正常解析', () {
      expect(StaticStopSetting.fromConfig(0), StaticStopSetting.off);
      expect(StaticStopSetting.fromConfig(2), StaticStopSetting.minutes2);
      expect(StaticStopSetting.fromConfig('5'), StaticStopSetting.minutes5);
    });

    test('非法时长兜底档位一律回落到默认 4 分钟', () {
      for (final bad in <Object?>[null, 'x', 999, -1, 3, 4.5, <String>[], true]) {
        expect(DurationFallbackSetting.fromConfig(bad),
            DurationFallbackSetting.fallback,
            reason: '输入 $bad 应当回落到默认值');
      }
    });

    test('合法时长兜底档位正常解析', () {
      expect(DurationFallbackSetting.fromConfig(0), DurationFallbackSetting.off);
      expect(DurationFallbackSetting.fromConfig(4), DurationFallbackSetting.minutes4);
      expect(DurationFallbackSetting.fromConfig('6'),
          DurationFallbackSetting.minutes6);
    });

    test('坏配置不会让录制起不来', () {
      // I4：任何远端配置的缺失 / 错误 / 异常，都不得导致录制无法开始或异常停止。
      final config = RecorderConfig(staticStop: StaticStopSetting.fromConfig('垃圾'));
      final controller = StopController(
          mode: WorkMode.continuousScan, config: config);

      expect(start(controller).whereType<StartRecording>(), hasLength(1));
      expect(controller.isRecording, isTrue);
    });
  });

  // ─────────────────────────────────────────────
  // 停录只依赖本地事实（§3.3.5）
  // ─────────────────────────────────────────────

  group('停录只依赖本地可观测的事实', () {
    test('不喂事件就不会自己停 —— 不存在偷偷跑的定时器', () {
      final controller = full(
          config: const RecorderConfig(staticStop: StaticStopSetting.minutes3));

      expect(controller.isRecording, isFalse);
      expect(controller.elapsedMs(t0 + 60 * minute), 0);
    });

    test('已录时长基于单调时钟，与墙钟无关', () {
      final controller = isolated();
      start(controller);

      // 规格 §3.6.3 / I11：用户改系统时间不得影响时长。
      // 状态机只吃单调毫秒，压根没有墙钟入参 —— 这是结构保证。
      expect(controller.elapsedMs(t0 + 5 * minute), 5 * minute);
    });
  });
}
