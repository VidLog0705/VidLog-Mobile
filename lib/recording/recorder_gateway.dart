import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../diagnostics/app_log.dart';

/// 原生层上报的事件。
sealed class NativeRecorderEvent {
  const NativeRecorderEvent();
}

/// 一个分段已封闭。
///
/// **收到这个就要立刻写进 manifest** —— 那是「重启后能收尾孤儿」的前提：
/// 进程被杀时来不及做任何事，所以已封闭的分段必须**在封闭的那一刻**就落了盘。
class SegmentClosedEvent extends NativeRecorderEvent {
  const SegmentClosedEvent({
    required this.filePath,
    required this.sequence,
    required this.startedAtMs,
    required this.endedAtMs,
  });

  final String filePath;
  final int sequence;

  /// 相对会话起点的**单调**毫秒偏移（规格 §3.6.3 / I11）。
  final int startedAtMs;
  final int endedAtMs;
}

/// 画面是否静止（规格 §3.3.3）。
///
/// 原生层做像素差分，只在状态**变化**时上报。
class SceneSampledEvent extends NativeRecorderEvent {
  const SceneSampledEvent({required this.isStatic});

  final bool isStatic;
}

/// 原生层识别到一个条码。
///
/// ⚠️ **这不等于「用户扫了一次码」。** 相机是连续识码的 ——
/// 包裹一直摆在取景框里，同一单号每秒会报好几次。
/// 把它变成「离散的扫码事件」是 `ScanGate` 的职责（那一层带测试）。
///
/// 坐标是**归一化**的、**原点在左上**。原生层负责换算：
/// iOS 的 Vision 原点在左下，要翻 y。
class BarcodeDetectedEvent extends NativeRecorderEvent {
  const BarcodeDetectedEvent({
    required this.text,
    required this.centerX,
    required this.centerY,
    this.confidence = 1.0,
  });

  final String text;
  final double centerX;
  final double centerY;
  final double confidence;
}

/// 相机或编码出错。
class RecorderFailedEvent extends NativeRecorderEvent {
  const RecorderFailedEvent(this.message);

  final String message;
}

/// 原生录制器。
///
/// 抽成接口是为了让编排逻辑可测 —— 真通道要起 Flutter 引擎才动得了，
/// 而「事件怎么喂给停录状态机」才是容易写错的地方。
abstract interface class RecorderGateway {
  Future<bool> hasCameraPermission();

  /// 弹系统授权框。
  ///
  /// 结果是异步的：调用方拿到 false 不代表用户拒绝，只代表**还没决定**，
  /// 应当等用户操作后重新调 [hasCameraPermission]。
  Future<bool> requestCameraPermission();

  // ── 相机与录制是两件事 ──
  //
  // 规格 §3.2.2：点「开始工作」→ 画面出现**可见的取景框**；扫到面单才开录。
  // 所以 [openCamera]（开相机送预览）与 [startRecording]（开录）必须分开。
  // 合成一个方法会出现「点了按钮屏幕上什么都没有，但其实在录」——
  // 这正是之前那版的问题。

  /// 打开相机并开始送预览。**不录。**
  ///
  /// [qrOnly] 为真时**只认二维码**（规格 §3.4.5 ④）：那是「扫码连接」
  /// 那个专用界面用的。
  ///
  /// ⚠️ **默认仍然是只认一维码，一个字都没放松** —— 面单上或环境里的二维码
  /// 不该被当成单号。所以这个开关由调用方显式打开，而**录制页永远不打开它**。
  ///
  /// 相机已经开着时调用它：只换识码范围，不重开相机（换范围要重开的话，
  /// 从录入界面返回录制页会闪一下黑屏）。
  Future<void> openCamera({bool qrOnly = false});

  /// 开始录一段。
  ///
  /// [directory] 是这一段（= 一个会话）的落盘位置；
  /// [segmentDuration] 决定单段时长 —— 掉电最多丢这么多。
  Future<void> startRecording({
    required String directory,
    required Duration segmentDuration,
  });

  /// 停止录制。**相机保持开着**，取景框还在，下件包裹接着扫。
  Future<void> stopRecording();

  /// 关闭相机（结束工作）。
  Future<void> closeCamera();

  Future<void> setZoom(double ratio);

