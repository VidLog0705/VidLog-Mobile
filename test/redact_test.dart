import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/diagnostics/redact.dart';

/// 脱敏这一层此前**没有专属测试**（2026-10-01 核出来的缺口）——
/// 而它的判据是**跨端对齐**的，走岔了没人会发现：诊断包是各发各的。
void main() {
  group('键名层', () {
    test('中英双语的密钥类键名都要命中', () {
      // ⚠️ 这份表与电脑端 `SensitiveName` **逐字对齐** ——
      // 走岔的表现是「电脑端挡住的，手机端漏了出去」。
      for (final name in const [
        'secret',
        'access_token',
        'refreshToken',
        'password',
        'passwd',
        'appKey',
        'credential',
        'Authorization',
        '凭据',
        '令牌',
        '密码',
        '口令',
        '密钥',
        '授权',
      ]) {
        expect(isSensitiveName(name), isTrue, reason: '$name 应该命中');
      }
    });

    test('普通键名不动', () {
      for (final name in const ['单号', '分段数', '耗时ms', '会话', '状态']) {
        expect(isSensitiveName(name), isFalse, reason: '$name 不该命中');
      }
    });

    test('⚠️ 子串匹配**会误伤**，这是有意接受的', () {
      // `monkey` 里含 `key`。命中的代价只是值被写成「（已修改）」，
      // 漏掉的代价是**凭据外发** —— 两害相权取前者。
      //
      // ⚠️ 这一条钉的是「别把它『修』成精确匹配」：那样挡得住 monkey 的误伤，
      // 却会漏掉 `userKey`、`appKeyId` 这一大批真的该挡的。
      expect(isSensitiveName('monkey'), isTrue);
    });

    test('密钥类的值换成占位文本', () {
      final redactor = Redactor();

      expect(redactor.redactValue('token', 'abc123def456'), redactedPlaceholder);
      expect(redactor.redactValue('单号', 'SF100'), 'SF100');
    });
  });

  group('值层', () {
    test('登记过的值被抹掉', () {
      final redactor = Redactor()..registerSecret('0123456789abcdef');

      expect(
        redactor.redact('连不上，凭据是 0123456789abcdef，请检查'),
        '连不上，凭据是 $maskPlaceholder，请检查',
      );
    });

    test('⚠️ 太短的**不登记**', () {
      // 登记一个 `"1"` 之后，日志里每一个 1 都会变成 `***`，等于把日志毁了。
      final redactor = Redactor()..registerSecret('abc');

      expect(redactor.redact('abc 和 12345'), 'abc 和 12345');
    });

    test('⚠️ 长的先换（短的是长的子串时）', () {
      // 先换短的会把长的换成 `***` 加一截尾巴，**而那截尾巴照样是秘密**。
      final redactor = Redactor()
        ..registerSecret('0123456789abcdef')
        ..registerSecret('0123456789abcdefEXTRA');

      expect(
        redactor.redact('值=0123456789abcdefEXTRA'),
        '值=$maskPlaceholder',
        reason: '不能留下 EXTRA 那截尾巴',
      );
    });

    test('没登记任何东西时原样返回', () {
      expect(Redactor().redact('原文一字不动'), '原文一字不动');
    });

    test('⚠️ 天花板：没登记过的密钥**挡不住**（这是明说的，不是 bug）', () {
      // 值层只挡得住**登记过的**那一个。没登记的新凭据、被变换过的
      //（重新 base64、转大写）、第三方异常里内嵌的 —— 一律挡不住。
      //
      // ⚠️ 钉它是为了**别让人以为这一层是保证**：真正的护栏是
      //「新生成密钥的那段代码顺手登记一次」（见 `device_identity`）。
      final redactor = Redactor()..registerSecret('aaaaaaaa11111111');

      expect(redactor.redact('bbbbbbbb22222222'), 'bbbbbbbb22222222');
    });
  });
}
