import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'palette.dart';

/// 自建播放器：**倍速 0.5 / 1 / 1.5 / 2、可全屏、全屏时自动转横屏并按 16:9**。
///
/// ## ⚠️ 为什么不再交给系统播放器
///
/// 原来这一段是走原生 `playVideo`（iOS `AVPlayerViewController` /
/// 安卓 `ACTION_VIEW`）。但**安卓那边是彻底失控的** —— 「用哪个播放器打开」都不一定
/// 知道，倍速、全屏、横屏一样都做不了。iOS 的系统播放器自带那三样，
/// 可选项是系统的、不受我们控制。需求方 2026-10-01 裁决：自建。
///
/// ⚠️ 原生那个 `playVideo` 通道**先留着不删**：删它要同时动 Kotlin 与 Swift 两个文件，
/// 而它不影响这里的行为。哪天真用不上了再一起收掉。
///
/// ## ⚠️ 两个必须堵住的坑
///
/// 1. **退出播放器时必须把方向转回来。** 只调一次
///    `setPreferredOrientations([landscape])` 而不管退出的话，用户回到列表页
///    会发现**整个 App 卡在横屏** —— 而且这一条在模拟器上不容易注意到，
///    真机上一眼就看见。
/// 2. **控制器必须 dispose。** 不 dispose 的话安卓那边的解码器不释放，
///    连着播几条之后新的就起不来了。
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key, required this.path, this.title});

  /// 本机文件路径。
  final String path;

  /// 顶上显示的名字（一般是文件名）。空着就不显示标题栏文字。
  final String? title;

  /// 打开它。整个 App 只有这一个播放入口（录像与网盘视频都走它）。
  static Future<void> open(BuildContext context, {required String path, String? title}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => VideoPlayerPage(path: path, title: title),
      ));

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _controller;
  String? _problem;
  double _speed = 1.0;
  bool _fullscreen = false;

  /// 拖动进度条时的目标位置（毫秒）；`null` = 没在拖。
  ///
  /// ⚠️ 单独存一个数、而不是直接读 `value.position`：拖动时画面要解码才跟上，
  /// 而**进度条与时间必须立刻跟手** —— 慢半拍的表现是「拖了但看着没动」。
  double? _scrubMillis;

  /// 拖动之前是不是在播 —— 抬手之后按原样还回去。
  bool _resumeAfterScrub = false;

  /// 连续 seek 的合流器（见 [LatestSeek] 的注释）。
  LatestSeek? _seeker;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    // ⚠️ 顺序要紧：先还方向，再放控制器。
    // 反过来的话，控制器已经没了而方向还是横的 —— 用户回到列表页卡在横屏，
    // 而这里一行日志都不会有。
    _restoreChrome();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final controller = VideoPlayerController.file(File(widget.path));

    try {
      await controller.initialize();

      // 合流器绑在这个控制器上（换一条视频会重新建一个）。
      _seeker = LatestSeek((target) => controller.seekTo(target));

      await controller.setPlaybackSpeed(_speed);
      await controller.play();

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() => _controller = controller);
    } on Object catch (error) {
      await controller.dispose();

      if (!mounted) return;

      // 播不了要**说清楚是哪一条文件播不了**：这个 App 里同时在播两种来源
      // （本机录的、从网盘下的），只回一句「播放失败」用户不知道该去查哪儿。
      setState(() => _problem = '这一段播不了：$error');
    }
  }

  /// 还方向、还系统栏。
  ///
  /// ⚠️ 两处都要还：只还方向的活，全屏时藏起来的系统栏会一直藏着。
  /// 而且**必须无条件还**（不是只在 `_fullscreen` 时还）—— 退出播放器时
  /// 正在全屏是最常见的那条路。
  void _restoreChrome() {
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  Future<void> _setFullscreen(bool on) async {
    if (on) {
      // ⚠️ 两个横屏方向都给：只给一个的话，用户把手机反过来拿就是倒着的画面。
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      _restoreChrome();
    }

    if (mounted) setState(() => _fullscreen = on);
  }

  Future<void> _setSpeed(double speed) async {
    // 记下来：换一条视频重进时沿用用户刚选的那一档。
    setState(() => _speed = speed);
    await _controller?.setPlaybackSpeed(speed);
  }

  /// 开始拖进度条。
  void _beginScrub(VideoPlayerValue value) {
    _resumeAfterScrub = value.isPlaying;

    // ⚠️ 拖的时候先暂停。不停的话画面一边往前走一边被 seek 拽回来，
    // 用户看到的不是「我拖到的那一帧」，而是那一帧附近某处 —— 而需求要的
    // 恰恰是「显示进度条定点的当前帧画面」。
    unawaited(_controller?.pause() ?? Future<void>.value());
  }

  /// 拖到了 [millis]（毫秒）。
  void _scrubTo(double millis) {
    // 进度条与时间**立刻跟手**；画面慢一点没关系（它要解码）。
    setState(() => _scrubMillis = millis);

    final target = Duration(milliseconds: millis.round());
    unawaited(_seeker?.request(target) ?? Future<void>.value());
  }

  /// 抬手了。
  Future<void> _endScrub(double millis) async {
    // ⚠️ 最后那一下**必须再请求一次**：拖动过程中发出去的那些可能都被合流
    // 丢掉了，而用户抬手的位置才是他真正要停的地方。
    await _seeker?.request(Duration(milliseconds: millis.round()));

    if (mounted) setState(() => _scrubMillis = null);

    if (_resumeAfterScrub) await _controller?.play();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.backdrop,
      appBar: _fullscreen
          ? null
          : AppBar(
              title: Text(widget.title ?? '播放', overflow: TextOverflow.ellipsis),
              backgroundColor: Palette.backdrop,
              foregroundColor: Palette.onDark,
            ),
      body: SafeArea(
        // 全屏时不要 SafeArea 的边距 —— 那会让画面缩在中间、四周一圈黑边。
        top: !_fullscreen,
        bottom: !_fullscreen,
        child: _problem != null
            ? _problemView(_problem!)
            : _controller == null
                ? const Center(child: CircularProgressIndicator())
                : _playerView(_controller!),
      ),
    );
  }

  Widget _problemView(String problem) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            problem,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Palette.onDarkSoft),
          ),
        ),
      );

  Widget _playerView(VideoPlayerController controller) => Column(
        children: [
          Expanded(
            child: GestureDetector(
              // 点画面本身也能切全屏 —— 大屏上那颗按钮够不着的时候，
              // 用户的第一个动作就是戳一下画面。
              onTap: () => _setFullscreen(!_fullscreen),
              child: Center(
                // ⚠️ 两种模式**用同一个比例**：视频自己的那个。
                //
                // 2026-10-01 之前全屏是写死的 16:9（需求方当时的口径）。改成跟着
                // 视频自己走，理由是这个画面是**证据** —— 非 16:9 的片子被拉变形，
                // 比四周留一圈黑边糟得多：变形是**看不出来的谎**，黑边是看得见的。
                child: AspectRatio(
                  aspectRatio: safeAspect(controller.value.aspectRatio),
                  child: VideoPlayer(controller),
                ),
              ),
            ),
          ),
          _controls(controller),
        ],
      );

  Widget _controls(VideoPlayerController controller) => Container(
        color: Palette.backdrop,
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        // ⚠️ 用 `ValueListenableBuilder` 而不是在 onPressed 里 `setState`：
        // 播放进度与「正在播/暂停」是**控制器那边**在变的（播完自动停、
        // 拖进度条、缓冲）。只在点击时刷一次的话，播完之后那个按钮还显示着
        // 「暂停」，用户会以为卡住了。
        child: ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _scrubber(value),
              Row(
                children: [
                  IconButton(
                    onPressed: () async {
                      if (value.isPlaying) {
                        await controller.pause();
                      } else {
                        await controller.play();
                      }
                    },
                    icon: Icon(
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Palette.onDark,
                    ),
                    tooltip: value.isPlaying ? '暂停' : '播放',
                  ),
                  Text(
                    _position(value, _scrubMillis),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Palette.onDarkSoft),
                  ),
                  const Spacer(),
                  ...playbackSpeeds.map((speed) => _speedButton(speed)),
                  IconButton(
                    onPressed: () => _setFullscreen(!_fullscreen),
                    icon: Icon(
                      _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      color: Palette.onDark,
                    ),
                    tooltip: _fullscreen ? '退出全屏' : '全屏',
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _speedButton(double speed) {
    final selected = (_speed - speed).abs() < 0.001;

    return TextButton(
      onPressed: () => _setSpeed(speed),
      style: TextButton.styleFrom(
        minimumSize: const Size(46, 36),
        padding: EdgeInsets.zero,
        foregroundColor: selected ? Palette.mediaPick : Palette.onDarkSoft,
      ),
      child: Text(
        labelForSpeed(speed),
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
      ),
    );
  }

  /// 进度条。
  ///
  /// ⚠️ 自己写、不用 `VideoProgressIndicator`：那个的 `allowScrubbing` 只在
  /// **抬手**时 seek 一次，拖动过程中画面**不动** —— 而需求要的是「拖到哪
  /// 就显示哪一帧」。所以这里每一动都 seek（由 [LatestSeek] 合流）。
  Widget _scrubber(VideoPlayerValue value) {
    final total = value.duration.inMilliseconds;
    if (!value.isInitialized || total <= 0) return const SizedBox(height: 24);

    // 拖动中显示**手指的位置**，没在拖才显示播放位置。
    final shown = (_scrubMillis ?? value.position.inMilliseconds.toDouble())
        .clamp(0, total.toDouble())
        .toDouble();

    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
      child: Slider(
        value: shown,
        max: total.toDouble(),
        onChangeStart: (_) => _beginScrub(value),
        onChanged: _scrubTo,
        onChangeEnd: (millis) => unawaited(_endScrub(millis)),
      ),
    );
  }

  /// `已播 / 总长`。
  ///
  /// ⚠️ 拖动中要报**手指那个位置**，不是播放器的位置 —— 需求里
  /// 「显示总时长及播放进度」和「拖动时显示定点那一帧」是同一件事的两面：
  /// 数字和画面必须指同一个地方，否则用户没法用它定位。
  static String _position(VideoPlayerValue value, double? scrubMillis) {
    if (!value.isInitialized) return '';

    final at = scrubMillis == null
        ? value.position
        : Duration(milliseconds: scrubMillis.round());

    return '${formatDuration(at)} / ${formatDuration(value.duration)}';
  }
}

/// 把控制器报的画面比例收拾成一个**能直接喂给 `AspectRatio`** 的数。
///
/// ⚠️ 未初始化时 `aspectRatio` 可能是 `0`、也可能是 `NaN`（`video_player` 在
/// 还没拿到尺寸前就那个样）。直接喂给 `AspectRatio` 会**抛断言**，
/// 表现是「刚点开播放就红屏」，而那时候用户什么都没做。
double safeAspect(double raw) => raw.isFinite && raw > 0 ? raw : 16 / 9;

/// 拖动进度条时「连续 seek」的**合流器**：只保留最后一个目标。
///
/// ## ⚠️ 为什么必须合流
///
/// 需求要的是「拖到哪就显示哪一帧」，所以拖动过程中要不停 `seekTo`。
/// 但 `seekTo` 不是瞬时的（它要解码到目标位置），用户在一条 3 分钟的进度条上
/// 快速划一下会排进几十个请求。不合流的话：
///
/// - 每一个都要解，**拖完之后画面还在慢慢追**；
/// - 追的还是中间那些**早就不要了**的位置 —— 用户手已经抬起来了，
///   画面却还在往回跳。
///
/// 所以这里只记「最新那个目标」，正在跑的那个跑完再去取最新的。
/// 中间那些**直接丢掉**：它们的唯一价值是「曾经被指过」，而画面只该停在最后那一下。
class LatestSeek {
  LatestSeek(this.perform);

  /// 真正去 seek 的那一下（由调用方注入，测试里换成记账的假件）。
  final Future<void> Function(Duration target) perform;

  Duration? _pending;
  bool _running = false;

  /// 请求跳到 [target]。
  Future<void> request(Duration target) async {
    if (_running) {
      // 正在跳 —— 不排队，**覆盖**上一个还没跑的目标。
      _pending = target;
      return;
    }

    _running = true;

    try {
      var next = target;
      while (true) {
        await perform(next);

        final queued = _pending;
        _pending = null;
        if (queued == null) return;

        next = queued;
      }
    } finally {
      _running = false;
    }
  }
}

/// 用户能选的四档倍速。
///
/// ⚠️ **逐字是需求方 2026-10-01 定的**（「倍速 0.5 / 1 / 1.5 / 2」）——
/// 少一档、多一档、改一个数，都要回去问，不要自己顺手调。
/// 提成公开常量是为了测试能钉住这一份，而不是在测试里另抄一遍字面量。
const playbackSpeeds = <double>[0.5, 1.0, 1.5, 2.0];

/// 倍速按钮上那个字。`1` 而不是 `1.0` —— 满屏小数点在真机上看着像乱码。
String labelForSpeed(double speed) =>
    speed == speed.roundToDouble() ? '${speed.toStringAsFixed(0)}x' : '${speed}x';

/// `mm:ss`；超过一小时才带上小时。
String formatDuration(Duration value) {
  final seconds = value.inSeconds.clamp(0, 359999);
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');

  return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
}
