/// VidLog 手机端 —— 跨端共享的硬约束值对象。
///
/// 与电脑端 `VidLog.Desktop.Core/Primitives.cs` 一一对应。
/// 契约以母仓 `VidLog0705/VidLog` 的 `docs/02-数据模型.md` 为准。
library;

final _separators = RegExp(r'[/\\]');
final _drivePrefix = RegExp(r'^[A-Za-z]:');
final _whitespace = RegExp(r'\s');
final _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

/// 录像文件在落点层 / 归档层中的位置。
///
/// 规格 §6.2 硬约束：路径只存相对路径。绝对路径在应用重装、容器变更后
/// 必然失效，因此本类型在构造时就拒绝一切绝对路径、UNC 路径与向上越级路径。
final class RelativePath {
  final String value;

  const RelativePath._(this.value);

  static RelativePath parse(String? raw) {
    final result = tryParse(raw);
    if (result == null) {
      throw FormatException('不是合法的相对路径', raw);
    }
    return result;
  }

  static RelativePath? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;

    // 刻意不用 Uri / package:path 的 isAbsolute：它们的判定结果随平台变化，
    // 而这里必须让手机端与电脑端、CI 上的判定完全一致。
    if (raw[0] == '/' || raw[0] == r'\') return null;
    if (_drivePrefix.hasMatch(raw)) return null;

    for (final segment in raw.split(_separators)) {
      if (segment == '..') return null;
    }

    return RelativePath._(raw);
  }

  @override
  bool operator ==(Object other) => other is RelativePath && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// 快递运单编号，归一化后的形态。
///
/// 规格 §1 与不变量 I5：单号是系统唯一的事实标识，其他属性（公司、分类、备注）
/// 都只是可修正标签。这里用独立类型而不是裸 [String]，是为了让
/// 「这个位置传进来的确实是单号」在类型层面就成立。
///
/// 归一化算法本身（规格 §3.2.3，含校验位处理）留到 M4 落定；本类型只守住
/// 「已归一化形态非空、不含空白字符」这条与生俱来的性质。
final class WaybillNumber {
  final String value;

  const WaybillNumber._(this.value);

  static WaybillNumber parse(String? raw) {
    final result = tryParse(raw);
    if (result == null) {
      throw FormatException('不是合法的单号', raw);
    }
    return result;
  }

  static WaybillNumber? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;

    // 归一化（§3.2.3）负责去除空白；到达本类型时应当已经去过。
    if (_whitespace.hasMatch(raw)) return null;

    return WaybillNumber._(raw);
  }

  @override
  bool operator ==(Object other) => other is WaybillNumber && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// 录像成品的内容哈希。
///
/// 规格 §3.6.1：指纹 = 内容哈希 + 单号 + 录制时间。
/// 算法定为 SHA-256（64 位十六进制）；比较时统一为小写，
/// 免得同一份内容因为大小写不同被当成两条证据。
final class ContentHash {
  static const algorithm = 'sha256';
  static const hexLength = 64;

  /// 小写十六进制形态。
  final String value;

  const ContentHash._(this.value);

  static ContentHash parse(String? raw) {
    final result = tryParse(raw);
    if (result == null) {
      throw FormatException('不是合法的 SHA-256 内容哈希', raw);
    }
    return result;
  }

  static ContentHash? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw.length != hexLength) return null;
    if (!_hex64.hasMatch(raw)) return null;

    return ContentHash._(raw.toLowerCase());
  }

  @override
  bool operator ==(Object other) => other is ContentHash && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
