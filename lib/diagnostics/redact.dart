/// 写盘前的脱敏 —— 与电脑端同一套判据。
///
/// 为什么必须在**写入**这一层：诊断包会把日志整个打包发回，而
/// `device.json` 里就躺着设备凭据。写进去再过滤就是两个过滤器，漏一个就外发。
library;

/// 命中密钥类的键名时写这个（`AGENTS.md` §6 的原话）。
const redactedPlaceholder = '（已修改）';

/// 抹掉值之后写这个。
const maskPlaceholder = '***';

/// 这个字段名是不是密钥类。
///
/// 判据与电脑端 `SensitiveName` 逐字对齐（中英双语、子串匹配）——
/// **两端走岔的表现是「电脑端挡住的，手机端漏了出去」**，
/// 而诊断包是各发各的，走岔了没人会发现。
///
/// ⚠️ 它是子串匹配，所以会误伤（`monkey` 里含 `key`）。这是**有意接受**的：
/// 命中的代价只是值被写成「（已修改）」，漏掉的代价是凭据外发。
bool isSensitiveName(String name) {
  const patterns = [
    'secret',
    'token',
    'password',
    'passwd',
    'key',
    'credential',
    'authorization',
    '凭据',
    '令牌',
    '密码',
    '口令',
    '密钥',
    '授权',
  ];

  final lower = name.toLowerCase();
  return patterns.any(lower.contains);
}

/// 值层的脱敏。
///
/// 三层里最软的一层：只挡得住**登记过的**密钥值。
/// 没登记过的新凭据、被变换过的（重新 base64、转大写）、以及第三方异常消息里
/// 内嵌的密钥 —— **一律挡不住**。正则解决不了「有人把不该记的东西记了」，
/// 这里做的是把爆炸半径压小，不是消灭它。
class Redactor {
  /// 登记一个「永远不该出现在日志里」的值。
  ///
  /// ⚠️ 太短的**不登记**：登记一个 `"1"` 之后，日志里每一个 1 都会变成 `***`，
  /// 等于把日志毁了。真实凭据是 32 字节 base64url、令牌 16 字节，都远长于此。
  void registerSecret(String? value) {
    if (value == null || value.trim().length < 8) return;
    _secrets.add(value);
  }

  /// 清空登记（只给测试用 —— 它会跨用例累积）。
  void resetForTesting() => _secrets.clear();

  final Set<String> _secrets = {};

  /// 把一串文本里登记过的密钥抹掉。
  ///
  /// 长的先换：短的是长的子串时，先换短的会把长的换成 `***` 加一截尾巴，
  /// 而那截尾巴照样是秘密。
  String redact(String text) {
    if (text.isEmpty || _secrets.isEmpty) return text;

    var result = text;
    for (final secret in _secrets.toList()..sort((a, b) => b.length.compareTo(a.length))) {
      result = result.replaceAll(secret, maskPlaceholder);
    }

    return result;
  }

  /// 一个 `data` 项要不要连值一起换掉；要就返回占位文本，否则 null。
  String? redactionFor(String key) => isSensitiveName(key) ? redactedPlaceholder : null;

  /// 把一个值按上面两条规矩过一遍。
  Object? redactValue(String key, Object? value) {
    if (redactionFor(key) case final placeholder?) return placeholder;
    if (value is String) return redact(value);
    return value;
  }
}
