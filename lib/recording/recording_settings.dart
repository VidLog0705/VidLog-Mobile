import 'dart:convert';
import 'dart:io';

import 'recorder_config.dart';
import 'recording_spec.dart';
import 'recording_workspace.dart' show writeFileAtomically;
import 'retention_setting.dart';
import 'work_mode.dart';

/// 用户选的录制设置（`<root>/settings.json`）。
///
/// 落盘的十四项：工作模式、静止停录档位、时长兜底档位、语音播报开关、
/// 录制规格三项（编码 / 分辨率 / 方向，规格 §3.1.7）、
/// 归档后的本地保留期四项（发货 / 退货 × 已备份 / 未备份，规格 §3.5.2.1）、
/// 2026-09-28 加的两项（面单条码最短长度、录制声音），
/// 以及 2026-10-01 加的实时共享开关（规格 §3.8）。
///
/// ## 为什么单独一个文件，不并进 `device.json`
///
/// `device.json` 装的是**本机身份**，而它读坏的代价不可逆：读不出 `deviceId`
/// 就只能重新生成，这台手机在电脑端**变成一台新设备**，之前的机位名再也对不上。
///
/// 设置是**每改一次开关就写一次**的东西。混进同一个文件，等于让一条高频、
/// 无关的写路径反复去碰身份 —— 把那个不可逆故障的出错面白白放大几十倍。
///
/// ## ⚠️ `accelerated` 故意不在这里
///
/// 它是**真机验收用的**（把时长兜底的首次询问压到 20 秒）。
/// 一旦落盘，验收完忘了关，**真实录制**就会在开录 20 秒后被问一次
/// 「是否停止录制」—— 一个调试开关就此变成产品行为，而且用户看着它像是
/// 正常功能。所以它每次启动都归 false，只活在内存里。
///
/// ## ⚠️ 读坏了**不抛异常**
///
/// 这是 I4 的落点：**任何配置的缺失 / 格式错误 / 值超范围都不得导致录制失败**。
/// 所以 [load] 把「文件不存在」和「文件是垃圾」当成同一件事 —— 一律走硬兜底，
/// 照常返回一份可用的设置。
///
/// 与 `device.json` 的另一个区别：**这里不主动建文件**。没有文件 = 用户从没改过，
/// 默认值就是对的，没必要为一个从没发生过的事写一次盘。等用户真改了再写。
class RecordingSettings {
  RecordingSettings({
    required this.path,
    required this.mode,
    required this.staticStop,
    required this.durationFallback,
    required this.voiceEnabled,
    required this.retentionArchivedOutbound,
    required this.retentionArchivedReturn,
    required this.retentionUnarchivedOutbound,
    required this.retentionUnarchivedReturn,
    this.codec = VideoCodec.h264,
    this.resolution = VideoResolution.p1080,
    this.orientation = RecordingOrientation.portrait,
    this.waybillMinLength = WaybillMinLength.fallback,
    this.recordAudio = true,
    this.liveShareEnabled = false,
  });

  final String path;

  /// 工作模式（规格 §3.3.1）。
  WorkMode mode;

  /// 静止停录档位（规格 §3.3.3）。
  StaticStopSetting staticStop;

  /// 时长兜底档位（规格 §3.3.4）。
  DurationFallbackSetting durationFallback;

  /// 语音播报开关。
  ///
  /// ⚠️ **默认开，而且读不出来也回落到开。** 理由与别的项相反，值得写下来：
  /// 规格 §3.3.2 的错码保护**就是靠播报**告诉用户「扫的不是同一件」。
  /// 这一项静默变成「关」（比如字段丢了、被人手改成字符串），用户不会发现 ——
  /// 他只会以为「这个功能没做」，然后把错的包裹录进去。
  /// **静默关掉一个提示功能，比静默开着吵一点严重得多。**
  bool voiceEnabled;

  /// 归档成功后，**发货**那批本地留多久（规格 §3.5.2.1 的**已备份**那一列）。
  ///
  /// 四个数分开存，互不影响 —— 需求方 2026-09-23 裁决的是「发货与退货各自一个」，
  /// 2026-09-24 又加了「已备份 / 未备份」这一维。
  RetentionSetting retentionArchivedOutbound;

  /// 归档成功后，**退货**那批本地留多久。改它不影响 [retentionArchivedOutbound]。
  RetentionSetting retentionArchivedReturn;

  /// **还没备份上去**的发货那批留多久。
  ///
  /// ⚠️ **这一列永不自动删任何东西**（那是唯一副本，I2）——
  /// 它到期的动作只有「催」：列表里标红 + 顶部那条「N 个未备份」。
  /// 起算点是**录完时刻**（未备份的还没有归档时刻可用）。
  RetentionSetting retentionUnarchivedOutbound;

