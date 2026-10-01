import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/live/live_server.dart';

/// 这一层要钉住三件事，而且三件错了都**只在电脑端那边看得出来**：
/// 「多画面能不能同时拉」「断开时上游停不停」「计数是不是实时的」。
///
/// ⚠️ 写这一组测试时踩到的那个坑，值得记在这里：**响应头是跟着第一块数据
/// 出去的**（实测 `HttpResponse.flush()` 在还没写过数据时不发头）。
/// 所以「先 `await request.close()` 再喂数据」是**死等** ——
/// `close()` 要等响应头，而响应头要等数据，而数据在等测试往下走。
/// 顺序必须是：起请求 → 等服务端接上 → 喂数据 → 再 await。
void main() {
  late List<StreamController<List<int>>> opened;
  late List<String> logs;
  late LiveServer server;
  late HttpClient client;
  late int port;

  setUp(() async {
    opened = [];
    logs = [];

    server = LiveServer(
      // ⚠️ 一定要接出来：服务端那一侧把异常收进日志里了，
      // 不接的话测试只会看到「超时」，看不到真正的原因。
      onLog: logs.add,
      counts: () => const LiveCounts(outbound: 7, returned: 2),
      video: () {
        // ⚠️ 每次调用都要**新开一路** —— 「各开一路」那条测试数的就是这个。
        final controller = StreamController<List<int>>();
        opened.add(controller);
        return controller.stream;
      },
    );

    port = await server.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    for (final controller in opened) {
      if (!controller.isClosed) await controller.close();
    }
    await server.stop();
  });

  Uri uri(String path) => Uri.parse('http://127.0.0.1:$port$path');

  /// 等服务端接上 [count] 条 `/live`。
  Future<void> waitForOpen(int count) async {
    for (var i = 0; i < 200 && opened.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(opened.length, greaterThanOrEqualTo(count), reason: '服务端没接上');
  }

  test('status 回当场扫的发货与退货数', () async {
    final response = await (await client.getUrl(uri('/status'))).close();
    final body = await response.transform(utf8.decoder).join();

    expect(response.statusCode, 200);
    expect(jsonDecode(body), {'f': 7, 't': 2, 'p': 480});
  });

  group('改档（电脑端进出全屏时用）', () {
    Future<HttpClientResponse> put(String query) async =>
        (await client.getUrl(uri('/quality$query'))).close();

    test('默认是格子那一档 480P', () {
      expect(server.quality, LiveQuality.tile);
      expect(LiveQuality.tile.height, 480);
    });

    test('改档回 200_并且叫一下原生那边', () async {
      final asked = <LiveQuality>[];
      final withCallback = LiveServer(
        counts: () => const LiveCounts(outbound: 0, returned: 0),
        video: () => const Stream<List<int>>.empty(),
        // ⚠️ 回 null = 原生说「换成了」。可以返回一条原因来拒绝 ——
        // 安卓那边的尺寸是开会话时钉死的，它**真的会拒**（见下面那条用例）。
        onQuality: (quality) async {
          asked.add(quality);
          return null;
        },
      );
      final otherPort = await withCallback.start();

      final response = await (await HttpClient()
              .getUrl(Uri.parse('http://127.0.0.1:$otherPort/quality?p=1080')))
          .close();
      await response.drain<void>();

      expect(response.statusCode, 200);
      expect(asked, [LiveQuality.p1080]);
      expect(withCallback.quality, LiveQuality.p1080);

      await withCallback.stop();
    });

    test('⚠️ 认不出的档回 400_而且不改', () async {
      // 悄悄退回默认值的后果是：电脑端以为自己选了 1080P，画面还是 480P，
      // 而**两边谁都不知道**。
      final before = server.quality;

      final response = await put('?p=4320');
      await response.drain<void>();

      expect(response.statusCode, 400);
      expect(server.quality, before, reason: '认不出来就不许动');
    });

    test('不给参数也是 400', () async {
      final response = await put('');
      await response.drain<void>();

      expect(response.statusCode, 400);
    });

    test('⚠️ 原生拒绝换档 ⇒ 回 400_而且**本机那一档也不许动**', () async {
      // ⚠️ 这条守的是一句实话：安卓那边的推流尺寸是**开会话时钉死的**
      // （改尺寸要重建相机会话 = 打断录制），所以它会拒。
      // 当场回 200 的话，电脑端会按新尺寸重开解码，而画面还是老尺寸 ——
      // 两边谁都不知道；而 `GET /status` 报出去的 `p` 也会变成假的。
      final refusing = LiveServer(
        counts: () => const LiveCounts(outbound: 0, returned: 0),
        video: () => const Stream<List<int>>.empty(),
        onQuality: (quality) async => '这一端只能推 480P',
      );
      final otherPort = await refusing.start();

      final response = await (await HttpClient()
              .getUrl(Uri.parse('http://127.0.0.1:$otherPort/quality?p=1080')))
          .close();
      final body = jsonDecode(await response.transform(utf8.decoder).join());

      expect(response.statusCode, 400);
      expect(body['why'], contains('480P'));
      expect(refusing.quality, LiveQuality.tile, reason: '没换成就得说实话');

      await refusing.stop();
    });

    test('改完之后 status 里报的是新档', () async {
      await (await put('?p=720')).drain<void>();

      final status = await (await client.getUrl(uri('/status'))).close();
      final body = jsonDecode(await status.transform(utf8.decoder).join());

      expect(body['p'], 720);
      expect(server.quality, LiveQuality.p720);
    });
  });

  group('画质档本身', () {
    test('三档就是需求方定的那三个', () {
      expect(
        LiveQuality.values.map((q) => q.height),
        [480, 720, 1080],
      );
    });

    test('⚠️ 这一档位不背文案', () {
      // 「好处与坏处」那三句是**电脑端选择界面上**的字，手机端不显示。
      // 曾经写在这里过（理由「只写一份」），但两个仓各自独立构建、抄不过去 ——
      // 那段话既没人用，又躺在一个 HTTP 服务里。这一条守着别再放回来。
      expect(
        LiveQuality.values.map((q) => q.height).toList(),
        [480, 720, 1080],
        reason: '这一层只管「出多少行的画面」，不管怎么跟用户解释',
      );
    });

    test('parse 认数字_认不出给 null 而不是退回默认', () {
      expect(LiveQuality.parse('480'), LiveQuality.p480);
      expect(LiveQuality.parse(' 720 '), LiveQuality.p720);
      expect(LiveQuality.parse('1080P'), isNull, reason: '只认数字，不认带后缀的');
      expect(LiveQuality.parse(null), isNull);
      expect(LiveQuality.parse(''), isNull);
    });
  });

  test('⚠️ status 必须禁缓存', () async {
    // 计数是「现在多少」。缓存一下就成了历史 —— 而这一格的用处就是实时。
    final response = await (await client.getUrl(uri('/status'))).close();
    await response.drain<void>();

    expect(
      response.headers.value(HttpHeaders.cacheControlHeader),
      contains('no-store'),
    );
  });

  test('live 把上游的字节原样吐出来', () async {
    final pending = (await client.getUrl(uri('/live'))).close();

    await waitForOpen(1);
    opened.single.add([1, 2, 3]);

    final response = await pending;

    expect(response.statusCode, 200);
    expect(await response.first, [1, 2, 3]);
    expect(logs.where((line) => line.contains('断了')), isEmpty);
  });

  test('⚠️ 每个客户端各开一路_不是共用', () async {
    // 裸流没有容器，中途接入的那个人要靠**开头那组 SPS/PPS + 一个 IDR** 才解得出来。
    // 共用一个已经在跑的流的话，他只能一直等下一个关键帧 ——
    // 表现是「别的格子都出来了，就这一格黑着」。
    final first = (await client.getUrl(uri('/live'))).close();
    await waitForOpen(1);

    final second = (await client.getUrl(uri('/live'))).close();
    await waitForOpen(2);

    expect(opened, hasLength(2), reason: '两个客户端必须开两路');

    // 各自喂自己那一份，互不串。
    opened[1].add([9]);
    expect(await (await second).first, [9]);

    opened[0].add([1]);
    expect(await (await first).first, [1]);
  });

  test('上游结束 ⇒ 这一路也结束（电脑端才等得到 EOF 去重连）', () async {
    final pending = (await client.getUrl(uri('/live'))).close();

    await waitForOpen(1);
    opened.single.add([0]);

    final response = await pending;
    final collected = <int>[];
    final done = Completer<void>();
    response.listen(collected.addAll, onDone: done.complete);

    opened.single.add([1, 2]);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await opened.single.close();
    await done.future.timeout(const Duration(seconds: 5));

    expect(collected, [0, 1, 2], reason: '上游给过的都要原样送到，一块不少');
  });

  // ⚠️ **「客户端半路消失 ⇒ 上游立刻停」这一条没法在这里可靠地验。**
  //
  // 试过：`client.close(force: true)` 之后，`response.done` **不响**
  //（它是「响应发完了」才完成的），而循环卡在 `await response.flush()` 里、
  // 走不到「下一帧检查断开」那一步 —— Dart 的测试客户端**模拟不忠实**
  // 这种半路断连。
  //
  // 服务端那边有两道保护（`done` 回调 + 每帧检查），但**它们只在真机上才算数**：
  // 真正的消费者是电脑端的 ffmpeg，它关掉那一格时走的是真实的 socket 断开。
  // 真机验收时看这一条：**关掉一格之后，那台手机的编码该停下来**
  //（日志里不该还在一路写）。

  test('别的路径回 404', () async {
    final response = await (await client.getUrl(uri('/随便什么'))).close();
    await response.drain<void>();

    expect(response.statusCode, 404);
  });
}
