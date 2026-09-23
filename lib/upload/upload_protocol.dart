/// 上传接口的形状 —— **两端必须逐字一致的那一半**。
///
/// 契约以母仓 `docs/05-上传接口形状.md` 为准，这里是它在 Dart 侧的落点。
/// 电脑端的对应物是 `VidLog.Desktop.Core/Upload/UploadContracts.cs`
/// 与 `UploadReceiver.cs` 里的 `ReceiptSignature`。
///
/// ## ⚠️ 这个文件里每改一个字都要同时改电脑端
///
/// 它是本项目**唯一一处**「一端改了另一端不知道就会静默坏掉」的地方：
/// 坏起来的样子是「传不上去」或「回执验签失败」，而**两端各自的单元测试都会是绿的**
/// （两边各自自洽）。文档 §2.7 把这一点写成了「为什么不是签 JSON」
/// —— 格式差异不会在各自的测试里暴露，只会在现场表现成「像被篡改了」。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 分片大小。
///
/// ⚠️ **权威在接收方**（文档 §0）。这里这个值是发送方**第一次探问时**用的，
/// 接收方回报的 `chunkSize` 与它不一致就按接收方的重切重探（见 `uploader.dart`）。
/// 写死两边「反正都一样」正是要防的那件事：两端各自漂移之后不会报错，
/// 只会变成「每次续传都要重传」。
const uploadChunkSize = 4 * 1024 * 1024;

/// 按固定分片大小算总分片数。空文件也算 1 片（接收方不接受 0 片）。
int chunkCountFor(int totalBytes, int chunkSize) {
  if (totalBytes <= 0) return 1;
  return (totalBytes + chunkSize - 1) ~/ chunkSize;
}

/// 第 [index] 片的字节区间 `[start, end)`。
///
/// ⚠️ 与电脑端 `UploadReceiver.ExpectedChunkLength` **必须是同一套算法**：
/// 那边是 `offset = index * ChunkSize`，长度取 `min(ChunkSize, total - offset)`。
/// 接收方靠这个算出「每一片该多大」，才能把「传了一半就断了的片」判成**没有**。
/// 两边算得不一样的表现是：分片永远报「没有」，续传永远从头开始。
(int, int) chunkRange(int totalBytes, int index, int chunkSize) {
  final start = index * chunkSize;
  if (start >= totalBytes) return (start, start);
  return (start, start + (totalBytes - start < chunkSize ? totalBytes - start : chunkSize));
}

/// 一次发布的回执 —— **手机端就是靠它才敢说「备份好了」**（不变量 I1）。
///
/// 字段与电脑端 `ReceiptPayload` 逐字对应。
class Receipt {
  const Receipt({
    required this.evidenceId,
    required this.contentHash,
    required this.publishedAt,
    required this.timeAnchor,
    required this.receiverDeviceId,
    required this.receiverDeviceName,
    required this.location,
  });

  final String evidenceId;

  /// 64 位小写十六进制，**不带 `sha256:` 前缀**（全链路只有这一种形态）。
  final String contentHash;

  final DateTime publishedAt;

  /// 接收方时间，构成外部时间锚（规格 §3.6.4）。
  ///
  /// 手机端保留期的**起算点就是它** —— 不是本地录完的时刻，更不是本机的钟：
  /// 一台离线 35 天的机器按本地时间算，会在刚归档那一瞬就被判成过期。
  final DateTime timeAnchor;

  final String receiverDeviceId;
  final String receiverDeviceName;

  /// 归档层内的相对路径。规格 §3.7.1：分享链接指向归档层，所以现在就得留着。
  final String location;

  static Receipt fromJson(Map<String, Object?> json) => Receipt(
        evidenceId: json['evidenceId']! as String,
        contentHash: json['contentHash']! as String,
        publishedAt: DateTime.parse(json['publishedAt']! as String).toUtc(),
        timeAnchor: DateTime.parse(json['timeAnchor']! as String).toUtc(),
        receiverDeviceId: (json['receiverDeviceId'] as String?) ?? '',
        receiverDeviceName: (json['receiverDeviceName'] as String?) ?? '',
        location: (json['location'] as String?) ?? '',
      );

  Map<String, Object?> toJson() => {
        'evidenceId': evidenceId,
        'contentHash': contentHash,
        'publishedAt': formatUtcIso7(publishedAt),
        'timeAnchor': formatUtcIso7(timeAnchor),
        'receiverDeviceId': receiverDeviceId,
        'receiverDeviceName': receiverDeviceName,
        'location': location,
      };
}