  /// 还没备份上去的退货那批留多久。见 [retentionUnarchivedOutbound]。
  RetentionSetting retentionUnarchivedReturn;

  /// 编码格式（规格 §3.1.7）。**录制前可选、录制中不可改**。
  VideoCodec codec;

  /// 分辨率档位。
  VideoResolution resolution;

  /// 成片方向。**只有手机端有这一项**（电脑端的摄像头方向由设备与安装决定）。
  RecordingOrientation orientation;

  /// 面单条码最短长度（需求方 2026-09-28 加，见 [WaybillMinLength]）。
  ///
  /// ⚠️ **只作用于相机识码**。手工输入的单号不走这个判据。
  WaybillMinLength waybillMinLength;

  /// 录像**文件里**带不带声音（需求方 2026-09-28 加）。
  ///
  /// ## ⚠️ 它与「语音播报」是两件事，别混
  ///
  /// - 这一项管的是**录出来的 mp4 里那条音轨**，也就是录进去了什么；
  /// - [voiceEnabled] 管的是**这台手机现在出不出声**（含表盘滴声）。
  ///
  /// 两个可以同时开：那时播报会被录进录像里。需求方 2026-09-28 明确
  /// 要的是两个独立开关，**不合并**。
  ///
  /// ## ⚠️ 默认**开**
  ///
  /// 取证视频带声音是更完整的一份证据。默认关的话，绝大多数用户
  /// 根本不会发现这个功能存在。代价要说清楚：**已装机的用户升上来之后，
  /// 录像会突然开始有声音** —— 这一点写在交付说明里。
  ///
  /// 读坏了同样回 `true`：这一项**没有安全方向可言** —— 关掉它不会更安全，
  /// 开着也只是多一条音轨。与 [voiceEnabled] 一样「只认真正的 bool」，
  /// 不认字符串 `'false'`。
  bool recordAudio;

  /// 实时共享：把这台手机的相机画面推给电脑端看（规格 §3.8）。
  ///
  /// ## ⚠️ 默认**关**，而且读不出来也回落成关
  ///
  /// 与 [voiceEnabled] / [recordAudio] 的方向**相反**，理由值得写下来：
  /// 那两项的默认值是在「静默关掉一个已有功能」与「静默开着」之间选，
  /// 静默关掉更糟。而这一项**开了才会发生一件事** ——
  /// 相机画面开始在局域网上传出去，同时多烧一份编码的 CPU 与电。
  /// 读坏了就替用户决定「把相机推出去」，那是替他做主，不是保守。
  ///
  /// ⚠️ 它**不影响录制**：推流那一路是独立的编码器，关它 / 开它都不碰
  /// 录制那条链路（规格 §3.8 的三条隔离规则）。
  bool liveShareEnabled;

  /// 用户选的那一档 —— 落盘与界面都按它走。
  ///
  /// ⚠️ 它与**实际启用**的那一档可能不一样：规格 §3.1.7 要求录制前做
  /// 真实的可用性检查，跑不通就回落，**而且回落必须可见**。
  /// 实际那一档由原生探测给出（见 `RecordingSpecProbe`），不是这个。
  RecordingSpec get requestedSpec =>
      RecordingSpec(codec: codec, resolution: resolution, orientation: orientation);

