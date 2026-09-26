import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/diagnostics/app_log.dart';
import 'package:vidlog_mobile/recording/recorder_gateway.dart';
import 'package:vidlog_mobile/upload/upload_protocol.dart';
import 'package:vidlog_mobile/upload/uploader.dart';

/// 收口点的留痕（2026-09-26）。
///
/// 这一端能长成「一处挂上就全覆盖」，是因为几个咽喉本来就只有一个入口：
/// 原生→Dart 只有 `parseNativeEvent`，出站只有 `UploadClient._send`，
/// 一趟队列只有 `Uploader.runOnce`。
void main() {
  setUp(() async => AppLog.instance.resetForTesting());
  tearDown(() async => AppLog.instance.resetForTesting());

  List<String> entries() => AppLog.instance.tail.value;

  group('原生事件的咽喉', () {
    test('★ 认不出的类型要发声_而不是静默丢弃', () {
      // ⚠️ 这里以前是一句 `return null`：认不出的消息**丢得一声不响**。
      // 那条规矩本身对（老版本 Dart 不该因为原生加了新事件就崩），
      // 但一声不响就把它变成了一个洞 —— 原生发了什么、这边为什么没反应，
      // 日志里一个字都没有。
      final parsed = parseNativeEvent({'type': '原生新加的事件', 'payload': '什么'});

      expect(parsed, isNull);
      expect(entries().single, contains('原生新加的事件'));
    });

    test('★ 载荷本身不落盘_只记类型名', () {
      // 原生事件里可能带着单号，而这条日志会进诊断包。
      parseNativeEvent({'type': '认不出的', 'waybill': 'SF1000000001'});

      expect(entries().single, isNot(contains('SF1000000001')));
    });

    test('★ 认得出的类型一条都不记_否则逐帧会把日志淹掉', () {
      // 相机是**连续识码**的：barcodeDetected 与 sceneSampled 每秒好几条。
      parseNativeEvent({
        'type': 'barcodeDetected',
        'text': 'SF1000000001',
        'centerX': 0.5,
        'centerY': 0.5,
      });
      parseNativeEvent({'type': 'sceneSampled', 'isStatic': false});
      parseNativeEvent({
        'type': 'segmentClosed',
        'filePath': '/tmp/a.mkv',
        'sequence': 0,
        'startedAtMs': 0,
        'endedAtMs': 1000,
      });

      expect(entries(), isEmpty);
    });

    test('字段缺了也要发声_否则那是另一种静默', () {
      // 形状不对（原生改坏了）与「认不出类型」是两回事，但都不该不吭声。
      expect(parseNativeEvent({'type': 'segmentClosed'}), isNull);
      expect(entries().single, contains('segmentClosed'));
    });
  });

  group('出站 HTTP', () {
    test('连不上时记一行_而且不带凭据', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      final client = UploadClient(
        address: '127.0.0.1',
        port: deadPort,
        credential: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
      );

      await expectLater(
        client.health(),
        throwsA(isA<UploadFailure>()),
      );

      final line = entries().single;
      expect(line, contains('连不上'));
      // ⚠️ 凭据在 Authorization 头上，绝不进日志 —— 诊断包是整份发回去的。
      expect(line, isNot(contains('AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8')));
    });
  });
}
