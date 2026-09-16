import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';

void main() {
  group('RelativePath —— 规格 §6.2 硬约束：路径只存相对路径', () {
    const absoluteAndUnc = <String>[
      r'C:\recordings\a.mp4',
      'D:/recordings/a.mp4',
      '/var/lib/vidlog/a.mp4',
      r'\recordings\a.mp4',
      r'\\nas\share\a.mp4',
      '//nas/share/a.mp4',
    ];

    for (final raw in absoluteAndUnc) {
      test('拒绝绝对路径或 UNC 路径: $raw', () {
        expect(RelativePath.tryParse(raw), isNull);
        expect(() => RelativePath.parse(raw), throwsFormatException);
      });
    }

    const traversal = <String>[
      '../outside.mp4',
      r'..\outside.mp4',
      'sessions/../../outside.mp4',
      r'sessions\..\..\outside.mp4',
    ];

    for (final raw in traversal) {
      test('拒绝向上越级路径: $raw', () {
        expect(RelativePath.tryParse(raw), isNull);
      });
    }

    test('拒绝空路径', () {
      expect(RelativePath.tryParse(null), isNull);
      expect(RelativePath.tryParse(''), isNull);
      expect(RelativePath.tryParse('   '), isNull);
    });

    const valid = <String>[
      '2026/09/16/SF1234567890.mp4',
      r'sessions\abc\segment-000.mkv',
      'a.mp4',
    ];

    for (final raw in valid) {
      test('接受合法的相对路径: $raw', () {
        expect(RelativePath.parse(raw).value, raw);
      });
    }

    test('同值相等，可直接用于去重', () {
      expect(RelativePath.parse('a/b.mp4'), RelativePath.parse('a/b.mp4'));
      expect(
        RelativePath.parse('a/b.mp4'),
        isNot(RelativePath.parse('a/c.mp4')),
      );
    });
  });

  group('WaybillNumber —— 不变量 I5：单号是唯一事实标识', () {
    const withWhitespace = <String>[
      'SF 1234567890',
      'SF\t1234567890',
      'SF1234567890\n',
    ];

    for (final raw in withWhitespace) {
      test('拒绝含空白字符的未归一化单号: ${raw.trim()}', () {
        // 归一化（§3.2.3）负责去除空白；到达本类型时应当已经去过。
        expect(WaybillNumber.tryParse(raw), isNull);
        expect(() => WaybillNumber.parse(raw), throwsFormatException);
      });
    }

    test('拒绝空单号', () {
      expect(WaybillNumber.tryParse(null), isNull);
      expect(WaybillNumber.tryParse(''), isNull);
    });

    test('接受归一化后的单号', () {
      expect(WaybillNumber.parse('SF1234567890').value, 'SF1234567890');
    });

    test('同值相等，可作为标识使用', () {
      expect(WaybillNumber.parse('SF1234567890'), WaybillNumber.parse('SF1234567890'));
      expect(
        WaybillNumber.parse('SF1234567890'),
        isNot(WaybillNumber.parse('SF1234567891')),
      );
    });
  });

  group('ContentHash —— 规格 §3.6.1：指纹的组成部分', () {
    const valid =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    test('拒绝长度不对的哈希', () {
      expect(ContentHash.tryParse(valid.substring(0, 63)), isNull);
    });

    test('拒绝非十六进制字符', () {
      expect(ContentHash.tryParse('z${valid.substring(1)}'), isNull);
    });

    test('拒绝空哈希', () {
      expect(ContentHash.tryParse(null), isNull);
      expect(ContentHash.tryParse(''), isNull);
    });

    test('统一为小写，免得同一份内容被判成两条证据', () {
      expect(ContentHash.parse(valid.toUpperCase()), ContentHash.parse(valid));
      expect(ContentHash.parse(valid.toUpperCase()).value, valid);
    });
  });
}
