import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 装配的**最后一跳**：方法写对了、测过了，而**没人调它**。
///
/// 这个项目在这种毛病上栽过三次（电脑端 `docs/实现决策.md` §35.1 记着），
/// 那边因此有一条绊线测试（`组合根把日志器递给了三处边界`）。
///
/// ⚠️ 这一端**没有依赖注入**（刻意用单例，理由见 §28.1），所以绊线只能
/// **按源码文本**读 —— 与 `DesktopServicesTests` 按文本读 `MainWindow.xaml`
/// 同一个路数。它管的是「有没有人调」，**管不了「调得对不对」**。
void main() {
  String source(String path) => File(path).readAsStringSync();

  test('⚠️ 组合根真的把日志器 init 了', () {
    // ⚠️ 不调 init 的话 `AppLog` **永远停在缓冲模式**：照记，只写在内存里，
    // 进程一退就没 —— 而磁盘上一条都不会有，**编译器一个字都不会说**。
    expect(
      source('lib/app/recorder_page.dart'),
      contains('AppLog.instance.init('),
      reason: '没人调 init = 磁盘上没有日志',
    );
  });

  test('⚠️ 一次上传真的包在 Trace.run 里', () {
    // 不包的话 `Trace.current` 恒为 null，那一段日志**串不起来** ——
    // 而它存在的全部理由就是串起来。
    expect(
      source('lib/upload/uploader.dart'),
      contains('Trace.run('),
      reason: '不包 = 关联 id 永远为空',
    );
  });

  test('⚠️ 实时共享真的接上了原生，而且报到走的是当前那个客户端', () {
    // 推流那一层（`lib/live/`）写完之后**一个调用点都没有**的话，
    // 设置页上那个开关就是一颗按下去什么也不发生的假开关 ——
    // 而「假开关」正是踩坑 #13 明令禁止的。
    final page = source('lib/app/recorder_page.dart');

    expect(page, contains('ChannelLiveGateway()'),
        reason: '没人建真的通道实现 = 开关点了不会有任何事发生');
    expect(page, contains('_applyLiveShare()'),
        reason: '没人调用 = 开关与推流之间是断的');

    // ⚠️ 报到必须**读当前那个 `_client`**，不能捕获建服务时的那一个：
    // 重新配对 / 改地址之后上传器会整个重建，捕获旧的那个会把报到
    // 打到一台已经不用的电脑上（而且那里没人报错）。
    expect(
      source('lib/live/live_service.dart'),
      contains('announce'),
      reason: '报到那一路是机位发现的全部来源',
    );
  });

  test('⚠️ 全仓不许出现 print / debugPrint', () {
    // 规格第一条就是「用成熟日志库替代 print/console.log」。而这一端的
    // `print` 在 Flutter 里**不打进日志文件**（只在 debug 控制台），
    // 于是它是一条**绕过落盘**的暗道 —— 写了就等于那条信息在真机上不存在。
    //
    // ⚠️ 注释里提到 `print` 不算（这一条测试自己就在提它），所以跳过注释行。
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final lines = entity.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        final trimmed = lines[index].trimLeft();
        if (trimmed.startsWith('//')) continue;

        if (trimmed.contains('print(') || trimmed.contains('debugPrint(')) {
          offenders.add('${entity.path}:${index + 1}');
        }
      }
    }

    expect(offenders, isEmpty, reason: '这些地方绕过落盘：$offenders');
  });

  test('★ lib/ 里一支裸色都不许有 —— 全部走 Palette', () {
    // 改造清单 T3。改版前全仓散着 73 处 `Colors.xxx`：同一个角色
    // （「压在画面上的次要字」）在四个文件里是四种白，而
    // 「退货该用哪一支橙」在列表页与详情页是两个色。
    //
    // ⚠️ **没有文件白名单，也没有色白名单 —— 只有 `Colors.transparent` 一个例外**，
    // 因为它不是一支颜色、是「没有颜色」（`Material(color:)` 的下沉层、
    // `surfaceTintColor` 关掉染色）。给它编一个 `Palette.transparent`
    // 只是把同样的字换个文件写，等于把白名单从 3 处搬到 1 处。
    //
    // ⚠️ 注释行跳过（这一条自己就在提 `Colors.`），与上面那条 `print` 同理。
    const allowed = 'Colors.transparent';
    final offenders = <String>[];
    final pattern = RegExp(r'Colors\.[A-Za-z0-9_]+');

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final lines = entity.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        if (lines[index].trimLeft().startsWith('//')) continue;

        for (final hit in pattern.allMatches(lines[index])) {
          if (hit.group(0) == allowed) continue;
          offenders.add('${entity.path}:${index + 1} → ${hit.group(0)}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些地方没走调色板（`lib/app/palette.dart`）：\n  '
          '${offenders.join('\n  ')}\n'
          '拿不准该用哪一支的话：压在**画面/视频**上的走 `onDark*` / `media*`，'
          '压在**浅底**上的走 `primary` / `green` / `amber` / `danger` 那几支。',
    );
  });

  test('★ 用户可见的文案里不许出现 markdown —— `**` 会原样印在屏幕上', () {
    // 电脑端 `docs/实现决策.md` §58.9 / §66.6。那一端踩过一次：界面上
    // **真的印出了字面的 `**`** —— 因为 `**加粗**` 在 WPF 的 TextBlock 里
    // 不是加粗，就是四个星号。而且当时只 grep 了 `.xaml`，漏掉了 Core / App
    // 两层的 C# 字符串，**是看着截图才发现的**。§58.9 的教训原话是
    // 「界面上的文字不止来自界面那一层」—— 手机端同理：用户看见的那句话
    // 可能写在任何一个 dart 文件里，不只是 `app/` 底下那几个页面。
    // （2026-10-06 全仓扫出 28 处，落在 6 个文件，其中 19 处不在 `app/` 里。）
    //
    // ⚠️ 判据是**恰好两个星号**（`(?<!\*)\*\*(?!\*)`），所以 `'***'`
    // 那个脱敏掩码（`lib/diagnostics/redact.dart`）天然不中 —— 它不是 markdown，
    // 是「这儿有秘密」的三个点。不用为它开白名单。
    //
    // ⚠️ 注释行跳过（这一条自己就在提 `**`），与上面两条同理。
    // ⚠️ 只认 `lib/` 下的字面量：从原生层（`android/`、`ios/`）或资源文件
    // 进来的文案它管不着。那两处 2026-10-06 手工扫过一遍是干净的（`**`
    // 只出现在 XML 注释里），但**没有绊线替它们守着**。
    final offenders = <String>[];
    final pattern = RegExp(r'(?<!\*)\*\*(?!\*)');

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final lines = entity.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        if (lines[index].trimLeft().startsWith('//')) continue;
        if (pattern.hasMatch(lines[index])) {
          offenders.add('${entity.path}:${index + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些行里有两个星号，会原样印在用户眼前：\n  '
          '${offenders.join('\n  ')}\n'
          '界面文字没有加粗可用 —— 要强调就换一句话讲清楚，别把星号留给用户看。',
    );
  });

  test('★ 字号只许从主题来 —— 白名单只剩两个文件，且它会自己缩', () {
    // 改造清单 T7。改版前全仓散着 **105 处 `fontSize:`**，其中 57 处是 12、
    // 19 处是 13 —— 同一个角色在不同页面是不同字号，而主题里那份定义
    // （`ThemeData`）本来可以说了算，却因为没人读它而形同虚设。
    //
    // ⚠️ **白名单冻结的是「文件」，不是「违例数」**：有人往
    // `recorder_page.dart` 里再加七处 `fontSize:`，这条绊线**不会红**。
    // 这个洞是明写在清单里的（T7「为什么全量清零」①），先接受它，理由是
    // 第二步（把 recorder_page 拆开、字号清零，与 T26 合并）做完白名单就空了。
    // 而下面那条「白名单里的文件如果已经没有 `fontSize:` 就报错」正是
    // 让它**自己缩**的机制 —— 不做这一步，白名单只会越用越松。
    const whitelist = <String>{
      // 第二步（T26 拆文件时一起清）。现在 78 处。
      'lib/app/recorder_page.dart',
      // 主题**定义处本身** —— 与桌面端 `Theme.xaml` 豁免同一个路数：
      // `navigationBarTheme.labelTextStyle` 就是在这儿把标签字号钉下来的，
      // 那不是在「用」主题，是在「写」主题。
      'lib/main.dart',
    };

    final offenders = <String>[];
    final stillNeeded = <String, int>{};

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final path = entity.path.replaceAll(r'\', '/');
      final lines = entity.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        // 注释里提到 `fontSize:` 不算（上面 zoom_dial 的注释就在提它）。
        if (lines[index].trimLeft().startsWith('//')) continue;
        if (!lines[index].contains('fontSize:')) continue;

        if (whitelist.contains(path)) {
          stillNeeded[path] = (stillNeeded[path] ?? 0) + 1;
        } else {
          offenders.add('$path:${index + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些地方写死了字号，改成 `Theme.of(context).textTheme.<角色>`：\n  '
          '${offenders.join('\n  ')}\n'
          '（11 → labelSmall，12 → bodySmall，14 → bodyMedium，16 → bodyLarge，'
          '22 → titleLarge）',
    );

    // 「只减不增」的那一半：某天有人把 recorder_page 清干净了却忘了删白名单，
    // 白名单就变成一张没人看的名单 —— 这条让它当场报出来。
    final stale = whitelist.where((path) => !stillNeeded.containsKey(path)).toList();
    expect(
      stale,
      isEmpty,
      reason: '这些文件已经没有写死的字号了，把它们从白名单里删掉：$stale',
    );
  });

  test('⚠️ 录制中锁住的正好是那四块 —— 【结束】与两个开关不许被锁', () {
    // 改造清单 T5。`_locked` 的调用点**恰好四处**，每一处都是一块次要控件：
    // 刻度盘、抽屉面板、抽屉入口、【对焦】。
    //
    // ⚠️ 这条绊线看着土，挡的却是两类真事故，而且两类都不会有别的测试发现：
    // - **少一处**：某块控件在录制中又能动了 —— 而它会动到正在录的那一段
    //   （改焦段、改工作模式、手动录入单号），那一段是**证据**。
    // - **多一处**：有人顺手把【结束】或右上角那两个开关也包进去。
    //   那更糟 —— 录到一半灯没开、或者要临时开推流，就得先停下来，
    //   而【结束】被锁死的话页面上**一个出口都没有了**。
    //
    // ⚠️ 数的是**源码文本**，所以它管得了「有没有」，管不了「包对没包对」
    // （比如把 `_locked(recording, x)` 写成 `_locked(false, x)`）。后者只能靠
    // widget 测试，而录制态在 widget 测试里到不了（要真相机）。到不了的地方
    // 就明写在这儿，别让它看起来像全验过了。
    final page = source('lib/app/recorder_page.dart');
    final calls = <int>[];

    final lines = page.split('\n');
    for (var index = 0; index < lines.length; index++) {
      if (lines[index].trimLeft().startsWith('//')) continue;
      if (lines[index].contains('_locked(')) calls.add(index + 1);
    }

    // 5 = 4 个调用点 + 1 个定义（`Widget _locked(bool locked, ...) => ...`）。
    expect(
      calls.length,
      5,
      reason: '`_locked` 的调用点应当恰好四处（刻度盘 / 抽屉面板 / 抽屉入口 / '
          '【对焦】），多见于第 $calls 行 —— 多一处少一处都要说清是为什么',
    );

    // 光拦不灰的话，用户看到的是一个点下去没反应的按钮（踩坑 #13 的假开关）；
    // 光灰不拦的话，被锁的那几块真按下去照样生效。两半都得在。
    final start = page.indexOf('Widget _locked(');
    final body = page.substring(start, page.indexOf(';', start));
    expect(body, contains('AbsorbPointer('), reason: '少了真拦的那半 —— 灰着但按得动');
    expect(body, contains('Opacity('), reason: '少了变灰的那半 —— 按不动但看不出来');
  });
}
