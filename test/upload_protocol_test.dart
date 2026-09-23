import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/upload/upload_protocol.dart';

/// 上传接口的**两端必须逐字一致的那一半**（母仓 `docs/05-上传接口形状.md`）。
///
/// 这一份测试的重心不是「函数算得对不对」，而是**格式对不对**：
/// 时间写几位小数、base64url 补不补 `=`、规范串几行、末尾有没有换行。
/// 这些差异**不会在两端各自的测试里暴露**（两边各自自洽），
/// 只会在现场表现成「回执验签失败」—— 而那看起来像被篡改了。
void main() {
  group('签名向量', () {
    /// ⚠️ 与电脑端 `UploadReceiverTests.签名向量_与手机端逐字一致` **同一组字面量**。
    ///
    /// 它们是手抄过去的，不是算出来的：算出来的只能证明「本端自洽」。
    /// 谁改了规范串的行数、字段顺序、时间格式或 base64url 的填充，
    /// 这一条**或**电脑端那一条会红。两边都绿才说明真的对得上。
    const credential = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';

    final receipt = Receipt(
      evidenceId: 'sess-1-000',
      contentHash: 'a' * 64,
      publishedAt: DateTime.utc(2026, 9, 23, 2, 31, 52, 117),
      timeAnchor: DateTime.utc(2026, 9, 23, 2, 31, 52, 117),
      receiverDeviceId: 'host-1',
      receiverDeviceName: 'packing-left',
      location: '2026/09/23/SF1000000001/sess-1_000.mp4',
    );

    test('规范串是七行且逐字与电脑端一致', () {
      expect(
        canonicalReceipt(receipt),
        'vidlog-receipt/v1\n'
        'sess-1-000\n'
        '${'a' * 64}\n'
        '2026-09-23T02:31:52.1170000+00:00\n'
        '2026-09-23T02:31:52.1170000+00:00\n'
        'host-1\n'
        'packing-left\n'
        '2026/09/23/SF1000000001/sess-1_000.mp4',
      );
    });

    test('签名逐字等于电脑端算出来的那一个', () {
      expect(receiptMac(credential, receipt),
          'omRj4j8WZTr74vJd-cXozVmrjecFPnQibPmpDpyAUC8');
    });

    test('验签认得出自己签的那一份', () {
      expect(
        verifyReceipt(credential, receipt,
            'omRj4j8WZTr74vJd-cXozVmrjecFPnQibPmpDpyAUC8'),
        isTrue,
      );
    });

    test('换一把凭据就验不过', () {
      // 局域网里另一台已入网的设备拿自己的凭据签一份同样的回执 —— 必须验不过。
      final other = base64UrlNoPad(List<int>.generate(32, (i) => 0xFF - i));

      expect(
        verifyReceipt(other, receipt,
            'omRj4j8WZTr74vJd-cXozVmrjecFPnQibPmpDpyAUC8'),
        isFalse,
      );
    });

    test('改了回执里任何一个字段都验不过', () {
      final signed = receiptMac(credential, receipt);

      expect(verifyReceipt(credential, Receipt(
        evidenceId: receipt.evidenceId,
        contentHash: receipt.contentHash,
        publishedAt: receipt.publishedAt,
        timeAnchor: receipt.timeAnchor,
        receiverDeviceId: receipt.receiverDeviceId,
        receiverDeviceName: receipt.receiverDeviceName,
        location: '别处.mp4',
      ), signed), isFalse);
    });
  });

  group('时间形态', () {
    test('是七位小数加 +00:00_不是三位小数加 Z', () {
      // ⚠️ Dart 的 toIso8601String() 给的是 `…52.117Z`，
      // 而电脑端给的是 `…52.1170000+00:00`。直接用它拼规范串就验不过签。
      final value = DateTime.utc(2026, 9, 23, 2, 31, 52, 117);

      expect(value.toIso8601String(), '2026-09-23T02:31:52.117Z');
      expect(formatUtcIso7(value), '2026-09-23T02:31:52.1170000+00:00');
    });

    test('微秒补在第 4 到第 6 位', () {
      expect(
        formatUtcIso7(DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 7)),
        '2026-01-02T03:04:05.0060070+00:00',
      );
    });

    test('本地时间先转 UTC 再写', () {
      // 带时区的时刻必须归到 UTC。不转的话同一条回执换台机器就换个写法，
      // 而签名是**逐字节**比对的。
      final local = DateTime.utc(2026, 9, 23, 2, 0).toLocal();

      expect(formatUtcIso7(local), '2026-09-23T02:00:00.0000000+00:00');
    });
  });

  group('分片算术', () {
    test('总分片数向上取整_空文件也算一片', () {
      expect(chunkCountFor(0, 100), 1);
      expect(chunkCountFor(1, 100), 1);
      expect(chunkCountFor(100, 100), 1);
      expect(chunkCountFor(101, 100), 2);
    });

    test('区间与电脑端的 ExpectedChunkLength 是同一套算法', () {
      // 电脑端：offset = index * chunkSize，长度 = min(chunkSize, total - offset)。
      // 两边算得不一样的表现是「接收方永远报这一片没有」—— 每次续传都从头开始，
      // 不报错，只是慢。
      expect(chunkRange(250, 0, 100), (0, 100));
      expect(chunkRange(250, 1, 100), (100, 200));
      expect(chunkRange(250, 2, 100), (200, 250));
    });

    test('越界的下标给出空区间而不是负长度', () {
      expect(chunkRange(250, 3, 100), (300, 300));
    });
  });

  group('base64url', () {
    test('不补等号填充', () {
      // ⚠️ .NET 的 Base64Url.DecodeFromChars **拒收**带 `=` 的输入。
      // 补了填充的话，凭据与签名在电脑端都会被判成非法。
      expect(base64UrlNoPad([0]), 'AA');
      expect(base64UrlNoPad([0, 0]), 'AAA');
      expect(base64UrlNoPad(List<int>.filled(32, 0)), 'A' * 43);
      expect(base64UrlNoPad([251, 255, 191]), '-_-_');
    });

    test('不带填充的输入也能解回来', () {
      // ⚠️ 裸的 `base64Url.decode` 会在这里报
      // `Invalid length, must be multiple of four` —— 而电脑端给的凭据
      // 与签名**恰恰不带填充**。这一条钉的就是那个坑。
      expect(base64UrlDecode('A' * 43).length, 32);
      expect(() => base64Url.decode('A' * 43), throwsFormatException);
    });

    test('带不带填充解出来是同一串字节', () {
      expect(base64UrlDecode('A' * 43), base64UrlDecode('${'A' * 43}='));
    });
  });

  group('定长比较', () {
    test('同长不同内容为假', () {
      expect(constantTimeEquals('abcd', 'abce'), isFalse);
    });

    test('长度不同为假_而不是抛', () {
      expect(constantTimeEquals('abcd', 'abc'), isFalse);
      expect(constantTimeEquals('', 'a'), isFalse);
    });

    test('全等为真', () {
      expect(constantTimeEquals('abcd', 'abcd'), isTrue);
    });
  });

  group('失败分类', () {
    test('连不上与 5xx 可重试', () {
      expect(const UploadFailure(UploadErrorCodes.network).isRetryable, isTrue);
      expect(const UploadFailure(UploadErrorCodes.server).isRetryable, isTrue);
    });

    test('内容类的失败一律不可重试', () {
      // ⚠️ 重试一条**内容对不上**的录像，重试多少次结果都一样 ——
      // 那只是拖 31 秒之后给出同一个答案，而用户以为它在努力。
      for (final code in const [
        UploadErrorCodes.hashMismatch,
        UploadErrorCodes.chunkMissing,
        UploadErrorCodes.evidenceMismatch,
        UploadErrorCodes.alreadyPublished,
        UploadErrorCodes.unplayable,
        UploadErrorCodes.badRequest,
        UploadErrorCodes.badSignature,
      ]) {
        expect(UploadFailure(code).isRetryable, isFalse, reason: code);
      }
    });

    test('401 与 404 说得出下一步该干什么', () {
      // 文档 §3 最后那段：这两种终态不能只说「再试试」。
      expect(const UploadFailure(UploadErrorCodes.badCredential).kind,
          UploadErrorKind.needsEnrollment);
      expect(const UploadFailure(UploadErrorCodes.notFound).kind,
          UploadErrorKind.hostTooOld);

      expect(const UploadFailure(UploadErrorCodes.badCredential).userHint,
          contains('重新配对'));
      expect(const UploadFailure(UploadErrorCodes.notFound).userHint,
          contains('升级电脑端'));
    });

    test('解不开的那条必须明说别删手机上的原文件', () {
      expect(const UploadFailure(UploadErrorCodes.unplayable).userHint,
          contains('别删'));
    });
  });

  group('回执', () {
    test('JSON 往返后签名不变', () {
      // 回执落盘再读回来（archive.jsonl）之后，`timeAnchor` 不能因为
      // 序列化往返而丢掉精度 —— 丢掉的话保留期就从错的地方起算。
      final receipt = Receipt(
        evidenceId: 'e-000',
        contentHash: 'b' * 64,
        publishedAt: DateTime.utc(2026, 9, 23, 2, 31, 52, 117),
        timeAnchor: DateTime.utc(2026, 9, 23, 2, 31, 52, 117),
        receiverDeviceId: 'host-1',
        receiverDeviceName: '打包间-左',
        location: '2026/09/23/SF1/e_000.mp4',
      );

      final round = Receipt.fromJson(
          jsonDecode(jsonEncode(receipt.toJson())) as Map<String, Object?>);

      expect(canonicalReceipt(round), canonicalReceipt(receipt));
      expect(round.receiverDeviceName, '打包间-左');
    });
  });
}