  /// 读设置。**任何读取失败都回落到硬兜底值，绝不抛。**
  static Future<RecordingSettings> load(String path) async {
    var json = const <String, Object?>{};

    final file = File(path);
    if (await file.exists()) {
      try {
        json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      } on Object {
        // 半个 JSON / 顶层不是对象 / 编码坏了 → 全走兜底。
        // **不 rethrow**：设置读不出来不能拦住录制（I4）。
      }
    }

    return RecordingSettings(
      path: path,
      mode: WorkMode.fromConfig(json['mode']),
      staticStop: StaticStopSetting.fromConfig(json['staticStop']),
      durationFallback: DurationFallbackSetting.fromConfig(json['durationFallback']),
      // 只认真正的 bool。**不认字符串 'false'** —— 认它就得在这里开始猜
      // 各种写法（'0' / 'no' / '' 算不算），而每多认一种就多一种把
      // 「本来是关」读成「开」或反之的机会。这个文件是我们自己写的。
      voiceEnabled: switch (json['voiceEnabled']) {
        final bool value => value,
        _ => true,
      },
      // 保留期四个数。⚠️ **老的 `retentionOutbound` / `retentionReturn` 也要认** ——
      // 那时它俩说的是「已备份后的本地保留期」，语义没变，只是多了一列
      // （规格 §3.5.2.1 的 2026-09-24 变更）。不认的话那两个数会被**静默丢掉**，
      // 用户看到的是「我明明设过 7 天，怎么变回全部保留了」。
      retentionArchivedOutbound: RetentionSetting.fromConfig(
          json['retentionArchivedOutbound'] ?? json['retentionOutbound']),
      retentionArchivedReturn: RetentionSetting.fromConfig(
          json['retentionArchivedReturn'] ?? json['retentionReturn']),
      // 新增的两列默认「全部保留」——**未备份那一列永不自动删**，
      // 所以老文件升上来之后的行为与从前完全一致（不会开始删东西）。
      retentionUnarchivedOutbound:
          RetentionSetting.fromConfig(json['retentionUnarchivedOutbound']),
      retentionUnarchivedReturn:
          RetentionSetting.fromConfig(json['retentionUnarchivedReturn']),
      codec: VideoCodec.fromConfig(json['codec']),
      resolution: VideoResolution.fromConfig(json['resolution']),
      orientation: RecordingOrientation.fromConfig(json['orientation']),
      // 2026-09-28 新增。⚠️ **老文件里没有这两个键** —— 缺席就走各自的默认档
      // （11 位 / 开）。这两个默认值就是「升级之后行为变了吗」的答案：
      // 条码下限**变了**（老版本什么都认），录制声音也**变了**（老版本不录音）。
      // 两条都写进交付说明。
      waybillMinLength: WaybillMinLength.fromConfig(json['waybillMinLength']),
      recordAudio: switch (json['recordAudio']) {
        final bool value => value,
        _ => true,
      },
      // 2026-10-01 新增。⚠️ 老文件里没有这个键 ⇒ 走 `false`（关）——
      // 「升级之后行为变了吗」的答案是：**没有**。谁也没在不知情的时候
      // 开始把画面推出去。
      liveShareEnabled: switch (json['liveShareEnabled']) {
        final bool value => value,
        _ => false,
      },
    );
  }

  /// 写回盘。走原子写：掉电时要么是旧的、要么是新的，不会留半个文件。
  Future<void> save() async {
    final file = File(path);
    await file.parent.create(recursive: true);

    await writeFileAtomically(
      path,
      const JsonEncoder.withIndent('  ').convert({
        // 模式存**名字**不存序号：序号看着短，但枚举一旦重排，
        // 老文件会被**静默**解析成另一个模式 —— 录制行为当场变了而没人知道。
        'mode': mode.name,

        // 两个档位存**分钟数**不存名字，因为 `fromConfig` 认的就是分钟数
        // （它是给远端配置写的，那边传过来的就是个数）。
        // 存名字的话 `int.tryParse('minutes3')` 会失败，然后**静默回落成默认档位**。
        'staticStop': staticStop.minutes,
        'durationFallback': durationFallback.minutes,

        'voiceEnabled': voiceEnabled,

        // 保留期同样存**天数**，理由与上面两个档位一样。`keepAll` 存的是 null。
        //
        // ⚠️ 这里**不能拿 0 去兼职表示「全部保留」** —— `0` 已经是
        // 「不保留」这个真实档位的天数。合并的话，读回来会把「永远不删」
        // 变成「归档后最快 24 小时就删」，而且是**静默**的：
        // 用户看到的下拉还是「全部保留」那一项挑不着毛病。
        //
        // ⚠️ 2026-09-27 起键名带上了「已备份 / 未备份」—— 老的
        // `retentionOutbound` / `retentionReturn` **不再写**（写了就是两份真相），
        // 但**读的时候仍然认**（见 `load`）。
        'retentionArchivedOutbound': retentionArchivedOutbound.days,
        'retentionArchivedReturn': retentionArchivedReturn.days,
        'retentionUnarchivedOutbound': retentionUnarchivedOutbound.days,
        'retentionUnarchivedReturn': retentionUnarchivedReturn.days,

        // 录制规格三项：与工作模式同一个理由，**存名字不存序号** ——
        // 序号一旦被当格式，枚举重排会把老文件静默解析成另一档，
        // 而这里的「静默」具体是：用户以为在录 4K，其实在录 720P。
        'codec': codec.name,
        'resolution': resolution.name,
        'orientation': orientation.name,

        // 条码下限存**位数**，理由与两个档位一样（`fromConfig` 认的就是个数）。
        // ⚠️ 「不限」存成 **0**，而 0 是一个真档位、不是「没设过」——
        // 两者必须分得开：键在且为 0 = 用户选了不限；**键不在**（老文件）
        // 才走默认的 11 位。合并的话，「不限」每次重开 App 都会被改回 11 位。
        'waybillMinLength': waybillMinLength.length,

        'recordAudio': recordAudio,

        'liveShareEnabled': liveShareEnabled,
      }),
    );
  }
}
