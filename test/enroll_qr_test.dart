import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/upload/enroll_qr.dart';

/// 入网二维码的解析（规格 §3.4.5）。
///
/// 这里最要紧的一条是**第一组里那个字面量**：它是把电脑端 `EnrollQr.Payload`
/// 的拼法**抄死在测试里**的。两端各自自洽、合起来不通 —— 这类毛病只有
/// 拿一条写死的内容去对才看得见（`upload_protocol.dart` 的注释里叫
/// 「两边各自自洽，合起来不通」）。
void main() {
  // 电脑端 EnrollQr.Payload 的输出，逐字。
  const fromDesktop =
      'vidlog://connect?host=192.168.1.23&port=8720&token=k7Qm3Zp1Rt8LxVn0aWbQ4g';

  group('电脑端写出来的那串', () {
    test('三段都能解出来', () {
      final payload = EnrollQrPayload.tryParse(fromDesktop);

      expect(payload, isNotNull);
      expect(payload!.host, '192.168.1.23');
      expect(payload.port, 8720);
      expect(payload.token, 'k7Qm3Zp1Rt8LxVn0aWbQ4g');
    });

    test('address 是电脑端屏幕上同时印着的那个地址', () {
      // 连不上时用户要照着它手填，所以它必须与二维码里的一致。
      expect(EnrollQrPayload.tryParse(fromDesktop)!.address, '192.168.1.23:8720');
    });

    test('两边空白不影响', () {
      expect(EnrollQrPayload.tryParse('  $fromDesktop\n'), isNotNull);
    });
  });

  group('不是 VidLog 的码 → null', () {
    test('一维码里的单号', () {
      // 扫码界面会看到环境里别的码。单号里当然没有 scheme。
      expect(EnrollQrPayload.tryParse('SF1000000001'), isNull);
    });

    test('别的产品的二维码（一段 URL）', () {
      expect(EnrollQrPayload.tryParse('https://example.com/connect?token=x'), isNull);
    });

    test('scheme 对但 authority 不是 connect', () {
      expect(EnrollQrPayload.tryParse('vidlog://pair?host=1.2.3.4&port=8720&token=x'), isNull);
      expect(EnrollQrPayload.tryParse('vidlog://connect/x?host=1.2.3.4&port=8720&token=x'), isNull);
    });

    test('大小写不敏感', () {
      // Uri 会把 scheme 与 host 都小写化 —— 电脑端哪天改了大小写也不该断。
      expect(
        EnrollQrPayload.tryParse('VidLog://Connect?host=1.2.3.4&port=8720&token=x'),
        isNotNull,
      );
    });

    test('空串', () {
      expect(EnrollQrPayload.tryParse(''), isNull);
      expect(EnrollQrPayload.tryParse('   '), isNull);
    });
  });

  group('缺一段就整个作废', () {
    test('没有 token', () {
      expect(EnrollQrPayload.tryParse('vidlog://connect?host=1.2.3.4&port=8720'), isNull);
      expect(EnrollQrPayload.tryParse('vidlog://connect?host=1.2.3.4&port=8720&token='), isNull);
      expect(EnrollQrPayload.tryParse('vidlog://connect?host=1.2.3.4&port=8720&token=   '), isNull);
    });

    test('没有 host', () {
      expect(EnrollQrPayload.tryParse('vidlog://connect?port=8720&token=x'), isNull);
    });

    test('端口不是数字、或者是 0、或者越界', () {
      // 端口变成 0 的表现是请求发去 http://1.2.3.4:0/ —— 没有一处会报错。
      expect(EnrollQrPayload.tryParse('vidlog://connect?host=1.2.3.4&port=&token=x'), isNull);
      expect(EnrollQrPayload.tryParse('vidlog://connect?host=1.2.3.4&port=abc&token=x'), isNull);
      expect(EnrollQrPayload.tryParse('vidlog://connect?host=1.2.3.4&port=0&token=x'), isNull);
      expect(EnrollQrPayload.tryParse('vidlog://connect?host=1.2.3.4&port=65536&token=x'), isNull);
      expect(EnrollQrPayload.tryParse('vidlog://connect?host=1.2.3.4&port=-1&token=x'), isNull);
    });

    test('地址里有空格或斜杠', () {
      // 这种地址拼进 http://$host:$port/... 会拼出一个**看着能发、发错地方**的 URL。
      expect(EnrollQrPayload.tryParse('vidlog://connect?host=1.2.3.4%20x&port=8720&token=x'), isNull);
      expect(EnrollQrPayload.tryParse('vidlog://connect?host=a/b&port=8720&token=x'), isNull);
    });
  });

  group('宽容但不含糊', () {
    test('多带的参数不影响', () {
      final payload = EnrollQrPayload.tryParse(
        'vidlog://connect?host=1.2.3.4&port=8720&token=x&v=2',
      );

      expect(payload?.host, '1.2.3.4');
      expect(payload?.token, 'x');
    });

    test('主机名（不是 IPv4）也收', () {
      // 电脑端现在写的是 IPv4，但把它写死成「必须 IPv4」的话，
      // 电脑端哪天改成主机名，手机端会一声不响地拒掉每一张码。
      expect(EnrollQrPayload.tryParse('vidlog://connect?host=vidlog-pc.lan&port=8720&token=x')?.host,
          'vidlog-pc.lan');
    });

    test('端口前后有空白也收', () {
      expect(EnrollQrPayload.tryParse('vidlog://connect?host=1.2.3.4&port=%208720&token=x')?.port,
          8720);
    });
  });
}
