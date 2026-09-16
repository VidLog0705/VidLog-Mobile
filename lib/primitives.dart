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
/// 规格 §3.2.3：**归一化后的结果才是单号，一切关联以此为准** ——
/// 所以 [parse] / [tryParse] 都先归一化再构造。
///
/// **已知缺口**：§3.2.3 还要求「处理校验位」，本实现**刻意没做**。
/// 校验位规则按承运商而异，规格没有给出适用算法；凭空实现会改变单号的同一性，
/// 而 I5 说单号是唯一事实标识 —— 改错了等于毁掉证据关联。
/// 补这个之前必须先拿到具体承运商的校验位规则。
///
/// 与电脑端 `VidLog.Desktop.Core/Primitives.cs` 的 `WaybillNumber` **行为一致**，
/// 两边必须同时改。
final class WaybillNumber {
  final String value;

  const WaybillNumber._(this.value);

  /// 规格 §3.2.3 的归一化：去除空白、统一大小写。
  ///
  /// 「统一大小写」规格没规定方向，本实现定为**大写**（母仓
  /// `docs/02-数据模型.md` §5.1 记录该决策）。校验位与分隔符**一律保留原样**。
  ///
  /// 归一化后为空则返回 null。
  static String? normalize(String? raw) {
    if (raw == null || raw.isEmpty) return null;

    final stripped = raw.replaceAll(_whitespace, '').toUpperCase();
    return stripped.isEmpty ? null : stripped;
  }

  static WaybillNumber parse(String? raw) {
    final result = tryParse(raw);
    if (result == null) {
      throw FormatException('不是合法的单号（归一化后没有任何有效字符）', raw);
    }
    return result;
  }

  static WaybillNumber? tryParse(String? raw) {
    final normalized = normalize(raw);
    if (normalized == null) return null;

    return WaybillNumber._(normalized);
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
