import 'dart:async';

import '../diagnostics/app_log.dart';
import 'live_gateway.dart';
import 'live_hub.dart';
import 'live_server.dart';

/// 实时推流这一整套的接线（规格 §3.8）。
///
/// 它把四样东西串起来：
///
/// | 件 | 干什么 |
/// |---|---|
/// | [LiveGateway] | 原生：编 H.264 裸流（**独立编码器，不碰录制**） |
/// | [LiveStreamHub] | 原生帧 → 每一路客户端（含 GOP 缓存，中途接入也解得出来） |
/// | [LiveServer] | 电脑端来拉的那三条件（`/live`、`/status`、`/quality`） |
/// | 报到 | 每隔一会儿告诉电脑端「我在这个地址、这个端口」 |
///
/// ## ⚠️ 规格 §3.8 那三条隔离规则落在这里
///
/// 1. **不许阻塞** —— 由原生那边保证（编码器吃不下就丢帧，见两端的原生实现）；
/// 2. **不许传染** —— 本类里**每一个**原生调用都被 try/catch 兜住，
///    任何失败都只变成一条日志 + 一格黑屏，绝不往上抛；
/// 3. **该让就让** —— [notifyRecordingPressure]：录制那边一报压力就停推流。
///
/// ## ⚠️ 它不认识「相机开没开」
///
/// 相机归 `RecordingCoordinator` 管，开机顺序由页面安排
/// （见 `recorder_page` 里那两处调用）。这一层只管「叫原生开始推」，
/// 起不来就如实回一条原因 —— **不自己判断能不能推**。
class LiveService {
  /// 三个必需件做成**公开的 final 字段**（`required this.x`），与同形的
  /// [LiveServer] 一致 —— 命名的构造参数不能以下划线开头，
  /// 写成 `required this._gateway` 是编译不过的，而走初始化列表又会多出
  /// 三条 `prefer_initializing_formals`（本仓 analyze 基线是 9 条，不往上抬）。
  LiveService({
    required this.gateway,
    required this.counts,
    required this.announce,
    AppLog? log,
    this.announceInterval = const Duration(seconds: 20),
  }) : _log = log ?? AppLog.instance;

  final LiveGateway gateway;
  final LiveCounts Function() counts;

  /// 向电脑端报到（`POST /api/v1/live/announce`）。**返回 null 表示送到了**。
  ///
  /// ⚠️ 做成一个函数而不是直接拿 `UploadClient`：这一层要能在没有网络、
  /// 没有电脑端的测试里验（报到失败 / 恢复各记一条那条判据就在那儿）。
  final Future<String?> Function(int port) announce;

  /// 当前这一段推流的那一层（没在推就是 null）。
  ///
  /// ⚠️ **它是「一段推流一个」，不是「一个进程一个」。** [LiveStreamHub] 的
  /// `close()` 是**不可逆**的（关掉之后 `push` 一个字都不收），而本类与它
  /// 都只被创建一次（见 `recorder_page` 里那处 `??=`）—— 共用一个的话，
  /// 第一次【停止工作】之后，后面每一段推流都会：报一个新端口、`/live` 回 200、
  /// **一帧都不来**。2026-10-03 那个「推流没有画面」正是这个形状。
  /// 所以 [start] 里新建、[stop] 里丢掉。
  LiveStreamHub? _hub;

  final AppLog _log;

  /// 多久报一次到。
  ///
  /// ⚠️ 它要比电脑端那边的过期时限（`LiveDirectory.DefaultTtl` = 60 秒）**短得多**
  /// —— 网络抖一下丢掉一次报到不该让那一格消失。20 秒给的是三次机会。
  final Duration announceInterval;

  LiveServer? _server;
  StreamSubscription<LiveNativeEvent>? _events;
  Timer? _announceTimer;

  /// 上一次报到是不是失败着（把重复的失败**去重成两条**：变坏一条、变好一条）。
  bool _announceFailing = false;

  /// 现在是哪一档（给界面与日志看）。
  LiveQuality _quality = LiveQuality.tile;

  /// 推流是不是开着。
  bool get isRunning => _server != null;

  /// 现在这一档。
  LiveQuality get quality => _quality;