/// 规范串（文档 §2.7）—— 七行、`\n` 连接、**末尾不加换行**。
String canonicalReceipt(Receipt receipt) => [
      receiptSignatureScheme,
      receipt.evidenceId,
      receipt.contentHash,
      formatUtcIso7(receipt.publishedAt),
      formatUtcIso7(receipt.timeAnchor),
      receipt.receiverDeviceId,
      receipt.receiverDeviceName,
      receipt.location,
    ].join('\n');

/// 规范串的第一行。将来换签名方案（M6 的公钥签名）时靠它区分。
const receiptSignatureScheme = 'vidlog-receipt/v1';

/// 算回执的 MAC。
///
/// HMAC-SHA256，**密钥 = 凭据的原始字节**（不是它的字符串）。
/// ⚠️ 这是 MAC 不是公钥签名：够用来确认「这条回执确实是那台电脑端发的」
/// （验证方就是持有同一份凭据的这台设备），但**没有不可否认性**。
/// 什么时候必须换成公钥签名，见文档 §5 —— 是 M6 的分享链接。
String receiptMac(String credential, Receipt receipt) {
  final key = base64UrlDecode(credential);
  final mac = Hmac(sha256, key).convert(utf8.encode(canonicalReceipt(receipt)));
  return base64UrlNoPad(mac.bytes);
}

/// 验签。[credential] 是本机入网时拿到的那把凭据。
///
/// ⚠️ **必须在标记「已归档」之前调。** 收到一个没验过的回执就当作备份成功，
/// 等于把「电脑端说它收到了」这件事交给网络上的任何一个人去说。
///
/// 比较用[constantTimeEquals]而不是 `==`：字符串的 `==` 在第一个不同的字节上
/// 就返回，攻击者能靠计时一个字节一个字节地试出正确的 MAC。
/// 局域网内的中间人正好有条件做这件事。
bool verifyReceipt(String credential, Receipt receipt, String signature) {
  final expected = receiptMac(credential, receipt);
  return constantTimeEquals(expected, signature);
}

/// 定长比较：**不看内容的差异位置，只看是否全等**。
///
/// 长度不同直接返回 false —— 长度本身不是秘密（MAC 恒为 43 个字符）。
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;

  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }

  return difference == 0;
}

/// UTC，`yyyy-MM-ddTHH:mm:ss.fffffff+00:00`（**7 位小数**）。
///
/// ## ⚠️ 为什么不能直接用 `toIso8601String()`
///
/// Dart 给的是 `2026-09-23T02:31:52.117Z` —— **3 位小数 + `Z`**，
/// 而电脑端 .NET 的 `"yyyy-MM-dd'T'HH:mm:ss.fffffffK"` 给的是 7 位小数 + `+00:00`。
/// 拼规范串时两者对不上，验签就会失败 —— 而那看起来像**回执被篡改了**。
/// 对取证产品来说，把格式差异误报成篡改是最坏的一种假警报。
///
/// Dart 的 `DateTime` 只有微秒精度（6 位），第 7 位恒补 `0`。
String formatUtcIso7(DateTime value) {
  final utc = value.toUtc();
  final date = '${_pad(utc.year, 4)}-${_pad(utc.month, 2)}-${_pad(utc.day, 2)}';
  final time = '${_pad(utc.hour, 2)}:${_pad(utc.minute, 2)}:${_pad(utc.second, 2)}';
  final fraction = '${_pad(utc.millisecond, 3)}${_pad(utc.microsecond, 3)}0';

  return '${date}T$time.$fraction+00:00';
}

String _pad(int value, int width) => value.toString().padLeft(width, '0');

/// base64url，**不带 `=` 填充**。
///
/// ⚠️ `base64Url.encode` 默认会补 `=`，而电脑端 .NET 的 `Base64Url.EncodeToString`
/// 不补、`DecodeFromChars` 也**拒收**带 `=` 的输入。所以两处（凭据与签名）
/// 都必须经过这个函数，不能直接用 `base64Url.encode`。
String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// 解 base64url，**自动补回 `=` 填充**。
///
/// ## ⚠️ 这一处是真的踩到过（2026-09-23，写这一层的当天）
///
/// Dart 的 `base64Url.decode` **拒收**不带填充的输入，报
/// `FormatException: Invalid length, must be multiple of four`；
/// 而电脑端给的凭据与签名**恰恰不带填充**（.NET 的 `Base64Url.EncodeToString`
/// 不补，`DecodeFromChars` 也拒收带 `=` 的）。
///
/// 也就是说：`base64Url.encode` → 必须 [base64UrlNoPad]，
/// `base64Url.decode` ← 必须走这里。**裸用任何一个都不行**，
/// 而且两处各错一半的话，只有在真机上第一次配对时才会暴露 ——
/// 表现是「验签失败」，看起来像被篡改。
///
/// 这正是文档 §2.7 说的那一类：两边各自自洽，合起来不通。
List<int> base64UrlDecode(String value) {
  final normalized = value.replaceAll('-', '+').replaceAll('_', '/');
  final padding = (4 - normalized.length % 4) % 4;

  return base64.decode(normalized + '=' * padding);
}

