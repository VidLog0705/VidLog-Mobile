import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../diagnostics/app_log.dart';

/// 一台手机当场扫了多少发货、多少退货（多画面每格下面那 `F` / `T` 用的）。
///
/// ⚠️ **它只是屏幕上显示的数**，绝不进视频水印 —— 规格 §3.8 2026-10-01 那条
/// 特意写明了「F 和 T 及数量**不写入最终视频水印**」。这一层压根不碰视频，
/// 所以「不写进去」是结构上成立的，不是靠自觉。
class LiveCounts {
  const LiveCounts({required this.outbound, required this.returned});

  /// 发货（屏幕上那个绿的 `F`）。
  final int outbound;

  /// 退货（屏幕上那个红的 `T`）。
  final int returned;

  Map<String, Object?> toJson() => {'f': outbound, 't': returned};
}

/// 推流的画质档（规格 §3.8，需求方 2026-10-01 定的三档）。
///
/// ## ⚠️ 这里**只有值**，没有文案
///
/// 三档各是什么、给用户怎么解释（「好处与坏处」那三句）——**那是电脑端的事**：
/// 选择界面在那边，用户也在那边选，手机端从头到尾**不显示**它。
/// 这一层只回答一件事：「电脑端要我出多少行的画面」。
///
/// ⚠️ 曾经把那段中文文案写在这里过，理由是「只写一份、界面照抄」——
/// **那个理由不成立**：两个仓各自独立构建，电脑端没法在编译期从 Dart 这边抄，
/// 于是那段话既没人用、又躺在一个莫名其妙的 HTTP 服务里。已删。
/// 文案现在归电脑端那个选择界面，见母仓规格 §3.8。
enum LiveQuality {
  p480(480, '480P'),
  p720(720, '720P'),
  p1080(1080, '1080P');

  const LiveQuality(this.height, this.label);

  /// 短边的行数（480 / 720 / 1080）。长边按相机自己的比例算，不写死。
  final int height;

  /// 日志与诊断里用的写法（**不是给用户看的界面文字** —— 那在电脑端）。
  final String label;

  /// 九宫格格子用的那一档（规格写死 480P）。
  ///
  /// ⚠️ 它同时是**手机端的初始档**：一台手机刚起推流时总是被当成格子里的一个，
  /// 直到电脑端双击进全屏才会来改。
  static const LiveQuality tile = p480;

  /// 从报文里读一档。认不出来返回 `null` —— **不悄悄退回默认值**：
  /// 电脑端报了一个我们不懂的档，那说明两边对不上，得让它知道，
  /// 而不是让它以为自己选上了。
  static LiveQuality? parse(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return null;

    for (final quality in values) {
      if (quality.height.toString() == text) return quality;
    }

    return null;
  }
}

/// 手机端的**实时推流服务**（规格 §3.8）。
///
/// ## 为什么是 HTTP + H.264 裸流
///
/// 需求方 2026-10-01 裁决的方案 A。理由：`dart:io` 自带 `HttpServer`
///（**不加任何依赖**），而电脑端那边**已经有**「ffmpeg 拉一路源 → 读原始帧 →
/// 界面显示」的通路（预览就是它）——把 ffmpeg 的输入从相机换成这个地址即可。
///
/// ## 两条路，各走各的
///
/// | 路径 | 给什么 |
/// |---|---|
/// | `GET /live` | **H.264 裸流**（Annex-B），电脑端交给 ffmpeg |
/// | `GET /status` | 一小段 JSON：当场扫的发货/退货数 + **当前画质档** + **编码侧丢帧** |
/// | `GET /quality?p=720` | 电脑端**改档**（进出全屏时用），`p` 取 480 / 720 / 1080 |
///
/// ⚠️ **改档只能由电脑端发起**（「全屏时用户自行选择」，而选的地方在电脑端）。
/// 手机端不自己决定 —— 它不知道自己那一格是在格子里还是在全屏。
///
/// ⚠️ 计数**故意不跟视频挤同一条路**：它每秒级刷新一次就够，
/// 混进裸流里既要做容器又要做解析，而且那样才有「不小心录进视频」的可能。
class LiveServer {
  LiveServer({
    required this.counts,
    required this.droppedFrames,
    required this.video,
    this.onQuality,
    void Function(String message)? onLog,
  }) : onLog = onLog ?? _toAppLog;

  /// ⚠️ **默认落进 `AppLog`，不是「没有」**。
  ///
  /// 原来这里是个可空的 `onLog`、默认 `null` ⇒ **没有调用方传它的时候，
  /// 这个服务的起停与出错一个字都不会留下**，而编译器不会说一个字
  ///（2026-10-01 核出来的一处真漏：`lib/live/` 全层静默）。
  ///
  /// 本仓的惯用法是**直接打单例**（`AppLog.instance`，理由见
  /// `docs/实现决策.md` §28.1「参数传不进去」），所以默认值就是它；
  /// 测试要隔离时传自己的进来。
  static void _toAppLog(String message) => AppLog.instance.info('推流', message);

