import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/diagnostics/app_log.dart';
import 'package:vidlog_mobile/main.dart';
import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/recorder_gateway.dart';
import 'package:vidlog_mobile/recording/recording_index.dart';

/// 采集页的**测试底座**（改造清单 T26③ 第 1 轮，2026-10-06）。
///
/// ## 这个文件要解决的是什么
///
/// `recorder_page.dart` 那个 State 类有 6247 行、零覆盖，而拆它之前必须
/// 先有东西能告诉你拆坏了。挡在中间的是**一个平台通道**：
/// `_bootstrap` 第一句就是 `getApplicationDocumentsDirectory()`，
/// 而 widget 测试里没有实现它 —— 于是 `_bootstrap` 当场失败、降级成
/// 「初始化失败」，`_sessions` 恒空，**备份页那一片一行都验不到**。
///
/// `record_detail_page_test.dart` 的文件头把这层天花板写了半年了。
///
/// ## 怎么打通的（两处，都实测过）
///
/// 1. **`path_provider` 走的是 MethodChannel**。这一点**不能靠猜**：
///    本机实测抛的是
///    `MissingPluginException(No implementation found for method
///    getApplicationDocumentsDirectory on channel plugins.flutter.io/path_provider)`
///    —— 也就是说没走那个纯 Dart 的 Windows 实现，打桩有效，**不用加任何依赖**。
/// 2. **`_bootstrap` 里全是真实文件 IO**，而 `flutter_test` 默认把测试
///    放在 fake-async 区里跑 —— 那些 Future **永远不会完成**。所以必须
///    `tester.runAsync(...)`，真实 IO 才跑得起来。
///
/// ## 现在有哪两条，各自怎么验「它能红」
///
/// 1. `★ 打上桩之后启动真的跑完` —— 反证：注释掉 `path_provider` 那个桩。
/// 2. `★ 盘上的录像真的显示出来了` —— 反证：把 `_bootstrap` 里 `_index`
///    的路径改个名（`index.jsonl` → 别的）⇒ 这一条红、第 1 条不变。
///
/// 第 2 条有两个**假红**的坑，都踩过：① 只写索引不建 `.mp4` 文件 ——
/// 界面会拿 `entry.location` 去 stat，文件不在就判成「已删除」滤掉，
/// 红在「0 条」而看着像索引没读进来；② 忘了 `scrollUntilVisible` ——
/// 列表懒构建，没滚到那张卡就一个都找不到。
///
/// ## ⚠️ 桩**只在这个文件里**，绝不许提到全局（比如 `flutter_test_config.dart`）
///
/// `widget_test.dart` 里**至少四条**断言建立在「`_bootstrap` 必然失败」之上：
///
/// - 「实时共享」那条断言 `设置还没读出来，稍等一下再按。`
/// - 「设置页档位控件必须禁用」那条断言 `_settings` 恒为 null
/// - 「什么都不备份时整页一个『已备份』都不许出现」那条的注释
/// - 「事件抽屉跟着日志走」那条靠「`_bootstrap` 会失败并记一条」凑出条数
///
/// 桩一提到全局，那几条会一起红 —— 而**红的不是桩错了，是那些断言
/// 本来就在测「坏了的时候什么样」**。两边各测各的，别合并。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;

  /// 数据目录指到临时目录，原生通道给个空实现。
  void stubPlatforms() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => documents.path,
    );

    // 原生录制通道（相机/权限/原生事件流）。这一趟测的是**界面与编排**，
    // 不是原生那一层 —— 给它一个「什么都没有」的实现，让它别抛。
    messenger.setMockMethodCallHandler(
      const MethodChannel(ChannelRecorderGateway.methodChannelName),
      (call) async => null,
    );

    // ⚠️ 事件流是 `EventChannel`，`listen` 也走 MethodChannel ——
    // 返回 null 会被当成「没实现」而抛 `MissingPluginException`，
    // 这个桩的返回值由 `setMockMethodCallHandler` 包成成功应答，
    // 所以 `async => null` 是「成功但一个事件都不推」。
    messenger.setMockMethodCallHandler(
      const MethodChannel(ChannelRecorderGateway.eventChannelName,
          StandardMethodCodec()),
      (call) async => null,
    );
  }

  setUp(() {
    documents = Directory.systemTemp.createTempSync('vidlog-test');
    stubPlatforms();
  });

  tearDown(() async {
    // ⚠️ `AppLog` 有一条自己的落盘定时器，不 reset 的话测试会挂在
    // 「A Timer is still pending even after the widget tree was disposed」。
    await AppLog.instance.resetForTesting();
    try {
      documents.deleteSync(recursive: true);
    } on Object {
      // 句柄还开着也无所谓 —— 系统临时目录。
    }
  });

  /// 起应用并**等真实 IO 跑完**。
  ///
  /// 不能用 `pumpAndSettle`：它在 fake-async 区里推进，等不到真实文件 IO；
  /// 而这一页还挂着一个每秒 `setState` 的秒针，`pumpAndSettle` 也永远
  /// 等不到静止。
  ///
  /// ⚠️ 400ms 不是拍的 —— 探针实测过时间线：`_bootstrap` 的盘上副作用
  /// （`calibration.json` / `device.json` / `logs/`）**500ms 内全部出现**，
  /// 包括那一步公网校时（`HttpDateClockSource`，连不上时**很快就失败**，
  /// 不是等满它 5 秒的超时）。真慢下来的话这条会先红。
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const VidLogApp());
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
  }

  /// ★ **底座本身**：打上桩之后，启动要真的跑完。
  ///
  /// 反证配方：把 `stubPlatforms()` 里 `path_provider` 那一段注释掉 ——
  /// 这一条会红，因为页面会显示「初始化失败：MissingPluginException…」。
  /// 它守的就是「底座还在」：谁把桩删了，后面所有条目一起变成摆设。
  testWidgets('★ 打上桩之后启动真的跑完 —— 不再降级成「初始化失败」',
      (WidgetTester tester) async {
    await pumpApp(tester);

    expect(
      find.textContaining('初始化失败'),
      findsNothing,
      reason: '桩没生效 —— 后面的条目都建立在「启动跑得完」上',
    );

    // 数据目录真的建出来了（`_bootstrap` 第三行就是建 `<documents>/vidlog`）。
    expect(
      Directory('${documents.path}/vidlog').existsSync(),
      isTrue,
      reason: '数据目录都没建 —— 启动根本没走到那一步',
    );
  });

  /// ★ **这一条就是第 1 轮的目的**：备份页第一次读得出盘上真有的录像。
  ///
  /// 在这之前，`_sessions` 恒空（`_bootstrap` 拿不到数据目录），
  /// 于是备份页那 1514 行 —— 列表项、删除、锁定、分享 ——
  /// **一行都验不到**。`record_detail_page_test.dart` 的文件头把这层
  /// 天花板写了半年。
  ///
  /// 索引是**用生产代码自己写的**（`JsonLinesRecordingIndex.add`），
  /// 不手抄 JSON 字段名：抄错一个字段，`tryFromJson` 会**静默丢掉这一条**，
  /// 而测试会红在一个跟真实原因毫无关系的地方。
  testWidgets('★ 盘上的录像真的显示出来了 —— `_sessions` 不再恒空',
      (WidgetTester tester) async {
    final startedAt = DateTime.now().subtract(const Duration(minutes: 5));

    await tester.runAsync(() async {
      // ⚠️ **必须真有这个文件。** 索引只是「记过这一条」，界面读盘时
      // 会拿 `entry.location` 去 stat（`recorder_page.dart:1915`），
      // 文件不在就判成「已删除」丢进 `gone`，那条从列表上消失。
      // 只写索引不写文件的话，这一条会红在「0 条」—— 看起来像索引没读进来，
      // 其实是被当成删掉的滤掉了。
      File('${documents.path}/vidlog/work/VL-20261006-100000-0001.mp4')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(1024, 0));

      await JsonLinesRecordingIndex('${documents.path}/vidlog/index.jsonl')
          .add(RecordingEntry(
        evidenceId: 'VL-20261006-100000-0001',
        sessionId: 'VL-20261006-100000-0001',
        waybill: WaybillNumber.parse('SF1000000001'),
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(minutes: 5)),
        duration: const Duration(minutes: 5),
        location: RelativePath.parse('work/VL-20261006-100000-0001.mp4'),
        contentHash: ContentHash.parse(List.filled(64, 'a').join()),
        sourceDeviceId: 'test-device',
      ));
    });

    await pumpApp(tester);

    // ⚠️ 这一页比一屏长，而 `ListView` **懒构建** —— 不滚下去那张卡
    // 压根不会被 build，`find` 会报「一个都没找到」。不是找法不对，
    // 是屏幕上真的还没有它。
    await tester.scrollUntilVisible(
      find.textContaining('视频记录（共'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(
      find.text('视频记录（共 1 条）'),
      findsOneWidget,
      reason: '盘上有那条录像，备份页却说 0 条 —— 索引没被读进来',
    );
  });
}
