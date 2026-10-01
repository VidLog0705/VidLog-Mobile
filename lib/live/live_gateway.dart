import 'dart:async';

import 'package:flutter/services.dart';

import '../diagnostics/app_log.dart';
import 'live_hub.dart';

/// 原生推流那边报上来的一件事。
///
/// ⚠️ 与 `RecorderEvent` 一样做成 sealed：**多一种原生事件时，Dart 这边
/// 认不出来的那条路要能被编译器指出来**（而不是静静地掉进某个 `default`）。
sealed class LiveNativeEvent {
  const LiveNativeEvent();
}

/// 原生编码器推上来一块 H.264（Annex-B）。
class LiveEncoded extends LiveNativeEvent {
  const LiveEncoded(this.frame);

  final LiveFrame frame;
}

/// 原生那边出了事（编码器起不来、相机没开、推流被原生自己停了）。
///
/// ⚠️ 它**不是**「录制出事了」—— 规格 §3.8 第 2 条：推流那边的任何异常
/// 都不许冒到录制那一侧。这一条消息的全部去处就是日志与那一格的黑屏。
class LiveFailed extends LiveNativeEvent {
  const LiveFailed(this.message);

  final String message;
}

/// 推流那一半的原生接口。
///
/// ## 为什么**另开一条通道**，不并进 `vidlog/recorder`
///
/// 规格 §3.8 第 2 条（不许传染）：两条通道的失败面分开之后，
/// 推流起不来**不会**让录制那条通道上的任何调用跟着进错误分支。
/// 并进去的话，`RecorderGateway` 的每一个调用点都要开始考虑
/// 「这次失败是不是推流引起的」。
///
/// ## ⚠️ 它是可替换的（测试里换成假件）
///
/// 与 `RecorderGateway` 同一条理由：没有相机也能验接线 ——
/// 服务有没有起、档位有没有透传、帧有没有进缓存，全都在这里测得到。
abstract interface class LiveGateway {
  /// 开推流，目标高度 [height]（480 / 720 / 1080 那一档的**行数**）。
  ///
  /// ⚠️ 相机没开时**要能失败**（返回非 null 的原因），而不是默默什么都不做 ——
  /// 「点开了却什么都没有」是本仓最贵的那类故障。
  Future<String?> startLive(int height);

  /// 停推流。**不关相机**（相机归录制那边管）。
  Future<void> stopLive();

  /// 换档（电脑端进/出全屏时叫它）。
  ///
  /// ⚠️ **改档只许重开推流那一个编码器**，录制那一侧的编码器一个字都不许动
  /// （规格 §3.8）。改不动时宁可继续用旧档。
  Future<void> setLiveQuality(int height);

  /// 原生推上来的事件流。
  Stream<LiveNativeEvent> get events;
}

/// 走平台通道的真实实现。
class ChannelLiveGateway implements LiveGateway {
  ChannelLiveGateway({MethodChannel? methods, EventChannel? events})
      : _methods = methods ?? const MethodChannel(methodChannelName),
        _events = events ?? const EventChannel(eventChannelName);

  static const methodChannelName = 'vidlog/live';
  static const eventChannelName = 'vidlog/live/frames';

  final MethodChannel _methods;
  final EventChannel _events;

  @override
  Future<String?> startLive(int height) async {
    try {
      await _methods.invokeMethod<void>('startLive', {'height': height});
      return null;
    } on PlatformException catch (error) {
      // 失败要说得出原因（编码器起不来 / 相机没开），由界面与日志显示。
      return error.message ?? '推流没能起来（${error.code}）';
    } on MissingPluginException {
      // ⚠️ 老包 / 安卓那边还没接上（本仓安卓的通道历来容易两端对不上）——
      // 如实说，**不假装成功**。
      return '这一端还没有接上实时推流。';
    }
  }

  @override
  Future<void> stopLive() => _methods.invokeMethod<void>('stopLive');

  @override
  Future<void> setLiveQuality(int height) =>
      _methods.invokeMethod<void>('setLiveQuality', {'height': height});

  @override
  Stream<LiveNativeEvent> get events => _events
      .receiveBroadcastStream()
      .map(parseLiveEvent)
      .where((event) => event != null)
      .cast<LiveNativeEvent>();
}

/// 把通道来的消息解成 [LiveNativeEvent]；认不出来返回 null。
///
/// ⚠️ **认不出来要留痕**（与本仓 `parseNativeEvent` 同一条）：
/// 静默丢弃会让「原生发了什么、这边为什么没反应」在日志里一个字都没有。
/// 老版本 Dart 不该因为原生加了新事件就崩，所以丢是丢，但要说话。
///
/// 公开是为了能被测（「认不出的消息要留痕」那条判据只有喂得进去才验得了）。
LiveNativeEvent? parseLiveEvent(dynamic raw) {
  if (raw is! Map) {
    AppLog.instance.warn('推流', '原生推流事件不是 map，已丢弃');
    return null;
  }

  switch (raw['type']) {
    case 'frame':
      final data = raw['data'];
      if (data is! Uint8List || data.isEmpty) {
        AppLog.instance.warn('推流', '推流帧没带数据，已丢弃');
        return null;
      }

      return LiveEncoded(
        LiveFrame(bytes: data, isKey: raw['key'] == true),
      );

    case 'failed':
      return LiveFailed(raw['message'] as String? ?? '原生推流未给出原因');

    default:
      AppLog.instance.warn('推流', '认不出的推流事件类型：${raw['type']}');
      return null;
  }
}