  /// 电脑端改档时叫一下它 —— 原生那边据此**重开那个低分辨率编码器**。
  ///
  /// ⚠️ **返回值是「换成了没有」**：返回 null 表示换成了，非 null 是不换的原因。
  /// 之所以要**等它**再回 HTTP，是因为这里有个真会发生的分叉：
  /// 安卓那边的推流尺寸是**开会话时钉死的**（改尺寸要重建相机会话 = 打断录制），
  /// 所以它可以拒绝换档。当场回 200 的话，电脑端会以为自己选上了、
  /// 按新尺寸重开解码 —— 而画面还是老尺寸，**两边谁都不知道**。
  /// 回 4xx 的话电脑端会保持原来的档（`LiveTile.SetQualityAsync` 就是这么写的）。
  ///
  /// ⚠️ **重开推流编码器绝不能碰到录制那一侧**（规格 §3.8 的硬约束）：
  /// 那两个是各自独立的 `MediaCodec` / `VTCompressionSession`，
  /// 改档只动推流那一个。改不动时**宁可继续用旧档**，也不许把录制拖下水。
  final Future<String?> Function(LiveQuality quality)? onQuality;

  /// 当前档。默认是**格子那一档**（480P）—— 手机端一开始总是被当成格子里的一个，
  /// 直到电脑端双击进全屏才会来改。
  LiveQuality _quality = LiveQuality.tile;

  /// 现在是哪一档。
  LiveQuality get quality => _quality;

  /// 报当前计数。做成回调而不是字段：计数是**别人**在变的（扫码那一路），
  /// 缓存一份在这里迟早会显示成旧的 —— 而这一格的用处就是「现在多少」。
  final LiveCounts Function() counts;

  /// 这台手机**编码这一侧**丢了多少帧（`LiveStreamHub.droppedFrames`）。
  ///
  /// ⚠️ **它既不是 [counts] 那一对数，也不是网络丢包。** 它是
  /// 「编码器长时间没吐关键帧、缓存装不下，只好**整段丢掉**」的次数。
  ///
  /// 为什么要报它：改造清单 T11 要把用户嘴里那句「卡」拆成**两个数** ——
  /// **编码侧**（手机报，就是这个）与**网络侧**（电脑端自己数收到的帧率）。
  /// 只看得见一半时，「卡」到底是手机编不动还是网线不行，是分不出来的。
  ///
  /// ⚠️ 做成回调的理由与 [counts] 完全一样：这个数是 `LiveStreamHub` 在变的，
  /// 在这里缓存一份，迟早显示成旧的 —— 而诊断用的数**显示成旧的**比没有更坏。
  final int Function() droppedFrames;

  /// 开一路**新的** H.264 裸流。
  ///
  /// ⚠️ **必须每接一个客户端就新开一路**，不是共用一个：裸流没有容器，
  /// 中途接入的那个人要靠**开头那组 SPS/PPS + 一个 IDR** 才解得出来。
  /// 给一个已经在跑的流的中间，他只能一直等下一个关键帧 ——
  /// 表现是「别的格子都出来了，就这一格黑着」。
  final Stream<List<int>> Function() video;

  final void Function(String message)? onLog;

  HttpServer? _server;

  /// 起服务；返回**实际绑上的端口**（传 0 时由系统分配，测试用得到）。
  Future<int> start({int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;

    unawaited(_serve(server));

    _log('实时推流服务起了：${server.address.host}:${server.port}');
    return server.port;
  }

  /// 停掉。
  ///
  /// ⚠️ 没起过就调它**不留痕**：否则日志里会出现一条「服务停了」，
  /// 而它压根没起过 —— 那比不记还糟。
  Future<void> stop() async {
    final server = _server;
    if (server == null) return;

    await server.close(force: true);
    _server = null;

    // ⚠️ 「停」也留一条（§6.1 的同一张表：有生命周期的组件，起停失败各一条）。
    _log('实时推流服务停了');
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      // ⚠️ 每个请求各自处理，**不 await**：`/live` 会一直挂着不断流，
      // await 它的话这个循环再也接不到第二个客户端 —— 而多画面要的正是
      // 「电脑端同时拉好几台」。单台手机也只有一路流，但连接可能重来。
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.path == '/status') {
        await _writeStatus(request);
        return;
      }

      if (request.uri.path == '/live') {
        await _pipeVideo(request);
        return;
      }

      if (request.uri.path == '/quality') {
        await _changeQuality(request);
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } on Object catch (error) {
      // 客户端断开是常态（电脑端那格关了、网络抖了），不当错误往上抛。
      _log('这一路断了：$error');
    }
  }

  /// 改档（`GET /quality?p=720`）。
  ///
  /// ⚠️ 认不出来的档回 **400，而且不改**。悄悄退回默认值的后果是：
  /// 电脑端以为自己选了 1080P，画面还是 480P，而**两边谁都不知道**。
  Future<void> _changeQuality(HttpRequest request) async {
    final wanted = LiveQuality.parse(request.uri.queryParameters['p']);

    if (wanted == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    // ⚠️ **先问原生，成了才认这一档**（顺序与电脑端那边一致：它也是先通知、
    // 成了才动本地解码）。原生怕的是「电脑端以为自己选了 1080P，
    // 而手机上还是 480P，两边都不知道」。
    if (onQuality != null) {
      final refusal = await onQuality!(wanted);

      if (refusal != null) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType('application', 'json', charset: 'utf-8')
          ..write(jsonEncode({'p': _quality.height, 'why': refusal}));

        await request.response.close();
        return;
      }
    }

    _quality = wanted;

    _log('改档：${wanted.label}');

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('application', 'json', charset: 'utf-8')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write('{"p":${wanted.height}}');

    await request.response.close();
  }

