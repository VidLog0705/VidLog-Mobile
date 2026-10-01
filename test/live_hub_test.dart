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

  test('⚠️ 缓存满了丢老的_但头部的关键帧不许丢', () async {
    // 丢了头部那个关键帧，新接入的人就**再也**解不出来了 ——
    // 而且他不知道自己解不出来（画面就是黑着）。
    //
    // ⚠️ 同时钉住**留痕**（§6.1：不许静默）：丢帧是每秒几十次的事，
    // 每次都记会把日志灌满 —— 所以只该在**「从不丢变成丢」**那一刻说一条。
    final logs = <String>[];
    final hub = LiveStreamHub(maxBufferedFrames: 4, onLog: logs.add);

    hub.push(frame(1, key: true));
    for (var i = 2; i <= 10; i++) {
      hub.push(frame(i));
    }

    expect(hub.bufferedFrames, 4);
    expect(hub.droppedFrames, 6);

    expect(logs, hasLength(1), reason: '丢了 6 帧，但只该说一条');
    expect(logs.single, contains('丢帧'));

    final stream = hub.subscribe();

    // ⚠️ 这条要在**开始消费之前**断言：`take` 收够就 break，而 break 会取消订阅、
    // hub 那边跟着把人摘掉 —— 消费完再看就是 0 了。
    expect(hub.subscriberCount, 1);

    expect((await take(stream, 4)).first, [1], reason: '头部那个关键帧必须在');

    // 来了个新的关键帧 ⇒ 缓存清空、不丢了 —— **再丢时该再响一条**
    //（「好了之后又坏」也是「变了」）。
    hub.push(frame(11, key: true));
    for (var i = 12; i <= 20; i++) {
      hub.push(frame(i));
    }

    expect(logs, hasLength(2), reason: '好了之后又坏，是「变了」');
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