  /// 因为录制压力被停掉的原因；没发生过就是 null。
  ///
  /// ⚠️ 界面要把它显示出来 —— 规格 §3.8 第 3 条明写「**并在界面说明为什么停**」。
  /// 悄悄停掉的话，用户看到的就是「刚才还有画面，怎么没了」。
  String? get stoppedBecauseOfPressure => _pressureReason;

  String? _pressureReason;

  /// 起推流。返回 null 表示成功；非 null 是给用户看的原因。
  ///
  /// 顺序是**先叫原生、再起服务**：反过来的话，电脑端能在「一帧都没有」的
  /// 状态下连上来（那一格会一直黑着，而两边都看不出为什么）。
  Future<String?> start() async {
    if (isRunning) return null;

    _pressureReason = null;

    // ⚠️ **这一段推流用新的一层**（见 [_hub] 的说明）：上一段停掉时把它关死了，
    // 复用它等于这一段一帧都推不出去。
    final hub = LiveStreamHub();

    // ⚠️ 高度取**格子那一档**（480P）：手机一开始总是被当成格子里的一个，
    // 直到电脑端双击进全屏才会来改档（规格 §3.8）。
    final failure = await gateway.startLive(_quality.height);
    if (failure != null) {
      // 起不来**不抛**（第 2 条：不许传染到录制那一路）。
      _log.warn('推流', '实时共享没能开起来：$failure');
      return failure;
    }

    final server = LiveServer(
      counts: counts,
      // ⚠️ 与下面那行 `video` 同一个理由：**用局部那个 `hub`，不用字段 `_hub`** ——
      // `/status` 随时可能被问到，而字段要等下面几行才赋值。
      droppedFrames: () => hub.droppedFrames,
      // 直接用局部那个 hub（不是字段）：`/live` 随时可能有人连上来，
      // 而字段要等下面几行才赋值 —— 这中间进来的那一路会拉到 null。
      video: hub.subscribe,
      onQuality: _onQualityRequested,
    );

    try {
      final port = await server.start();
      _server = server;
      _hub = hub;

      _listenToNative(hub);

      _log.info('推流', '实时共享开了：端口 $port、${_quality.label}');
      _announceNow(port);
      _announceTimer = Timer.periodic(announceInterval, (_) => _announceNow(port));

      return null;
    } on Object catch (error) {
      // 服务起不来（端口被占、权限）—— 把它刚开的编码器收回去，
      // 否则那是个没人消费、白烧电的编码器。
      _log.warn('推流', '实时共享的 HTTP 服务起不来：$error');
      await gateway.stopLive();
      return '推流服务起不来（$error）';
    }
  }

  /// 停推流。**不关相机**（相机归录制那边管）。
  ///
  /// ⚠️ 没开着的时候调它**不留痕**：否则日志里会出现一条「实时共享停了」，
  /// 而它压根没起过 —— 那比不记还糟（`LiveServer.stop` 同一条规矩）。
  Future<void> stop() async {
    if (!isRunning) return;

    _announceTimer?.cancel();
    _announceTimer = null;

    await _events?.cancel();
    _events = null;

    final server = _server;
    _server = null;
    if (server != null) await server.stop();

    // ⚠️ **先摘下来再关**：关掉之后这一层就废了（`push` 一个字都不收），
    // 留着它下次 [start] 就会以为还能用（见 [_hub]）。
    final hub = _hub;
    _hub = null;
    hub?.close();

    try {
      await gateway.stopLive();
    } on Object catch (error) {
      // 原生那边停不掉不该拦住这里 —— 相机与编码器的回收还有别的闸。
      _log.warn('推流', '原生推流没停干净：$error');
    }

    _log.info('推流', '实时共享停了');
  }

  /// 录制那边报了压力 —— **把推流停掉**（规格 §3.8 第 3 条）。
  ///
  /// ⚠️ 前两条（不阻塞、不传染）只挡得住**代码层面**的互相拖累；
  /// 而推流白耗的 CPU 与热量是**整机共享**的，那会实打实地让录制掉帧。
  /// 这一条是三条里最后一道闸，也是唯一一条能兜住那个物理事实的。
  ///
  /// 取舍写在这里：**录制是证据，推流是便利。两者冲突时无条件舍推流。**
  Future<void> notifyRecordingPressure(String reason) async {
    if (!isRunning) return;

    _pressureReason = reason;
    _log.warn('推流', '录制那边报压力（$reason）—— 自动停掉实时共享。录制优先。');

    await stop();
  }

