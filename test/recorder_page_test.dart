import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/diagnostics/app_log.dart';
import 'package:vidlog_mobile/main.dart';
import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/recorder_gateway.dart';
import 'package:vidlog_mobile/recording/recording_index.dart';
import 'package:vidlog_mobile/recording/work_mode.dart';

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
/// ## 现在有哪五条，各自怎么验「它能红」
///
/// 1. `★ 打上桩之后启动真的跑完` —— 反证：注释掉 `path_provider` 那个桩。
/// 2. `★ 盘上的录像真的显示出来了` —— 反证：把 `_bootstrap` 里 `_index`
///    的路径改个名（`index.jsonl` → 别的）⇒ 这一条红、第 1 条不变。
/// 3. `★ 设置读出来之后档位控件就能点了` —— 反证：`_settingsReady` 写死成
///    `false` ⇒ 这一条红，而 `widget_test.dart` 那条反面**仍是绿的**（实测）
///    —— 反面单独立不住，这正是这条存在的理由。
/// 4. `★ 从列表点进详情页` —— 反证：把列表项的 `onTap` 摘成 `null`。
/// 5. `★ 锁定这一条` —— 反证：把 `setLocked` 的值写反（`!locked` → `false`）
///    ⇒ 这一条红，而且报出盘上那行真的写着 `"Value":"false"`。
///
/// 第 2、4 条踩过的**假红**，都不是「找法不对」，是环境：
/// ① 只写索引不建 `.mp4` 文件 —— 界面会拿 `entry.location` 去 stat，
/// 文件不在就判成「已删除」滤掉，红在「0 条」而看着像索引没读进来；
/// ② 默认测试窗口 800×600 **太矮**，列表项被底部四栏压住，`tap` 的 hit test
/// 落在导航栏上 —— 而且**它不抛异常**，只是那一下点到了别处，后面红在
/// 「点不开」。第 4 条因此把窗口调到 1000×1400。
/// ③ 这一页比一屏长时得先 `scrollUntilVisible` —— 列表懒构建，没滚到就找不到。
///
/// 第 5 条（锁定）又踩了四个，同样都不是「找法不对」：
/// ④ `_toggleLock` → `_refreshDiagnostics` 是条**多段**真实 IO 链 ——
///    每 `await` 一次续跑就回到 fake-async 区，所以要用 `settleIo()`
///    **交替推**。只推一轮的话 `labels.jsonl` 会**建出来但是空的**，
///    看着像「标签表写坏了」。
/// ⑤ 标签表的字段名是 **PascalCase**（`Key` / `Value`，与电脑端
///    `Labels/LabelStore.cs` 逐字同构）。按小写去 `contains` 会红，
///    而原因跟锁定一点关系都没有。
/// ⑥ 读盘要用**同步**读：`runAsync(() => file.readAsString())` 在这条链上
///    给出的是空串（文件其实已经 113 字节）。
/// ⑦ 「退出去再进来」**别走 pop**：`tester.pageBack()` 点不到那个返回箭头，
///    `NavigatorState.pop()` 之后路由**仍在树上**（实测 backButtons=1、
///    Navigator 只有 1 个、pop 完单号还是 2 个）。改成卸载再挂载整棵树
///    （`pumpWidget(SizedBox())` → `pumpApp`）—— 顺带多验了一条更硬的：
///    **重启之后它仍然锁着**。
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

  /// 往工作区种一条录像：**索引与 `.mp4` 两个都要真写**。
  ///
  /// ⚠️ 只写索引不写文件的话界面会拿 `entry.location` 去 stat
  /// （`recorder_page.dart:1915`），文件不在就判成「已删除」丢进 `gone`，
  /// 那条从列表上消失 —— 红在「0 条」而看着像索引没读进来。
  ///
  /// 索引是**用生产代码自己写的**（`JsonLinesRecordingIndex.add`），
  /// 不手抄 JSON 字段名：抄错一个字段，`tryFromJson` 会**静默丢掉这一条**，
  /// 而测试会红在一个跟真实原因毫无关系的地方。
  Future<void> seedRecording(WidgetTester tester) async {
    final startedAt = DateTime.now().subtract(const Duration(minutes: 5));

    await tester.runAsync(() async {
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
  }

  /// 把测试窗口调高。
  ///
  /// ⚠️ 默认 800×600 **太矮**：列表项被底部那四栏压住，`tap` 的 hit test
  /// 落在导航栏上 —— 而且**它不抛异常**，只是那一下点到了别处，
  /// 后面红在「点不开」这种看着像接线断了的地方。
  void useTallWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 放真实 IO 跑一阵，再 `pump` 一次让 fake-async 那边的续跑 —— 交替推几轮。
  ///
  /// ⚠️ **一轮不够**（实测）：`_toggleLock` → `_refreshDiagnostics` 是条
  /// **多段**的真实 IO 链，每 `await` 一次续跑就回到 fake-async 区，
  /// 下次真实 IO 又得靠 `runAsync` 推。只推一轮的话 `labels.jsonl` 会被
  /// **建出来但是空的** —— 那看着像「标签表写坏了」，其实只是没跑完。
  Future<void> settleIo(WidgetTester tester, [int rounds = 20]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  /// 从备份页列表点开第一条录像的详情页。
  ///
  /// ⚠️ 不用 `pumpAndSettle`：采集页那个秒针还在转，永远不会静止。
  Future<void> openDetail(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.textContaining('视频记录（共'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    await tester.tap(find.text('SF1000000001'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
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
    await seedRecording(tester);

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

  /// ★ **`_settingsReady` 的另一半**：设置读出来之后，控件必须**能点**。
  ///
  /// `widget_test.dart` 那条「盘上的设置没读出来之前，档位控件必须是禁用的」
  /// 钉的是反面 —— 而反面**单独立不住**：把 `_settingsReady` 写死成 `false`，
  /// 那一条照样绿（它本来就跑在「没读出来」那个状态里），
  /// 而用户看到的是**设置页永远是灰的**，一个都点不动。
  /// 有了这一条正面，两边才合起来把守卫钉死。
  testWidgets('★ 设置读出来之后档位控件就能点了 —— `_settingsReady` 的另一半',
      (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('设置').last);
    await tester.pump(const Duration(milliseconds: 400));

    final chip = find.byType(SegmentedButton<WorkMode>);
    await tester.scrollUntilVisible(
      chip,
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(
      tester.widget<SegmentedButton<WorkMode>>(chip).onSelectionChanged,
      isNotNull,
      reason: '设置读出来了控件还是禁用的 —— 设置页整个是灰的，一个都点不动',
    );
  });

  /// ★ **从列表点进详情页** —— 解掉 `record_detail_page_test.dart` 文件头
  /// 写着的那半天花板。
  ///
  /// 那一页自己是测得挺好的，但一直是从**手搭的假数据**直接 pump 起来的：
  /// 「备份页的 widget 测试受限于 `_sessions` 恒空……列表项那七项、
  /// 原来挤在行上的那三个操作**都验不到**」。
  /// 它验不到的其实是**接线**：列表上那一条真的点得开、开了之后
  /// 拿到的是**这一条**的数据（而不是某一条默认值）。
  ///
  /// ⚠️ 不用 `pumpAndSettle`：下面那页（采集页）的秒针还在转，永远不会静止。
  testWidgets('★ 从列表点进详情页，看到的是盘上那一条', (WidgetTester tester) async {
    useTallWindow(tester);
    await seedRecording(tester);
    await pumpApp(tester);
    await openDetail(tester);

    expect(find.text('录像详情'), findsOneWidget, reason: '点不开 —— 列表项没接上详情页');
    expect(find.text('1 段'), findsOneWidget, reason: '段数不是这一条的');
    expect(
      find.textContaining('work/VL-20261006-100000-0001.mp4'),
      findsOneWidget,
      reason: '详情页拿到的路径不是这一条的',
    );
  });

  /// ★ **锁定这一条** —— 承重 + 不可逆那一类里，在本底座上唯一进得去的一个。
  ///
  /// 这条**不看界面自证**：界面说「已锁定」只证明它自己改了内存里的一个
  /// 映射，而清理判定读的是**盘上那个标签表**。两处一旦分家，用户看到的
  /// 就是「界面上明明锁着，还是被清掉了」——`isEvidenceLocked` 的注释
  /// 把这个状态叫「用户没机会理解」。
  ///
  /// 所以断言要**分两半**：界面上那两句话变了，**并且** `labels.jsonl`
  /// 里真的多了一行 `locked=true`。
  ///
  /// （删除与交付那两条路在本底座上进不去 —— `_askDelete` 第一句就是
  /// 「没有 `_client` 就返回」，而 `_client` 要入网之后才有。
  /// 那两条要等假电脑端，不在第 1 轮。）
  testWidgets('★ 锁定这一条：界面变了，标签表也真写了', (WidgetTester tester) async {
    useTallWindow(tester);
    await seedRecording(tester);
    await pumpApp(tester);

    // 锁之前，盘上那个标签表**还不存在**（种数据只写了索引与 mp4）。
    final labels = File('${documents.path}/vidlog/labels.jsonl');
    expect(labels.existsSync(), isFalse, reason: '还没锁，标签表不该先有了');

    await openDetail(tester);

    await tester.tap(find.byKey(const Key('detail-lock')));
    await settleIo(tester);

    // ★ 承重的那一半先断 —— 界面对了不算数，标签表写了才算。
    //
    // ⚠️ 用**同步**读。`runAsync(() => file.readAsString())` 在这条链上
    // 会给出一个空串（实测；文件其实已经 113 字节了），
    // 而那个空串看着像「标签表写坏了」，能把人带偏很久。
    final raw = labels.readAsStringSync();
    // ⚠️ 字段名是 **PascalCase**（`EvidenceId`/`Key`/`Value`/`UpdatedAt`）——
    // 与电脑端 `Labels/LabelStore.cs` 逐字同构，`label_store.dart` 的文件头
    // 头一句就写着。按小写去 contains 会红，而原因跟锁定一点关系都没有。
    expect(raw, contains('"Key":"locked"'), reason: '标签表里没有 locked 这一行');
    expect(raw, contains('"Value":"true"'), reason: '写了 locked，但值不是 true');

    // ★ 界面那一半要**退出去再进来**才看得到：
    // `RecordDetailPage.locked` 是**构造参数**（`record_detail_page.dart:133`），
    // 父页 `_refreshDiagnostics` 的 `setState` 重建不了已经 push 上去的那条路由
    // （实测：点完停在原地，那句话不变）。
    //
    // ⚠️ 这里用**卸载再挂载整棵树**来表达「退出去再进来」，
    // 而不是 pop：`tester.pageBack()` 点不到那个返回箭头，
    // `NavigatorState.pop()` 之后详情页**仍在树上**（实测：backButtons=1、
    // Navigator 只有 1 个、pop 完 `SF1000000001` 还是 2 个）。
    // 那条路在这套测试里走不通，别在这儿耗 —— 而且这样还顺带验了一条更硬的：
    // **重启之后它仍然锁着**（`_bootstrap` 重新读盘）。
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester);
    await openDetail(tester);

    expect(find.text('已锁定'), findsOneWidget, reason: '锁了，回来再看还是没有那个标记');
    expect(find.text('解锁这一条'), findsOneWidget);
  });
}
