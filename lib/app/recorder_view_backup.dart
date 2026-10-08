// ignore_for_file: invalid_use_of_protected_member
//
// ⚠️ 上面这条是这套拆法**必须付的价**，不是图省事：`State.setState` 带
// `@protected`，而分析器不把 `extension on _RecorderPageState` 认作
// 「State 的子类内部」，于是本文件里每一处 `setState(` 都报这一条。
// 语言本身允许（同一个 library、编译通过、测试全绿）—— 那是 lint 的误报，
// 它判的是「在不在子类里」，认不出 extension。只收窄这一条规则，
// 不做 `ignore_for_file: all`。
part of 'recorder_page.dart';

// T26③ 第 2 轮：从 `recorder_page.dart` 整段搬过来的 —— **纯搬家**。
// 一行都没改（`diff` 可证），只是位置换了。
//
// ⚠️ 是 `extension on _RecorderPageState`，不是独立的类：同 library 的
// extension 读得到私有成员，且跨 extension 调用**不带前缀**就能解析 ——
// 所以搬走它们一个字都不用改调用点。理由详见 `recorder_page.dart` 里
// `part` 那一段注释。

extension on _RecorderPageState {

  String get _tabTitle => switch (_tab) {
        0 => '备份',
        1 => '发货',
        2 => '退货',
        _ => '设置',
      };

