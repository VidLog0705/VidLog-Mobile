import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/about_page.dart';
import 'package:vidlog_mobile/app/netdisk_page.dart';

/// 「关于我们」与「网盘视频」两个二级页（需求方 2026-09-28 那张图上的两张卡）。
///
/// ## 这一组真正在守的两件事
///
/// ① **版本号不许漂。** `appVersion` 是个 Dart `const`，而 `pubspec.yaml` 是
///    唯一的真相。故意不引 `package_info_plus` 的代价就是「两个数可能对不上」——
///    所以配一条**读真文件对账**的测试，漂了当场红。这也和本仓既有的
///    「测试直接读真实文件」风格一致（见 `error_handlers_test.dart`）。
///
/// ② **点了没反应的东西不许摆出来。** 2026-10-01 之前网盘那一页是壳，
///    这条落成「控件必须是**灰的**、并明说为什么灰」。链路接通之后说法变了、
///    道理没变：**没登录之前根本不摆查询框**（摆了就是填了没反应的死表单，
///    踩坑 #13）；而没和电脑端配对时，「连电脑端」那颗按钮灰着并写明原因
///    —— 借令牌那条路本来就要电脑端，让它失败一次不如直接不让点。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: child);

  /// 这一页的导出那件事**由采集页注入**（包里那几样只有那一页有）——
  /// 测试里给一个记账的桩，验「按了会叫它、它说的话会显示出来」。
  AboutPage page({List<int>? calls, String note = '（测试）已生成'}) => AboutPage(
        onExportLogs: () async {
          calls?.add(1);
          return note;
        },
      );

  group('关于我们', () {
    test('★ 版本号与 pubspec.yaml 逐字一致', () {
      // `pubspec.yaml` 里那一行形如 `version: 1.0.0+1`。
      // 不用 yaml 包 —— 为一个字段引一个解析器不值，而且这一行是我们自己写的。
      final line = File('pubspec.yaml')
          .readAsLinesSync()
          .map((l) => l.trim())
          .firstWhere((l) => l.startsWith('version:'),
              orElse: () => fail('pubspec.yaml 里没有 version: 那一行'));

      final declared = line.substring('version:'.length).trim();

      expect(
        appVersion,
        declared,
        reason: 'App 里显示的版本与 pubspec.yaml 对不上了 —— '
            '要么改 appVersion，要么改 pubspec.yaml，两个必须一样',
      );
    });

    testWidgets('页上显示的就是那个版本号', (tester) async {
      await tester.pumpWidget(wrap(page()));

      expect(find.text('关于我们'), findsOneWidget, reason: 'AppBar 上得有标题');
      expect(find.text('版本 $appVersion'), findsOneWidget);

      // 版本那一行的 key 是给真机验收和别的测试用的，钉住它。
      expect(find.byKey(const Key('about-version')), findsOneWidget);
    });

    testWidgets('⚠️ 不摆「检查更新」这类点不动的入口', (tester) async {
      // 没有更新服务就是没有。摆上去就是个点了没反应的按钮（踩坑 #13）。
      await tester.pumpWidget(wrap(page()));

      expect(find.textContaining('检查更新'), findsNothing);
      expect(find.textContaining('检查新版本'), findsNothing);
    });

    testWidgets('★ 导出日志：按下去真的调到采集页那件事，且把那句话显示出来',
        (tester) async {
      final calls = <int>[];
      await tester
          .pumpWidget(wrap(page(calls: calls, note: '（测试）已生成并弹了分享面板')));

      expect(find.byKey(const Key('about-export-logs')), findsOneWidget);
      // 生成之前**不摆**那一行结果 —— 摆一句占位的话会被当成真的结果读。
      expect(find.byKey(const Key('about-export-note')), findsNothing);

      await tester.tap(find.byKey(const Key('about-export-logs')));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1), reason: '按一下只该叫一次');
      expect(find.text('（测试）已生成并弹了分享面板'), findsOneWidget);
    });

    testWidgets('⚠️ 导出中那颗按钮变灰（连点会生成好几份）', (tester) async {
      final calls = <int>[];
      // 一个**不立刻返回**的桩：导出要读几百行日志，这中间按钮必须是灰的。
      await tester.pumpWidget(wrap(AboutPage(onExportLogs: () async {
        calls.add(1);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return '（测试）好了';
      })));

      await tester.tap(find.byKey(const Key('about-export-logs')));
      await tester.pump();

      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('about-export-logs')))
            .onPressed,
        isNull,
      );

      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
      expect(find.text('（测试）好了'), findsOneWidget);
    });
  });

  group('网盘视频（已接通，2026-10-01）', () {
    // ⚠️ 传一个临时目录当 `rootPath`：这一页开起来会去读令牌文件，
    // 读真实的应用数据目录等于让测试去碰用户机器上的东西。
    Widget page() => NetdiskPage(
          client: null,
          rootPath: Directory.systemTemp.createTempSync('vidlog-netdisk-page-').path,
        );

    testWidgets('★ 没登录时把两条路都摆出来', (tester) async {
      await tester.pumpWidget(wrap(page()));
      await tester.pump();

      expect(find.byKey(const Key('netdisk-login')), findsOneWidget);
      expect(find.byKey(const Key('netdisk-self-login')), findsOneWidget);
    });

    testWidgets('★ 没登录之前**不摆**查询框（摆了就是填了没反应的死表单）', (tester) async {
      // 原来这条钉的是「搜索框必须是灰的」。链路接通之后换个说法、道理不变：
      // 没登录就没有可查的东西，那就**根本先不出现** —— 比灰着更彻底。
      await tester.pumpWidget(wrap(page()));
      await tester.pump();

      expect(find.byKey(const Key('netdisk-search')), findsNothing);
    });

    testWidgets('★ 没和电脑端配对时_「连电脑端」灰着并写明原因', (tester) async {
      await tester.pumpWidget(wrap(page()));
      await tester.pump();

      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('netdisk-login')))
            .onPressed,
        isNull,
        reason: '借令牌那条路本来就要电脑端 —— 让它失败一次不如直接不让点',
      );

      // 而「自己登录」那条路**必须能点**：人在局域网外就全靠它。
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('netdisk-self-login')))
            .onPressed,
        isNotNull,
        reason: '人在外面时这是唯一一条路，灰了就等于这一页没有用',
      );
    });

    testWidgets('⚠️ 这一页不许出现任何许可相关的东西（L8）', (tester) async {
      // 手机端整条链路没有任何许可判断（`04-许可设计.md`：手机端免费）。
      //
      // ⚠️ 2026-10-01 改过一次词表：原来禁的是『授权』二字，而这一页接通之后
      // **合法地用到了 OAuth 意义上的「授权」**（百度那套叫 OAuth 授权）。
      // 继续禁它只会逼着实现去绕着讲话。所以换成**只有许可才会用的那几个词**
      // —— 这一条守的是「不许开许可的口子」，不是「不许提授权两个字」。
      await tester.pumpWidget(wrap(page()));
      await tester.pump();

      for (final word in const ['激活', '许可', '试用', '许可证', '未授权']) {
        expect(find.textContaining(word), findsNothing);
      }
    });
  });
}