  Future<void> _writeStatus(HttpRequest request) async {
    final body = utf8.encode(jsonEncode({
      ...counts().toJson(),
      // ⚠️ 把当前档也报出去：电脑端「明明选了 1080P 怎么还是糊」的时候，
      // 有这个数就能一眼看出是改档没生效、还是那一格本来就该糊。
      'p': _quality.height,
      // ⚠️ 编码侧丢帧（T11）。**单开一个键，不塞进 `LiveCounts.toJson()`** ——
      // 那个类装的是「当场扫了多少发货/退货」，是**业务计数**；
      // 这个是**推流健康度**。混进同一个 JSON 对象里迟早有人把两者当成一回事
      // （那种错的表现是：改「今天扫了几件」时把丢帧一起改了，而没人看得出来）。
      'd': droppedFrames(),
    }));

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('application', 'json', charset: 'utf-8')
      // ⚠️ 必须禁缓存：计数是「现在多少」，缓存一下就成了历史。
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..contentLength = body.length;

    request.response.add(body);
    await request.response.close();
  }

  Future<void> _pipeVideo(HttpRequest request) async {
    final response = request.response;

    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('video', 'h264')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      // ⚠️⚠️ **这个开关是这条路的命门。**
      //
      // `HttpResponse` 是个 `IOSink`，`bufferOutput` 默认是 **true** ——
      // 也就是**所有输出都攒在内部缓冲区里**，攒够一块才真发出去。
      // 实测（`tool/live_probe.dart`，客户端换成 `curl -N` 排除客户端缓冲）：
      // 不关它的话，客户端**一个字节都收不到**，直到这一路结束才一次性全到 ——
      // 实时画面上就是「一直黑着，关掉才刷出来」。
      // 而且光靠 `flush()` **不管用**（fire-and-forget 与 await 都试过）。
      //
      // 关掉之后每帧立刻出去，代价是每帧一次系统调用 ——
      // 而这条路本来就是拿带宽换延迟的。
      ..bufferOutput = false;

    // ⚠️ **响应头是跟着第一块数据一起出去的**（实测：还没写数据时 `flush()`
    // 不把头发出去）。对 ffmpeg 这不是问题 —— 它连上之后本来就等到有帧为止。
    // ⚠️ 但**相机没开、一帧都没有时这条连接会一直挂着**，
    // 所以电脑端那一侧**必须自己设连接超时**，别指望这边会拒绝。
    await response.flush();

    // ⚠️ 中继这一层不是多余的：`await for` 只在**下一块数据到来时**才会发现
    // 「该停了」。客户端走掉之后，编码器会接着跑（相机卡住时更是**永远**不停）——
    // 而它就是靠下面那个 `cancel` 立刻停住的。
    final source = video();
    final relay = StreamController<List<int>>();
    final subscription = source.listen(
      relay.add,
      onError: relay.addError,
      onDone: relay.close,
      cancelOnError: true,
    );

    var closed = false;

    // ⚠️ 客户端断开（电脑端关了那一格、或网络抖了）—— **立刻**把上游停掉。
    // 不停的话编码器会一直往一条没人读的管道里写：手机白发热、白耗电。
    //
    // ⚠️ 但**不能只靠它**：`response.done` 是「响应发完了」才完成的，
    // 客户端半路消失时**不一定会响**（实测没响）。所以下面那个循环里
    // 还有一道「最迟下一帧就停」的兜底。
    unawaited(response.done.whenComplete(() async {
      closed = true;
      await subscription.cancel();
      if (!relay.isClosed) await relay.close();
    }));

    try {
      // ⚠️ **用 `await for` 自己泵，而且每帧 `await flush`。**
      //
      // 先前写的是 `listen(...)` + `unawaited(response.flush())`，
      // **实测不管用**（见上面 `bufferOutput` 那一段）。`await flush` 才真推得出去，
      // 顺带拿到了背压 —— 上游喂太快时这里会等，而不是无限攒在内存里。
      await for (final chunk in relay.stream) {
        // 客户端已经走了（上面那个 `done` 响了）就别再写。
        if (closed) break;

        response.add(chunk);
        await response.flush();

        // 兜底：`done` 没响、但客户端其实已经走了 —— **最迟下一帧就停**。
        if (closed) break;
      }
    } on Object catch (error) {
      _log('这一路流出错：$error');
    } finally {
      await subscription.cancel();
    }

    try {
      await response.close();
    } on Object {
      // 客户端早走了 —— 关不上不是错，这一路本来就是为了它才存在的。
    }
  }

  void _log(String message) => onLog?.call(message);
}
