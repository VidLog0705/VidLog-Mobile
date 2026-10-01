import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/netdisk/netdisk_token.dart';

/// 借令牌这条路上最容易写错的两件事：
/// **给不了的时候不许拿旧的凑**、**问不到的时候才许拿旧的顶上**。
void main() {
  late Directory temp;
  late String path;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vidlog-netdisk-');
    path = '${temp.path}/netdisk-token.json';
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  NetdiskGrant okGrant({String token = 'access-1', String app = 'VidLog'}) =>
      NetdiskGrant(
        status: NetdiskGrant.ok,
        accessToken: token,
        appName: app,
      );

  group('读电脑端回的那一份', () {
    test('四档状态都认得', () {
      for (final status in [
        NetdiskGrant.ok,
        NetdiskGrant.notLoggedIn,
        NetdiskGrant.unavailable,
        NetdiskGrant.failed,
      ]) {
        final grant = NetdiskGrant.fromJson({'status': status});
        expect(grant.status, status);
      }
    });

    test('状态对但令牌是空的_不算拿到', () {
      // ⚠️ 回包少了一半时，拿着空令牌去调网盘只会换回一串看不懂的 31045 ——
      // 所以「能用」的判据是三个字段都有，不是状态等于 ok。
      expect(NetdiskGrant.fromJson({'status': 'ok'}).isOk, isFalse);
      expect(
        NetdiskGrant.fromJson({'status': 'ok', 'accessToken': '  '}).isOk,
        isFalse,
      );
      expect(
        NetdiskGrant.fromJson({'status': 'ok', 'accessToken': 'a'}).isOk,
        isFalse,
        reason: '没有应用名就拼不出 /apps/<它>/，照样用不了',
      );
      expect(okGrant().isOk, isTrue);
    });

    test('字段名是 camelCase_与上传接口同一套', () {
      final grant = NetdiskGrant.fromJson({
        'status': 'ok',
        'accessToken': 'a',
        'appName': 'VidLog',
        'message': 'x',
      });
      expect(grant.accessToken, 'a');
      expect(grant.appName, 'VidLog');
      expect(grant.message, 'x');
    });
  });

  group('落盘', () {
    test('只落能用的那一份', () async {
      final store = NetdiskTokenStore(path);

      await store.save(NetdiskGrant(
        status: NetdiskGrant.notLoggedIn,
        message: '没登着',
      ));

      expect(await store.load(), isNull);
      expect(File(path).existsSync(), isFalse, reason: '给不出来的那些不该落盘');
    });

    test('落下去再读回来是同一份', () async {
      final store = NetdiskTokenStore(path);
      await store.save(okGrant());

      final back = await NetdiskTokenStore(path).load();

      expect(back!.accessToken, 'access-1');
      expect(back.appName, 'VidLog');
    });

    test('读坏了当没有_不抛', () async {
      // 令牌是**可以重新借**的东西。为一份缓存把整页打不开，是拿能用的换不能用的。
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync('{ 这不是 json');

      expect(await NetdiskTokenStore(path).load(), isNull);
    });

    test('抹掉之后就没有了', () async {
      final store = NetdiskTokenStore(path);
      await store.save(okGrant());
      await store.clear();

      expect(await store.load(), isNull);
      // 再抹一次也不抛（删不掉不是错）。
      await store.clear();
    });
  });

  group('手机自己登录（简化模式）', () {
    test('授权链接里只有 AppKey_没有 secret', () {
      // ⚠️ 这一条是**合规边界**：AGENTS §2 写死「客户端绝不内置 secret」。
      // 简化模式是唯一一种不要 secret 的（文档 004：适用于无 Server 端配合的应用）。
      final url = buildImplicitAuthorizeUrl(
        appKey: 'APPKEY123',
        redirectUri: 'vidlog://oauth',
      );

      expect(url, contains('response_type=token'));
      expect(url, contains('client_id=APPKEY123'));
      expect(url, contains('scope=basic%2Cnetdisk'));
      expect(url, isNot(contains('secret')));
    });

    test('带 state 时才带上它', () {
      final without = buildImplicitAuthorizeUrl(appKey: 'k', redirectUri: 'r');
      expect(without, isNot(contains('state=')));

      final with_ = buildImplicitAuthorizeUrl(appKey: 'k', redirectUri: 'r', state: 'abc');
      expect(with_, contains('state=abc'));
    });

    test('令牌在 fragment 里_要读得出来', () {
      // ⚠️ 文档 008 的跳转组成是 `<回调地址>#access_token=xxx&expires_in=xxx&…`。
      // 只读 query 的话会**永远读不到**，而表现是「授权明明成功了，App 说没拿到」。
      final at = DateTime(2026, 10, 1, 12);
      final grant = parseImplicitRedirect(
        'vidlog://oauth#access_token=tok-1&expires_in=2592000&scope=basic+netdisk',
        appName: 'VidLog',
        now: at,
      );

      expect(grant.isOk, isTrue);
      expect(grant.accessToken, 'tok-1');
      expect(grant.appName, 'VidLog');
      expect(grant.expiresAt, at.add(const Duration(seconds: 2592000)));
      expect(grant.expiredAt(at), isFalse);
      expect(grant.expiredAt(at.add(const Duration(days: 31))), isTrue);
    });

    test('万一百度改成回 query_也读得出来', () {
      final grant = parseImplicitRedirect(
        'https://x/cb?access_token=tok-2',
        appName: 'VidLog',
      );
      expect(grant.accessToken, 'tok-2');
    });

    test('用户点取消要说成取消_不是出错', () {
      // 「出错了」会让人以为是程序坏了，于是反复重试一件永远不会成的事。
      final grant = parseImplicitRedirect(
        'vidlog://oauth#error=access_denied&error_description=user+denied',
        appName: 'VidLog',
      );

      expect(grant.status, NetdiskGrant.failed);
      expect(grant.accessToken, isNull);
      expect(grant.message, contains('取消'));
    });

    test('别的 error 要带出百度那句话', () {
      final grant = parseImplicitRedirect(
        'vidlog://oauth#error=invalid_client&error_description=app+not+exist',
        appName: 'VidLog',
      );

      expect(grant.status, NetdiskGrant.failed);
      expect(grant.message, contains('app not exist'));
    });

    test('没有令牌、没有有效期时都不编', () {
      expect(
        parseImplicitRedirect('vidlog://oauth', appName: 'VidLog').status,
        NetdiskGrant.failed,
      );

      // expires_in 读不出来 ⇒ expiresAt 是 null（**不编一个数**：编短了逼用户白重新授权，
      // 编长了会在真过期之后继续拿它去调网盘，那时报的错与「过期」毫无关系）。
      final grant = parseImplicitRedirect(
        'vidlog://oauth#access_token=t',
        appName: 'VidLog',
      );
      expect(grant.expiresAt, isNull);
      expect(grant.expiredAt(DateTime(2099)), isFalse, reason: '没有有效期就当作没过期');
    });

    test('落盘再读回来_有效期还在', () async {
      final store = NetdiskTokenStore(path);
      final at = DateTime(2026, 10, 1, 12);

      await store.save(parseImplicitRedirect(
        'vidlog://oauth#access_token=t&expires_in=100',
        appName: 'VidLog',
        now: at,
      ));

      final back = await NetdiskTokenStore(path).load();
      expect(back!.expiresAt, at.add(const Duration(seconds: 100)));
    });
  });

  group('用户从 oob 那一页粘回来的东西', () {
    test('粘一整条跳转网址', () {
      final grant = parsePastedCredential(
        'http://openapi.baidu.com/oauth/2.0/login_success#access_token=tok-1&expires_in=2592000',
        appName: 'VidLog',
      );

      expect(grant.isOk, isTrue);
      expect(grant.accessToken, 'tok-1');
    });

    test('⚠️ 只抄了页面上那一行参数_也要认', () {
      // 百度是把结果**印在页面上**的（oob 那条路），用户框选那一行复制，
      // 比复制整条地址栏自然得多。只认 fragment 的话这里会回一句
      // 「跳转回来的网址里没有令牌」—— 而用户明明把令牌摆在眼前。
      final grant = parsePastedCredential(
        'access_token=tok-2&expires_in=100&scope=basic+netdisk',
        appName: 'VidLog',
      );

      expect(grant.isOk, isTrue);
      expect(grant.accessToken, 'tok-2');
    });

    test('⚠️ 只抄了那串令牌_不被当成网址', () {
      // 判据要是写成「能不能 parse 成 Uri」，这一串会被当成网址
      //（`126.ee2c…` 看着就像个 scheme），然后回「里面没有令牌」。
      final at = DateTime(2026, 10, 1, 12);
      final grant = parsePastedCredential(
        '126.ee2ca5592d5289e2885eeba126bc98ff.YHmyFbqEz_EUyG0EnsTXREp9VqDJmyIDpxeA1zw.EzfneA',
        appName: 'VidLog',
        now: at,
      );

      expect(grant.isOk, isTrue);
      expect(grant.accessToken, startsWith('126.'));
      // 有效期按文档写死的 30 天算（004：「Access Token 有效期30天」）。
      // 不算的话这一份会被当成永不过期，真过期后报的错与「过期」毫无关系。
      expect(grant.expiresAt, at.add(const Duration(days: 30)));
    });

    test('粘回来的东西里带错误_如实报', () {
      final grant = parsePastedCredential(
        'vidlog://oauth#error=access_denied',
        appName: 'VidLog',
      );

      expect(grant.status, NetdiskGrant.failed);
      expect(grant.message, contains('取消'));
    });

    test('什么都没粘_说清楚', () {
      expect(
        parsePastedCredential('   ', appName: 'VidLog').status,
        NetdiskGrant.failed,
      );
    });
  });

  group('取令牌的顺序', () {
    test('问电脑端问到了_就用刚借的_并落盘', () async {
      final store = NetdiskTokenStore(path);
      final session = NetdiskSession(
        fetchFromHost: () async => okGrant(token: 'fresh'),
        store: store,
      );

      final grant = await session.token();

      expect(grant.accessToken, 'fresh');
      expect((await NetdiskTokenStore(path).load())!.accessToken, 'fresh');
    });

    test('问到了新的_哪怕本地那份还没过期也用新的', () async {
      // ⚠️ 电脑端可能自己续过期，续期之后旧的那串未必还算数。
      // 「本地这份看着还没坏」不是理由 —— 用刚借到的才是唯一稳妥的。
      final store = NetdiskTokenStore(path);
      await store.save(okGrant(token: 'old'));

      final session = NetdiskSession(
        fetchFromHost: () async => okGrant(token: 'fresh'),
        store: store,
      );
      await session.restore();

      expect((await session.token()).accessToken, 'fresh');
    });

    test('连不上电脑端时_退回落盘那份接着用', () async {
      // 这条**必须**成立：借用令牌就是为了跨网用，连不上电脑端时还要能用，
      // 不然「落盘」这件事白做了。
      final store = NetdiskTokenStore(path);
      await store.save(okGrant(token: 'cached'));

      final session = NetdiskSession(
        fetchFromHost: () async => throw const SocketException('连不上'),
        store: store,
      );
      await session.restore();

      expect((await session.token()).accessToken, 'cached');
    });

    test('这次问不到时_也退回落盘那份', () async {
      final store = NetdiskTokenStore(path);
      await store.save(okGrant(token: 'cached'));

      final session = NetdiskSession(
        fetchFromHost: () async => const NetdiskGrant(
          status: NetdiskGrant.failed,
          message: '问不到百度网盘：触发限流',
        ),
        store: store,
      );
      await session.restore();

      expect((await session.token()).accessToken, 'cached');
    });

    test('连不上又没落盘时_如实说连不上', () async {
      final session = NetdiskSession(
        fetchFromHost: () async => throw const SocketException('连不上'),
        store: NetdiskTokenStore(path),
      );

      final grant = await session.token();

      expect(grant.status, NetdiskGrant.failed);
      expect(grant.accessToken, isNull);
      expect(grant.message, contains('电脑端'));
    });

    test('电脑端说没登着_如实报_并且把落盘那份抹掉', () async {
      // ⚠️ 这一条是重点。「没登着」是**确定性的给不了**，接着用落盘那份只会让
      // 用户对着一堆网盘错误码猜；而那份缓存留着，下次连不上电脑端时又会被拿出来用。
      final store = NetdiskTokenStore(path);
      await store.save(okGrant(token: 'cached'));

      final session = NetdiskSession(
        fetchFromHost: () async => const NetdiskGrant(
          status: NetdiskGrant.notLoggedIn,
          message: '电脑端还没登录百度网盘',
        ),
        store: store,
      );
      await session.restore();

      final grant = await session.token();

      expect(grant.status, NetdiskGrant.notLoggedIn);
      expect(grant.accessToken, isNull, reason: '不许把已经作数的旧令牌混在答复里');
      expect(await NetdiskTokenStore(path).load(), isNull, reason: '那一份已经在骗人了');
      expect(session.cached, isNull);
    });
  });
}
