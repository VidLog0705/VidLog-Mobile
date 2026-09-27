import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/recording/thumbnail_cache.dart';

/// 缩略图缓存（规格 §3.4.3）。
///
/// 规格原话：**不得每次进页面都重新抽帧**。抽一帧要解一段视频（几百毫秒到几秒），
/// 一页 15 条就是几秒 —— 而它**每次翻页、每次切回这一栏**都会重来一遍。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vidlog-thumb-');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// 造一个「视频」文件（内容无所谓，抽帧是假的）。
  String video(String id) {
    final file = File('${temp.path}/$id.mp4')..writeAsStringSync('video-bytes');
    return file.path;
  }

  test('★ 第一次抽，第二次直接读缓存（不再调原生）', () async {
    var calls = 0;

    final cache = ThumbnailCache(
      rootDirectory: temp.path,
      generate: (videoPath, outputPath) async {
        calls++;
        File(outputPath).writeAsStringSync('jpeg-bytes');
        return true;
      },
    );

    final path = video('e1');

    final first = await cache.thumbnailFor('e1', path);
    final second = await cache.thumbnailFor('e1', path);

    expect(first, isNotNull);
    expect(second, first);
    expect(calls, 1, reason: '第二次必须读缓存 —— 每次进页面都重抽是规格点名不许的');
  });

  test('★ 重启之后也认缓存（判据是文件在不在）', () async {
    // ⚠️ 判据不能是「我们抽过没有」——那在冷启动之后全部落空，
    // 于是每次开 App 都要重抽一整页。
    final path = video('e1');

    final first = ThumbnailCache(
      rootDirectory: temp.path,
      generate: (v, out) async {
        File(out).writeAsStringSync('jpeg');
        return true;
      },
    );
    await first.thumbnailFor('e1', path);

    var secondCalls = 0;
    final reopened = ThumbnailCache(
      rootDirectory: temp.path,
      generate: (v, out) async {
        secondCalls++;
        return false;
      },
    );

    expect(await reopened.thumbnailFor('e1', path), isNotNull);
    expect(secondCalls, 0, reason: '盘上已经有图了，不该再抽一次');
  });

  test('抽不出来返回 null，而且不抛', () async {
    // 缩略图是锦上添花：它坏掉不该让整页列表失败（与「标签写失败不算收尾失败」同一个取舍）。
    final cache = ThumbnailCache(
      rootDirectory: temp.path,
      generate: (v, out) async => false,
    );

    expect(await cache.thumbnailFor('e1', video('e1')), isNull);
  });

  test('抽帧抛异常也不抛出去', () async {
    final cache = ThumbnailCache(
      rootDirectory: temp.path,
      generate: (v, out) async => throw StateError('解码器炸了'),
    );

    expect(await cache.thumbnailFor('e1', video('e1')), isNull);
  });

  test('视频文件不在时直接 null，不去调原生', () async {
    var calls = 0;

    final cache = ThumbnailCache(
      rootDirectory: temp.path,
      generate: (v, out) async {
        calls++;
        return true;
      },
    );

    expect(await cache.thumbnailFor('e1', '${temp.path}/根本没有这个文件.mp4'), isNull);
    expect(calls, 0);
  });

  test('失败时不留下半截 JPG', () async {
    // 抽到一半被杀会留下一个半截文件 —— 而界面会把它当成一张真缩略图显示出来
    // （一片灰，看不出是坏的）。所以先写临时名再改名。
    final cache = ThumbnailCache(
      rootDirectory: temp.path,
      generate: (v, out) async {
        File(out).writeAsStringSync('半截');
        return false;
      },
    );

    await cache.thumbnailFor('e1', video('e1'));

    expect(File(cache.pathFor('e1')).existsSync(), isFalse);
    expect(
      Directory('${temp.path}/thumbnails')
          .listSync()
          .where((e) => e.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('抽好的图落在 <root>/thumbnails/<evidenceId>.jpg', () async {
    final cache = ThumbnailCache(
      rootDirectory: temp.path,
      generate: (v, out) async {
        File(out).writeAsStringSync('jpeg');
        return true;
      },
    );

    final path = await cache.thumbnailFor('e1', video('e1'));

    expect(path, '${temp.path}/thumbnails/e1.jpg');
    expect(File(path!).existsSync(), isTrue);
  });
}