  /// 面单刚进框：对焦到画面正中 + 临时放大，两秒后回到原倍率
  /// （需求方 2026-09-22）。
  ///
  /// **无参数、无返回值、fire-and-forget**：那两秒的计时归**原生**，
  /// 不是 Dart。回弹必须落在**同一台 `AVCaptureDevice` 对象**上 ——
  /// 放 Dart 计时的话，中间一次 [closeCamera]/[openCamera]（切栏、结束/开始）
  /// 会让回调去改**新**会话的倍率。原生自己持有就等于零同步、零新 Dart 状态。
  ///
  /// **失败不是错误**：和 [setZoom] 一样是尽力而为 —— 设备可能不支持对焦，
  /// 也可能正忙着。调用方吞掉即可（I4 的精神：能力缺失不许把录制搞坏）。
  ///
  /// 两端都实现了（安卓 2026-09-23 接的，见 `RecorderChannel.kt`）——
  /// 但**都没上过真机**，所以「失败不是错误」这条今天仍然要照着写。
  Future<void> autoFocusAndZoom();

  /// 设备支持的最大变焦倍率。
  ///
  /// 规格 §3.1.2：「倍率不得超过设备能力上限」。原生层本来就会钳，
  /// 这个方法是为了**让表盘的刻度对得上** —— 否则设备只支持 2 倍时，
  /// 用户把表盘划到 5 倍、画面却停在 2 倍，表盘在骗人。
  ///
  /// **相机没开时拿不到**（返回 null）：上限来自相机设备本身。
  /// 调用方拿不到时用一个保守的默认值即可。
  Future<double?> maxZoom();

  /// 设备支持的**最小**变焦倍率。
  ///
  /// 2026-09-22 起表盘的左端不再是个常数：原生层改成优先挑带**超广角**的
  /// 双/三镜头虚拟设备，那时 iPhone 的下限是 **0.5**；只有广角镜头的设备
  /// 仍是 1.0。表盘左端画到哪取决于它（规格 §3.1.2）。
  ///
  /// **相机没开时拿不到**（返回 null）—— 与 [maxZoom] 同一个道理，
  /// 下限也是相机设备本身的属性。拿不到时按 1.0 处理（当作没有超广角）。
  Future<double?> minZoom();

  /// 立刻对焦到画面正中，**不动倍率**。
  ///
  /// 规格 §3.1.2：表盘滑动时「无论怎么滑都自动对焦」。倍率一变，原来
  /// 对好的那点就不实了 —— 所以每滑一段都要重新对一次。
  ///
  /// 与 [autoFocusAndZoom] 共用原生那段对焦逻辑，区别只是不放大、不计时回弹。
  ///
  /// **尽力而为**：与 [setZoom] 一样，失败不抛（设备可能不支持对焦）。
  Future<void> focusNow();

  /// 拨一下齿轮的模拟声（表盘滑过一个刻度）。规格 §3.1.2。
  ///
  /// 用系统的**输入点击音**，**不带任何音频资源** —— 洁净室与许可证
  /// （规格 §10）的账上就少一笔，与 [speak] 走系统 TTS 是同一条理由。
  ///
  /// 音量与开关**跟随系统**的「键盘反馈」：用户把它关掉时不响是**正常的**，
  /// 不是 bug。
  ///
  /// **尽力而为**：调用方吞掉即可（某些系统把「键盘反馈」整个关掉时不响）。
  Future<void> playDetentSound();

  /// 读出一句提示（规格 §3.3.2 / §3.3.4 / §3.3.6）。
  ///
  /// 为什么交给原生而不是放音频文件：措辞是中文、要能改，
  /// 而系统 TTS 不需要多带一份音频资源，也不用核对它的许可证（规格 §10）。
  ///
  /// [beep] 为真时**先「滴」一声再开口**（规格 §3.3.6）。滴声与语音必须
  /// **两个不同的音**（同一个音分不出「系统认了这一下」和「系统在说话」），
  /// 且同样只许用系统内置的 —— 一样不许引入音频素材文件。
  ///
  /// **失败不是错误**：设备可能没装中文语音包、或用户关了朗读。
  /// 提示丢一句是小事，不能让它拖垮停录。
  Future<void> speak(String text, {bool beep = false});

  /// 原生事件流。
  Stream<NativeRecorderEvent> get events;
}

/// 走平台通道的真实实现。
class ChannelRecorderGateway implements RecorderGateway {
  ChannelRecorderGateway({MethodChannel? methods, EventChannel? events})
      : _methods = methods ?? const MethodChannel(methodChannelName),
        _events = events ?? const EventChannel(eventChannelName);

  static const methodChannelName = 'vidlog/recorder';
  static const eventChannelName = 'vidlog/recorder/events';

  final MethodChannel _methods;
  final EventChannel _events;

  @override
  Future<bool> hasCameraPermission() async =>
      await _methods.invokeMethod<bool>('hasCameraPermission') ?? false;

  @override
  Future<bool> requestCameraPermission() async =>
      await _methods.invokeMethod<bool>('requestCameraPermission') ?? false;

