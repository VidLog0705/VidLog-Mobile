/// 录制规格：编码 + 分辨率 + 方向（规格 §3.1.7）。
///
/// 与电脑端 `VidLog.Desktop.Core/Media/RecordingSpec.cs` 是**同一份规格的两半**：
/// 编码与分辨率两端的档位、名字、容量系数都**必须逐字一致**（用户在两台机器上
/// 看到的是同一组选项），而**方向只有手机端有** —— 电脑端的摄像头方向由设备与
/// 安装决定，不提供选项（规格 §3.1.7 ② 原话「仅手机端」）。
///
/// ## 这个文件里有三条不能忘的规矩
///
/// 1. **界面上只写「H.265」**，任何地方都不得出现「HEVC」。规格原话：
///    「两个名字混用会让用户以为是两种不同的编码」。所以名字由
///    [RecordingSpec.codecLabel] **一处产出**，别处不许拼。
/// 2. **帧率上限 30、不提供选择** ⇒ 它是常量 [kFrameRate]，不是配置项。
/// 3. **`fromConfig` 认任意垃圾输入**（I4：配置坏掉不得导致录制失败）。
library;

/// 编码格式。
///
/// ⚠️ **落盘存名字不存序号** —— 与 [WorkMode] 同一个理由：序号一旦枚举重排，
/// 老配置会被**静默**解析成另一种编码，用户看到的画面质量当场变了而没人知道。
enum VideoCodec {
  h264,
  h265;

  /// 配置坏掉时用的值（规格 §3.1.7 表格的默认档）。
  static const fallback = VideoCodec.h264;

  static VideoCodec fromConfig(Object? raw) {
    if (raw is VideoCodec) return raw;
    if (raw is String) {
      final name = _normalize(raw);
      for (final codec in VideoCodec.values) {
        if (_normalize(codec.name) == name) return codec;
      }
    }
    return fallback;
  }
}

/// 分辨率档位。
///
/// ⚠️ 名字与序号都落盘过（历史包写的是 `uhd4K` 这样的名字），所以
/// [fromConfig] 只认名字 —— 序号从来不是这套枚举的存储格式。
enum VideoResolution {
  /// 4K。
  uhd4K,

  /// 1080P（默认）。
  p1080,

  /// 720P。
  p720;

  static const fallback = VideoResolution.p1080;

  static VideoResolution fromConfig(Object? raw) {
    if (raw is VideoResolution) return raw;
    if (raw is String) {
      final name = _normalize(raw);
      for (final resolution in VideoResolution.values) {
        if (_normalize(resolution.name) == name) return resolution;
      }
    }
    return fallback;
  }
}

/// 把「H.265」/「h-265」/「H265」这类写法归一成枚举名那种形态（`h265`）。
///
/// 宽容不是为了好看：索引里的编码名可能来自**另一端的写端**
/// （电脑端写的是枚举名，手机端写的是自己的名字），也见过人手改坏的配置。
/// 认不出来会**静默回落到默认档**，于是「4K 的录像按 1080P 估容量」——
/// 而容量估算正被「清理到够为止」用着，估错就是「删了还不够」。
String _normalize(String raw) =>
    raw.trim().toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

/// 成片方向（**只有手机端有这一项**）。
///
/// [portrait] 是默认：这一行的活是拿手机对着面单扫，绝大多数时候是竖着持机。
///
/// ⚠️ 两个横屏的名字按**听筒朝哪边**定，两端的原生实现都照这一条映射
/// （iOS 的旋转角、安卓的 `setOrientationHint`）——
/// 而两边系统的命名习惯与此**正好相反**，所以那两处的注释里都写了「别照着名字改」。
enum RecordingOrientation {
  /// 横左：手机向**左**倒（听筒朝左，Home 键在右手侧）。
  landscapeLeft,

  /// 竖屏（默认）。
  portrait,

  /// 横右：手机向**右**倒（听筒朝右）。
  landscapeRight;

  static const fallback = RecordingOrientation.portrait;

  static RecordingOrientation fromConfig(Object? raw) {
    if (raw is RecordingOrientation) return raw;
    if (raw is String) {
      final name = _normalize(raw);
      for (final orientation in RecordingOrientation.values) {
        if (_normalize(orientation.name) == name) return orientation;
      }
    }
    return fallback;
  }
}