// ─────────────────────────────────────────────
// 失败分类（文档 §3）
// ─────────────────────────────────────────────

/// 错误码常量。**它们是协议的一部分，不是给人看的文案** ——
/// 发送方按码决定「重试还是进终态」，改字符串等于改协议。
/// 与电脑端 `UploadErrors` 逐字对应。
abstract final class UploadErrorCodes {
  static const badRequest = 'bad_request';
  static const badCredential = 'bad_credential';
  static const alreadyPublished = 'already_published';
  static const hashMismatch = 'hash_mismatch';
  static const chunkMissing = 'chunk_missing';
  static const evidenceMismatch = 'evidence_mismatch';
  static const unplayable = 'unplayable';
  static const notFound = 'not_found';
  static const badCode = 'bad_code';
  static const noPendingRequest = 'no_pending_request';

  /// 本地合成的码：根本没连上（拒绝连接 / 超时 / 解析不了地址）。
  static const network = 'network';

  /// 本地合成的码：电脑端回了个 5xx。
  static const server = 'server';

  /// 本地合成的码：回执验签不过。
  ///
  /// ⚠️ 这个码**不在协议里**，因为它永远不该出现 —— 出现了就说明
  /// 要么有人在局域网上伪造回执，要么两端对规范串的理解走岔了。
  /// 两种都必须当场停住并且**让用户看见**：静默重试只会把「被篡改」
  /// 拖成一条说不清道不明的「上传失败」。
  static const badSignature = 'bad_signature';
}

/// 这次失败该怎么办。
enum UploadErrorKind {
  /// 退避重试。
  retryable,

  /// 不可重试 —— 直接进终态，界面上要能看见。
  terminal,

  /// 凭据无效：**不可重试，但要重新入网**。
  needsEnrollment,

  /// 路由不存在：电脑端版本太旧。
  hostTooOld,
}

/// 一次上传失败。
///
/// ⚠️ [userHint] 是**给用户的下一步**，不是给日志的。文档 §3 最后那段：
/// 「说得出原因的那两种，提示里必须说出来」—— 因为其他失败只能说「再试试」，
/// 而这两种能说「重新配对电脑」「升级电脑端」。规格 §3.4.3 要的就是这个。
class UploadFailure implements Exception {
  const UploadFailure(this.code, {this.detail, this.status});

  final String code;
  final String? detail;
  final int? status;

  UploadErrorKind get kind => switch (code) {
        UploadErrorCodes.badCredential => UploadErrorKind.needsEnrollment,
        UploadErrorCodes.notFound => UploadErrorKind.hostTooOld,
        UploadErrorCodes.network || UploadErrorCodes.server => UploadErrorKind.retryable,
        // 其余协议码都是「重试多少次都一样」：内容本身或两端实现的问题。
        _ => UploadErrorKind.terminal,
      };

  bool get isRetryable => kind == UploadErrorKind.retryable;

  /// 界面上那一行提示。**说得出下一步的必须说出来。**
  String get userHint => switch (code) {
        UploadErrorCodes.network => '连不上电脑端。检查是不是同一个局域网、电脑端是不是开着。',
        UploadErrorCodes.server => '电脑端出错了，可以再试一次。',
        UploadErrorCodes.badCredential => '这台手机在电脑端已经不认了，请重新配对。',
        UploadErrorCodes.notFound => '电脑端版本太旧，认不出这个接口。请升级电脑端。',
        UploadErrorCodes.unplayable =>
          '电脑端打不开这段录像。**别删手机上的原文件**，重新录一次这一件。',
        UploadErrorCodes.alreadyPublished => '电脑上已经有一份同名但内容不同的录像，请找管理员核对。',
        UploadErrorCodes.hashMismatch => '传过去的和手机上的对不上，这段录像没有再自动重试。',
        UploadErrorCodes.chunkMissing => '有分片没传完，这段录像没有再自动重试。',
        UploadErrorCodes.evidenceMismatch => '录像编号对不上，这是程序的问题，请联系开发。',
        UploadErrorCodes.badSignature =>
          '**回执的签名不对**：这台电脑端给的回执验不过，或者内容是假的。'
              '先别删手机上的原文件，找管理员核对电脑端。',
        UploadErrorCodes.badRequest => '电脑端没看懂这次请求，这是程序的问题，请联系开发。',
        _ => '上传失败（$code）。',
      };

  @override
  String toString() => detail == null ? code : '$code：$detail';
}