  @override
  Future<void> openCamera({bool qrOnly = false}) =>
      _methods.invokeMethod<void>('openCamera', {'qrOnly': qrOnly});

  @override
  Future<void> startRecording({
    required String directory,
    required Duration segmentDuration,
  }) =>
      _methods.invokeMethod<void>('startRecording', {
        'directory': directory,
        'segmentDurationMs': segmentDuration.inMilliseconds,
      });

  @override
  Future<void> stopRecording() => _methods.invokeMethod<void>('stopRecording');

  @override
  Future<void> closeCamera() => _methods.invokeMethod<void>('closeCamera');

  @override
  Future<void> setZoom(double ratio) =>
      _methods.invokeMethod<void>('setZoom', {'ratio': ratio});

  @override
  Future<double?> maxZoom() => _methods.invokeMethod<double>('maxZoom');

  @override
  Future<double?> minZoom() => _methods.invokeMethod<double>('minZoom');

  @override
  Future<void> focusNow() => _methods.invokeMethod<void>('focusNow');

  @override
  Future<void> playDetentSound() =>
      _methods.invokeMethod<void>('playDetentSound');

  @override
  Future<void> autoFocusAndZoom() =>
      _methods.invokeMethod<void>('autoFocusAndZoom');

  @override
  Future<void> speak(String text, {bool beep = false}) => _methods
      .invokeMethod<void>('speak', {'text': text, 'beep': beep});

  @override
  Stream<NativeRecorderEvent> get events =>
      _events.receiveBroadcastStream().map(parseNativeEvent).where((e) => e != null).cast();
}

/// 把通道来的 map 解析成领域事件。
///
/// 认不出来的消息**直接丢掉**而不是抛 —— 原生层加了新事件类型时，
/// 老版本 Dart 不该因此崩掉（版本偏斜在移动端是常态）。
/// 把一条原生消息解成领域事件；认不出来返回 null。
///
/// ⚠️ **公开是为了能被测**（与 `deviceNameInputFormatter` 同一条理由）：
/// 「认不出的消息要留痕」那条判据只有在测试能真的喂一条进去时才验得了。
@visibleForTesting
NativeRecorderEvent? parseNativeEvent(dynamic raw) {
  if (raw is! Map) {
    // 不是 map 说明消息形状就不对（原生层改坏了、或者根本不是我们的消息）。
    _reportDropped('非 map', raw);
    return null;
  }

  switch (raw['type']) {
    case 'segmentClosed':
      final filePath = raw['filePath'];
      final sequence = raw['sequence'];
      if (filePath is! String || sequence is! int) {
        _reportDropped('segmentClosed 少了字段', raw);
        return null;
      }

      return SegmentClosedEvent(
        filePath: filePath,
        sequence: sequence,
        startedAtMs: (raw['startedAtMs'] as num?)?.toInt() ?? 0,
        endedAtMs: (raw['endedAtMs'] as num?)?.toInt() ?? 0,
      );

    case 'sceneSampled':
      return SceneSampledEvent(isStatic: raw['isStatic'] == true);

    case 'barcodeDetected':
      final text = raw['text'];
      if (text is! String || text.isEmpty) {
        _reportDropped('barcodeDetected 没带内容', raw);
        return null;
      }

      return BarcodeDetectedEvent(
        text: text,
        centerX: (raw['centerX'] as num?)?.toDouble() ?? 0.5,
        centerY: (raw['centerY'] as num?)?.toDouble() ?? 0.5,
        confidence: (raw['confidence'] as num?)?.toDouble() ?? 1.0,
      );

    case 'failed':
      return RecorderFailedEvent(raw['message'] as String? ?? '原生层未给出原因');

    default:
      // ⚠️ 这里以前是**一句 return null** —— 认不出的消息静默丢弃。
      // 那条规矩本身是对的（老版本 Dart 不该因为原生加了新事件就崩），
      // 但**丢得一声不响**就把它变成了一个洞：原生那边发了什么、
      // 这边为什么没反应，日志里一个字都没有。
      // 认不出来是**罕见**的（版本偏斜时才发生），所以记 Warning 不会刷屏。
      _reportDropped('认不出的事件类型 ${raw['type']}', raw);
      return null;
  }
}

/// 记一条「有消息被丢掉了」。
///
/// ⚠️ **载荷本身不落盘**（只记类型名）：原生事件里可能带着单号，
/// 而这条日志会进诊断包。要诊断「为什么这个事件没被处理」，
/// 类型名就够了；真要看载荷，那是另一件事，得先想清楚脱敏。
void _reportDropped(String reason, dynamic raw) {
  AppLog.instance.warn('原生', '丢弃了一条原生消息：$reason', data: {
    if (raw is Map && raw['type'] != null) '类型': raw['type'],
  });
}
