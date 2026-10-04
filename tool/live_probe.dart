// 一次性探针：不走 flutter_test，也不走 dart:io 的 HttpClient
// —— 改用 `curl -N` 当客户端，分辨「服务端没发」还是「Dart 客户端攒着不发」。
//
//   dart run tool/live_probe.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vidlog_mobile/live/live_server.dart';

Future<void> main() async {
  final controller = StreamController<List<int>>();

  final server = LiveServer(
    onLog: (message) => stdout.writeln('[server] $message'),
    counts: () => const LiveCounts(outbound: 7, returned: 2),
    droppedFrames: () => 0,
    video: () => controller.stream,
  );

  final port = await server.start();
  final url = 'http://127.0.0.1:$port/live';
  stdout.writeln('[probe] 服务端在 $url');

  // 一边喂帧，一边让 curl 去读。
  var sent = 0;
  final feeding = Timer.periodic(const Duration(milliseconds: 200), (_) {
    sent++;
    controller.add(utf8.encode('frame-$sent\n'));
  });

  await Future<void>.delayed(const Duration(milliseconds: 300));

  stdout.writeln('[probe] 起 curl -N（它自己不做缓冲）…');
  final result = await Process.run('curl.exe', ['-N', '-s', '--max-time', '2', url]);

  stdout.writeln('[probe] curl 退出码 ${result.exitCode}');
  stdout.writeln('[probe] curl 收到的正文：\n${result.stdout}');
  stdout.writeln('[probe] 这期间一共喂了 $sent 帧');

  feeding.cancel();
  await controller.close();
  await server.stop();
  stdout.writeln('[probe] 完');
}
