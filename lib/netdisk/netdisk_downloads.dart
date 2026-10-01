import 'dart:io';

import 'package:crypto/crypto.dart';

import '../diagnostics/app_log.dart';

/// 从网盘下下来的视频放在哪。
///
/// ⚠️ 放**应用数据目录**里，不用临时目录：用户「下完点播放」可能过一会儿才点，
/// 而系统清临时目录时那段还在播 —— Android 上直接表现为播放中断。
class NetdiskDownloads {
  NetdiskDownloads(this.rootPath);

  /// 应用数据目录（`recorder_page` 那个 `_rootPath`）。
  final String rootPath;

  /// 下下来的都放这个子目录。
  String get directory => '$rootPath/netdisk';

  Future<void> ensure() async {
    final dir = Directory(directory);
    if (!await dir.exists()) await dir.create(recursive: true);
  }

  /// 一条网盘文件落到本机时的路径。
  ///
  /// ## ⚠️ 这个文件名是**远端给的**，所以它是一条安全边界
  ///
  /// `server_filename` 和 `path` 都是网盘回的，不是我们拼的。里面出现
  /// `../../` 、绝对路径、控制字符，都会让文件落到**目录之外**
  /// （或者让某一次写入覆盖掉别人）。所以这里只取最后一段、再把危险字符清掉。
  ///
  /// ⚠️ **前面再挂一小段远端路径的哈希**：不同日期目录下**可能同名**
  /// （形状是 `<单号>_<会话>_<序号>.mp4`，撞名不是不可能），
  /// 撞上就是后下的把先下的覆盖掉 —— 而表现是「点开的是另一条录像」，
  /// 那是最不该出的一种错。哈希只取 8 位，够区分、也不至于让文件名没法看。
  String pathFor({required String remotePath, required String fileName}) {
    final safe = _safeName(fileName, fallback: 'video.mp4');
    final stamp = sha256.convert(remotePath.codeUnits).toString().substring(0, 8);

    return '$directory/$stamp-$safe';
  }

  /// 把一个文件停掉并抹掉（用户点「删除下载」）。
  Future<void> remove(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object catch (error) {
      // 删不掉不是错：下一次下载会覆盖它。这里抛的话，用户会看到一次
      // 与「删除」毫无关系的失败。
      // ⚠️ 但**不静默**（§6.1）—— 记 debug 就够：它没有后果，只是不该没有痕迹。
      AppLog.instance.debug('网盘', '下载件的旧文件删不掉（下次会覆盖）', data: {'错误': '$error'});
    }
  }

  /// 只留最后一段，并清掉控制字符与那几个危险字符。
  static String _safeName(String fileName, {required String fallback}) {
    var name = fileName.replaceAll('\\', '/');
    final cut = name.lastIndexOf('/');
    if (cut >= 0) name = name.substring(cut + 1);

    // 控制字符（含 \r\n）一律去掉：它们能骗过显示，也能骗过某些文件系统调用。
    name = name.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();

    // `.` 与 `..` 不是文件名，是**目录**。放过去就等于把「写到哪」交给远端。
    if (name.isEmpty || name == '.' || name == '..') return fallback;

    return name;
  }
}
