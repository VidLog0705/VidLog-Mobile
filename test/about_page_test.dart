import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/recorder_page.dart';

/// 「关于我们」与「网盘视频」两个二级页（需求方 2026-09-28 那张图上的两张卡）。
///
/// ## 这一组真正在守的两件事
///
/// ① **版本号不许漂。** `appVersion` 是个 Dart `const`，而 `pubspec.yaml` 是
///    唯一的真相。故意不引 `package_info_plus` 的代价就是「两个数可能对不上」——
///    所以配一条**读真文件对账**的测试，漂了当场红。这也和本仓既有的
///    「测试直接读真实文件」风格一致（见 `error_handlers_test.dart`）。
///
/// ② **没接通的东西必须说出来。** 网盘那一页是壳（后端在电脑端都还没做）。
///    做成「填了单号点搜索没反应」的表单就是踩坑 #13 —— 用户会以为是自己
///    网络的问题，反复试。所以控件必须是**灰的**，而且**明说为什么灰**。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: child);

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
      await tester.pumpWidget(wrap(const AboutPage()));

      expect(find.text('关于我们'), findsOneWidget, reason: 'AppBar 上得有标题');
      expect(find.text('版本 $appVersion'), findsOneWidget);

      // 版本那一行的 key 是给真机验收和别的测试用的，钉住它。
      expect(find.byKey(const Key('about-version')), findsOneWidget);
    });

    testWidgets('⚠️ 不摆「检查更新」这类点不动的入口', (tester) async {
      // 没有更新服务就是没有。摆上去就是个点了没反应的按钮（踩坑 #13）。
      await tester.pumpWidget(wrap(const AboutPage()));

      expect(find.textContaining('检查更新'), findsNothing);
      expect(find.textContaining('检查新版本'), findsNothing);
    });
  });

  group('网盘视频（壳）', () {
    testWidgets('★ 明说「还没接通」，而不是摆一个能填的表单', (tester) async {
      await tester.pumpWidget(wrap(const NetdiskShellPage()));

      expect(find.byKey(const Key('netdisk-not-connected')), findsOneWidget);
      expect(find.textContaining('还没接通'), findsOneWidget);
    });

    testWidgets('★ 登录与搜索都是**灰的**（不是点了没反应）', (tester) async {
      await tester.pumpWidget(wrap(const NetdiskShellPage()));

      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('netdisk-login')))
            .onPressed,
        isNull,
        reason: '登录按钮能点却没反应 → 用户会以为是自己网络的问题',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('netdisk-search')))
            .enabled,
        isFalse,
        reason: '搜索框能填却没反应 → 同上',
      );
    });

    testWidgets('⚠️ 这一页不许出现任何许可相关的东西（L8）', (tester) async {
      // 手机端整条链路没有任何许可判断（`04-许可设计.md`：手机端免费）。
      // 网盘这一页是壳，将来接通也不许在这里开第一个口子。
      await tester.pumpWidget(wrap(const NetdiskShellPage()));

      for (final word in const ['激活', '许可', '试用', '授权']) {
        expect(find.textContaining(word), findsNothing);
      }
    });
  });
}
