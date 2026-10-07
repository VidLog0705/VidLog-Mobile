import 'package:flutter/material.dart';

/// App 版本号。**必须与 `pubspec.yaml` 的 `version:` 逐字一致。**
///
/// ⚠️ **故意不引 `package_info_plus`**：为了一页上显示一次的字符串加一个
/// 平台依赖不划算，而且那个包在 widget 测试里必然拿不到值（没有平台通道）——
/// 「关于我们」就会在测试里永远显示「未知」，等于这一页唯一的内容测不到。
///
/// 换成「一个 const + 一条**读真文件对账**的测试」：不用依赖，漂了当场红。
/// 测试见 `test/about_page_test.dart`。
///
/// ⚠️ 它跟着 [AboutPage] 住在这个文件里（而不是单开一个 constants）：除了这一页，
/// 只有采集页那两处（启动日志、诊断包抬头）用它，而采集页**本来就要 import
/// 这个文件**拿 [AboutPage] —— 单开一个文件只会多一行 import 和一次跳转。
/// 真出现第三个消费方再拆。
const String appVersion = '1.0.0+6';

/// 「关于我们」二级页。
///
/// ⚠️ **只显示盘上真有的东西**（§13.1）—— 应用名、版本号、这产品是干什么的。
/// **不摆**「检查更新」这类入口：没有更新服务就是没有，摆上去点不动
/// （踩坑 #13，与 `NetdiskPage` 同一条规矩）。
///
/// ⚠️ 这一页**不许出现任何许可相关的东西**（L8，手机端整条链路没有许可判断）。
/// 那条断言在 `test/about_page_test.dart` 里钉着。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.onExportLogs});

  /// 「导出日志」那一颗点了干什么：**生成诊断包 + 交给系统分享面板**，
  /// 返回要在这一页上显示的那句话。
  ///
  /// ⚠️ 做成回调、而不是在这一页自己干，是因为包里那几样东西
  ///（会话数 / 未收尾数 / 索引条目 / 设备名 / 当前设置）**只有采集页那一份状态有**。
  /// 在这里重读一遍盘等于把同一件事写第二份，两边的口径迟早会走岔
  /// （诊断包的口径错了，拿到它的人也看不出错）。
  final Future<String> Function() onExportLogs;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  /// 导出/分享那一步的结果（生成之前是 null）。
  String? _note;

  /// 正在导出。**按下去要变灰** —— 生成包要读几百行日志，连点会生成好几份。
  bool _busy = false;

  Future<void> _exportAndShare() async {
    setState(() {
      _busy = true;
      _note = null;
    });

    final note = await widget.onExportLogs();

    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = note;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于我们')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('VidLog 手机端',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text('版本 $appVersion',
                      key: const Key('about-version'),
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  Text(
                    '电商打包取证系统的现场采集端：扫面单开录、按件归档、'
                    '备份到电脑端。\n'
                    '录像按原始文件保存 —— 不裁剪、不模糊、不压缩，'
                    '文件里带的就是当时拍到的。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),

          // ── 日志导出（需求方 2026-10-03）─────────────────────
          //
          // ⚠️ 生成之后**直接弹手机自带的分享面板**（微信 / 邮件 / 网盘都行），
          // 不再让用户去「文件」App 里自己翻 —— 那一步在 Android 上
          // 根本走不通（文件在 app 私有目录）。见 `DiagnosticsPackage` 的类注释。
          _sectionCard(
            title: '日志',
            children: [
              Text(
                // ⚠️ 界面上不写 `**粗体**` —— 那不是 Markdown，用户看到的是四个星号。
                '遇到问题时，把日志发回来给我们看。\n'
                '生成的那个文件里有：最近的日志、当前设置、环境与索引摘要。'
                '不含任何录像。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                key: const Key('about-export-logs'),
                onPressed: _busy ? null : _exportAndShare,
                icon: const Icon(Icons.ios_share, size: 18),
                label: Text(_busy ? '正在生成…' : '导出日志'),
              ),
              if (_note != null) ...[
                const SizedBox(height: 8),
                Text(_note!, key: const Key('about-export-note'),
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 这一页里的一张卡（与设置页那几张的版式一致：小标题 + 内容）。
  Widget _sectionCard({required String title, required List<Widget> children}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}