/// 帧率上限。规格：「最高 30 帧、**不提供选择**」。
///
/// 所以它是常量而不是档位 —— 摆一个只有一个选项的下拉是骗人的
/// （用户会以为别的机型上有得选）。
const int kFrameRate = 30;

/// 一档完整的录制规格。
class RecordingSpec {
  const RecordingSpec({
    this.codec = VideoCodec.h264,
    this.resolution = VideoResolution.p1080,
    this.orientation = RecordingOrientation.portrait,
  });

  /// 默认档：H.264 + 1080P + 竖屏（规格 §3.1.7 的表格）。
  static const standard = RecordingSpec();

  final VideoCodec codec;
  final VideoResolution resolution;
  final RecordingOrientation orientation;

  /// **成片**（播放器看到的）宽高。
  ///
  /// 横屏两档都是标准的 16:9；竖屏就是把宽高对调 —— 原生的编码尺寸仍是横的
  /// （iOS 的 session preset / 安卓选出来的 `Size`），再靠旋转让播放器转过来，
  /// 所以「存的是横的、看的是竖的」这件事在这一处收口。
  (int, int) get size {
    final (width, height) = switch (resolution) {
      VideoResolution.uhd4K => (3840, 2160),
      VideoResolution.p720 => (1280, 720),
      VideoResolution.p1080 => (1920, 1080),
    };

    return orientation == RecordingOrientation.portrait
        ? (height, width)
        : (width, height);
  }

  /// 画面宽 / 画面高。
  ///
  /// ⚠️ **取景框要用它，不能再用那个写死的 `720 / 1280`**（规格 §3.2.2 的连带项）。
  /// 界面画的框和系统实际判定的范围必须严格一致，否则用户看着框把面单放进去、
  /// 系统却说不算 —— 那是取证工具最不能有的行为。改了方向而框不跟着改，
  /// 就正好会变成那样。
  double get aspectRatio {
    final (width, height) = size;
    return width / height;
  }

  /// 界面上写的编码名（**唯一一处产出**，见文件头的规矩 1）。
  String get codecLabel => codec == VideoCodec.h265 ? 'H.265' : 'H.264';

  /// 界面上写的分辨率名。
  String get resolutionLabel => switch (resolution) {
        VideoResolution.uhd4K => '4K',
        VideoResolution.p720 => '720P',
        VideoResolution.p1080 => '1080P',
      };

  /// 界面上写的方向名。
  String get orientationLabel => switch (orientation) {
        RecordingOrientation.landscapeLeft => '横左',
        RecordingOrientation.landscapeRight => '横右',
        RecordingOrientation.portrait => '竖屏',
      };

  /// 「H.264 1080P 竖屏」这样的一句话 —— 回落提示里要的就是它。
  String get label => '$codecLabel $resolutionLabel $orientationLabel';

  /// 录制码率（bit/s）。
  ///
  /// 以本机原来那个写死的 8 Mbps 为 720P 的基准，按像素数等比放大，
  /// H.265 再打六折（同画质下它本来就省）。
  ///
  /// ⚠️ 不按像素等比的话，**4K 会按 720P 的码率编**：选项做得出来、
  /// 画面却糊得没法当证据 —— 那比没有这一档更糟。
  int get bitRate {
    const baseline = 8 * 1000 * 1000; // 720P（1280×720）
    const baselinePixels = 1280 * 720;

    final (width, height) = size;
    final scaled = baseline * (width * height) / baselinePixels;

    return codec == VideoCodec.h265 ? (scaled * 0.6).round() : scaled.round();
  }

