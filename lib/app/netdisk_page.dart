import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../diagnostics/app_log.dart';
import '../netdisk/baidu_pan.dart';
import '../netdisk/netdisk_downloads.dart';
import '../netdisk/netdisk_token.dart';
import '../upload/uploader.dart';
import 'palette.dart';
import 'video_player_page.dart';

/// 「网盘视频」二级页：登录网盘 → 按单号后 6 位查 → 下到手机 → 播放。
///
/// ## ⚠️ 这一页 2026-10-01 之前是一个**壳**
///
/// 那时它的理由是「网盘那半在电脑端都还没做」（`04-实现决策` §49.7）。
/// **那个理由已经过期**：电脑端批次 5 做完了，手机端这一页也真接上了。
///
/// ## 登录有两条路，缺一不可
///
/// | | 什么时候用 | 令牌从哪来 |
/// |---|---|---|
/// | **向电脑端借** | 日常（人在店里，手机和电脑在同一个局域网） | 电脑端已经登着网盘，借一个现成的 |
/// | **自己登录** | 人在外面，连不上电脑端 | 手机走百度**简化模式**自己授权 |
///
/// ⚠️ 自己登录那条**没有 refresh_token**（简化模式不发），而且**刷新那一步本身
/// 也要 client_secret**（文档 007）——所以手机自己登的这一份 **30 天后必须重新
/// 授权一次**。这是平台给的约束，界面上要说给用户听，不能装作没这回事。
class NetdiskPage extends StatefulWidget {
  const NetdiskPage({
    super.key,
    required this.client,
    required this.rootPath,
    this.onScan,
  });

  /// 连电脑端那个客户端。**没配对时是 null** —— 那时只剩「自己登录」那条路。
  final UploadClient? client;

  /// 应用数据目录（令牌与下载都落在它下面）。
  final String rootPath;

  /// 扫一张面单，返回**面单上的原文**；用户返回就是 `null`。
  ///
  /// ⚠️ 由调用方注入，而不是这一页自己开相机：开相机要 `RecorderGateway` 与
  /// **生效的**录制规格，那两样只有录制页手上有；而且「这一页之前相机就开着的话
  /// **不能关**」那条讲究（录制中、或发货栏的取景框还开着）也跟着一起过来。
  /// 没传就**不摆**扫码那颗按钮 —— 摆一个按不动的更糟。
  final Future<String?> Function(BuildContext context)? onScan;

  @override
  State<NetdiskPage> createState() => _NetdiskPageState();
}

class _NetdiskPageState extends State<NetdiskPage> {
  late final NetdiskSession _session;
  late final NetdiskDownloads _downloads;

  final _digits = TextEditingController();
  final _pasted = TextEditingController();

  NetdiskGrant? _grant;
  BaiduPanClient? _pan;

  List<NetdiskFile>? _results;
  NetdiskQuota? _quota;
  String? _note;
  bool _busy = false;

  /// 正在下载的那一条，以及它下到哪了（0~1）。没在下载时为 null。
  NetdiskFile? _downloading;
  double _progress = 0;

  /// 已下好的：远端路径 → 本机路径。点标题就直接播，不用再下一次。
  final _local = <String, String>{};

  @override
  void initState() {
    super.initState();

    _downloads = NetdiskDownloads(widget.rootPath);
    _session = NetdiskSession(
      // ⚠️ 没配对时**不装作能借**：`fetchFromHost` 直接说「连不上电脑端」，
      // 让 `NetdiskSession` 走它那条「退回本机那份」的路。
      fetchFromHost: widget.client?.netdiskToken ??
          () async => const NetdiskGrant(
                status: NetdiskGrant.failed,
                message: '这台手机还没和电脑端配对，借不到令牌 —— 用下面的【自己登录网盘】。',
              ),
      store: NetdiskTokenStore('${widget.rootPath}/netdisk-token.json'),
    );

    unawaited(_restore());
  }

  @override
  void dispose() {
    _digits.dispose();
    _pasted.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    await _session.restore();

    // ⚠️ 落盘那份可能早就过期了（自己登的那份没有续期能力）。过期就当没有 ——
    // 拿一串过期的去调网盘，报回来的是与「过期」毫无关系的错。
    final cached = _session.cached;
    if (cached != null && cached.expiredAt(DateTime.now())) {
      await _session.token();
    }

    if (!mounted) return;
    _adopt(_session.cached);
  }

