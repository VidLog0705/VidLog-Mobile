import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/diagnostics/app_log.dart';
import 'package:vidlog_mobile/recording/device_identity.dart';
import 'package:vidlog_mobile/main.dart';
import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/recording_spec.dart';
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
/// ## 现在有哪十一条，各自怎么验「它能红」
///
/// 第 1–8 条在备份页那一摊，9–11 是 2026-10-06 补的工作页 / 设置页。
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
/// 6. `★ 删一条还没备份的：先给「重新上传」这条出路` —— 反证：把判定层的
///    `needsUploadChoice` 写死成 `false`（两个窗合成一个）⇒ 标题那句红。
/// 7. `★ 确认删除：盘上那一段真的没了` —— 反证：`_deleteNow` 里把
///    `locationByEvidenceId` 换成一个空表 ⇒ 文件没删掉，红在「还在」。
/// 8. `★ 标签表写不进去：界面不许假装锁上了，日志也不许`（2026-10-06 加）
///    —— 反证：`_toggleLock` 末尾 `return actual` → `return want`，并把日志
///    改成照 `want` 记 ⇒ 红在 `Found 1 widget with text "解锁这一条"`（实测）。
///    造失败的办法是**在标签表那个路径上放一个目录**（`writeAsString` 当场抛），
///    与权限/平台无关，本机和 CI 一个行为。
/// 9. `★ 问不到闪光灯就不画那颗按钮，实时共享照样画`（工作页）—— 反证：把
///    `if (_torchUsable == true)` 改成 `if (true)` ⇒ 红在
///    `Found 1 widget with key ['work-torch']`（实测）。
/// 10. `★ 没有相机权限时点【开始】：真去试了，不许假装开始`（工作页）—— 反证：
///    把 `_startWorking` 开头那段权限检查整段换成直接 `return` ⇒ 红在
///    `Expected: contains 'requestCameraPermission' / Actual: ['hasCameraPermission']`
///    （实测）。
/// 11. `★ 改一项设置真落盘`（设置页）—— 反证：把 `_updateSettings` 末尾那句
///    `unawaited(settings.save())` 注释掉 ⇒ 红在
///    `PathNotFoundException … settings.json`（**文件根本没建出来**，实测）
///    —— 顺带证明那个文件确实是 `save()` 写的，不是 `_bootstrap` 顺手建的。
///
/// 第 2、4 条踩过的**假红**，都不是「找法不对」，是环境：
/// ① 只写索引不建 `.mp4` 文件 —— 界面会拿 `entry.location` 去 stat，
/// 文件不在就判成「已删除」滤掉，红在「0 条」而看着像索引没读进来；
/// ② 默认测试窗口 800×600 **太矮**，列表项被底部四栏压住，`tap` 的 hit test
/// 落在导航栏上 —— 而且**它不抛异常**，只是那一下点到了别处，后面红在
/// 「点不开」。第 4 条因此把窗口调到 1000×1400。
/// ③ 这一页比一屏长时得先 `scrollUntilVisible` —— 列表懒构建，没滚到就找不到。
///
/// 第 5 条（锁定）又踩了五个，同样都不是「找法不对」：
/// ④ `_toggleLock` → `_refreshDiagnostics` 是条**多段**真实 IO 链 ——
///    每 `await` 一次续跑就回到 fake-async 区，所以要用 `settleIo()`
///    **交替推**。只推一轮的话 `labels.jsonl` 会**建出来但是空的**，
///    看着像「标签表写坏了」。
/// ⑤ 标签表的字段名是 **PascalCase**（`Key` / `Value`，与电脑端
///    `Labels/LabelStore.cs` 逐字同构）。按小写去 `contains` 会红，
///    而原因跟锁定一点关系都没有。
/// ⑥ 读盘要用**同步**读：`runAsync(() => file.readAsString())` 在这条链上
///    给出的是空串（文件其实已经 113 字节）。
/// ⑦ `settleIo` 的**轮数别抠**：`_refreshDiagnostics` 一条链里有 **7 个
///    await**（孤儿、索引、打卡、逐条 stat、占盘、归档、标签），每个来回
///    都要一轮 —— 20 轮**刚好卡在边界上**：盘上已经写好了（标签表那半
///    能过），但 `_toggleLock` 的 Future 还没 resolve，界面那半就红在
///    「Found 0 widgets with text "已锁定"」，看着完全不像跟轮数有关。
///    现在是 40 轮。
/// ⑧ ⚠️ **曾经要「退出去再进来」才看得到，那是缺陷不是测试限制**
///    （2026-10-06 修）：详情页的 `locked` 是构造参数的一次性快照，父页的
///    `setState` 重建不了已经 push 上去的那条路由。所以老写法是先卸载再挂载
///    整棵树（`pumpWidget(SizedBox())` → `pumpApp`）—— 顺带多验了「重启之后
///    仍然锁着」。现在 `onToggleLock` 返回新锁态，**当场就变**，这一段直接
///    断言。`pumpWidget(SizedBox())` 那招留在这儿当参考（要验「重启后还在」
///    时还用得上），但**别再用它掩盖「按完当场不变」**。
///    ⚠️ 而且它当初**点不着**：`tester.pageBack()` 找不到那个返回箭头，
///    `NavigatorState.pop()` 之后路由**仍在树上**（实测 backButtons=1、
///    Navigator 只有 1 个、pop 完单号还是 2 个）。
/// ⚠️ **第 9 条之后补的**：新加一条测试时最容易忘的是**收尾**（`finishApp`）。
/// 忘了的症状有两副，都不是「断言错了」：① 报「A Timer is still pending」；
/// ② **下一条测试要等满 10 分钟才超时** —— 实测把整轮从 13 秒拖到 10 分钟以上。
/// 切一栏（`_onTabChanged` 会 `_log`）、按一下开关都会记日志，所以**每条改过
/// 界面的测试都要收尾**，别只在「看起来会记日志」的那几条上做。
///
/// ⑧ `AppLog` 是 **debounce 落盘**的，那个定时器**不在 widget 树里** ——
///    卸载树也带不走它。所以 `settleIo` 里**两边都要推**：`runAsync` 推真实
///    时间、`pump(duration)` 推 fake 时钟（只 `pump()` 不带时长的话 fake 时钟
///    一步都不走）。不这么做时报的是「A Timer is still pending even after the
///    widget tree was disposed」，看着像那一页被搞坏了。
///
/// ⚠️ **删/交付那两条进入门槛**：`_askDelete` 头一句就是「没有 `_client` 就
/// 返回」，而 `_client` 要 `_identity` 非空才建得出来 —— 所以第 6、7 条先
/// `seedIdentity()` 种一份 `device.json`（地址填没人监听的本地端口）。
/// **「已经备份过」那一档进不去**（要造归档记录），第 1 轮不做。
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

  /// 通道上被调过的方法，按顺序记下来。
  ///
  /// ⚠️ 为什么需要它：光看界面**分不出**「真的去试了、试完说不行」和
  /// 「压根没试、只是屏幕上恰好还留着上一步那句话」。第 10 条那个
  /// 「没有相机权限」在**进采集栏自动开相机**那一步就已经显示出来了 ——
  /// 只断言那句文字的话，`_startWorking` 就算静默 `return` 也照样绿。
  late List<String> calls;

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
      (call) async {
        calls.add(call.method);
        return null;
      },
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
    calls = [];
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
  /// （`recorder_events.dart:57`；2026-10-06 T26③ 第 2 轮之前它在
  /// `recorder_page.dart:1915`），文件不在就判成「已删除」丢进 `gone`，
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

  /// 种一个「已经和电脑端配过对」的身份。
  ///
  /// `_bootstrap` 里 `_buildUploader()` 的**头一句**就是
  /// `if (identity == null) return;` —— 没有它就没有 `_client`，
  /// 而没有 `_client` 时 `_askDelete` 也是**头一句就返回**：
  /// 「删除」这条路整个是关着的，界面上按它什么都不会发生。
  /// 这一条只是让那个开关打开 —— 地址填的是**没人监听**的本地端口，
  /// 所以回查必然「查不了」，那正是要测的那种情形。
  Future<void> seedIdentity(WidgetTester tester) async {
    await tester.runAsync(() => DeviceIdentity(
          path: '${documents.path}/vidlog/device.json',
          deviceId: 'test-device',
          deviceName: '测试机位',
          hostAddress: '127.0.0.1',
          hostPort: 8720,
          credential: 'test-credential',
        ).save());
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
  /// ⚠️ 两边都要推：`runAsync` 推的是**真实**时间，而 `pump(duration)`
  /// 推的是 **fake 时钟** —— 只 `pump()` 不带时长的话，`AppLog` 那种
  /// debounce 落盘定时器一步都不走，测试结束时会报
  /// 「A Timer is still pending even after the widget tree was disposed」。
  /// ⚠️ 轮数别抠：《刷新一遍盘》那条链（`_refreshDiagnostics`）里就有
  /// **7 个 await**（孤儿、索引、打卡、逐条 stat、占盘、归档、标签），
  /// 每个来回都要一轮 —— 20 轮刚好卡在边界上，会红在「界面没变」这种
  /// 看不出跟轮数有关的地方。40 轮 = 800ms 真实 + 800ms fake。
  Future<void> settleIo(WidgetTester tester, [int rounds = 40]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
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
  /// 收尾：把 `AppLog` 那个 debounce 定时器推到期，再卸载整棵树。
  ///
  /// ⚠️ **每一条改过界面的测试都要调**，别只在「看起来会记日志」的那几条上调。
  /// 切一栏（`_onTabChanged` 会 `_log`）、按一下开关，都记日志 ——
  /// 而 `AppLog` 是**debounce 落盘**的，那个定时器**不在 widget 树里**，
  /// 卸载树也带不走它。
  ///
  /// 不调的症状有两副，都很难从现场看出来：
  /// ① 测试体结束时报「A Timer is still pending even after the widget tree
  ///    was disposed」—— 看着像那一页被搞坏了，其实只是日志还没落盘；
  /// ② **下一条测试要等满 10 分钟才超时** —— 因为框架在等那个定时器。
  ///    实测第 9、10 条就是这样把整轮从 9 秒拖到 10 分钟以上的。
  Future<void> finishApp(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
  }

  /// 切到某一栏（0 备份 / 1 发货 / 2 退货 / 3 设置）。
  ///
  /// ⚠️ 按**图标**找，别按 `find.text('设置')` —— 设置页正文里也有一处
  /// `Text('设置')`（那是页面大标题），按文字找会命中两个。
  Future<void> switchTab(WidgetTester tester, IconData icon) async {
    await tester.tap(find.byIcon(icon));
    await tester.pump();
    await settleIo(tester, 8);
  }

  /// ★ **问不到闪光灯就不画那颗按钮，而实时共享照样画**。
  ///
  /// 这一对钉的是踩坑 #13（**绝不画按下去什么都不发生的假开关**）与
  /// `_workSwitches` 注释里那句「两个都是真开关，画之前先问清楚」：
  /// 手电筒要**问到有**才画，实时共享**一直画**（它是一条设置，
  /// 按下去立刻有句实话回你，见 `_toggleLiveShare`）。
  ///
  /// 两条必须成对断：只断「手电筒不在」的话，整个右上角没画出来也是绿的
  /// —— 那是空断言。`work-live-share` 在，才证明那一排真的建出来了。
  ///
  /// 反证：把 `if (_torchUsable == true)` 改成无条件画 ⇒ 这一条红。
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

    // ⚠️ 2026-10-09 起设置页是「入口列表 + 二级页」，那个三选胶囊在
    // 【工作模式】那一页里 —— 先点进去。
    await tester.tap(find.text('工作模式'));
    await tester.pumpAndSettle();

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

  /// ★ **二级页改了设置，二级页自己当场跟着变。**
  ///
  /// ⚠️ 这条钉的是两层结构（2026-10-09）里**最容易漏的那一件事**：
  /// 二级页是 `Navigator.push` 上去的，**不在** `_settingsPage` 那棵子树里 ——
  /// `_updateSettings` 里那句 `setState` 刷不到它。
  /// 少了 `_settingsTick`（或者 `_updateSettings` 里忘了 `value++`）的话，
  /// 用户点了分段按钮**界面纹丝不动**，而盘上其实已经改了 ——
  /// 比「没保存」更坏：它看起来像没生效，用户会再点一次。
  ///
  /// 反证：把 `_updateSettings` 里 `_settingsTick.value++;` 那一行删掉 ⇒ 红在
  /// 「点了 720p 这一页没跟着变」（实测）。
  testWidgets('★ 二级页改一项设置：这一页当场跟着变', (WidgetTester tester) async {
    useTallWindow(tester);
    await pumpApp(tester);
    await switchTab(tester, Icons.settings_outlined);
    await tester.tap(find.text('录像设置'));
    await tester.pumpAndSettle();

    final seg = find.byKey(const Key('settings-resolution'));
    expect(tester.widget<SegmentedButton<VideoResolution>>(seg).selected,
        <VideoResolution>{VideoResolution.p1080},
        reason: '新盘上默认档不是 1080p 了 —— 下面那条会变成空断言');

    await tester.tap(find.text('720p'));
    await tester.pumpAndSettle();

    // 两处都断：① 分段按钮自己选中了没有；② 同一张卡底下那句说明换了没有。
    // 只断一处的话，「按钮换了但说明没换」这种半吊子重建照样绿。
    expect(tester.widget<SegmentedButton<VideoResolution>>(seg).selected,
        <VideoResolution>{VideoResolution.p720},
        reason: '点了 720p 这一页没跟着变 —— 用户会以为点了没生效');
    expect(find.text('1280 × 720 · 30 帧 · 更省空间、更流畅。'), findsOneWidget,
        reason: '说明还停在旧档位上 —— 这一页只重建了一半');
    expect(find.text('1920 × 1080 · 30 帧 · 清楚与体积之间的折中。'), findsNothing);

    await finishApp(tester);
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

    // ★ 界面那一半 —— **当场**就要变。
    //
    // 2026-10-06 之前这里得「卸载再挂载整棵树」才看得到：`locked` 当时是
    // 构造参数的一次性快照，父页 `_refreshDiagnostics` 的 `setState` 重建不了
    // 已经 push 上去的那条路由，所以按完停在原地、那句话不变。
    // 现在 `onToggleLock` **返回新锁态**，详情页自己 `setState`。
    expect(find.text('已锁定'), findsOneWidget, reason: '按下去了，这句话当场就该出现');
    expect(find.text('解锁这一条'), findsOneWidget);
  });

  /// ★ **删一条还没备份的** —— 弹出来的必须是「给一条上传的出路」，
  /// 不是直接问「确认删除」。
  ///
  /// 这条钉的是 §3.5.6② 那个「两个窗不许合并」：删一条**已经核对过在电脑上**
  /// 的、和删一条**还没备份**的，前提完全不同 —— 后者一删就是永久没了。
  /// 合并成一个窗的话，用户在第二种情形下按的是同一个「确认删除」，
  /// 而他心里想的是第一种。
  ///
  /// ⚠️ 这里电脑端**不存在**（地址是没人监听的本地端口），所以回查必然
  /// 「查不了」—— 而「查不了」**绝不当成「在」**，于是这一条落在未备份那档。
  /// 「已备份 ⇒ 弹另一个窗」那半要造归档记录，不在第 1 轮。
  testWidgets('★ 删一条还没备份的：先给「重新上传」这条出路',
      (WidgetTester tester) async {
    useTallWindow(tester);
    await seedRecording(tester);
    await seedIdentity(tester);
    await pumpApp(tester);
    await openDetail(tester);

    await tester.tap(find.byKey(const Key('detail-delete')));
    await settleIo(tester, 6);

    expect(
      find.text('这一条还没备份'),
      findsOneWidget,
      reason: '拿删已备份那条的窗来问未备份的 —— 用户按的是同一个「确认删除」',
    );
    expect(find.text('删除这一条录像'), findsNothing, reason: '两个窗混了');
    expect(
      find.byKey(const Key('delete-upload-instead')),
      findsOneWidget,
      reason: '没有「重新上传」这条出路，用户只剩删这一条路',
    );

    // ★ 弹窗出现**不等于**已经删了 —— 盘上那段还在。
    expect(
      File('${documents.path}/vidlog/work/VL-20261006-100000-0001.mp4')
          .existsSync(),
      isTrue,
      reason: '只是弹了个窗，录像就已经没了',
    );
  });

  /// ★ **按「确认删除」之后，盘上那一段真的没了** —— 不可逆动作。
  ///
  /// 上一条验的是「问对了」，这一条验的是「真的做了」。两条合起来才是
  /// 那个动作完整的一遍：**问对 + 做对**。
  ///
  /// ⚠️ 只断盘上那个文件 —— 详情页自己的 pop 在这套测试里未必真退得回去
  /// （见文件头第 ⑦ 条），而「文件没了」是这件事里唯一不可逆、也唯一
  /// 真正承重的那一半。
  testWidgets('★ 确认删除：盘上那一段真的没了', (WidgetTester tester) async {
    useTallWindow(tester);
    await seedRecording(tester);
    await seedIdentity(tester);
    await pumpApp(tester);
    await openDetail(tester);

    final video =
        File('${documents.path}/vidlog/work/VL-20261006-100000-0001.mp4');
    expect(video.existsSync(), isTrue, reason: '还没删呢');

    await tester.tap(find.byKey(const Key('detail-delete')));
    await settleIo(tester, 6);

    await tester.tap(find.byKey(const Key('delete-confirm')));
    await settleIo(tester, 12);

    expect(video.existsSync(), isFalse, reason: '按了「确认删除」，盘上那一段还在');

    // ⚠️ 收拾干净再走：删完会记一条日志，而 `AppLog` 是 **debounce 落盘**的
    // —— 那个定时器不在 widget 树里，卸载树也带不走它。不收尾的话测试体
    // 结束时报的是「A Timer is still pending even after the widget tree was
    // disposed」，那句话看着像删除把页面搞坏了，其实跟删除一点关系都没有。
    await finishApp(tester);
  });

  /// ★ **写不进去的时候，界面和日志都不许说「已锁定」**。
  ///
  /// 锁定是「永不被自动清理」那条豁免的**唯一开关**（`label_store.dart` 的
  /// `setLocked` 注释原话）。它写失败而界面照样显示锁上了，用户就会以为
  /// 这条保住了 —— 等到被清理掉，他没有任何机会理解发生了什么。
  ///
  /// 造这个失败的办法是**在标签表的路径上放一个目录**：`writeAsString` 当场
  /// 抛 `FileSystemException`。跟权限、跟平台都无关，本机和 CI 一个行为。
  ///
  /// 反证：把 `_toggleLock` 末尾的 `return actual` 改回 `return want`
  /// （或者把日志那个 `if (actual == want)` 拆掉，照着 `want` 记）
  /// ⇒ 这一条红。
  testWidgets('★ 标签表写不进去：界面不许假装锁上了，日志也不许', (WidgetTester tester) async {
    useTallWindow(tester);
    await seedRecording(tester);
    await pumpApp(tester);

    // 目录占住这个路径 ⇒ 写标签必抛。
    Directory('${documents.path}/vidlog/labels.jsonl').createSync(recursive: true);

    await openDetail(tester);
    await tester.tap(find.byKey(const Key('detail-lock')));
    await settleIo(tester);

    // ★ 这半是**用户会吃大亏**的那半：按钮必须还停在「锁定这一条」。
    // 换成「解锁这一条」的话，用户看到的是「现在锁着了」。
    expect(find.text('解锁这一条'), findsNothing,
        reason: '盘上根本没写进去，界面却换成了「解锁这一条」—— 用户以为保住了');
    expect(find.text('已锁定'), findsNothing, reason: '顶上那个标记也不许冒出来');
    expect(find.textContaining('不会被自动清理'), findsOneWidget);

    // ★ 另外半是**事后追责**那半（§6.1 不可逆动作）：日志里不能只有一条
    // 「已锁定」，否则查「这条为什么被清了」会照着它当成锁着的。
    final tail = AppLog.instance.tail.value.join('\n');
    expect(tail, contains('锁定没生效'),
        reason: '盘上没写进去，日志里必须留下这一条 —— 否则事后没人追得出来');
    expect(tail, isNot(contains('已锁定 VL-20261006-100000-0001')),
        reason: '日志记的是**盘上真成了没有**，不是「按过了」');

    await finishApp(tester);
  });

  testWidgets('★ 问不到闪光灯就不画那颗按钮，实时共享照样画', (WidgetTester tester) async {
    useTallWindow(tester);
    await pumpApp(tester);
    await switchTab(tester, Icons.local_shipping_outlined);

    // 桩里 `hasTorch` 回 null（「问不到」），不是抛 —— 走到的是
    // `_torchUsable = null` 那一支。
    expect(find.byKey(const Key('work-torch')), findsNothing,
        reason: '问不到闪光灯还画那颗按钮，就是踩坑 #13 说的假开关');
    expect(find.byKey(const Key('work-live-share')), findsOneWidget,
        reason: '它是「那一排真的建出来了」的凭据 —— 少了它上面那句就是空的');

    await finishApp(tester);
  });

  /// ★ **没有相机权限时点【开始】：真去试了，而且不许假装开始**。
  ///
  /// I3：**不存在静默失败**。按下去一点反应都没有，是这一整类毛病里最坏的一种
  /// —— 用户不知道该去改什么。
  ///
  /// ⚠️ 光断「屏幕上写着没有相机权限」是**空断言**：进采集栏那一步会自动开相机
  /// （`_enterCaptureTab` → `_openCamera`），那句话在点【开始】**之前**就已经
  /// 在屏幕上了。`_startWorking` 就算第一句就静默 `return`，那句话照样在。
  ///
  /// 所以钉的是**通道**：点完之后 `hasCameraPermission` 必须**再被调一次**
  /// （证明它真的去试了），而 `startRecording` **一次都不许有**
  /// （证明它没假装开始）。
  ///
  /// 反证：把 `_startWorking` 开头那句 `if (!await _gateway.hasCameraPermission())`
  /// 连同里面整段删掉、换成直接 `return` ⇒ 这一条红在「没再调过权限」。
  testWidgets('★ 没有相机权限时点【开始】：真去试了，不许假装开始', (WidgetTester tester) async {
    useTallWindow(tester);
    await pumpApp(tester);
    await switchTab(tester, Icons.local_shipping_outlined);

    expect(find.text('没有相机权限'), findsOneWidget,
        reason: '进栏自动开相机那一步就该说了');
    expect(calls, contains('hasCameraPermission'), reason: '进栏时问过一次');

    // 从这里开始数 —— 上面进栏那一次的调用不算在这一次里。
    calls.clear();

    await tester.tap(find.widgetWithText(FilledButton, '开始'));
    await settleIo(tester, 10);

    expect(calls, contains('hasCameraPermission'),
        reason: '按了【开始】却没再去问一次权限 —— 那是静默 return，I3 不许');
    expect(calls, contains('requestCameraPermission'),
        reason: '没权限就该去要一次，而不是直接放弃');
    expect(calls.where((m) => m == 'startRecording'), isEmpty,
        reason: '没权限却开了录 —— 用户看不到画面，而机器已经在录了');
    expect(find.widgetWithText(FilledButton, '开始'), findsOneWidget,
        reason: '没开起来，按钮就不该变成「结束」');

    await finishApp(tester);
  });

  /// ★ **改一项设置真落盘**。
  ///
  /// 与锁定那条同形：界面上那个开关动了不算数，`settings.json` 上真变了才算。
  /// 设置**不落盘**的话，用户在设置页改了半天、退出重进全白改，而界面上
  /// 从头到尾没有任何异常。
  ///
  /// 反证：把 `_updateSettings` 末尾那句 `unawaited(settings.save())` 拿掉 ⇒ 红。
  testWidgets('★ 改一项设置真落盘 —— settings.json 上真变了', (WidgetTester tester) async {
    useTallWindow(tester);
    await pumpApp(tester);
    await switchTab(tester, Icons.settings_outlined);

    final file = File('${documents.path}/vidlog/settings.json');

    // ⚠️ 2026-10-09 起设置页是「入口列表 + 二级页」，这个开关在
    // 【录像设置】那一页里 —— 先点进去。
    await tester.tap(find.text('录像设置'));
    await tester.pumpAndSettle();

    final box = find.byKey(const Key('settings-record-audio-switch'));
    // ⚠️ 两句都要，缺一不可：
    //   · `scrollUntilVisible` 只滚到**目标进 widget 树**（列表是懒加载的，
    //     进 cacheExtent 就算数）—— 卡片这时可能还在视口**外面**；
    //   · `ensureVisible` 才管**滚进视口**。
    // 这个开关现在在二级页（2026-10-09 改的结构），1400 高的窗口里它本来就
    // 露得出来；两句照旧都留着 —— 结构与字号以后还会动，而两条**各自**
    // 盖的是不同的病：
    // 早先「一页十二张卡」那一版里，T7 第二步把 13 号字升到 14 之后这个开关
    // 中心点落到 y=1418，而测试窗口只有 1400 高 ⇒ 只靠前一句的话差 18px
    // 露不出来，`tap` 落空（报「would not hit test」），设置没改、
    // `settings.json` 也没建。反过来说，只留后一句也不行：卡片压根还没进树，
    // `ensureVisible` 会 `Bad state: No element`。（两条都是 2026-10-06 实测到的。）
    await tester.scrollUntilVisible(box, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(box);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(box).onChanged, isNotNull,
        reason: '设置已经读出来了（`_settingsReady`），这个开关就不该是灰的');

    await tester.tap(box);
    // 写盘是 `unawaited` 的 —— 它不等，所以这里得推给它。
    await settleIo(tester, 8);

    // 字段名是 camelCase（`recording_settings.dart` 的 `toJson`）——
    // 与标签表那套 PascalCase **不是**一个口径，别照搬。
    expect(file.readAsStringSync(), contains('"recordAudio": false'),
        reason: '开关动了，盘上没变 —— 用户改的设置根本没存下来');

    await finishApp(tester);
  });
}