  /// 这条规格的本地容量系数（字节/秒）。
  ///
  /// ⚠️ **两端同一张表、同一个单位**（电脑端
  /// `CleanupPlanner.BytesPerSecond`）。对不上的话，两端的「将腾出多少」
  /// 会给出不同的数 —— 而用户会以为其中一个在骗他。
  /// **改一处必须改两处。**
  ///
  /// ⚠️⚠️ **但这张表是照电脑端标定的，对我们偏小约 2 倍**（2026-09-27 查清）：
  /// 两端的码率本来就不一样 —— 电脑端 ffmpeg 命令行里**一个码率参数都没有**
  /// （CRF，随画面走），而我们**显式设了码率**（见 [bitRate]，Android 走
  /// `KEY_BIT_RATE`、iOS 走 `AVVideoAverageBitRateKey`，都是硬目标）。
  ///
  /// 照 [bitRate] 算：1080P H.264 目标是 **18 Mbps**（表里按 1100 KB/s ≈ 8.8 Mbps 估）、
  /// 4K H.264 是 **72 Mbps**（表里 32 Mbps）—— 每一格都偏小 1.8~2.25 倍。
  ///
  /// **偏小为什么危险**：按空间清理是「攒到够为止」，以为每条更小就会**删更多条**，
  /// 而删的是不可逆的证据。（偏大那头才安全：少删。）
  ///
  /// ⚠️ **今天先不改数值**：两端的真实码率**都没有实测过**（上面那个 18 Mbps
  /// 是纸面推导，电脑端 CRF 下的真实码率更没测过）。拿一组推导换掉另一组推导，
  /// 只是把「已知偏小」变成「未知」。**接上按空间清理那一档之前必须实测标定。**
  ///
  /// 认不出的规格（老索引行没这两个字段、被人手改坏的值）一律走默认档那一格，
  /// 与设置层「越界回落默认值」同一条规矩。
  static double bytesPerSecondOf(String? codecName, String? resolutionName) {
    final codec = VideoCodec.fromConfig(codecName);
    final resolution = VideoResolution.fromConfig(resolutionName);

    // 单位 KB/s。⚠️ 这几个数是照**电脑端**（CRF，真实码率低）标定的 ——
    // 我们是固定码率、比这些大，见方法注释里那段说明。
    final kilobytesPerSecond = switch ((codec, resolution)) {
      (VideoCodec.h265, VideoResolution.uhd4K) => 2500,
      (VideoCodec.h265, VideoResolution.p1080) => 700,
      (VideoCodec.h265, VideoResolution.p720) => 350,
      (VideoCodec.h264, VideoResolution.uhd4K) => 4000,
      (VideoCodec.h264, VideoResolution.p720) => 550,
      _ => 1100, // H.264 1080P = 默认档
    };

    return kilobytesPerSecond * 1024;
  }

  /// 回落顺序：先用户选的那个，再逐级退。
  ///
  /// 规格只说「回落到**真正能跑通的组合**」，没写顺序。顺序与电脑端
  /// `RecordingSpec.FallbacksFrom` **同一份**：
  /// ① 用户选的；② 同编码降分辨率（画质差一点，但用户的编码偏好保住了）；
  /// ③ 保 1080P 换回 H.264；④ 720P + H.264（最后的兜底）。
  ///
  /// ⚠️ **方向不参与回落**：它是「怎么拿手机」，不是设备能力 ——
  /// 手机转个身而已，没有「这台手机转不了」这回事。回落表里换掉方向
  /// 只会让用户莫名其妙地拿到一段横着的录像。
  static List<RecordingSpec> fallbacksFrom(RecordingSpec wanted) {
    final ordered = <RecordingSpec>[
      wanted,
      wanted.withResolution(VideoResolution.p1080),
      wanted.withResolution(VideoResolution.p720),
      RecordingSpec(
          codec: VideoCodec.h264,
          resolution: VideoResolution.p1080,
          orientation: wanted.orientation),
      RecordingSpec(
          codec: VideoCodec.h264,
          resolution: VideoResolution.p720,
          orientation: wanted.orientation),
    ];

    final seen = <String>{};
    final result = <RecordingSpec>[];

    for (final spec in ordered) {
      // 去重按「编码 + 分辨率」—— 方向本来就不变，不必进键。
      if (seen.add('${spec.codec.name}/${spec.resolution.name}')) {
        result.add(spec);
      }
    }

    return result;
  }

  RecordingSpec withResolution(VideoResolution next) => RecordingSpec(
      codec: codec, resolution: next, orientation: orientation);

  /// 交给原生层的形态。
  ///
  /// 用**枚举名**而不是序号：序号在两端各排各的，一旦有一边重排，
  /// 传过去的就是另一档（而这一层没有任何东西会因此报错 —— 只是画质变了）。
  Map<String, String> toWire() => {
        'codec': codec.name,
        'resolution': resolution.name,
        'orientation': orientation.name,
      };

  @override
  bool operator ==(Object other) =>
      other is RecordingSpec &&
      other.codec == codec &&
      other.resolution == resolution &&
      other.orientation == orientation;

  @override
  int get hashCode => Object.hash(codec, resolution, orientation);

  @override
  String toString() => label;
}
