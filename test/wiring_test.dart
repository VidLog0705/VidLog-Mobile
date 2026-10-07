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
/// 一个「壳」文件 + 它 `part` 进来的那些文件 —— 同一个 library 的全部路径。
///
/// ⚠️ T26③ 第 2 轮把 `recorder_page.dart` 拆成了**同一个 library** 的十几个
/// 文件（那边写 `part 'x.dart';`，这边写 `part of 'recorder_page.dart';`）。
/// 按路径读**单个文件**的话，下面这些绊线会在「东西还在、只是换了文件」的时候
/// 变红 —— 那是**假红**，比没有绊线更坏：下一次真断线就没人当回事了。
List<String> libraryFiles(String shell) {
  final file = File(shell);
  final paths = <String>[shell.replaceAll(r'\', '/')];

  for (final line in file.readAsLinesSync()) {
    final part = RegExp(r"^\s*part\s+'([^']+)'").firstMatch(line);
    if (part != null) {
      paths.add('${file.parent.path}/${part.group(1)}'.replaceAll(r'\', '/'));
    }
  }

  return paths;
}

/// 读一个文件的源码；它是「壳」的话，把整个 library 一起读进来。
///
/// 没有 `part` 的文件（`uploader.dart` / `live_service.dart`）拿到的就是它自己。
String source(String path) =>
    libraryFiles(path).map((p) => File(p).readAsStringSync()).join('\n');

void main() {
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

  test('★ lib/ 里一个写死的圆角都不许有 —— 全部走 Corners', () {
    // 改造清单 P1（需求方 2026-10-07 拍板：**只补圆角、迁到零裸值**）。
    // 迁移前 `lib/` 下 16 处圆角全是裸数字、7 个不同数值。
    //
    // ⚠️ **规则是「圆角必须来自 `Corners`」，不是「不许出现某个数」** ——
    // 后者漏得掉 `BorderRadius.vertical(top: Radius.circular(12))` 这种写法。
    // 所以这里抓的是**构造器**，再看它的实参里有没有 `Corners.`。
    //
    // ⚠️ **没有白名单。** 唯一允许写裸值的地方是令牌自己
    // （`lib/app/corners.dart`）—— 与 T3 裸色、T7 字号同一个收尾方式。
    // 真需要第八支，就加进 `corners.dart` 并起个角色的名字，别在这儿开口子。
    //
    // ⚠️ 注释行跳过（这一条自己就在提这些构造器），与 `print` / `Colors.` 两条同理。
    const tokenFile = 'lib/app/corners.dart';
    final offenders = <String>[];
    final pattern = RegExp(
      r'BorderRadius\.(?:circular|all|only|vertical|horizontal)\(|Radius\.circular\(',
    );

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.replaceAll(r'\', '/') == tokenFile) continue;

      final lines = entity.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        if (lines[index].trimLeft().startsWith('//')) continue;

        for (final hit in pattern.allMatches(lines[index])) {
          final rest = lines[index].substring(hit.end);
          final close = rest.indexOf(')');
          final args = close < 0 ? rest : rest.substring(0, close);
          if (args.contains('Corners.')) continue;
          offenders.add(
            '${entity.path}:${index + 1} → '
            '${lines[index].substring(hit.start).trim()}',
          );
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些圆角是写死的（该走 `lib/app/corners.dart`）：\n  '
          '${offenders.join('\n  ')}\n'
          '挑一支的办法看名字（pill / card / note / thumb / tag / '
          'header / iconBox）；都不合适就在 `corners.dart` '
          '里补一支**按角色命名**的，别在调用点写数字。',
    );
  });

  test('★ 每一支圆角都真的有人用 —— 没人用的那支是纯装饰', () {
    // ⚠️ 这一条是**反向**的，专门盯「令牌层变摆设」。
    //
    // 桌面 T4 那三支是被 `Theme.xaml` 自己吃掉的（定义即使用）；手机端没这个待遇
    // —— `ThemeData` 只吃一处圆角。所以这一层唯一的用处就是「调用点来读它」，
    // 一支没人读的常量就是纯装饰，正是 T4 当初拒绝做 spacing 令牌的那个理由。
    //
    // ⚠️ 这一层里**有三支只有一个用户**（`thumb` / `header` / `iconBox`），
    // 所以这条现在就能红：删掉其中任何一支的**唯一**那个调用点，
    // 它立刻从「只有一个用户」掉到零。
    //
    // ⚠️ **注释行必须跳过**（与上面两条绊线同理，但这里不止是「免得自己提到自己」）：
    // 不跳的话，把唯一的调用点注释掉、再在注释里提一句 `Corners.thumb`，
    // 这条照样绿 —— 那就成了一个**能被最省事的改法骗过**的检查。
    final tokens = RegExp(r'static const (\w+) =')
        .allMatches(File('lib/app/corners.dart').readAsStringSync())
        .map((m) => m.group(1)!)
        .toList();
    expect(tokens, isNotEmpty, reason: '`corners.dart` 里一支令牌都没解析出来？');

    final unused = <String>[];
    for (final token in tokens) {
      final pattern = RegExp('Corners\\.$token\\b');
      final used = Directory('lib').listSync(recursive: true).any(
            (entity) =>
                entity is File &&
                entity.path.endsWith('.dart') &&
                entity.path.replaceAll(r'\', '/') != 'lib/app/corners.dart' &&
                entity.readAsLinesSync().any(
                      (line) =>
                          !line.trimLeft().startsWith('//') &&
                          pattern.hasMatch(line),
                    ),
          );
      if (!used) unused.add(token);
    }

    expect(
      unused,
      isEmpty,
      reason: '这几支令牌没有任何调用点，等于摆设：$unused\n'
          '要么把调用点迁过来，要么把这支删掉 —— 别留着「以后可能用得上」的常量。',
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

  test('★ 字号只许从主题来 —— 白名单只剩主题定义处那一个', () {
    // 改造清单 T7。改版前全仓散着 **105 处 `fontSize:`**，其中 57 处是 12、
    // 19 处是 13 —— 同一个角色在不同页面是不同字号，而主题里那份定义
    // （`ThemeData`）本来可以说了算，却因为没人读它而形同虚设。
    //
    // ✅ **第二步 2026-10-06 做完了**：`lib/` 下那 72 处全部换成
    // `Theme.of(context).textTheme.<角色>`，名单里 `recorder_page` 那一项
    // 当场被下面那条 stale 检查逼着删掉（那正是它存在的用处）。
    // ⚠️ 只是「改完」，**还没有真机逐屏看过** —— 这一刀是真行为变化
    // （13→14、15→16 会挤布局），本地能证的只有「测试全绿 + 名单收干净」。
    //
    // ⚠️ **白名单冻结的是「文件」，不是「违例数」**：有人往某个已清干净的文件里
    // 再加七处 `fontSize:`，这条绊线**不会红**。这个洞明写在清单里
    // （T7「为什么全量清零」①），先接受它 —— 剩下唯一那项是主题定义处本身，
    // 它**永远不会缩**，所以「只减不增」的机制到这里已经用尽。
    // ⚠️ 白名单的单位是**一个 library**，不是一个文件：一项展开成壳 + 它
    // `part` 进来的全部文件（`libraryFiles`）。T26③ 第 2 轮把
    // `recorder_page.dart` 拆成了十几个 part 文件 —— 照文件名逐个加进来的话，
    // 这份名单会变成一张「什么都放行」的名单。
    const whitelistShells = <String>[
      // 主题**定义处本身** —— 与桌面端 `Theme.xaml` 豁免同一个路数：
      // `navigationBarTheme.labelTextStyle` 就是在这儿把标签字号钉下来的，
      // 那不是在「用」主题，是在「写」主题。
      'lib/main.dart',
    ];
    final whitelist = <String>{
      for (final shell in whitelistShells) ...libraryFiles(shell),
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
          '（T7 第二步用的对照表：10/11 → labelSmall，12 → bodySmall，'
          '13 → labelLarge，14 → bodyMedium，15/16 → bodyLarge，'
          '20/22 → titleLarge，26 → headlineSmall）',
    );

    // 「只减不增」的那一半：清干净了却忘了删白名单，白名单就变成一张没人看的
    // 名单 —— 这条让它当场报出来。（T7 第二步就是被它逼着删掉
    // `recorder_page` 那一项的。）
    //
    // ⚠️ 按**整个 library** 判、不按单个文件判：一个 library 拆成十几个文件之后，
    // 逐个文件判的话，那些天生没有字号的 part 文件会永远被判成「已经没有了」——
    // 又一处假红。要的是「这一整块清干净了没有」。
    final stale = whitelistShells
        .where((shell) =>
            libraryFiles(shell).every((p) => !stillNeeded.containsKey(p)))
        .toList();
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

  test('⚠️ 清理流水在设置页上真的有出路', () {
    // T24。「零件好、没人接」是本仓反复踩过的病（规格 §6.2 那句「保留可查的
    // 清理记录」从写下第一行起就成立，而**一直没有地方能看**）——
    // 这一条钉的就是**那个入口真的存在**。
    //
    // ⚠️ 它管的是「有没有接上」，**管不了「点进去画得对不对」**：
    // 后者由 `cleanup_log_page_test.dart` 拿一个真目录跑。
    final settings = source('lib/app/recorder_settings.dart');
    final page = source('lib/app/cleanup_log_page.dart');

    // ① 设置页上真有那张卡，且**列进了设置页的 children** ——
    //    只写一个方法没人调的话，那一页上什么都不会出现。
    expect(settings, contains('Widget _cleanupLogCard()'),
        reason: '那张卡没有了 = 用户找不到这一页');
    expect(settings, contains('_cleanupLogCard(),'),
        reason: '写了卡片却没摆进 `_settingsPage` 的 children = 页面上看不见');

    // ② 点它真的推一个页面上去。
    expect(settings, contains('onTap: _openCleanupLogPage'),
        reason: '卡片点不动 = 假开关（踩坑 #13）');
    expect(settings, contains('CleanupLogPage('),
        reason: '处理器里没建那个页面');

    // ③ 那一页读的是**带坏行计数**的那个入口，且路径走 `inRoot` ——
    //    自己拼一遍 `'$root/cleanup-audit.jsonl'` 正是下面那条绊线盯着的。
    expect(page, contains('CleanupAuditLog.inRoot('),
        reason: '流水路径不许在页面里手拼');
    expect(page, contains('.loadPage()'),
        reason: '用 `loadAll()` 的话读不动的行会被悄悄跳过，而这一页看着干干净净');
  });

  test('★ 审计文件的名字只许写在一个地方', () {
    // T24 收口时数的：`'$root/cleanup-audit.jsonl'` 原先在
    // `recorder_records_ops.dart` 里抄了三遍，流水页还要用第四次 ——
    // 只要有一处拼错，用户看到的就是「清完了、流水上是空的」，
    // 而那本账存在的意义正是「这条录像什么时候没的」。
    //
    // ⚠️ 注释里提到这个名字不算（这一条自己就在提它），跳过注释行 ——
    // 与 `print` / `Colors.` 那几条绊线同理。
    const tokenFile = 'lib/recording/cleanup_audit.dart';
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.replaceAll(r'\', '/') == tokenFile) continue;

      final lines = entity.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        if (lines[index].trimLeft().startsWith('//')) continue;
        if (lines[index].contains('cleanup-audit.jsonl')) {
          offenders.add('${entity.path}:${index + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些地方自己拼了流水文件名，改成 `CleanupAuditLog.inRoot(root)`：\n  '
          '${offenders.join('\n  ')}',
    );
  });
}
