import 'dart:async';

import '../diagnostics/app_log.dart';

/// 原生编码器推上来的一块字节。
///
/// ⚠️ **`isKey` 这个标志是整个多画面能不能用的关键。** 裸流没有容器，
/// 中途接入的客户端必须从**关键帧**（IDR）开始才解得出来；而
/// 「哪一块是 IDR」只有编码器自己知道（安卓 `BUFFER_FLAG_KEY_FRAME`、
/// iOS `kCMSampleAttachmentKey_NotSync` 的反面），Dart 这边认不出来。
///
/// ⚠️ 约定：**关键帧那一块里已经带了 SPS/PPS**（原生那边负责前置）。
/// 这样 Dart 这边不用另外维护一份参数集 —— 而那正是最容易漏掉的一步。
class LiveFrame {
  const LiveFrame({required this.bytes, required this.isKey});

  final List<int> bytes;
  final bool isKey;
}

/// 原生编码器 → 每一路 HTTP 客户端之间的那一层（规格 §3.8）。
///
/// ## 为什么需要它
///
/// 电脑端最多同时看 9 格，也就是**最多 9 个客户端**各拉一路。而裸流的特点决定了
/// 每个客户端**必须从关键帧开始**：给一个已经在跑的半途，他只能一直等下一个
/// 关键帧 —— 表现是「别的格子都出来了，就这一格黑着，过几秒才亮」。
///
/// 所以这里留一个 **GOP 缓存**：从最近一个关键帧开始的那一串。
/// 新客户端接进来先把这串补给他，然后接上实时的。
///
/// ## ⚠️ 缓存满了丢**老的**，但**不丢头部的关键帧**
///
/// 实时画面宁可掉帧，也不能让延迟越积越大（越积越大的表现是「画面比现实慢半分钟」，
/// 而看的人以为那就是现在）。所以要有个上限。
/// 但丢的时候**必须留着头部那个关键帧** —— 把它丢了，新接入的人就再也解不出来了，
/// 而且他不知道自己解不出来（画面就是黑着）。
class LiveStreamHub {
  LiveStreamHub({this.maxBufferedFrames = 60, void Function(String message)? onLog})
      : onLog = onLog ?? _toAppLog {
    if (maxBufferedFrames < 2) {
      throw ArgumentError('至少要有两帧：一个关键帧 + 一帧新的');
    }
  }

  /// GOP 缓存最多留多少帧。按 30fps 算，60 帧 = 2 秒。
  final int maxBufferedFrames;

  /// 留痕（§6.1：不许静默）。
  ///
  /// ⚠️ **默认落进 `AppLog`，不是「没有」** —— 可空 + 默认 null 的话，
  /// 没有调用方传它就等于这一层没有留痕（2026-10-01 核出来的真漏）。
  final void Function(String message) onLog;

  static void _toAppLog(String message) => AppLog.instance.warn('推流', message);

  final _gop = <LiveFrame>[];
  final _subscribers = <StreamController<List<int>>>[];

  var _dropped = 0;
  var _closed = false;

  /// 这一次「开始丢帧」已经说过了没有。
  ///
  /// ⚠️ 丢帧是**每秒几十次**的事，每次都记会把日志灌满（而灌满的日志等于没有日志）。
  /// 所以只在**「从不丢变成丢」**那一刻说一条，之后靠 [droppedFrames] 那个数说话；
  /// 等下一个关键帧把缓存清空、不丢了，再把标记复位 —— 下次真丢时才会再响。
  var _dropNotified = false;

  /// 因为缓存满了被丢掉的帧数（诊断用）。
  ///
  /// ⚠️ 它一直涨说明**消费端跟不上**（电脑端网络慢、或者 ffmpeg 解不过来）。
  /// 那本身不是故障（实时画面掉帧是对的），但值得记一笔 ——
  /// 用户抱怨「画面卡」时，先看这个数。
  int get droppedFrames => _dropped;

  /// 现在有几路客户端在看。
  int get subscriberCount => _subscribers.length;

  /// 缓存里现在有几帧（诊断用）。
  int get bufferedFrames => _gop.length;

  /// 原生那边推一块上来。
  void push(LiveFrame frame) {
    if (_closed) return;

    // 新 GOP 从这里开始：**先清空**，否则上一段的老帧会被当成这一段的前导。
    if (frame.isKey) {
      _gop.clear();

      // 缓存被清空了 = 又跟得上了。复位那个标记，下次真丢时才会再响一条。
      _dropNotified = false;
    }

    _gop.add(frame);

    // ⚠️ 丢的时候从**第 1 个**开始丢，`_gop[0]` 留着 ——
    // 它要么是这一段的关键帧，要么是「还没等到关键帧」时最早的那一帧。
    while (_gop.length > maxBufferedFrames) {
      _gop.removeAt(1);
      _dropped++;
      _noteDrop();
    }

    for (final subscriber in _subscribers) {
      // 已经关掉的那一路（客户端走了）就别写了。
      if (subscriber.isClosed) continue;
      subscriber.add(frame.bytes);
    }
  }

  /// 开一路新的。
  ///
  /// ⚠️ **先把 GOP 缓存补给他**，再接上实时的 —— 顺序不能反：
  /// 先接实时的话，他会在关键帧到来之前先收到几块 P 帧，那些解不出来。
  Stream<List<int>> subscribe() {
    final controller = StreamController<List<int>>();

    for (final frame in _gop) {
      controller.add(frame.bytes);
    }

    _subscribers.add(controller);
    controller.onCancel = () => _subscribers.remove(controller);

    return controller.stream;
  }

  /// 丢帧了 —— 只在**第一次**说一条（见 [_dropNotified]）。
  void _noteDrop() {
    if (_dropNotified) return;
    _dropNotified = true;

    onLog(
      'GOP 缓存满了，开始丢帧。这本身不是故障（实时画面宁可掉帧，也不能让延迟越积越大），'
      '但**一直丢**说明消费端跟不上 —— 电脑端网络慢、或者那边解码来不及。',
    );
  }

  /// 关掉所有客户端（比如用户把实时共享关了）。
  ///
  /// ⚠️ **不能 `await` 那些 close**：单订阅的 `StreamController` 如果**没人听过**，
  /// 它的 `close()` 返回的 Future **永远不会完成**（「done 事件送达」这件事
  /// 对没有订阅者的流不会发生）—— await 它会挂死在这里，
  /// 表现是「关掉实时共享之后界面卡住」。
  void close() {
    _closed = true;

    for (final subscriber in [..._subscribers]) {
      if (!subscriber.isClosed) unawaited(subscriber.close());
    }

    _subscribers.clear();
  }
}
