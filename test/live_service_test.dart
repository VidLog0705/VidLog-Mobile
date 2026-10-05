import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/diagnostics/app_log.dart';
import 'package:vidlog_mobile/live/live_gateway.dart';
import 'package:vidlog_mobile/live/live_hub.dart';
import 'package:vidlog_mobile/live/live_server.dart';
import 'package:vidlog_mobile/live/live_service.dart';

/// 实时推流那一路的接线（规格 §3.8）。
///
/// 原生换成假件，但**HTTP 服务是真的**（真绑端口、真发请求）——
/// 「原生说的端口与真的在听的端口是不是同一个」只有真起一次才知道，
/// 而对不上时的表现是「电脑端连过去是空的」，没有别的线索。
class FakeLiveGateway implements LiveGateway {
  final _events = StreamController<LiveNativeEvent>.broadcast();

  /// 原生被要求开了几次、各是什么档（行数）。
  final List<int> started = [];

  /// 原生被要求改到哪些档。
  final List<int> qualities = [];

  int stopCount = 0;

  /// 非 null = 让 `startLive` 失败（模拟「编码器起不来」）。
  String? startFailure;

  void push(List<int> bytes, {bool isKey = false}) =>
      _events.add(LiveEncoded(LiveFrame(bytes: bytes, isKey: isKey)));

  void fail(String message) => _events.add(LiveFailed(message));

  @override
  Future<String?> startLive(int height) async {
    started.add(height);
    return startFailure;
  }

  @override
  Future<void> stopLive() async => stopCount++;

  @override
  Future<void> setLiveQuality(int height) async => qualities.add(height);

  @override
  Stream<LiveNativeEvent> get events => _events.stream;

  Future<void> close() => _events.close();
}