  /// [hub] 是**这一段推流**的那一层（调用点传进来，不是读字段）——
  /// 事件流与 [start]/[stop] 之间没有别的闸，直接在闭包里钉住这一段，
  /// 就不会有「上一段的帧被推给下一段」这种串台。
  void _listenToNative(LiveStreamHub hub) {
    _events = gateway.events.listen(
      (event) {
        switch (event) {
          case LiveEncoded(:final frame):
            hub.push(frame);
          case LiveFailed(:final message):
            // 原生自己停了（编码器崩、相机被收走）—— 留痕，并让这一格黑着。
            // ⚠️ **不在这里调 stop()**：那会把 HTTP 服务也拆了，而电脑端
            // 那一格会从「有信号」变成「无信号输入」—— 两句话不是一回事。
            _log.warn('推流', '原生推流报了故障：$message');
        }
      },
      onError: (Object error) => _log.warn('推流', '原生推流事件流出错：$error'),
      cancelOnError: false,
    );
  }

  /// 电脑端要求改档（进出全屏）。返回 null = 换成了，非 null = 不换的原因。
  ///
  /// ⚠️ **换成了才更新本地那一档**：安卓那边的尺寸是开会话时钉死的，
  /// 它可以拒绝 —— 那时本地记着新档、而实际还在推老档，
  /// 下一次 `GET /status` 报出去的 `p` 就是假的。
  Future<String?> _onQualityRequested(LiveQuality wanted) async {
    if (wanted == _quality) return null;

    // ⚠️ **只重开推流那一个编码器**；录制那一侧一个字都不动（规格 §3.8）。
    final refusal = await _applyQuality(wanted);

    if (refusal == null) {
      _quality = wanted;
      return null;
    }

    _log.warn('推流', '换档到 ${wanted.label} 失败，继续用 ${_quality.label}：$refusal');
    return refusal;
  }

  /// 叫原生换档。返回 null = 成了。
  Future<String?> _applyQuality(LiveQuality wanted) async {
    try {
      await gateway.setLiveQuality(wanted.height);
      _log.info('推流', '档位换成 ${wanted.label}');

      // ⚠️ **换档 = 原生那边重开一个编码器**，而缓存里还留着**老编码器**那些帧：
      // 尺寸与参数集都不同，这一刻接入的电脑端会先拿到一段老画面、紧接着新的 ——
      // 一路裸流里混着两种尺寸，ffmpeg 那边就是花屏 + 一串解码错误
      //（2026-10-03 的日志里正是这个形状）。丢掉，让新接入的等下一个关键帧。
      //
      // 已经在看的那几路不受影响：它们收到过的老帧已经过去了，新编码器的关键帧
      // 里带着新的 SPS/PPS，ffmpeg 认得出来（裸流换分辨率本来就是这么走的）。
      _hub?.clear();
      return null;
    } on Object catch (error) {
      // 改不动就继续用旧档 —— 那比把推流整个搞坏好（规格 §3.8 明写）。
      return '$error';
    }
  }

  void _announceNow(int port) {
    unawaited(announce(port).then((failure) {
      if (failure == null) {
        if (_announceFailing) {
          _announceFailing = false;
          _log.info('推流', '电脑端又能收到报到了。');
        }

        return;
      }

      // ⚠️ **只在「从好变坏」那一刻记一条**：手机不在局域网里、电脑端没开，
      // 这两个都是**常态**（工人拿着手机走开了），每次都记的话
      // 一分钟三条、一小时一百八十条。
      if (!_announceFailing) {
        _announceFailing = true;
        _log.warn(
          '推流',
          '电脑端收不到我的报到：$failure'
          '（手机那边照常录制与推流，只是电脑端的多画面里不会出现这台机位）',
        );
      }
    }));
  }

  /// 服务与事件流的回收（页面销毁时调）。
  Future<void> dispose() => stop();
}
