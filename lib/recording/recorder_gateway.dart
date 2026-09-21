import 'package:flutter/services.dart';

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
  Future<void> openCamera();

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
  Future<void> openCamera() => _methods.invokeMethod<void>('openCamera');

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
  Stream<NativeRecorderEvent> get events =>
      _events.receiveBroadcastStream().map(_parse).where((e) => e != null).cast();
}

/// 把通道来的 map 解析成领域事件。
///
/// 认不出来的消息**直接丢掉**而不是抛 —— 原生层加了新事件类型时，
/// 老版本 Dart 不该因此崩掉（版本偏斜在移动端是常态）。
NativeRecorderEvent? _parse(dynamic raw) {
  if (raw is! Map) return null;

  switch (raw['type']) {
    case 'segmentClosed':
      final filePath = raw['filePath'];
      final sequence = raw['sequence'];
      if (filePath is! String || sequence is! int) return null;

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
      if (text is! String || text.isEmpty) return null;

      return BarcodeDetectedEvent(
        text: text,
        centerX: (raw['centerX'] as num?)?.toDouble() ?? 0.5,
        centerY: (raw['centerY'] as num?)?.toDouble() ?? 0.5,
        confidence: (raw['confidence'] as num?)?.toDouble() ?? 1.0,
      );

    case 'failed':
      return RecorderFailedEvent(raw['message'] as String? ?? '原生层未给出原因');

    default:
      return null;
  }
}
