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

  /// 开始录制。
  ///
  /// [directory] 是这个会话的工作目录；
  /// [segmentDuration] 决定单段时长 —— 掉电最多丢这么多。
  Future<void> startSession({
    required String directory,
    required Duration segmentDuration,
  });

  Future<void> stopSession();

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
  Future<void> startSession({
    required String directory,
    required Duration segmentDuration,
  }) =>
      _methods.invokeMethod<void>('startSession', {
        'directory': directory,
        'segmentDurationMs': segmentDuration.inMilliseconds,
      });

  @override
  Future<void> stopSession() => _methods.invokeMethod<void>('stopSession');

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

    case 'failed':
      return RecorderFailedEvent(raw['message'] as String? ?? '原生层未给出原因');

    default:
      return null;
  }
}
