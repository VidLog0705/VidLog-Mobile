/// 缩略图（规格 §3.4.3 的列表项之一）。
///
/// 规格要求备份页每条都带一张**缩略图 + 播放按钮**。抽帧由**系统 API** 做：
/// iOS `AVAssetImageGenerator` / 安卓 `MediaMetadataRetriever` ——
/// **不引任何第三方包**（与本仓一贯的立场一致：能走系统 API 就不引包）。
///
/// ## ⚠️ 必须缓存
///
/// 规格原话：**不得每次进页面都重新抽帧**。
/// 抽一帧要解一段视频（几百毫秒到几秒），一页 15 条就是几秒 —— 而它**每次翻页、
/// 每次从别的栏切回来**都会重来一遍。所以抽出来的图落在
/// `<root>/thumbnails/<evidenceId>.jpg`，第二次直接读文件。
///
/// ⚠️ 缓存**不设过期**：一段录像的文件不会变（索引是追加写、文件写完就不再动），
/// 所以「同名即同图」。真正会变的是**文件被删**——那时缩略图也就没人问了
/// （列表是按索引渲染的，索引里没有它就不显示）。
library;

import 'dart:io';

/// 抽帧与落地。
///
/// [generate] 由原生提供（见 `recorder_gateway.dart` 的同名方法）：
/// 把 [videoPath] 的第一帧写成 [outputPath]。返回 false 表示抽不出来
/// （文件坏了、编解码器不支持）—— **那不是错误**，界面显示一个占位方块即可。
typedef ThumbnailGenerator = Future<bool> Function(String videoPath, String outputPath);

/// 缩略图缓存。
class ThumbnailCache {
  ThumbnailCache({
    required this.rootDirectory,
    required ThumbnailGenerator generate,
  }) : _generate = generate;

  /// 数据根目录。缩略图落在 `<root>/thumbnails/`。
  final String rootDirectory;

  final ThumbnailGenerator _generate;

  /// 已经在抽的那些（同一条录像同时被两处问到时别抽两次）。
  final Map<String, Future<String?>> _inFlight = {};

  String pathFor(String evidenceId) => '$rootDirectory/thumbnails/$evidenceId.jpg';

  /// 拿这一段的缩略图路径；抽不出来返回 null。
  ///
  /// ⚠️ **失败也**不会抛：缩略图是**锦上添花**，它坏掉不该让整页列表失败
  /// （I4 的同一条精神 —— 与「标签写失败不算收尾失败」同一个取舍）。
  Future<String?> thumbnailFor(String evidenceId, String videoPath) {
    return _inFlight.putIfAbsent(evidenceId, () async {
      try {
        final cached = File(pathFor(evidenceId));

        // ⚠️ 判据是「文件在不在」而不是「我们抽过没有」——
        // 后者在**重启之后**会全部落空，于是每次冷启动都要重抽一遍整页。
        if (await cached.exists() && await cached.length() > 0) {
          return cached.path;
        }

        final video = File(videoPath);
        if (!await video.exists()) return null;

        await cached.parent.create(recursive: true);

        // 先写临时名再改名：抽到一半被杀时留下的是一个**半截 JPG**
        // （而界面会把它当成一张真的缩略图显示出来 —— 一片灰，看不出是坏的）。
        final temporary = '${cached.path}.tmp';

        final ok = await _generate(videoPath, temporary);
        if (!ok) {
          await _quietDelete(temporary);
          return null;
        }

        await File(temporary).rename(cached.path);
        return cached.path;
      } on Object {
        // 抽帧失败：返回 null，界面显示占位。**不抛。**
        return null;
      } finally {
        // 抽完就从「在抽」里拿掉 —— 留着的话，文件后来被删了就永远拿不到新的。
        _inFlight.remove(evidenceId);
      }
    });
  }

  static Future<void> _quietDelete(String path) async {
    try {
      await File(path).delete();
    } on Object {
      // 删不掉只是留个 .tmp 垃圾。
    }
  }
}
