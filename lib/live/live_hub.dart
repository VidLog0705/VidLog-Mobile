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
/// ## ⚠️ 缓存里**永远是从关键帧到最新一帧的连续一段**
///
/// 这条不变量是这个类存在的全部理由，破了它就等于没有它：
/// 裸流里每一帧都参考前一帧，中间**少一帧**，它后面那些帧就全解不出来 ——
/// 电脑端拿到的是一段**满屏马赛克**，而他还以为自己连上了。
///
/// 所以：
///
/// 1. 关键帧一到就**清空**重来（上一段的老帧绝不能当成这一段的前导）；
/// 2. 满了（见 [maxBufferedFrames]）**整段丢掉**，而不是从中间抽一帧；
///    整段丢掉之后，新接入的人只会等下一个关键帧（手机那边 2 秒一个），
///    拿到的是干净的 —— 那比给他一段有洞的画面强得多；
/// 3. 头不是关键帧时**一块都不补**（见 [subscribe]）。
///
/// ⚠️ **它是「一段推流」的，不是整个进程一个。** `close()` 之后这一层就废了
///（`_closed` 立起来之后 `push` 一个字都不收，这是有意的：那之后还往这里推，
/// 说明有人拿着一段已经结束的推流在用）。所以调用方**每一段重开时都要新建一个**，
/// 而不是共用一个 —— 2026-10-03 那个「停了之后就再也没有画面」的缺陷正是栽在
/// 共用上（见 `LiveService.start` 里那段注释）。
class LiveStreamHub {
  LiveStreamHub({this.maxBufferedFrames = 120, void Function(String message)? onLog})
      : onLog = onLog ?? _toAppLog {
    if (maxBufferedFrames < 2) {
      throw ArgumentError('至少要有两帧：一个关键帧 + 一帧新的');
    }
  }

  /// GOP 缓存最多留多少帧。
  ///
  /// ⚠️ **它要装得下一整段 GOP**，否则每次新客户端接入都要等下一个关键帧。
  /// 手机那边两个平台都是 **2 秒**一个关键帧：
  ///
  /// | 帧率 | 2 秒是多少帧 |
  /// |---|---|
  /// | 15fps（安卓推流那一路） | 30 |
  /// | 30fps（录制那一路、iOS） | 60 |
  /// | 60fps（相机给到 60 的设备） | 120 |
  ///
  /// 所以取 120。⚠️ **原来写的是 60** —— 那在 30fps 的设备上刚好卡在边界
  ///（2 秒 = 60 帧，抖动一两帧就超），一超就从中间抽一帧，于是**整段补给新客户端的
  /// 画面全是花屏**。现在超了是整段丢（见 [push]），所以这个数只是「要不要走那条
  /// 兜底路」的分界，不是「能不能解出来」的分界。
  final int maxBufferedFrames;

  /// 留痕（§6.1：不许静默）。
  ///
  /// ⚠️ **默认落进 `AppLog`，不是「没有」** —— 可空 + 默认 null 的话，
  /// 没有调用方传它就等于这一层没有留痕（2026-10-01 核出来的真漏）。
  final void Function(String message) onLog;

  static void _toAppLog(String message) => AppLog.instance.warn('推流', message);

  final _gop = <LiveFrame>[];
  final _watchers = <_Watcher>[];

  var _dropped = 0;
  var _closed = false;

  /// 这一次「开始丢帧」已经说过了没有。
  ///
  /// ⚠️ 丢帧是**每秒几十次**的事，每次都记会把日志灌满（而灌满的日志等于没有日志）。
  /// 所以只在**「从不丢变成丢」**那一刻说一条，之后靠 [droppedFrames] 那个数说话；
  /// 等下一个关键帧把缓存清空、不丢了，再把标记复位 —— 下次真丢时才会再响。
  var _dropNotified = false;

  /// 因为装不下被丢掉的帧数（诊断用）。
  ///
  /// ⚠️ 它一直涨说明**编码器长时间没吐关键帧**（缓存里那一段已经长到装不下）——
  /// 那本身不是故障，但用户抱怨「画面卡」时，先看这个数。
  int get droppedFrames => _dropped;

  /// 现在有几路客户端在看（含还在等关键帧的）。
  int get subscriberCount => _watchers.length;

  /// 缓存里现在有几帧（诊断用）。
  int get bufferedFrames => _gop.length;

  /// 缓存里这一段**是不是从关键帧开始的**。
  ///
  /// ⚠️ 只有它为真才补得出去（见 [subscribe]）—— 公开出来是给测试钉这条不变量的。
  bool get hasKeyFrameAtHead => _gop.isNotEmpty && _gop.first.isKey;

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