  /// 把一份令牌用起来（或者收拾干净）。
  void _adopt(NetdiskGrant? grant) {
    setState(() {
      _grant = grant;

      // ⚠️ 三个字段齐了才建客户端：少一个（比如没有应用名）建出来的东西
      // 拼不出 `/apps/<它>/`，调什么都报「目录不存在」。
      _pan = grant != null && grant.isOk
          ? BaiduPanClient(
              accessToken: grant.accessToken!,
              appName: grant.appName!,
            )
          : null;
    });
  }

  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _note = null;
    });

    try {
      await body();
    } on Object catch (error) {
      if (!mounted) return;

      final failure = error is NetdiskFailure ? error : null;

      // ⚠️ 授权不管用了（errno -6 / 20016 / 20017 / 31045）时，**把那两扇门重新摆出来**：
      // 这一页会退回「还没登录」那一屏，而那一屏上就是【连电脑端】与【自己登录网盘】。
      // 只抛一句「errno 31045」等于把用户扔在原地 —— 他知道出事了，但不知道该按哪儿。
      if (failure != null && failure.isAuthFailure) {
        // ⚠️ **要留痕**：这一步把用户的令牌摘了，他下次回来会问「怎么又要我登录」。
        // 失败的那一刻过后，只有日志答得上来是哪一个码把它摘的。
        AppLog.instance.warn('网盘', '授权不管用了，退回登录那一屏', data: {
          'errno': failure.errno,
        });

        _adopt(null); // 它自己会 setState
        setState(() => _note = '网盘的授权不管用了（这个模式不能续期，或者后台被取消了）——'
            '重新登录一次：在店里用【连电脑端】，人在外面用【自己登录网盘】。');
        return;
      }

      setState(() => _note = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ─────────────────────────────────────────────
  // 登录
  // ─────────────────────────────────────────────

  Future<void> _connect() => _run(() async {
        final grant = await _session.token();
        if (!mounted) return;

        _adopt(grant.isOk ? grant : null);
        if (!grant.isOk) setState(() => _note = grant.message);
      });

  /// 打开百度授权页。
  ///
  /// ⚠️ 用 `redirect_uri=oob`：百度会把结果**显示在一个页面上**，用户复制回来。
  /// 所以下面那个粘贴框**不是兜底，是这条路的一环**。
  Future<void> _openAuthorizePage() => _run(() async {
        final url = buildImplicitAuthorizeUrl(
          appKey: baiduAppKey,
          redirectUri: baiduOobRedirect,
        );

        final opened = await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        );

        if (!mounted) return;

        setState(() => _note = opened
            ? '浏览器里登录并同意之后，那一页上会显示一串令牌 —— 复制它，粘到下面框里。'
            : '打不开浏览器。手动打开这个网址也一样：\n$url');
      });

  Future<void> _usePasted() => _run(() async {
        // ⚠️ 应用名从**现有的那份令牌**里取：简化模式不回这个东西，
        // 而远端根 `/apps/<应用名>/` 处处要用它。手上有过借来的那份就有。
        final appName = _grant?.appName;
        if (appName == null || appName.isEmpty) {
          setState(() => _note = '还缺「应用名」—— 先在店里连一次电脑端（借一次令牌），'
              '它会把应用名一起带过来。自己登录这一步要靠它拼网盘目录。');
          return;
        }

        final grant = parsePastedCredential(_pasted.text, appName: appName);
        if (!grant.isOk) {
          setState(() => _note = grant.message);
          return;
        }

        await _session.store.save(grant);
        if (!mounted) return;

        _pasted.clear();
        _adopt(grant);
        setState(() => _note = '已登录。这一份 30 天后要重新授权一次（这个模式不能续期）。');
      });

  Future<void> _signOut() => _run(() async {
        await _session.store.clear();
        if (!mounted) return;

        _adopt(null);
        setState(() {
          _results = null;
          _quota = null;
          _note = '已从这台手机上退出。**网盘上的东西一个都没动。**';
        });
      });

  // ─────────────────────────────────────────────
  // 查 / 下 / 播
  // ─────────────────────────────────────────────

  Future<void> _search() => _run(() async {
        final pan = _pan;
        if (pan == null) return;

        final digits = _digits.text.trim();
        if (digits.isEmpty) {
          setState(() => _note = '先填单号的后 6 位（或者扫码）。');
          return;
        }

        final found = await pan.findByWaybillTail(digits);
        if (!mounted) return;

        setState(() {
          _results = found;
          _note = found.isEmpty
              ? '网盘上没找到单号后 6 位是「$digits」的录像。'
              : '找到 ${found.length} 条。';
        });
      });

  /// 扫一张面单 → 填进去 → **直接查**。
  ///
  /// ⚠️ 扫完顺手查一次，不再让用户按一遍【查询】：面单已经在手上了，
  /// 再点一下是纯粹多一步。⚠️ 但**扫到的不是面单**（解出来一个数字都没有）时
  /// 不查 —— 拿空串去问网盘只会把上一次的结果冲掉。
  Future<void> _scan() async {
    final onScan = widget.onScan;
    if (onScan == null) return;

    final scanned = await onScan(context);
    if (!mounted || scanned == null) return;

    final digits = lastSixDigits(scanned);

    setState(() {
      _digits.text = digits;
      if (digits.isEmpty) _note = '扫到的这一串里没有单号数字，没去查。';
    });

    if (digits.isNotEmpty) await _search();
  }

  Future<void> _loadQuota() => _run(() async {
        final pan = _pan;
        if (pan == null) return;

        final quota = await pan.quota();
        if (mounted) setState(() => _quota = quota);
      });

  Future<void> _download(NetdiskFile file) => _run(() async {
        final pan = _pan;
        if (pan == null) return;

        setState(() {
          _downloading = file;
          _progress = 0;
        });

        await _downloads.ensure();
        final link = await pan.dlink(file.path);
        final target = _downloads.pathFor(
          remotePath: file.path,
          fileName: file.name,
        );

        await pan.download(
          link,
          target,
          onProgress: (received, total) {
            if (!mounted || total <= 0) return;
            // 按**字节**算百分比：用户看到的是「下了多少」，
            // 而分片、缓冲这些是内部的事。
            setState(() => _progress = (received / total).clamp(0, 1).toDouble());
          },
        );

        if (!mounted) return;

        setState(() {
          _local[file.path] = target;
          _downloading = null;
          _progress = 0;
        });
      });

  void _play(NetdiskFile file) {
    final path = _local[file.path];
    if (path == null) return;

    unawaited(VideoPlayerPage.open(context, path: path, title: file.name));
  }

  // ─────────────────────────────────────────────
  // 界面
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('网盘视频')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 加载态（T10）。⚠️ 一根**说不清进度**的细线，不是假百分比：
          // 查一次要把目录一页页翻完（最多 20 页），慢起来好几秒，
          // 而这几秒里原来只有「按钮灰了」这一个信号 —— 那与「按不动」分不开。
          if (_busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
          ],
          if (_note != null) ...[
            Card(
              color: Palette.amberTint,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _note!,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          _accountCard(),
          const SizedBox(height: 12),
          if (_grant?.isOk == true) ...[
            _quotaCard(),
            const SizedBox(height: 12),
            _searchCard(),
            const SizedBox(height: 12),
            _resultsCard(),
          ],
        ],
      ),
    );
  }

  Widget _accountCard() {
    final connected = _grant?.isOk == true;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('网盘账号', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              connected
                  ? _connectedLine()
                  : '还没登录。日常在店里用【连电脑端】；人在外面用【自己登录网盘】。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('netdisk-login'),
                  // ⚠️ 没配对时**这条按不动**（不是点了没反应）：借令牌那条路
                  // 本来就要电脑端，灰着并说明原因，比让它失败一次强。
                  onPressed: _busy || widget.client == null ? null : _connect,
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('连电脑端取授权'),
                ),
                OutlinedButton.icon(
                  key: const Key('netdisk-self-login'),
                  onPressed: _busy ? null : _openAuthorizePage,
                  icon: const Icon(Icons.open_in_browser, size: 18),
                  label: const Text('自己登录网盘'),
                ),
                if (connected)
                  TextButton.icon(
                    key: const Key('netdisk-logout'),
                    onPressed: _busy ? null : _signOut,
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('退出登录'),
                  ),
              ],
            ),
            if (widget.client == null) ...[
              const SizedBox(height: 6),
              Text(
                '（这台手机还没和电脑端配对，所以【连电脑端】是灰的。）',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: Palette.muted),
              ),
            ],
            if (!connected) ...[
              const SizedBox(height: 12),
              TextField(
                key: const Key('netdisk-paste'),
                controller: _pasted,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '把授权页上那串令牌粘到这里',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('netdisk-paste-confirm'),
                onPressed: _busy ? null : _usePasted,
                child: const Text('用这一串登录'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _connectedLine() {
    final expiry = _grant?.expiresAt;
    if (expiry == null) {
      return '已连接（借用电脑端的授权，它会自己续期）。';
    }

    final days = expiry.difference(DateTime.now()).inDays;
    return '已连接（手机自己登的，${expiry.year}-${_two(expiry.month)}-${_two(expiry.day)} 到期'
        '${days >= 0 ? '，还有 $days 天' : ''}）。⚠️ 这个模式不能续期，到期要重新授权一次。';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  Widget _quotaCard() {
    final quota = _quota;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('网盘容量', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton(
                  key: const Key('netdisk-quota-refresh'),
                  onPressed: _busy ? null : _loadQuota,
                  child: const Text('查一下'),
                ),
              ],
            ),
            if (quota == null)
              Text('还没查。', style: Theme.of(context).textTheme.bodySmall)
            else ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: quota.usedRatio),
              const SizedBox(height: 8),
              // ⚠️ 三个数都要给：「还剩多少」与「一共多大」分开看，
              // 用户才知道是该清理还是该扩容。
              Text(
                '已使用 ${_gb(quota.used)} · 剩余 ${_gb(quota.free)} · 总空间 ${_gb(quota.total)}',
                key: const Key('netdisk-quota-text'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 字节 → GB。保留一位小数：网盘动辄几百 GB，再多的小数位没有意义。
  static String _gb(int bytes) => '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';

  Widget _searchCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('查录像', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                '填单号的后 6 位，或者拿扫码枪扫面单上的单号。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('netdisk-search'),
                      controller: _digits,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '单号后 6 位',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('netdisk-search-go'),
                    onPressed: _busy ? null : _search,
                    child: const Text('查询'),
                  ),
                  // ⚠️ 没传 `onScan` 时**整颗不摆**（不是灰着）：这一页的调用方
                  // 一定拿得到 gateway，摆一颗按不动的只会让人以为相机坏了。
                  if (widget.onScan != null) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      key: const Key('netdisk-scan'),
                      onPressed: _busy ? null : _scan,
                      icon: const Icon(Icons.qr_code_scanner, size: 18),
                      label: const Text('扫码'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      );

  Widget _resultsCard() {
    final results = _results;
    if (results == null) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('查到的录像', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (results.isEmpty)
              Text('这一条没查到。', style: Theme.of(context).textTheme.bodySmall)
            else
              ...results.map(_resultRow),
          ],
        ),
      ),
    );
  }

  Widget _resultRow(NetdiskFile file) {
    final downloading = _downloading?.path == file.path;
    final local = _local[file.path];

    return ListTile(
      key: Key('netdisk-file-${file.fsId}'),
      contentPadding: EdgeInsets.zero,
      title: Text(file.name, style: Theme.of(context).textTheme.bodyMedium),
      subtitle: Text(
        _gb(file.size),
        style: Theme.of(context).textTheme.labelSmall,
      ),
      trailing: local != null
          // 下好了就只剩「播放」—— 再下一次是白费流量。
          ? FilledButton.tonal(
              key: Key('netdisk-play-${file.fsId}'),
              onPressed: () => _play(file),
              child: const Text('播放'),
            )
          : downloading
              ? SizedBox(
                  width: 76,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      LinearProgressIndicator(value: _progress),
                      const SizedBox(height: 4),
                      // ⚠️ 百分比要**看得见数**，不能只有一根条：
                      // 「还要多久」是用户此刻唯一想知道的事。
                      Text(
                        '${(_progress * 100).toStringAsFixed(0)}%',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                )
              : OutlinedButton(
                  key: Key('netdisk-download-${file.fsId}'),
                  onPressed: _busy ? null : () => _download(file),
                  child: const Text('下载'),
                ),
    );
  }
}
