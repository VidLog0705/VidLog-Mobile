import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/live/live_hub.dart';

/// 这一层要钉住的是**新接入的客户端能不能立刻出画**。
/// 错了的表现全在电脑端那边：某一格一直黑着、过几秒才亮 ——
/// 而看的人只会以为「那台手机掉线了」。
void main() {
  LiveFrame frame(int tag, {bool key = false}) =>
      LiveFrame(bytes: [tag], isKey: key);

  /// 收够 [count] 块就返回。
  Future<List<List<int>>> take(Stream<List<int>> stream, int count) async {
    final chunks = <List<int>>[];

    await for (final chunk in stream) {
      chunks.add(chunk);
      if (chunks.length >= count) break;
    }

    return chunks;
  }

  test('⚠️ 新接入的先拿到关键帧_再接上实时的', () async {
    // 给一个半途（只有 P 帧）的话，他解不出来 —— 只能一直等下一个关键帧。
    final hub = LiveStreamHub();

    hub.push(frame(1, key: true));
    hub.push(frame(2));
    hub.push(frame(3));

    final receiving = take(hub.subscribe(), 4);

    hub.push(frame(4));

    expect(await receiving, [
      [1], // 关键帧
      [2],
      [3],
      [4], // 实时接上
    ]);
  });

  test('接了新的关键帧之后_不再补更早的', () async {
    final hub = LiveStreamHub();

    hub.push(frame(1, key: true));
    hub.push(frame(2));
    hub.push(frame(3, key: true)); // 新的 GOP 从这里开始
    hub.push(frame(4));

    final receiving = take(hub.subscribe(), 2);

    expect(await receiving, [
      [3],
      [4],
    ], reason: '老 GOP（1、2）不该再补出去 —— 那是上一段的画面');
  });

  test('⚠️ 装不下了就整段丢_绝不从中间抽一帧', () async {
    // 从中间抽一帧会在这段里留一个**洞**，洞之后的每一帧都缺参考 ——
    // 新接入的电脑端拿到的是一整段解不出来的画面（花屏），而两边都不知道为什么。
    //
    // ⚠️ 同时钉住**留痕**（§6.1：不许静默）：这个兜底**每次推流都命中**会
    // 灌满日志 —— 所以只该在**「不丢变成丢」**那一刻说一条。
    final logs = <String>[];
    final hub = LiveStreamHub(maxBufferedFrames: 4, onLog: logs.add);

    hub.push(frame(1, key: true));
    for (var i = 2; i <= 6; i++) {
      hub.push(frame(i));
    }

    expect(hub.bufferedFrames, 2, reason: '只留刚推上来的那一帧 + 上一轮剩下的');
    expect(hub.droppedFrames, 4);
    expect(hub.hasKeyFrameAtHead, isFalse, reason: '整段丢掉之后头上就不是关键帧了');

    expect(logs, hasLength(1), reason: '丢了 4 帧，但只该说一条');
    expect(logs.single, contains('整段丢掉'));

    // 新接入的这一路：**一个字节都不该收到**，直到下一个关键帧。
    final receiving = take(hub.subscribe(), 2);

    // ⚠️ 这条要在**开始消费之前**断言：`take` 收够就 break，而 break 会取消订阅、
    // hub 那边跟着把人摘掉 —— 消费完再看就是 0 了。
    expect(hub.subscriberCount, 1);

    hub.push(frame(7)); // P 帧：解不出来，不给
    hub.push(frame(8, key: true)); // 关键帧：从这里开始
    hub.push(frame(9));

    expect(await receiving, [
      [8],
      [9],
    ], reason: '他拿到的第一块必须是关键帧');

    // 关键帧来了 ⇒ 不丢了，标记复位 —— **再丢时该再响一条**
    //（「好了之后又坏」也是「变了」）。
    for (var i = 10; i <= 14; i++) {
      hub.push(frame(i));
    }

    expect(logs, hasLength(2), reason: '好了之后又坏，是「变了」');
  });

  test('⚠️ 清掉历史之后_新接入的照样等关键帧', () async {
    // 编码器重开（换档就是重开一个）之后必须清 —— 老编码器那些帧的尺寸与
    // 参数集都不同，混在一路裸流里，ffmpeg 那边就是花屏 + 一串解码错误。
    final hub = LiveStreamHub();

    hub.push(frame(1, key: true));
    hub.push(frame(2));

    hub.clear();

    expect(hub.bufferedFrames, 0);
    expect(hub.hasKeyFrameAtHead, isFalse);

    final receiving = take(hub.subscribe(), 2);

    hub.push(frame(3)); // 老画面的尾巴：不该给他
    hub.push(frame(4, key: true)); // 新编码器的第一个关键帧
    hub.push(frame(5));

    expect(await receiving, [
      [4],
      [5],
    ]);
  });

  test('⚠️ 关掉之后再有人来拉_当场结束而不是挂着', () async {
    // 挂着的话，电脑端那一格会一直等到 `-rw_timeout` 才醒过来；
    // 给一条空的流，它当场就知道「这一路没了」，能立刻重连。
    final hub = LiveStreamHub()..close();

    expect(await hub.subscribe().toList(), isEmpty);
  });

  test('多路客户端各收各的', () async {
    final hub = LiveStreamHub();
    hub.push(frame(1, key: true));

    final a = take(hub.subscribe(), 2);
    final b = take(hub.subscribe(), 2);

    expect(hub.subscriberCount, 2);

    hub.push(frame(2));

    expect(await a, [
      [1],
      [2],
    ]);
    expect(await b, [
      [1],
      [2],
    ]);
  });

  test('客户端走了之后不再给他写', () async {
    final hub = LiveStreamHub();
    hub.push(frame(1, key: true));

    final receiving = take(hub.subscribe(), 1);
    expect(await receiving, [
      [1],
    ]);

    // `take` 收够就 break —— 订阅被取消，hub 那边该把人摘掉。
    await Future<void>.delayed(Duration.zero);

    expect(hub.subscriberCount, 0);

    // 之后再推不该抛（往一条已取消的订阅里写）。
    hub.push(frame(2));
  });

  test('关掉之后谁都没有了', () async {
    final hub = LiveStreamHub();
    hub.push(frame(1, key: true));
    hub.subscribe();

    hub.close();

    expect(hub.subscriberCount, 0);
    // 关之后再推也不该抛。
    hub.push(frame(2));
  });

  test('上限太小要当场拒', () {
    // 留不下一帧新的，这个缓存就没有意义了。
    expect(() => LiveStreamHub(maxBufferedFrames: 1), throwsArgumentError);
  });
}
