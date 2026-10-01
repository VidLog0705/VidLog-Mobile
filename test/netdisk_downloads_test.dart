import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/netdisk/netdisk_downloads.dart';

/// 这里钉的是**一条安全边界**：文件名是网盘给的，不是我们拼的。
void main() {
  late Directory temp;
  late NetdiskDownloads downloads;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vidlog-netdl-');
    downloads = NetdiskDownloads(temp.path);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  String pathFor(String name, {String remote = '/apps/VidLog/a.mp4'}) =>
      downloads.pathFor(remotePath: remote, fileName: name);

  test('正常文件名照旧可用', () {
    final path = pathFor('SF100001234567_ab12_000.mp4');
    expect(path, endsWith('-SF100001234567_ab12_000.mp4'));
    expect(path, startsWith(downloads.directory));
  });

  test('⚠️ 带 ../ 的名字不许跑出目录', () {
    // 远端给什么名字我们管不了，但**落到哪**必须由我们说了算。
    for (final evil in [
      '../../../etc/passwd',
      r'..\..\windows\system32\x.mp4',
      '/etc/shadow',
    ]) {
      final path = pathFor(evil);
      expect(
        path.startsWith('${downloads.directory}/'),
        isTrue,
        reason: '「$evil」跑到目录外面去了：$path',
      );
      // 而且最后一段里不许还剩路径分隔符。
      expect(path.split('/').last, isNot(contains('/')));
    }
  });

  test('⚠️ 点与双点不许当文件名', () {
    // `.` 与 `..` 不是文件名，是**目录**。放过去等于把「写到哪」交给远端。
    expect(pathFor('..'), endsWith('-video.mp4'));
    expect(pathFor('.'), endsWith('-video.mp4'));
    expect(pathFor('   '), endsWith('-video.mp4'));
  });

  test('控制字符一律去掉', () {
    // 它们能骗过显示，也能骗过某些文件系统调用。
    final path = pathFor('a\r\nb\u0000.mp4');
    expect(path, isNot(contains('\n')));
    expect(path, isNot(contains('\u0000')));
    expect(path, endsWith('-ab.mp4'));
  });

  test('⚠️ 不同目录下的同名文件落到不同路径', () {
    // 形状是 `<单号>_<会话>_<序号>.mp4`，不同日期撞名不是不可能。
    // 撞上就是后下的覆盖先下的，而表现是「点开的是另一条录像」。
    final a = downloads.pathFor(
      remotePath: '/apps/VidLog/2026/09/30/发货/x.mp4',
      fileName: 'x.mp4',
    );
    final b = downloads.pathFor(
      remotePath: '/apps/VidLog/2026/10/01/发货/x.mp4',
      fileName: 'x.mp4',
    );

    expect(a, isNot(b));
  });

  test('同一个远端路径每次都落到同一个地方', () {
    expect(pathFor('x.mp4', remote: '/apps/VidLog/a.mp4'),
        pathFor('x.mp4', remote: '/apps/VidLog/a.mp4'));
  });

  test('删不掉也不抛', () async {
    // 下一次下载会覆盖它。这里抛的话，用户会看到一次与「删除」毫无关系的失败。
    await downloads.remove('${temp.path}/根本没有这个文件.mp4');
  });
}
