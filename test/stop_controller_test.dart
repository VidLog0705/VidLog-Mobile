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
  const second = 1000;
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

    test('★ 扫码静止停录：复扫同码**也**停止（2026-09-22 二次推翻）', () {
      // ⚠️ **这条测试在 2026-09-22 被需求方推翻过一次，方向反过来。**
      //
      // 更早的写法断言的是「复扫同码**不**停」，理由是 §3.3.1 的停止条件列
      // 只写了「离场→入场→静止」，若也认复扫这个模式就与「同码停」等价了。
      // 需求方 2026-09-22 晚些三次口述全都指向「复扫同码就停」，
      // 遂作废该裁定（规格 §3.3.1 记为「二次推翻」）。
      //
      // 变红配方 = 把 `WorkMode.stopsOnSameWaybillRescan` 的
      // `scanThenStaticStop` 那行改回 `false`。**红的必须是这一条。**
      final controller = isolated(
          mode: WorkMode.scanThenStaticStop, staticStop: StaticStopSetting.minutes3);
      start(controller);

      final actions = controller.handle(WaybillDetected(t0 + minute, waybillA));

      expect(stops(actions).single.trigger, StopTrigger.sameWaybillRescan);
      expect(controller.isRecording, isFalse);
    });

    test('★ 两个模式的区别还在：静止兜底的门槛不同', () {
      // 「扫码静止改成复扫同码就停」之后，这个模式**没有**变成同码停的副本 ——
      // 它仍然多一道「包裹先离场、再入场」的前置门槛（[staticStopRequiresPackageReturn]）。
      // 少了这条，`scanThenStaticStop` 那行改成 true 就真的只是把两个模式合并了。
      // 变红配方 = 把 `staticStopRequiresPackageReturn` 改成恒 false。
      //
      // ⚠️ 静止档位设成**关闭**：这个模式的 2 秒是**它自己的**（规格 §3.3.1 📌），
      // 不读档位。用「关闭」跑，停下来了就顺带证明这 2 秒不是档位给的。
      final controller = isolated(
          mode: WorkMode.scanThenStaticStop, staticStop: StaticStopSetting.off);
      start(controller);

      // 面单一直摆着没动，但**从没离场**：静止判定不许开闸。
      expect(controller.handle(Heartbeat(t0 + 3 * minute)), isEmpty);
      expect(controller.isRecording, isTrue, reason: '没离过场 = 静止门槛没开');

      // 离场 → 入场 → 再静止 2 秒，这才停。
      controller.handle(TrackedPackageLeft(t0 + 3 * minute + 1000));
      controller.handle(TrackedPackageEntered(t0 + 3 * minute + 2000));

      expect(
          stops(controller.handle(
                  Heartbeat(t0 + 3 * minute + 2000 + 2 * second)))
              .single
              .trigger,
          StopTrigger.sceneStatic);
    });

    test('★ 扫码静止停录：停掉的是这一段，不是结束工作', () {
      // 需求方 2026-09-22 原话：「扫码静止停录是面单在镜头下静止两秒，
      // 然后**结束当前段视频录制**。而不是彻底停止工作。」（规格 §3.3.1 📌 第 2 点）
      //
      // 状态机这一层能证明的就是「停录之后还能立刻为下一件开录」——
      // 「相机还开着」是编排器/页面那一层的事（那里有 `_cameraOpen` 与自己的一组测试）。
      final controller = isolated(
          mode: WorkMode.scanThenStaticStop, staticStop: StaticStopSetting.off);
      start(controller);
      controller.handle(TrackedPackageLeft(t0 + minute));
      controller.handle(TrackedPackageEntered(t0 + minute + 1000));
      expect(
          stops(controller.handle(Heartbeat(t0 + minute + 1000 + 2 * second))),
          hasLength(1));

      final again = start(controller, at: t0 + 2 * minute);

      expect(again.whereType<StartRecording>(), hasLength(1),
          reason: '停的只是这一段，下一件照常开录');
      expect(controller.isRecording, isTrue);
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

    test('扫错多次也不会停 —— 同一单号扫多少次都不算切换', () {
      // 规格 §3.3.2 禁止这个机制（同一单号扫多次只提示），所以断言的是
      // 「扫多少次都不停」。**连续扫不受此限**，但它的判据是
      // 「扫到**不同**的单号」，不是「扫了很多次」——
      // 见下面「换段式连续扫（§3.3.1，2026-09-22 需求变更）」那一组。
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
  // 声音提示（§3.3.6，需求方 2026-09-22 晚些）
  // ─────────────────────────────────────────────
  //
  // 规格那张表有六行，**三行要滴、三行不要**。这里逐行验，
  // 因为「多滴了一声」和「少滴了一声」在真机上都是要重出一版包的错。

  group('声音提示（§3.3.6）', () {
    /// 把动作里那两句播报摘出来，顺序与滴声一起看。
    List<(VoicePrompt, bool)> sounds(List<RecorderAction> actions) =>
        actions.whereType<Speak>().map((a) => (a.prompt, a.beep)).toList();

    test('★ 识别到单号开录：滴一声 + 播「开始录像」', () {
      final controller = isolated(mode: WorkMode.sameWaybillStop);

      expect(sounds(start(controller)), [(VoicePrompt.startRecording, true)]);
    });

    test('★ 复扫到同一单号停录：滴一声 + 播「停止录像」', () {
      final controller = isolated(mode: WorkMode.sameWaybillStop);
      start(controller);

      final actions = controller.handle(WaybillDetected(t0 + minute, waybillA));

      expect(sounds(actions), [(VoicePrompt.stopRecording, true)]);
    });

    test('★ 连续扫换段：只播「开始录像」，不播上一段的「停止录像」', () {
      // 这是「换段只播开始」那条规格。一句「停止」接着一句「开始」
      // 会让操作员以为录断了，而实际上本段是正常收尾的。
      final controller = isolated(mode: WorkMode.continuousScan);
      start(controller);

      final rotate = controller.handle(WaybillDetected(t0 + minute, waybillB));
      expect(sounds(rotate), isEmpty, reason: '换段那一下本身不出声');

      // 下一段重新进来（编排器在收尾之后带着新单号再喂一次）。
      final next = controller.handle(WaybillDetected(t0 + minute + 100, waybillB));

      expect(sounds(next), [(VoicePrompt.startRecording, true)]);
    });

    test('★ 扫到不同面单：滴一声 + 播「面单错误，请扫描正确面单」，且不停录', () {
      final controller = isolated(mode: WorkMode.sameWaybillStop);
      start(controller);

      final actions = controller.handle(WaybillDetected(t0 + minute, waybillB));

      expect(sounds(actions), [(VoicePrompt.differentWaybill, true)]);
      expect(stops(actions), isEmpty);
    });

    test('★ 画面静止自动停：**不播**「停止录像」', () {
      // 刻意不播（规格 §3.3.6 的约束）。用户多半已经走开，
      // 补一句只会像设备在自言自语，还会盖住下一件的「开始录像」。
      // 变红配方 = 在 `_stop` 里把那条 `if (trigger == ...)` 去掉。
      final controller = isolated(
          mode: WorkMode.sameWaybillStop, staticStop: StaticStopSetting.minutes2);
      start(controller);

      final actions = controller.handle(Heartbeat(t0 + 3 * minute));

      expect(stops(actions).single.trigger, StopTrigger.sceneStatic);
      expect(sounds(actions), isEmpty);
    });

    test('★ 时长兜底自动停：**不播**「停止录像」', () {
      final controller = durationOnly();
      start(controller);
      controller.handle(Heartbeat(t0 + 4 * minute)); // 先弹出询问，没人理

      final actions = controller.handle(Heartbeat(t0 + 5 * minute));

      expect(stops(actions).single.trigger, StopTrigger.durationFallback);
      expect(sounds(actions), isEmpty);
    });

    test('★ 时长兜底点【停止】：也不播「停止录像」', () {
      // 那是用户手里的按钮按出来的，但他按的不是【结束】——
      // 规格 §3.3.6 那张表里没有这一行，所以照旧一声不响。
      final controller = durationOnly();
      start(controller);
      controller.handle(Heartbeat(t0 + 4 * minute));

      final actions = controller.handle(
          DurationPromptAnswered(t0 + 4 * minute + 1000, continueRecording: false));

      expect(stops(actions).single.trigger, StopTrigger.durationFallback);
      expect(sounds(actions), isEmpty);
    });

    test('★ 手动停止：状态机一声不响（那两句由编排器播）', () {
      // 「点【结束】播『停止工作』」不在状态机里 —— 那是「用户点了按钮」，
      // 不是录制事件。见 `RecordingCoordinator.stopWorking`。
      // 在这里再播一句「停止录像」就是同一件事说两遍。
      final controller = isolated(mode: WorkMode.sameWaybillStop);
      start(controller);

      final actions = controller.handle(ManualStopRequested(t0 + minute));

      expect(stops(actions).single.trigger, StopTrigger.manual);
      expect(sounds(actions), isEmpty);
    });

    test('★ 时长兜底那句询问**不滴**（规格那张表里没它）', () {
      final controller = durationOnly();
      start(controller);

      final actions = controller.handle(Heartbeat(t0 + 4 * minute));

      expect(sounds(actions), [(VoicePrompt.durationTimeout, false)]);
    });
  });

  // ─────────────────────────────────────────────
  // 换段式连续扫（§3.3.1，2026-09-22 需求变更）
  // ─────────────────────────────────────────────

  group('换段式连续扫', () {
    test('★ 扫到别的单号 = 换件：收掉本段，且不说「面单不同」', () {
      final controller = isolated(mode: WorkMode.continuousScan);
      start(controller);

      final actions = controller.handle(WaybillDetected(t0 + minute, waybillB));

      expect(stops(actions).single.trigger, StopTrigger.nextWaybill);
      expect(controller.isRecording, isFalse);

      // 换件在连续扫里是**正常路径**，不是错码。播一句「面单不同」既不对，
      // 还会盖过下一件的开录播报。
      expect(actions.whereType<Speak>(), isEmpty);
    });

    test('换件之后还能接着为新单号开录', () {
      final controller = isolated(mode: WorkMode.continuousScan);
      start(controller);
      controller.handle(WaybillDetected(t0 + minute, waybillB));

      final actions = controller.handle(WaybillDetected(t0 + 2 * minute, waybillB));

      expect(actions.whereType<StartRecording>(), hasLength(1));
      expect(controller.isRecording, isTrue);
      expect(controller.currentWaybill, waybillB);
    });

    test('★ 错码保护没漏到另两个模式（只有连续扫换段）', () {
      // 这是唯一挡住「换段」漏进另两个模式的闸：
      // 变红配方 = 把 `WorkMode.rotatesOnNewWaybill` 改成恒 true。
      for (final mode in [WorkMode.sameWaybillStop, WorkMode.scanThenStaticStop]) {
        final controller = isolated(mode: mode);
        start(controller);

        final actions = controller.handle(WaybillDetected(t0 + minute, waybillB));

        expect(stops(actions), isEmpty, reason: '$mode 不该换段');
        expect(actions.whereType<Speak>().single.prompt, VoicePrompt.differentWaybill,
            reason: '$mode 必须照旧提示「面单不同」');
        expect(controller.isRecording, isTrue, reason: '$mode 必须继续录');
      }
    });

    test('rotatesOn 是纯查询：问它不改变任何状态', () {
      // 编排器要在派发事件**之前**问它（决定这一下算不算本段的复扫打点），
      // 所以它绝不能有副作用 —— 问两次的答案必须一样，且状态机没动。
      final controller = isolated(mode: WorkMode.continuousScan);
      start(controller);

      expect(controller.rotatesOn(waybillB), isTrue);
      expect(controller.rotatesOn(waybillB), isTrue);
      expect(controller.rotatesOn(waybillA), isFalse);
      expect(controller.isRecording, isTrue);
      expect(controller.currentWaybill, waybillA);
    });

    test('没在录的时候问 rotatesOn 一律 false', () {
      final controller = isolated(mode: WorkMode.continuousScan);

      expect(controller.rotatesOn(waybillB), isFalse);
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
      // 本组一律把静止档位设成**关闭**（[isolated] 的默认值）——
      // 规格 §3.3.1 的 2026-09-22 📌 说得很明白：这个模式的 2 秒是**它自己的**，
      // 不读档位。拿「关闭」跑，「它停了」就同时证明了「这 2 秒不来自档位」。
      //
      // ⚠️ 变红配方（每条的「红了就是你要证明的那条」）：
      // - 把 `ownStaticStopDuration` 改成返回 null → 前四条全红（2 秒那条判据没了，
      //   档位又是关闭的，于是永远不停）
      // - 把 `staticStopRequiresPackageReturn` 改成恒 false → 第一条红
      // - 把 `_staticStopDelay` 改成只读档位 → 后两条红

      test('包裹没离场时，静止多久都不停', () {
        final controller = isolated(mode: WorkMode.scanThenStaticStop);
        start(controller);

        expect(controller.handle(Heartbeat(t0 + 10 * minute)), isEmpty,
            reason: '门槛未满足：包裹还没离场');
      });

      test('只离场不回来，也不停', () {
        final controller = isolated(mode: WorkMode.scanThenStaticStop);
        start(controller);
        controller.handle(TrackedPackageLeft(t0 + minute));

        expect(controller.handle(Heartbeat(t0 + 10 * minute)), isEmpty);
      });

      test('离场后再入场，静止满 2 秒就停；差一点不停', () {
        final controller = isolated(mode: WorkMode.scanThenStaticStop);
        start(controller);

        controller.handle(TrackedPackageLeft(t0 + 4 * minute));
        controller.handle(TrackedPackageEntered(t0 + 5 * minute));

        // ⚠️ 这 2 秒**从入场那一刻**起算（不是从离场前那次活动算）。
        expect(
            controller.handle(Heartbeat(t0 + 5 * minute + 2 * second - 1)), isEmpty,
            reason: '差 1 毫秒，不该停');
        expect(
            stops(controller.handle(Heartbeat(t0 + 5 * minute + 2 * second)))
                .single
                .trigger,
            StopTrigger.sceneStatic);
      });

      test('入场之后又有活动，这 2 秒从头再计', () {
        final controller = isolated(mode: WorkMode.scanThenStaticStop);
        start(controller);
        controller.handle(TrackedPackageLeft(t0 + minute));
        controller.handle(TrackedPackageEntered(t0 + 2 * minute));
        controller.handle(SceneSampled(t0 + 2 * minute + 1500, isStatic: false));

        expect(controller.handle(Heartbeat(t0 + 2 * minute + 3 * second)), isEmpty,
            reason: '入场后 1.5 秒有活动 ⇒ 静止时钟推后，3 秒时还差一点');
        expect(
            stops(controller.handle(
                Heartbeat(t0 + 2 * minute + 1500 + 2 * second))),
            hasLength(1));
      });

      test('★ 静止档位设成「关闭」也照样停（这 2 秒不是档位给的）', () {
        // 规格 §3.3.1 📌 第 1 点：少了这条，本模式在「复扫同码就停」之后
        // 与同码停**完全等价**，只剩一个名字。
        final controller =
            isolated(mode: WorkMode.scanThenStaticStop, staticStop: StaticStopSetting.off);
        start(controller);
        controller.handle(TrackedPackageLeft(t0 + minute));
        controller.handle(TrackedPackageEntered(t0 + minute + second));

        expect(
            stops(controller.handle(Heartbeat(t0 + minute + second + 2 * second))),
            hasLength(1));
      });

      test('★ 另外两个模式不吃这 2 秒 —— 那是扫码静止自己的判据', () {
        for (final mode in [WorkMode.continuousScan, WorkMode.sameWaybillStop]) {
          final controller = isolated(
              mode: mode, staticStop: StaticStopSetting.off);
          start(controller);

          expect(controller.handle(Heartbeat(t0 + 10 * second)), isEmpty,
              reason: '$mode 的静止判据由档位管，档位关闭时 2 秒、10 秒都不停');
        }
      });

      test('另外两个模式不要求「离场再入场」这个门槛', () {
        for (final mode in [WorkMode.continuousScan, WorkMode.sameWaybillStop]) {
          final controller =
              isolated(mode: mode, staticStop: StaticStopSetting.minutes3);
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