void main() {
  late FakeLiveGateway gateway;
  late List<int> announced;
  late String? announceFailure;
  late LiveService service;

  setUp(() {
    gateway = FakeLiveGateway();
    announced = [];
    announceFailure = null;

    AppLog.instance.resetForTesting();

    service = LiveService(
      gateway: gateway,
      counts: () => const LiveCounts(outbound: 3, returned: 1),
      announce: (port) async {
        announced.add(port);
        return announceFailure;
      },
    );
  });

  tearDown(() async {
    await service.dispose();
    await gateway.close();
  });

  /// 报到里那个端口 —— 也就是电脑端会去连的端口。
  int announcedPort() => announced.single;

  Future<HttpClientResponse> fetch(String path, int port) async {
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    return request.close();
  }

  /// 让排队的微任务都跑完（报到那一路是 `unawaited(…then(…))`）。
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('★ 起推流：原生按**格子那一档（480P）**开，报到的是**真的在听的端口**', () async {
    expect(await service.start(), isNull);

    expect(gateway.started, [480]);
    expect(announced, hasLength(1));

    // ⚠️ 这条是这一组里最要紧的一句：报到里那个端口必须**真的**能连上。
    // 报一个错的端口时，手机这边一切正常，只有电脑端那一格是黑的。
    final response = await fetch('/status', announcedPort());
    final body = await response.transform(utf8.decoder).join();

    expect(response.statusCode, 200);

    // ⚠️ `d`（编码侧丢帧）在这里只会是 0，但**它必须在**：它证明
    // `LiveService` 把 `LiveServer` 那个 `droppedFrames` 回调真的接上了 ——
    // 少接一个参数就编译不过，而**接上一个恒等于 0 的东西**只有这一句看得见。
    // 「那个数会不会跟着走」由 `live_server_test.dart` 单独钉住。
    expect(jsonDecode(body), {'f': 3, 't': 1, 'p': 480, 'd': 0});
  });

  test('原生起不来：如实回一条原因，**不抛**，也不去起服务', () async {
    gateway.startFailure = '相机没开';

    expect(await service.start(), '相机没开');
    expect(service.isRunning, isFalse);

    // 一次报到都不该有 —— 报到了电脑端就会去连一个根本不存在的服务。
    expect(announced, isEmpty);

    // 也没起 HTTP 服务：随便打个端口都连不上。
    await expectLater(
      fetch('/status', 9),
      throwsA(isA<SocketException>()),
    );
  });

  test('★ 原生推上来的帧真的走到了 /live 那一路', () async {
    await service.start();

    // ⚠️ 先推再连：新接入的客户端会先拿到缓存里那一段（从关键帧起），
    // 所以这条不依赖「连上之后才推」的时序。
    gateway.push([1, 2, 3, 4], isKey: true);
    await settle();

    final response = await fetch('/live', announcedPort());

    // ⚠️ 按**字节**收，不按块收：HTTP 那边怎么切块不是这条要验的事。
    final bytes = await response.expand((chunk) => chunk).take(4).toList();

    expect(bytes, [1, 2, 3, 4]);
  });

  test('★ 停一段再开一段：第二段**照样**把帧送出去', () async {
    // ⚠️ 这条是 2026-10-03「推流没有画面」的回归判据。
    // 那一段推流的缓存被 `stop()` 关死之后又被第二段复用，于是第二段：
    // 报到照发、`/live` 照回 200、**一帧都不来** —— 电脑端那一格永远黑着，
    // 而手机这边每一条日志看起来都正常。
    await service.start();
    await service.stop();

    await service.start();

    gateway.push([1, 2, 3, 4], isKey: true);
    await settle();

    // ⚠️ 用 `last` 不是 `single`：这里报到了**两次**，要连的是第二段那个端口。
    final response = await fetch('/live', announced.last);
    final bytes = await response.expand((chunk) => chunk).take(4).toList();

    expect(bytes, [1, 2, 3, 4]);
  });

  test('电脑端改档 → 只叫原生换档，手机上那一档跟着变', () async {
    await service.start();

    final response = await fetch('/quality?p=720', announcedPort());
    await response.drain<void>();
    await settle();

    expect(response.statusCode, 200);
    expect(gateway.qualities, [720]);
    expect(service.quality, LiveQuality.p720);

    // ⚠️ 换档**不许**把推流停掉再起来：停一下再起会丢一段画面，
    // 而电脑端那边只是双击进全屏。
    expect(gateway.stopCount, 0);
    expect(service.isRunning, isTrue);
  });

  test('⚠️ 换档 = 编码器重开：这一刻接入的客户端不许再收到老编码器那一段', () async {
    await service.start();

    gateway.push([1], isKey: true);
    gateway.push([2]);
    await settle();

    final response = await fetch('/quality?p=720', announcedPort());
    await response.drain<void>();
    await settle();

    // 老编码器的尾巴 + 新编码器的关键帧（真机上新编码器的第一帧就是关键帧）。
    gateway.push([3]);
    gateway.push([4], isKey: true);
    gateway.push([5]);
    await settle();

    final live = await fetch('/live', announcedPort());
    final bytes = await live.expand((chunk) => chunk).take(2).toList();

    expect(
      bytes,
      [4, 5],
      reason: '一路裸流里混着两种尺寸（[1,2] 老画面 + [3]），ffmpeg 那边就是花屏',
    );
  });

  test('认不出的档：原生一个字都不该收到（400 且不改）', () async {
    await service.start();

    final response = await fetch('/quality?p=999', announcedPort());
    await response.drain<void>();
    await settle();

    expect(response.statusCode, 400);
    expect(gateway.qualities, isEmpty);
    expect(service.quality, LiveQuality.tile);
  });

  test('★ 录制报压力 → 自动停推流，并且记下**为什么停**', () async {
    await service.start();

    await service.notifyRecordingPressure('设备过热');

    expect(service.isRunning, isFalse);
    expect(gateway.stopCount, 1);
    expect(service.stoppedBecauseOfPressure, '设备过热');
  });

  test('★ 压力停了几次要写在日志那一行里（T16 取证）', () async {
    // ⚠️ 累计数必须在**每一行**里：界面那个日志镜像只有最近 60 行、盘上也有上限，
    // 压力连着报十几次时前面的行会被挤掉 —— 而「一共被挤掉几次」正是要看的东西。
    await service.start();
    await service.notifyRecordingPressure('设备过热');

    await service.start();
    await service.notifyRecordingPressure('设备过热');

    final lines = AppLog.instance.tail.value
        .where((line) => line.contains('自动停掉实时共享'))
        .toList();

    expect(lines, hasLength(2));
    // ⚠️ `tail` 是**新的在前**（`_publishTail` 往前插）。
    expect(lines.last, contains('第 1 次'));
    expect(lines.first, contains('第 2 次'));
  });

  test('⚠️ 没开着的时候报压力：什么都不做（不许把状态机搅乱）', () async {
    await service.notifyRecordingPressure('设备过热');

    expect(gateway.stopCount, 0);
    expect(service.stoppedBecauseOfPressure, isNull);
  });

  test('停：原生也停、服务也停', () async {
    await service.start();

    await service.stop();

    expect(service.isRunning, isFalse);
    expect(gateway.stopCount, 1);
  });

  test('⚠️ 没起过就停 —— 不留痕（不写一条「实时共享停了」）', () async {
    await service.stop();

    expect(
      AppLog.instance.tail.value.where((line) => line.contains('实时共享停了')),
      isEmpty,
    );
  });

  test('原生报故障：留一条痕，但**不把服务拆掉**', () async {
    await service.start();

    gateway.fail('编码器崩了');
    await settle();

    expect(
      AppLog.instance.tail.value.any((line) => line.contains('编码器崩了')),
      isTrue,
    );

    // ⚠️ 这一条是重点：服务拆掉的话，电脑端那一格会从「有信号」变成
    // 「无信号输入」—— 而那是**两句话**（前者是这边坏了，后者是手机没开共享）。
    expect(service.isRunning, isTrue);
  });

  group('报到', () {
    test('★ 失败只记一条，好了再记一条（它每 20 秒跑一次，不能次次记）', () async {
      // ⚠️ 这条守的是「同一件事说几遍」：报到是每 20 秒一次的事，
      // 手机不在局域网里时它**每次都失败**，次次记的话一小时一百八十条。
      announceFailure = '连不上电脑端';
      await service.start();
      await settle();

      expect(
        AppLog.instance.tail.value.where((line) => line.contains('收不到我的报到')),
        hasLength(1),
      );

      // 好了 —— 恢复也要说一句，否则用户以为一直没连上。
      announceFailure = null;
      await service.stop();
      await service.start();
      await settle();

      expect(
        AppLog.instance.tail.value.where((line) => line.contains('又能收到报到了')),
        hasLength(1),
      );
    });
  });
}