  /// 备份页：本机身份 → 三个统计 → 电脑备份 → 录像记录。
  ///
  /// ## 为什么这一页先做
  ///
  /// 规格 §3.4.3 标着 ★，原文写明它来自一次**真实故障**：原系统上传失败后
  /// 进入终态、永不重试，用户完全不知道数据没传上去。那类故障的第一道防线
  /// 不是重试次数，是**看得见**。
  ///
  /// ⚠️ **只显示盘上真有的东西**：已收尾的录像、盘上的实际占用、探测得到的
  /// 连通性。不放剩余空间、不放上传进度条 —— 那些今天一个都测不出来，
  /// 而假数字在真机上会被当成真的（这个项目吃过一次亏）。
  ///
  /// ## 2026-09-27：照需求方第三张自绘草图重做
  ///
  /// 外观几乎全变（卡片化 → 标题 + 三张独立卡 + 通栏按钮），
  /// 功能**只加不减**。逐条改动与两处「图上画了、没做」记在
  /// `docs/实现决策.md` §46。
  Widget _backupPage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _identityHeader(),
        const SizedBox(height: 16),
        _statsRow(),
        const SizedBox(height: 12),
        _hostCard(),
        const SizedBox(height: 12),
        _recordsCard(),
      ],
    );
  }

  // ── ① 本机身份 ───────────────────────────────

  /// 顶部身份区（2026-09-27 照草图从「一张卡 + 两个胶囊」改成标题区）。
  ///
  /// 草图上这里是：大字号机位名 + 一个绿点 + 局域网 IP，下面一行产品名，
  /// 右端一个连通性胶囊。**不再是卡片**。
  ///
  /// ⚠️ 机位名必须**可改**（需求方 2026-09-22：电脑端靠它区分机位，而且要能改），
  /// 而草图上没有铅笔。所以铅笔留在名字右边 —— 只是做小了。
  /// 一个能改却看不出能改的名字，用户不会发现，只会以为改不了（踩坑 #13）。
  ///
  /// ⚠️ 那个绿点说的是**局域网通不通**（有这个地址才点得亮），不是「有网」——
  /// 手机端今天**测不出**「本机能不能上公网」，画成一个笼统的「在线」
  /// 就是一个测不出来的状态（§13.1 那条自律）。
  ///
  /// ⚠️ 名字是 `Flexible` + 省略号：它是**用户自己敲的**，敲一个长名字
  /// 就足以把这一行撑爆，而溢出的后果是黄黑条，不是「难看一点」。
  Widget _identityHeader() {
    final identity = _identity;
    final ip = _lanIp;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      identity?.deviceName ?? defaultDeviceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: '改本机名',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.edit_outlined,
                      size: 15,
                      color: context.palette.faint,
                    ),
                    onPressed: identity == null ? null : _editDeviceName,
                  ),
                ],
              ),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: ip == null ? context.palette.faint : context.palette.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    ip ?? '未连局域网',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(color: context.palette.muted),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '电商发货 / 退货视频取证系统',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.palette.muted),
              ),
            ],
          ),
        ),
        _hostPill(),
      ],
    );
  }

  /// 顶部右上角那个胶囊：**电脑端在不在**。
  ///
  /// ⚠️ 草图上写的是「设备在线」，而**手机端测不出「本机能不能上公网」** ——
  /// 照那个字面落下来就是一个测不出来的状态（§13.1）。
  /// 所以这里如实写「电脑端在线 / 电脑端离线 / 未连接」，
  /// 判据与下面那张卡**同一个**（`_hostOnline` + 地址 + 凭据）。
  ///
  /// ⚠️ 草图上它右边有个 `›`，**没画** —— 它要指的是下面那张卡，
  /// 而那张卡就在同一屏上；画一个点不动的箭头正是踩坑 #13。
  /// （这一页上保留下来的每一个 `›` 都真的去得了地方：行进详情页、
  /// 【管理】进批量模式。）
  Widget _hostPill() {
    final identity = _identity;
    final paired = (identity?.credential ?? '').isNotEmpty;
    final hasHost = (identity?.hostAddress ?? '').isNotEmpty;
    final online = hasHost && paired && _hostOnline;

    final text = !hasHost || !paired
        ? '未连接'
        : (_probingHost
            ? '探测中…'
            : (online ? '电脑端在线' : '电脑端离线'));

    // 只有「在线」是绿的，其余三种（未连接 / 探测中 / 离线）是同一支灰。
    // 改版前这里写了 `grey` 两次、`green` 一次，底还要各自再兑一次透明度。
    final (fg, bg) = (!hasHost || !paired || _probingHost || !online)
        ? (context.palette.muted, context.palette.hairline)
        : (context.palette.green, context.palette.greenTint);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Corners.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 7, color: fg),
          const SizedBox(width: 5),
          Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: fg)),
        ],
      ),
    );
  }

  // ── ② 本机今日 / 本机全部 / 总占用 ──────────────

  /// 三个数字，**三张独立的小卡**（2026-09-27 照草图；原先是三格 + 细分隔线）。
  ///
  /// 三个口径都是**需求方 2026-09-22 定的**，标字是 2026-09-27 照草图定的：
  /// - **本机今日** = 起录时间落在今天 0:00~23:59 的条数
  /// - **本机全部** = 录到的总条数，**一个单号从开始到结束算一条**（不是索引行数）
  /// - **总占用** = 盘上视频的**实际**大小；传到电脑后删掉手机上的，就按删后的算
  ///
  /// ⚠️ 「本机今日」这四个字比上一版的「本机」+ 注「今日录的」好：
  /// 那个「本机」会和旁边那块「本机全部」撞车（§13.4 记着这一处歧义）。
  ///
  /// ⚠️ 总占用可能**大于**上面那些条的大小之和 —— 它含还没走完收尾的孤儿片段。
  /// 它答的是「这些视频在手机上占了多少地方」，不是「已入库的占了多少」。
  /// 这一版把上一版那句注「手机上现存」去掉了（草图没有），**那句注要留着**：
  /// 去掉之后这个数会被读成「已经入库的占了多少」，而它其实含孤儿片段。
  /// 所以它挂在下面那行小字上（见 [_statCard] 的 `note`）。
  Widget _statsRow() {
    final used = _sizeParts(_videoBytes);

    // ⚠️ `IntrinsicHeight` 是为了让三张卡**一样高**（右边那张多一行小注，
    // 不等高的话三张卡顶边齐、底边参差，看着像坏了）。
    //
    // ⚠️ **不能只在 `Row` 上写 `CrossAxisAlignment.stretch`** ——
    // 这一页是个 `ListView`，纵向没有约束，stretch 会往下传一个
    // `h=Infinity`，直接 `BoxConstraints forces an infinite height` 崩掉。
    // `IntrinsicHeight` 先量出最高的那一张，再把那个高度给三张。
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _statCard(
              icon: Icons.videocam_outlined,
              tint: context.palette.primary,
              tintBg: context.palette.blueTint,
              value: '$_todayCount',
              label: '本机今日',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _statCard(
              icon: Icons.layers_outlined,
              tint: context.palette.primary,
              tintBg: context.palette.blueTint,
              value: '${_sessions.length}',
              label: '本机全部',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _statCard(
              icon: Icons.storage_outlined,
              tint: context.palette.violet,
              tintBg: context.palette.violetTint,
              value: used.value,
              unit: used.unit,
              label: '总占用',
              note: '含没收尾的片段',
            ),
          ),
        ],
      ),
    );
  }

  /// 一张统计小卡：彩色图标 + 大数字 + 标字（+ 可选的一行小注）。
  ///
  /// ⚠️ 数字套 `FittedBox`：总占用带单位（`6.9 GB`），而窄屏上三张卡
  /// 每张只有一百来像素 —— 不缩的话要么溢出、要么被省略号截成 `6.…`
  /// （数字被截断比难看糟得多，用户会当成真的）。
  Widget _statCard({
    required IconData icon,
    required Color tint,
    required Color tintBg,
    required String value,
    String? unit,
    required String label,
    String? note,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: tintBg,
                // 草图上这三个是**圆**，不是圆角方。尺寸与图标都不动 ——
                // 草图改的只是那个形状（§47）。
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 19, color: tint),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 2),
                  Text(
                    unit,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.palette.muted),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.palette.muted),
            ),
            if (note != null)
              Text(
                note,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: context.palette.muted),
              ),
          ],
        ),
      ),
    );
  }

  // ── ③ 电脑备份 ───────────────────────────────

  /// 配对电脑 + 连通性 + 那个最要紧的数字。
  ///
  /// ⚠️ 「连接 / 离线」探的是**电脑端那台机器**（M3 已经在 8720 端口上开着的
  /// HTTP 服务），既不代表本机有网，也不代表「备份通道建好了」——
  /// 上传代码（M5）2026-09-23 已经写完，所以这一页现在**直接说备份状态**
  /// （`N 个未备份` + 每条的小标），而不是靠一句免责声明兜着。
  /// 那个绿色小字仍然不能自己单独解释自己：**它旁边必须有那个数字。**
  ///
  /// ## 2026-09-27 照需求方草图重排
  ///
  /// 三处变化，没有一处是纯外观：
  ///
  /// 1. **「N 个未备份」提到最上面、加大加粗** —— 它是整页最要紧的一句话
  ///    （需求方 2026-09-23 原话：「58个未备份，连接后自动备份」）。
  ///    原来它夹在标题和四行键值表中间，是这一页上最小的一行字。
  /// 2. **右上角那个垃圾桶 = 断开配对**（需求方 2026-09-27 定的）。
  ///    ⚠️ 它**一条录像都不碰**，这句话写在弹窗的第一段和确认按钮的字上。
  /// 3. 四行键值表换成一行「名字 · 地址」。表格里那三个标签
  ///    （电脑端名字 / 局域网 IP / 配对）里，用户故障时真正要找的是
  ///    「它认得我吗」和「我该点哪个按钮」—— 那两样现在都在下面。
  ///
  /// ⚠️ 那个橙色感叹号**去掉了**：它原来只说「这儿有事」，是什么事要看下面。
  /// 现在右上角的胶囊直接把状态写成了字（「未配对」「电脑端离线」），
  /// 一个说不清是什么事的图标就不必留了。
  ///
  /// ⚠️ 【配对电脑】与【扫码连接】原来是**两个按钮、同一个动作**
  /// （都调 `_pairHost`，都是开扫码页）—— 两个标签做同一件事，
  /// 用户会以为它们不一样。合成一个，标签随配对状态变。
  Widget _hostCard() {
    final identity = _identity;
    final name = identity?.hostName ?? '';
    final address = identity?.hostAddress ?? '';
    final hasHost = address.isNotEmpty;
    // 「配对过」与「填了地址」是**两件事**：填了地址只说明知道去哪儿找它，
    // 配对过才说明它认这台手机的凭据（能把包收下）。
    final paired = (identity?.credential ?? '').isNotEmpty;
    final online = hasHost && paired && _hostOnline;

    // 还有多少条没备份上去 —— **这是整页最要紧的那个数字**
    // （需求方 2026-09-23 照草图加的：「58个未备份，连接后自动备份」）。
    //
    // 判定与列表上那个小标**共用 `summarizeUploadState`**：两处各写一套的话，
    // 迟早出现「上面说 3 个没备份、下面每一条都写着已备份」，而用户没有任何
    // 办法判断哪个才对。
    //
    // ⚠️ 归档状态还没读出来（`_archiveRecords` 空）时，这里会把所有录像都算成
    // 未备份。**这个方向是对的** —— 与 `summarizeUploadState` 同一条规矩：
    // 宁可说「还没备份」，也不能说「已备份」。
    final pending = _sessions
        .where((session) =>
            summarizeUploadState(session.evidenceIds, _archiveRecords) !=
            UploadState.archived)
        .length;

    return Card(
      child: Padding(
        // 右边只留 6：右上角那个垃圾桶是 `IconButton`，它自带一圈内边距。
        padding: const EdgeInsets.fromLTRB(16, 10, 6, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 草图上「电脑备份」前面是一个**实心蓝圆 + 白色显示器**。
                // 尺寸与三张统计卡的图标底**同档**（34 的圆 / 19 的图标）——
                // 这一页上「图标装在一个色块里」只有这一种画法，
                // 两个尺寸会看起来像两种东西（§47）。⚠️ 圆，不是圆角方。
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    // ⚠️ 同 `_settingCard`：实心块读 `primarySolid`。
                    color: context.palette.primarySolid,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.monitor, size: 19, color: Palette.onDark),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '电脑备份',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _pairedPill(hasHost: hasHost, paired: paired),
                _forgetButton(hasHost: hasHost, paired: paired),
              ],
            ),
            if (_sessions.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                pending > 0
                    ? '$pending 个未备份，${paired ? '连上电脑后会自动传过去' : '连接后自动备份'}'
                    : '${_sessions.length} 个都已经备份到电脑端了。',
                style: 
                  // 加大加粗：整页最要紧的一句话，原来它是这一块最小的字。
                  Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: pending > 0 ? FontWeight.w600 : FontWeight.w400, color: pending > 0 ? context.palette.ink : context.palette.green),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              hasHost
                  ? '${name.isEmpty ? '电脑端' : name} · $address'
                  : '还没填电脑端地址。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.palette.muted),
            ),
            if (_nextRetryAt != null)
              Text(
                '下次自动重试 ${_stamp(_nextRetryAt!)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.palette.muted),
              ),
            const SizedBox(height: 10),
            // 主按钮**通栏**（照草图）：这一页上用户最常做的一件事就是
            // 「现在传一下」，给它一整行的宽度。
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                // 没配对就点不动，而**为什么点不动**写在上面那行状态和
                // 那段说明里 —— 一个点了没反应的按钮和一句没头没尾的禁用一样糟
                // （踩坑 #13）。
                onPressed: (!paired || _uploading) ? null : () => _runUploads(manual: true),
                icon: _uploading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload_outlined, size: 18),
                label: Text(_uploading ? '备份中…' : '立即备份'),
              ),
            ),
            const SizedBox(height: 2),
            // `Wrap` 而不是 `Row`：窄屏上一行排不下，硬塞会把最后那个
            // 挤出屏幕外面 —— 而**被挤出去的那个会显得像根本没做**。
            Wrap(
              spacing: 4,
              children: [
                if (hasHost)
                  TextButton(
                    onPressed: identity == null ? null : _probeHost,
                    child: Text(online ? '重新搜索' : '重新连接'),
                  ),
                // 扫码连接：**主路径**（规格 §3.4.5 ①）。电脑端上点
                // 【连接电脑/手机】弹出二维码，这里扫它 —— 用户不用手输任何东西。
                TextButton(
                  onPressed: identity == null ? null : _pairHost,
                  child: Text(paired ? '重新配对' : '扫码连接'),
                ),
                TextButton(
                  onPressed: identity == null ? null : _editHost,
                  child: Text(hasHost ? '改电脑端地址' : '填电脑端地址'),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              !paired
                  ? '还没和电脑端配对，录像传不上去。'
                      '这些录像现在只在这台手机上，手机丢了就没了。'
                  : (online
                      // I1 的原文口径：**收到回执之前不清理**。这里说的是同一件事，
                      // 只是用用户的话说。
                      //
                      // ⚠️ 末句原来写着「按保留期自动清理还没做（M6）」，那句**已经过期**：
                      // 执行层 2026-09-27 就补上了（`cleanup_executor.dart`），
                      // 触发点在启动时（本文件 `_offerCleanup`）。
                      // 而且按规格 §3.5.5「禁止静默清理」，它**永远**不会「自动」跑 ——
                      // 所以这里不能说「以后会自动清」，那是给用户一个不会兑现的承诺。
                      ? '收尾好的录像会自己传到电脑端。'
                          '在收到电脑端的回执之前，手机上那份不会删 —— '
                          '按保留期的清理也不会自己跑：每次开 App 会先算一遍、问过你才删。'
                      : '电脑端现在不在线，可重新连接。'
                          '收尾好的录像会在连上之后自己传过去。'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              '手机连不上电脑端时，用【改电脑端地址】把二维码里那串地址改成对的，再重扫一次。'
              '（一台电脑可能同时插着有线、无线和虚拟网卡，它挑出来的地址不一定是你能连上的那个。）',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: context.palette.muted),
            ),
          ],
        ),
      ),
    );
  }

  /// 「已配对 / 未配对」，贴在「电脑备份」那一行的右端。
  ///
  /// ⚠️ 它与页面顶端那个「电脑端在线 / 离线」**不是一回事**，也不是重复：
  /// 这个说的是**它认不认这台手机**（有没有凭据），那个说的是**它现在在不在**。
  /// 合成一个的话，「在线但没配对」会显示成「在线」，而上传照样一条也传不上去。
  ///
  /// **没配对就说「未配对」，不说「离线」。** 「离线」会让人以为
  /// 「配对过、只是没连上」，而真实情况是**根本没配过对** ——
  /// 这两件事要修的东西不一样（改地址 vs 重新扫码）。
  Widget _pairedPill({required bool hasHost, required bool paired}) {
    final text = paired ? '已配对' : '未配对';
    final (fg, bg) = paired
        ? (context.palette.green, context.palette.greenTint)
        : (context.palette.muted, context.palette.hairline);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Corners.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(paired ? Icons.link : Icons.link_off, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: fg)),
        ],
      ),
    );
  }

  /// 右上角那个垃圾桶 = **断开配对**（需求方 2026-09-27 照草图定的）。
  ///
  /// ⚠️ 没配过对、也没填过地址时**不显示** —— 没有关系可断，
  /// 而一个点了没反应的图标和一句没头没尾的禁用一样糟（踩坑 #13）。
  Widget _forgetButton({required bool hasHost, required bool paired}) {
    if (!hasHost && !paired) return const SizedBox.shrink();

    return IconButton(
      key: const Key('host-forget'),
      // tooltip 写「断开配对」而不是「删除」：这个图标离「删录像」太近了，
      // 鼠标停上去（真机上是长按）必须看到它到底删的是什么。
      tooltip: '断开配对',
      visualDensity: VisualDensity.compact,
      icon: Icon(Icons.delete_outline, size: 20, color: context.palette.faint),
      onPressed: _forgetHost,
    );
  }

  /// 忘掉这台电脑端。
  ///
  /// ⚠️ **一条录像都不碰。** 清掉的只是配对关系：地址 / 端口 / 名字 / 凭据
  /// （见 `DeviceIdentity.forgetHost`）。这个图标离「删录像」太近了，
  /// 所以弹窗第一句和确认按钮上的字都必须说着同一件事。
  ///
  /// ⚠️ 断开之后**必须重新走一遍入网**（契约 §1.1 步骤 4：凭据丢失 →
  /// 重新入网，**不得降级为免凭据**）—— 所以弹窗里要写明「得重新扫码」，
  /// 不然用户会以为断开只是「先歇一会儿」。
  Future<void> _forgetHost() async {
    final identity = _identity;
    if (identity == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开和这台电脑端的配对？'),
        content: const Text(
          '只是让这台手机忘掉电脑端的地址和配对凭据。\n\n'
          '手机上录的、电脑上存着的录像，一条都不动。\n\n'
          '断开之后录像传不上去，要用的时候得重新扫一次电脑端的二维码。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('host-forget-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('断开配对'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    await identity.forgetHost();

    // ⚠️ `Uploader` 与 `_client` 都是**照着地址和凭据造出来的**（见 `_buildUploader`）。
    // 不重建的话它们还攥着刚被清掉的那份凭据 —— 界面上写着「未配对」，
    // 而底下还在往那台电脑传，还是拿一个对方已经不该认的凭据。
    _buildUploader();
    _hostOnline = false;

    _log('已断开与电脑端的配对（一条录像都没动）');
    if (mounted) setState(() {});
  }

  /// 一条录像的备份状态。
  ///
  /// **六段传到五段也是「备份失败」** —— 列表上写「已备份」而实际缺一段，
  /// 正是这一页要防的那种假话（见 `summarizeUploadState`）。
  Widget _uploadChip(RecordingSession session) {
    final state = summarizeUploadState(session.evidenceIds, _archiveRecords);
    final look = _uploadLook(state);

    // 失败的那一格**可以点**：点开是「为什么没传上去」和一个【再试一次】。
    // 规格 §3.4.3 ★：失败必须可见，而且必须有个能救回来的入口 ——
    // 一个只报错、不给出口的界面，故障照旧收不了场。
    if (state == UploadState.failed) {
      return ActionChip(
        visualDensity: VisualDensity.compact,
        backgroundColor: look.tint,
        avatar: Icon(Icons.error_outline, size: 16, color: look.color),
        label: Text(look.text, style: TextStyle(color: look.color)),
        onPressed: () => _showUploadFailure(session),
      );
    }

    return Chip(
      visualDensity: VisualDensity.compact,
      backgroundColor: look.tint,
      label: Text(look.text, style: TextStyle(color: look.color)),
    );
  }

  /// 手动删除这一条（规格 §3.5.6）。
  ///
  /// ## 顺序是刻意的：**先回查，再弹窗**
  ///
  /// 规格 ③ 要求「删之前必须回查归档层」，而回查的结果**决定了**弹哪一种窗：
  /// 查不到 / 查不了时**根本不该弹「确认删除」** —— 弹了就等于把一个
  /// 系统已经知道不该做的动作交给用户去点。所以顺序是：
  ///
  /// ```
  /// 已备份 ⇒ 逐段回查 ⇒ 都还在 ⇒ 两选一窗
  ///                  ⇒ 有查不到 / 查不了 ⇒ **不弹删除窗**，只告诉他为什么不能删
  /// 未备份 ⇒ 三选一窗（没有那份可查，需求方裁决过：这种也给删）
  /// ```
  /// 这一次录制锁着没有（规格 §3.6.5）。
  ///
  /// ⚠️ 判据用 `label_store.isEvidenceLocked` —— **与清理判定同一个函数**。
  /// 在界面里另写一个（比如直接比 `== 'true'`）会漏掉判据里的第三条
  /// 「**认不出来的值当锁着**」，于是出现「界面显示没锁、清理却把它保留了」
  /// —— 那个状态用户没机会理解。
}