    // ⚠️ 装不下就**整段丢掉**（只留刚推上来的这一帧），不是从中间抽一帧。
    //
    // 抽中间那一帧会在这一段里留一个**洞**，洞之后的每一帧都缺参考 ——
    // 新接入的电脑端拿到的是一段**解不出来**的画面（花屏，而 ffmpeg 只在
    // stderr 里刷 `left block unavailable for requested intra mode` 之类），
    // 而两边都不知道为什么。整段丢掉之后，他只是**等下一个关键帧**（≤2 秒）。
    //
    // 正常情况根本走不到这里：缓存大小 ≥ 一整段 GOP（见 [maxBufferedFrames]）。
    if (_gop.length > maxBufferedFrames) {
      _dropped += _gop.length - 1;

      // 只留刚推上来的那一帧 —— 它是**当下**，不是历史。留着它这个缓存的
      // 「头不是关键帧 ⇒ 不补」于是自然成立（见 [subscribe]）。
      _gop.removeRange(0, _gop.length - 1);
      _noteDrop();
    }

    // 关键帧 ⇒ 还在等的那几路**从现在这一帧起**就跟上了。必须在下面那个循环
    // 之前放开，否则他们连这个关键帧都收不到，永远等下去。
    if (frame.isKey) {
      for (final watcher in _watchers) {
        watcher.waitingForKey = false;
      }
    }

    for (final watcher in _watchers) {
      // 已经关掉的那一路（客户端走了）就别写了。
      if (watcher.controller.isClosed) continue;

      // ⚠️ **还没等到关键帧的一路，一个字节都不给。** 给他半途的 P 帧，
      // 他解不出来 —— 而解不出来的样子（黑着/花屏/整块马赛克）与「手机没推流」
      // 长得一模一样，看的人只会以为那台手机掉线了。让他等下一个关键帧
      //（≤2 秒）比给一堆垃圾强。
      if (watcher.waitingForKey) continue;

      watcher.controller.add(frame.bytes);
    }
  }

  /// 开一路新的。
  ///
  /// ⚠️ **先把 GOP 缓存补给他**，再接上实时的 —— 顺序不能反：
  /// 先接实时的话，他会在关键帧到来之前先收到几块 P 帧，那些解不出来。
  ///
  /// ⚠️ **他拿到的第一块一定是关键帧。** 头不是关键帧时就一块都不补，
  /// 而且**从下一个关键帧起才开始给他实时的**（见 [_Watcher.waitingForKey]）——
  /// 半途的 P 帧他解不出来，解不出来的样子（黑着/花屏）与「手机没推流」
  /// 长得一模一样，看的人只会以为那台手机掉线了。
  Stream<List<int>> subscribe() {
    // 关掉的这一层不再给任何东西：给一条空的流，让上面那一路**当场结束**，
    // 电脑端那边立刻就能重连，而不是挂在一条永远不来的流上等超时。
    if (_closed) return Stream<List<int>>.empty();

    final controller = StreamController<List<int>>();
    final watcher = _Watcher(controller, waitingForKey: !hasKeyFrameAtHead);

    if (hasKeyFrameAtHead) {
      for (final frame in _gop) {
        controller.add(frame.bytes);
      }
    }

    _watchers.add(watcher);
    controller.onCancel = () => _watchers.remove(watcher);

    return controller.stream;
  }

  /// 把缓存里的历史**丢掉**（这一层本身照常活着）。
  ///
  /// ⚠️ **推流编码器重开之后必须调**（改档就是重开一个）。
  /// 新编码器的尺寸与参数集都可能与老的不同，而缓存里还留着老编码器那些帧 ——
  /// 不丢的话，那一刻接入的电脑端会**先收到一段老编码器的画面**，紧接着是新的：
  /// 一路裸流里混着两种尺寸，ffmpeg 那边解出来就是花屏 + 一串解码错误
  ///（2026-10-03 的日志里正是这个形状，而用户说的「卡」就卡在这儿）。
  void clear() {
    _gop.clear();
    _dropNotified = false;
  }

  /// 丢帧了 —— 只在**第一次**说一条（见 [_dropNotified]）。
  void _noteDrop() {
    if (_dropNotified) return;
    _dropNotified = true;

    onLog(
      '缓存里这一段长到装不下了，整段丢掉 —— 新接入的电脑端要等下一个关键帧'
      '（手机那边 2 秒一个）。这本身不是故障（宁可晚两秒，也不给一段解不出来的画面），'
      '但一直这样说明编码器迟迟不吐关键帧。',
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

    for (final watcher in [..._watchers]) {
      if (!watcher.controller.isClosed) unawaited(watcher.controller.close());
    }

    _watchers.clear();
  }
}

/// 看客之一：一路客户端 + 「他是不是还在等关键帧」。
///
/// 这个标记就是「他拿到的第一块一定是关键帧」那条不变量本身 ——
/// 没有它，[LiveStreamHub.subscribe] 在缓存头不是关键帧时只能二选一：
/// 要么给他一串解不出来的 P 帧，要么等（而那要一个位置记着「谁在等」）。
class _Watcher {
  _Watcher(this.controller, {required this.waitingForKey});

  final StreamController<List<int>> controller;
  bool waitingForKey;
}
