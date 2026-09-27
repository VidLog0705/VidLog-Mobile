import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/record_detail_page.dart';
import 'package:vidlog_mobile/recording/business_type.dart';

/// 录像详情页（需求方 2026-09-27 照备份页草图定的）。
///
/// ## 为什么这一页**能**在 widget 测试里验，而备份页那一层不能
///
/// 备份页的 widget 测试受限于 `_sessions` 恒空（要 `path_provider` 平台通道
/// 才读得出 `index.jsonl`），所以列表项那七项、原来挤在行上的那三个操作
/// **都验不到**。这一页是**纯展示 + 回调**，一行业务判定都没有 —— 谁来都能
/// 把它直接构造出来按一遍，所以它成了那三个操作真正的回归守卫。
///
/// ⚠️ 三处最容易写反、写反了用户会吃大亏的地方，这里各有一条钉着：
/// 1. 删除回调返回 false（回查没过、审计写不进去）时 **不许 pop**；
/// 2. 判不出业务类型时**那一格不出现**（不猜）；
/// 3. 「原视频、没打码」那句提示必须在（规格 §3.6.6：打码整条不做）。
void main() {
  /// ⚠️ 这一页是**被 push 出来**的，这里也得 push 出来 ——
  /// `home:` 的话 pop 的就是根路由，`find.text('录像详情')` 删成删不成都
  /// 一样会消失，「没删成就得留在原地」那条就变成永远绿的空断言。
  Future<void> open(
    WidgetTester tester, {
    BusinessType? businessType = BusinessType.outbound,
    bool locked = false,
    VoidCallback? onPlay,
    VoidCallback? onToggleLock,
    VoidCallback? onShare,
    Future<bool> Function()? onDelete,
  }) async {
    // ⚠️ 默认的测试画布是 800×600，而这一页是个 `ListView`（**懒加载**）——
    // 下面那三个按钮根本没被建出来，`find.byKey` 会报 `Found 0 widgets`。
    // 不是「找的方式不对」，是**屏幕上真的还没有它们**。
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RecordDetailPage(
                    title: 'SF1000000001',
                    businessType: businessType,
                    uploadText: '已备份',
                    uploadColor: Colors.green,
                    timeText: '9月16日 17:32',
                    durationText: '00:48',
                    sizeText: '12.3 MB',
                    segmentText: '2 段',
                    location: '2026/09/16/SF1000000001/e1.mp4',
                    locked: locked,
                    preview: const SizedBox.shrink(),
                    onPlay: onPlay,
                    onToggleLock: onToggleLock ?? () {},
                    onShare: onShare ?? () {},
                    onDelete: onDelete ?? () async => true,
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('★ 备份页那一行收进来的三个操作，都在这儿', (WidgetTester tester) async {
    var locked = 0;
    var shared = 0;

    await open(tester,
        onToggleLock: () => locked++, onShare: () => shared++);

    expect(find.text('录像详情'), findsOneWidget);

    // 三个操作都要**点得动而且真的转发出去** —— 只 find 到不算数：
    // 一个画出来但连不到东西的按钮，用户按下去什么都不会发生。
    await tester.tap(find.byKey(const Key('detail-lock')));
    await tester.tap(find.byKey(const Key('detail-share')));

    expect(locked, 1);
    expect(shared, 1);
    expect(find.byKey(const Key('detail-delete')), findsOneWidget);
  });

  testWidgets('★ 删掉了才 pop；删不成要留在原地', (WidgetTester tester) async {
    // ⚠️ 这一条是**最容易写反**的：写成「按了就 pop」的话，
    // 回查没过（归档层上那份没了）时用户会看到详情页关掉，
    // 而**那句「为什么不能删」一闪就被吞了**，录像还在。
    var asked = false;

    await open(tester, onDelete: () async {
      asked = true;
      return false; // 删不成
    });

    await tester.tap(find.byKey(const Key('detail-delete')));
    await tester.pumpAndSettle();

    expect(asked, isTrue, reason: '判定该发出去（它会弹「为什么不能删」）');
    expect(find.text('录像详情'), findsOneWidget, reason: '没删成就得留在原地');
  });

  testWidgets('删成了就 pop', (WidgetTester tester) async {
    await open(tester, onDelete: () async => true);

    await tester.tap(find.byKey(const Key('detail-delete')));
    await tester.pumpAndSettle();

    expect(find.text('录像详情'), findsNothing);
  });

  testWidgets('★ 判不出业务类型时那一格不出现 —— 不猜', (WidgetTester tester) async {
    // 标签认不出就是不写（`BusinessType.tryParse`）。猜一个「发货视频」
    // 出来，事后没人分得清它是真的还是猜的。
    await open(tester, businessType: null);

    expect(find.text('发货视频'), findsNothing);
    expect(find.text('退货视频'), findsNothing);
    // 但别的格子照常。
    expect(find.text('已备份'), findsOneWidget);
  });

  testWidgets('发货 / 退货两个字与列表上那个小标**同一个字符串**', (WidgetTester tester) async {
    await open(tester, businessType: BusinessType.returning);

    expect(find.text('退货视频'), findsOneWidget);
    expect(find.text(BusinessType.returning.displayName), findsOneWidget);
  });

  testWidgets('锁着的时候：状态说得出来，按钮变成「解锁」', (WidgetTester tester) async {
    await open(tester, locked: true);

    expect(find.text('已锁定'), findsOneWidget);
    expect(find.text('解锁这一条'), findsOneWidget);
  });

  testWidgets('没锁的时候按钮是「锁定」，而且说明了锁了有什么用', (WidgetTester tester) async {
    await open(tester);

    expect(find.text('已锁定'), findsNothing);
    // 「不会被自动清理」这几个字不能省：光写「锁定」，用户不知道锁了干嘛。
    expect(find.textContaining('不会被自动清理'), findsOneWidget);
  });

  testWidgets('★ 交付那句提示必须在：原视频、没打码（规格 §3.6.6）',
      (WidgetTester tester) async {
    // 打码**整条不做**是需求方定的。这句话不说清楚，用户会以为系统
    // 替他处理过面单上的姓名电话 —— 而交出去的每一个字节都是原样的。
    await open(tester);

    expect(find.textContaining('没有打码'), findsOneWidget);
    expect(find.textContaining('原样'), findsOneWidget);
  });

  testWidgets('详情页上那些数**是调用方给的**，这一页不自己算', (WidgetTester tester) async {
    // 两处各写一套格式化的话，列表上写着 `9月16日` 而这里写着 `09-16`，
    // 同一个东西两个样子（而搜索框是按屏幕上真有的字匹配的）。
    await open(tester);

    for (final value in ['9月16日 17:32', '00:48', '12.3 MB', '2 段']) {
      expect(find.text(value), findsOneWidget, reason: '「$value」该原样出现在这一页上');
    }
  });
}
