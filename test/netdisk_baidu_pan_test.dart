import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/netdisk/baidu_pan.dart';

/// 这一层最容易写错的四件事：**按单号后 6 位比的是哪一段**、
/// **翻页的起点用哪个数**、**直链那一层还有个小 errno**、
/// **给不出直链时不许拿着空串去下**。
void main() {
  String json(Object value) => jsonEncode(value);

  BaiduPanClient clientWith(List<Uri> seen, List<String> replies) {
    var index = 0;
    return BaiduPanClient(
      accessToken: 'token-1',
      appName: 'VidLog',
      fetch: (uri) async {
        seen.add(uri);
        return replies[index++];
      },
    );
  }

  group('按单号后 6 位找', () {
    test('单号那一段的末尾对得上就算命中', () {
      expect(tailMatches('SF100001234567_ab12_000.mp4', '234567'), isTrue);
    });

    test('⚠️ 会话号里的数字不算命中', () {
      // 纯 contains 的话，下面这条会被「234567」搜出来 —— 而它根本不是那个单号。
      expect(tailMatches('SF999999999999_234567_000.mp4', '234567'), isFalse);
    });

    test('不是末尾不算', () {
      expect(tailMatches('SF234567000000_ab12_000.mp4', '234567'), isFalse);
    });

    test('空输入不匹配任何东西', () {
      expect(tailMatches('SF100001234567_ab12_000.mp4', '   '), isFalse);
    });

    test('单号那一段就是文件名里第一段', () {
      expect(waybillOf('SF100001234567_ab12_000.mp4'), 'SF100001234567');
      expect(waybillOf('没有下划线.mp4'), '没有下划线.mp4');
    });
  });

  group('扫到的单号 → 查询用的 6 位', () {
    test('取末尾那一串数字的最后 6 位', () {
      expect(lastSixDigits('SF100001234567'), '234567');
      expect(lastSixDigits('  YT9999000001 '), '000001');
    });

    test('不满 6 位就原样给', () {
      // 用户扫到一半也要能用，不能因为「不够 6 位」就吞掉。
      expect(lastSixDigits('SF123'), '123');
    });

    test('⚠️ 末尾带字母时仍然取数字那段', () {
      // 取「最后 6 个字符」的话这里会拿到 `1234AB` —— 而 `tailMatches` 那边
      // 比的是数字，两边对不上，表现是「扫了单号却查不到」。
      expect(lastSixDigits('SF1234AB'), '1234');
    });

    test('一个数字都没有时返回空', () {
      expect(lastSixDigits(''), '');
      expect(lastSixDigits('   '), '');
      expect(lastSixDigits('SFABC'), '');
    });
  });

  group('翻页', () {
    test('下一页的起点用服务端回的 cursor_不是本页起点加条数', () {
      // ⚠️ 文档 057 的请求参数表：has_more=1 时「应使用返回的 cursor 作为下一次
      // 查询的起点」。按 start + limit 的另一种口径翻，会在某个目录大小上
      // **静默漏掉中间那一段** —— 表现是「某条明明传上去了的录像搜不到」。
      final seen = <Uri>[];
      final client = clientWith(seen, [
        json({
          'errno': 0,
          'has_more': 1,
          'cursor': 777,
          'list': [
            {'path': '/apps/VidLog/a.mp4', 'server_filename': 'a.mp4', 'size': 1, 'fs_id': 1, 'isdir': 0},
          ],
        }),
        json({'errno': 0, 'has_more': 0, 'list': <Object>[]}),
      ]);

      return client.listAll().then((files) {
        expect(files, hasLength(1));
        expect(seen, hasLength(2));
        expect(seen[1].queryParameters['start'], '777', reason: '第二页要用 cursor');
        expect(seen[0].queryParameters['recursion'], '1', reason: '不递归就漏掉日期目录里的东西');
        expect(seen[0].queryParameters['path'], '/apps/VidLog');
      });
    });

    test('目录不进结果', () {
      final client = clientWith(<Uri>[], [
        json({
          'errno': 0,
          'has_more': 0,
          'list': [
            {'path': '/apps/VidLog/2026', 'server_filename': '2026', 'isdir': 1},
            {'path': '/apps/VidLog/a.mp4', 'server_filename': 'a.mp4', 'size': 5, 'isdir': 0},
          ],
        }),
      ]);

      return client.listAll().then((files) {
        expect(files.map((f) => f.name), ['a.mp4']);
      });
    });

    test('errno 非 0 要抛_不装作列到了空目录', () {
      final client = clientWith(<Uri>[], [
        json({'errno': 31045, 'errmsg': 'access_token 校验未通过'}),
      ]);

      expect(client.listAll(), throwsA(isA<NetdiskFailure>()));
    });

    test('页数到顶还没列完要抛_不回半截列表', () {
      final client = clientWith(<Uri>[], [
        json({'errno': 0, 'has_more': 1, 'cursor': 1, 'list': <Object>[]}),
        json({'errno': 0, 'has_more': 1, 'cursor': 2, 'list': <Object>[]}),
      ]);

      expect(client.listAll(maxPages: 2), throwsA(isA<NetdiskFailure>()));
    });
  });

  group('容量', () {
    test('三个数照接口回的原样读', () {
      final quota = parseQuota(json({
        'errno': 0,
        'total': 2205465706496,
        'used': 686653888910,
        'free': 1518811817586,
      }));

      expect(quota.total, 2205465706496);
      expect(quota.used, 686653888910);
      expect(quota.free, 1518811817586);
      expect(quota.usedRatio, closeTo(0.3113, 0.001));
    });

    test('总量为 0 时不做除零', () {
      expect(const NetdiskQuota(total: 0, used: 0, free: 0).usedRatio, 0);
    });

    test('errno 非 0 要抛', () {
      expect(
        () => parseQuota(json({'errno': 31045})),
        throwsA(isA<NetdiskFailure>()),
      );
    });
  });

  group('下载直链', () {
    String meta({int top = 0, int? item, String? dlink = 'https://d.pcs.baidu.com/x?sig=1'}) =>
        json({
          'errno': top,
          'list': [
            {
              'errno': item ?? 0,
              'path': '/apps/VidLog/a.mp4',
              'dlink': ?dlink,
            },
          ],
        });

    test('取到直链', () {
      expect(parseDlink(meta()), 'https://d.pcs.baidu.com/x?sig=1');
    });

    test('⚠️ 顶层 0 但这一条自己带 errno 时_要抛', () {
      // 文档 047 的 `list[].errno`：「批量查询且该文件失败时」。
      // 只看顶层的话会拿到一个**空直链**，然后拿着空串去下载。
      expect(
        () => parseDlink(meta(item: 31190, dlink: null)),
        throwsA(isA<NetdiskFailure>()),
      );
    });

    test('dlink 是空串也要抛', () {
      expect(
        () => parseDlink(meta(dlink: '')),
        throwsA(isA<NetdiskFailure>()),
      );
    });

    test('顶层 errno 非 0 要抛', () {
      expect(
        () => parseDlink(json({'errno': 31045, 'list': <Object>[]})),
        throwsA(isA<NetdiskFailure>()),
      );
    });
  });

  group('网不通与授权不管用了（T10 的「离线」「无权限」两态）', () {
    test('⚠️ 断网时抛的是给人看的那句话_不是 SocketException 原文', () async {
      // 原来 `SocketException: Failed host lookup: 'pan.baidu.com' (OS Error: …)`
      // 是原样端到用户眼前的：英文、带 errno，用户看不出「这不是我的单号错了」。
      final client = BaiduPanClient(
        accessToken: 'token-1',
        appName: 'VidLog',
        fetch: (uri) async => throw const SocketException('Failed host lookup'),
      );

      await expectLater(
        client.quota(),
        throwsA(isA<NetdiskFailure>()
            .having((f) => f.message, 'message', offlineMessage)),
      );
    });

    test('⚠️ 业务失败不许被翻成「没网」', () {
      // 网盘**答了**、只是答的是「不让你干这件事」—— 与「网不通」的下一步完全不同
      // （一个是等网络，一个是换账号 / 换路径）。翻错了，用户会一直去查 Wi-Fi。
      const failure = NetdiskFailure('网盘不让列目录（errno -6）', errno: -6);
      expect(describeNetdiskError(failure), same(failure));
    });

    test('超时也算网不通', () {
      expect(
        describeNetdiskError(TimeoutException('太慢')),
        isA<NetdiskFailure>().having((f) => f.message, 'message', offlineMessage),
      );
    });

    test('isAuthFailure 认电脑端那张表上的四个码', () {
      for (final code in [-6, 20016, 20017, 31045]) {
        expect(
          NetdiskFailure('x', errno: code).isAuthFailure,
          isTrue,
          reason: 'errno=$code 是「授权不管用了」，界面要退回重新登录那一屏',
        );
      }
    });

    test('⚠️ 没网的错不许当成授权失效', () {
      // 判错了会把用户**掉线式地登出**：他只是没网，却看到「重新登录一次」。
      expect(const NetdiskFailure(offlineMessage).isAuthFailure, isFalse);
      expect(const NetdiskFailure('应用还在审核中', errno: 20011).isAuthFailure, isFalse);
    });
  });
}
