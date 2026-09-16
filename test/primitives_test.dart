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
    const whitespaceCases = <List<String>>[
      ['SF 1234567890', 'SF1234567890'],
      ['SF\t1234567890', 'SF1234567890'],
      ['SF1234567890\n', 'SF1234567890'],
      ['  SF1234567890  ', 'SF1234567890'],
    ];

    for (final pair in whitespaceCases) {
      test('归一化去除空白: ${pair[0].trim()}', () {
        expect(WaybillNumber.normalize(pair[0]), pair[1]);
      });
    }

    const caseCases = <List<String>>[
      ['sf1234567890', 'SF1234567890'],
      ['Sf1234567890', 'SF1234567890'],
    ];

    for (final pair in caseCases) {
      test('归一化统一为大写: ${pair[0]}', () {
        expect(WaybillNumber.normalize(pair[0]), pair[1]);
      });
    }

    test('归一化后为空则视为非法', () {
      for (final raw in <String?>[null, '', '   ', '\t\r\n']) {
        expect(WaybillNumber.normalize(raw), isNull);
        expect(WaybillNumber.tryParse(raw), isNull);
        expect(() => WaybillNumber.parse(raw), throwsFormatException);
      }
    });

    test('Parse 先归一化再构造', () {
      expect(WaybillNumber.parse(' sf 1234567890\n').value, 'SF1234567890');
    });

    test('不同写法必须归一到同一单号', () {
      // 扫码枪带换行、人工输入带空格或小写 —— 归一化后必须是同一个单号，
      // 否则同一件包裹会被记成两条证据（违反 I5）。
      expect(WaybillNumber.parse('SF1234567890\r\n'), WaybillNumber.parse(' sf 1234567890 '));
    });

    test('不同单号不相等', () {
      expect(
        WaybillNumber.parse('SF1234567890'),
        isNot(WaybillNumber.parse('SF1234567891')),
      );
    });

    test('校验位与分隔符保留原样，这是刻意的', () {
      // §3.2.3 要求「处理校验位」，但规格没给适用算法。
      // 凭空剥离会改变单号的同一性（I5），所以这里断言的是「不动它」。
      // 等拿到具体承运商的校验位规则再改这条测试。
      for (final raw in <String>['SF-1234567890', 'SF1234567890-1']) {
        expect(WaybillNumber.normalize(raw), raw);
      }
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
