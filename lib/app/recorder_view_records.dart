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

  /// 备份页里的一行 —— **规格 §3.4.3 点名的七项**（2026-09-27 照草图重排）。
  ///
  /// | # | 那一项 | 落点 |
  /// |---|---|---|
  /// | ① | 标签（发货 / 退货） | 左边那道彩色竖条 + 副标题里那个「发货视频 / 退货视频」 |
  /// | ② | 缩略图 | 左边 56×56 的方块，抽帧失败时是占位图标 |
  /// | ③ | 播放按钮 | 缩略图上那个 ▶ 覆盖层 |
  /// | ④ | 单号 | 标题 |
  /// | ⑤ | 录制时间 | 副标题前半 |
  /// | ⑥ | 时长 | 副标题后半 |
  /// | ⑦ | 已上传 / 未上传 | 右端那个状态小标（**与总览共用同一个归并规则**） |
  ///
  /// ⚠️ **④ 是「列表里显示的名字」，不是磁盘文件名** ——
  /// 磁盘名与归档路径**一律不动**（改了会波及索引、检索、归档回查，
  /// 还要迁移已经录好的那些）。
  ///
  /// ⚠️ 2026-09-27 标题从 `单号.mp4` 改成**光一个单号**（照草图）——
  /// **这是一处需求变更**，记在母仓 `docs/01-行为规格书.md` §3.4.3。
  /// 搜索框仍然认 `单号.mp4` 那种输入（见 `matchesQuery`）。
  ///
  /// ⚠️ 行上那三个操作（锁定 / 交付 / 删除）**搬去了详情页**（点整行进）。
  /// 三个 20 像素的图标挤在右端，本来就是这一行上最挤的地方，而其中两个
  /// 是不可逆或半不可逆的（删除；交付存进相册就收不回来）——
  /// 搬进详情页意味着**按之前先看清这一条的完整信息**，可点区域也大了好几倍。
  Widget _recordTile(RecordingSession session) {
    final type = _businessTypeOf(session);

    return InkWell(
      // 整行可点：管理模式是「挑一条」，平时是「看这一条」。
      // ⚠️ 管理模式下**必须换成挑**，不能还是往详情页跳 ——
      // 用户正在按顺序勾选，半路跳走再回来会把勾的进度打断。
      onTap: _managing
          ? () => setState(() {
                if (!_selected.remove(session.sessionId)) {
                  _selected.add(session.sessionId);
                }
              })
          : () => _openDetail(session),
      child: Container(
        // ① 彩色竖条：发货蓝、退货橙、**判不出来时灰**。
        // 判不出来是真的会发生的（标签认不出就不写），灰色说的是
        // 「这一条我不知道是哪一类」，不是「它属于第三类」。
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: businessTypeLook(type).color, width: 3),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
        child: Row(
          children: [
            if (_managing) ...[
              // 勾选框是**另一个可点区域**（与整行分开）：整行可点时，
              // 想取消勾选的人很容易点到行上、结果又把它勾回去了。
              Checkbox(
                key: Key('pick-${session.sessionId}'),
                value: _selected.contains(session.sessionId),
                onChanged: (value) => setState(() {
                  if (value == true) {
                    _selected.add(session.sessionId);
                  } else {
                    _selected.remove(session.sessionId);
                  }
                }),
              ),
              const SizedBox(width: 4),
            ],
            _thumbnail(session),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ④ 显示名（单号不可能为空，见 `waybillOf`）
                  Text(
                    waybillOf(session),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  // ① 标签 + ⑤ 时间 + ⑥ 时长
                  //
                  // `Wrap`：窄屏上那个胶囊和后面那串日期排不下一行时，
                  // **换行**而不是把日期截掉 —— 日期是七项里的两项，不能少。
                  Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (type != null) _typeBadge(type),
                      Text(
                        '${_stamp(session.startedAt)} · ${_durationLabel(session.duration)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Palette.muted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            // ⑦ 上传状态
            _uploadChip(session),
            // `›`：它指向**详情页**（点整行就是那里），是个真的去处。
            // 这一页上保留下来的每一个 `›` 都是这样 —— 一个点不动的箭头
            // 正是踩坑 #13 说的那种「让用户猜」。
            if (!_managing)
              const Icon(Icons.chevron_right, size: 18, color: Palette.faint),
          ],
        ),
      ),
    );
  }

  /// 这一条是发货还是退货。判不出来时为 null（**不猜**）。
  BusinessType? _businessTypeOf(RecordingSession session) {
    for (final evidenceId in session.evidenceIds) {
      final raw = _labelsByEvidence[evidenceId]?[BusinessType.labelKey];
      final parsed = BusinessType.tryParse(raw);
      if (parsed != null) return parsed;
    }

    return null;
  }

  /// ① 标签。**带图标**（照草图）。
  ///
  /// ⚠️ 文字与颜色都**不能省**：「发货视频 / 退货视频」这几个字是唯一
  /// 分得清两类的东西 —— 只靠颜色的话，色弱的人分不出蓝和橙，
  /// 而这两栏的录像在业务上完全不是一回事。
  ///
  /// 颜色走 `businessTypeLook`（`palette.dart`）。**这里是唯一的定义处** ——
  /// 详情页那颗胶囊、这一页的行首竖条读的都是它。改版前这一页自己写了一个
  /// `_typeColor`、详情页又各写了一遍，于是列表上是一个橙、点进去是另一个橙。
  Widget _typeBadge(BusinessType type) {
    final look = businessTypeLook(type);
    final returning = type == BusinessType.returning;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: look.tint,
        borderRadius: BorderRadius.circular(Corners.tag),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            returning ? Icons.assignment_return_outlined : Icons.local_shipping_outlined,
            size: 12,
            color: look.color,
          ),
          const SizedBox(width: 3),
          // 名字走 `BusinessType.displayName` —— 与详情页那个胶囊同一个字符串。
          Text(
            type.displayName,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: look.color),
          ),
        ],
      ),
    );
  }

  /// ② 缩略图那一张图**本身**（不定尺寸，撑满父级）。
  ///
  /// ⚠️ 列表上的 56×56 和详情页上那一整块 16:9，**必须是同一帧、走同一个缓存**
  /// （`_thumbnails`）—— 各写一套的话详情页会重新抽一次帧，而
  /// 「不得每次进页面都重新抽帧」正是规格点名要防的。
  ///
  /// ⚠️ **抽帧是异步的、而且会缓存**，所以这里用 `FutureBuilder`：
  /// 第一帧是占位，抽好了自动换成图。
  Widget _thumbImage(RecordingSession session) {
    final evidenceId = session.evidenceIds.first;
    final videoPath = '$_rootPath/${_locationByEvidenceId[evidenceId] ?? ''}';

    return FutureBuilder<String?>(
      future: _thumbnails.thumbnailFor(evidenceId, videoPath),
      builder: (context, snapshot) {
        final path = snapshot.data;

        if (path == null) {
          return Container(
            color: Palette.hairline,
            child: const Icon(Icons.movie_outlined, size: 22, color: Palette.faint),
          );
        }

        return Image.file(File(path), fit: BoxFit.cover);
      },
    );
  }

  /// ② 缩略图 + ③ 播放按钮（列表里那一小块）。
  ///
  /// ⚠️ 2026-09-27 起**点一下就能播**，不再等抽帧成功 ——
  /// 抽帧失败不该连带把播放也锁上（那是两件事，而用户看到的是
  /// 「这行点了没反应」）。▶ 那个图标也**一直画着**，它才是「这里能点」的记号。
  ///
  /// 2026-09-27 从 48 放到 56（照草图）：48 那一档在副标题多一行时
  /// 显得比整行矮一截，缩略图就成了一块「贴上去的小方块」而不是这一行的头。
  Widget _thumbnail(RecordingSession session) {
    final evidenceId = session.evidenceIds.first;
    final videoPath = '$_rootPath/${_locationByEvidenceId[evidenceId] ?? ''}';

    return InkWell(
      // ③ 播放：交给**系统播放器**（不自己写播放器、不引 video_player）。
      onTap: () => _play(session, videoPath),
      child: SizedBox(
        width: 56,
        height: 56,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(Corners.thumb),
              child: _thumbImage(session),
            ),
            const Center(
              child: Icon(Icons.play_circle_fill, size: 22, color: Palette.onDarkSoft),
            ),
          ],
        ),
      ),
    );
  }

  /// 交付这一段（规格 §3.7）：**原样**存进系统相册 + 弹系统分享面板。
  ///
  /// ## 「只在归档层就先取回本地」
  ///
  /// 规格原话：「如视频不在电脑端或者手机端本地，那么……需要从存储中下载视频到本地，
  /// 然后分享」。所以本地副本不在时，先从电脑端取回来（`/media/{evidenceId}`，
  /// 就是回放页用的那个端点 —— 它已经在了，不必另开一个下载接口）。
  ///
  /// ⚠️ **不转码、不压缩、不裁剪**（§3.7.1）：整条路上没有任何处理视频的代码。
  ///
  /// ⚠️ §3.6.6：**打码整条不做**。交出去的成品里面单上的姓名电话地址**会原样跟出去**，
  /// 界面不许暗示做过隐私处理。
  Future<void> _shareSession(RecordingSession session) async {
    final root = _rootPath;
    final evidenceId = session.evidenceIds.first;
    var path = '$root/${_locationByEvidenceId[evidenceId] ?? ''}';

    try {
      if (!await File(path).exists()) {
        final fetched = await _fetchFromArchive(session, evidenceId);
        if (fetched == null) return;
        path = fetched;
      }

      final problem = await _gateway.shareVideo(path);

      if (problem != null) {
        // I3：交付失败必须说出来 —— 用户以为发出去了，而对方什么都没收到。
        _log('⚠️ 交付没成功：$problem');
        if (mounted) setState(() => _status = problem);
        return;
      }

      _log('📤 已交付 ${session.waybill.value}（存进相册并弹出分享）');
    } on Object catch (error) {
      _log('⚠️ 交付没能进行：$error');
      if (mounted) setState(() => _status = '交付没能进行：$error');
    }
  }

  /// 本地副本不在时，从归档层（电脑端）取回这一段。
  ///
  /// 取回来的那份落在 `<root>/` 下的临时位置 —— 它**不进索引**：
  /// 交付件不是录像（I7 改写后的落点），而索引只增不减。
  Future<String?> _fetchFromArchive(RecordingSession session, String evidenceId) async {
    final client = _client;
    final root = _rootPath;

    if (client == null) {
      if (mounted) setState(() => _status = '本地副本不在了，而电脑端还没配对 —— 没法取回来交付。');
      return null;
    }

    if (mounted) setState(() => _status = '本地副本不在了，正在从电脑端取回来…');

    final target = '$root/share/${session.waybill.value}.mp4';

    try {
      await client.downloadEvidence(evidenceId, target);
      _log('⬇️ 从电脑端取回了 ${session.waybill.value}');
      return target;
    } on Object catch (error) {
      if (mounted) setState(() => _status = '取不回来：$error');
      return null;
    }
  }

  /// 播放这一段。
  ///
  /// ⚠️ 走的是**自建播放器**（`VideoPlayerPage`），不再是原生那个 `playVideo`
  /// （系统播放器）。换掉的理由：安卓那边 `ACTION_VIEW` 是彻底失控的 ——
  /// 倍速 / 全屏 / 自动横屏 16:9 一样都做不了（需求方 2026-10-01 裁决）。
  /// 原生那个通道先留着不删，见 `VideoPlayerPage` 的类注释。
  ///
  /// ⚠️ 播不了**不在这里兜**：那一页自己会把原因显示在画面上（**它才知道**
  /// 是哪一条文件、什么错）。这里再弹一次只会盖住那句话。
  Future<void> _play(RecordingSession session, String videoPath) =>
      VideoPlayerPage.open(context, path: videoPath, title: session.waybill.value);

  /// 归档状态 → 那一格的字与色。
  ///
  /// 用词与 `ArchiveRecord` 的状态名**一一对应**，不另起一套：
  /// 界面上一套、落盘一套的话，对着日志排查的人会先怀疑自己看错了哪一套。
  ({String text, Color color, Color tint}) _uploadLook(UploadState state) =>
      switch (state) {
        UploadState.archived => (
            text: '已备份',
            color: Palette.green,
            tint: Palette.greenTint,
          ),
        UploadState.uploading => (
            text: '备份中…',
            color: Palette.primary,
            tint: Palette.blueTint,
          ),
        UploadState.backoff => (
            text: '待重试',
            color: Palette.amber,
            tint: Palette.amberTint,
          ),
        // 草图里没有失败态 —— 红是规格要求的语义色，全应用只有这一支。
        UploadState.failed => (
            text: '备份失败',
            color: Palette.danger,
            tint: Palette.hairline,
          ),
        UploadState.pending => (
            text: '未备份',
            color: Palette.muted,
            tint: Palette.hairline,
          ),
      };

  // ── ④ 视频记录 ───────────────────────────────

  /// 视频记录列表：搜索 + 筛选 + 分页 + 管理（批量）。
  ///
  /// 分页是需求方 2026-09-22 定的（每页 5/10/15，左右箭头换页）——
  /// 不是为了性能，是因为手机一屏放不下，而**总页数得看得见**。
  /// 2026-09-27 照草图重做时需求方核过：它和「N 个未备份」**两样都留**。
  ///
  /// 列的是 `_sessions`（一次录制一条），**不是索引行** —— 索引是按分段记的，
  /// 一段 30 分钟的录制会列出 6 行来，用户数不出那个数字是哪来的。
  Widget _recordsCard() {
    final query = _recordsQuery;

    // ⚠️ **三条筛选（来源 / 日期 / 搜索词）的判定全在 `filterSessions` 里**
    // —— 纯函数，有测试。写在这个 `build` 里的话这一页的筛选逻辑就没有覆盖了
    // （widget 测试里 `_sessions` 恒空，构造不出「多条里有几条该留下」）。
    //
    // 搜索是**纯本地筛选**：不查网、不查许可（文档 §04 的 L8 ——
    // 未激活 / 试用到期 / 校验失败都不得挡住检索与回放）。
    final filtered = filterSessions(
      _sessions,
      day: _recordsDay,
      source: _recordsSource,
      query: query,
      typeOf: _businessTypeOf,
    );

    final pageCount = filtered.isEmpty
        ? 1
        : (filtered.length + _recordsPageSize - 1) ~/ _recordsPageSize;

    // 夹在**本地变量**里、不改状态：条数变少（换了筛选、删了录像）时
    // `_recordsPage` 可能越界，而在 build 里改状态 Flutter 会直接报错。
    final page = _recordsPage.clamp(0, pageCount - 1);
    final rows = filtered
        .skip(page * _recordsPageSize)
        .take(_recordsPageSize)
        .toList();

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '视频记录（共 ${filtered.length} 条）',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                // 【管理】：批量选 + 批量锁定 + 批量删除（需求方 2026-09-27）。
                //
                // ⚠️ 一条录像都没有时**点不动** —— 进一个空的管理模式什么也做不了，
                // 而用户会以为这个按钮坏了（踩坑 #13）。
                TextButton(
                  key: const Key('records-manage'),
                  onPressed: _sessions.isEmpty ? null : _toggleManage,
                  child: Text(_managing ? '完成' : '管理'),
                ),
              ],
            ),
          ),
          // 搜索框（需求方 2026-09-23 照草图加）：单号或日期，**纯本地筛**。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: TextField(
              key: const Key('records-search'),
              controller: _recordsSearch,
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索单号或日期',
                hintStyle: Theme.of(context).textTheme.labelLarge,
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 【扫码搜索】（需求方 2026-09-27 照草图加）：
                    // 一个箱子在手上时，**对着面单扫一下比手打单号快得多**，
                    // 而单号打错一位就是「怎么搜不到」。
                    IconButton(
                      key: const Key('records-scan'),
                      tooltip: '扫面单上的条码',
                      icon: const Icon(Icons.qr_code_scanner, size: 20),
                      onPressed: _scanToSearch,
                    ),
                    if (query.isNotEmpty)
                      IconButton(
                        key: const Key('records-clear'),
                        tooltip: '清空搜索',
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => _applyFilter(() {
                          _recordsSearch.clear();
                          _recordsQuery = '';
                        }),
                      ),
                  ],
                ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => _applyFilter(() => _recordsQuery = value),
            ),
          ),
          // 两个筛选胶囊（照草图）。**两个各管一维**：合成一个「全部」的话，
          // 用户没法知道那个「全部」是不限时间还是不限来源。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [_sourceChip(), _dayChip()],
            ),
          ),
          if (_managing) _manageBar(filtered),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                // 搜不到 / 筛没了时**必须说出来是什么条件把它筛没的**：
                // 一片空白看起来像这一页坏了，而不是「手机上确实没有这个单号」，
                // 而且用户得知道**怎么退回去**（踩坑 #13）。
                query.isNotEmpty
                    ? '没有找到和「$query」有关的录像。'
                    : (_recordsDay == null && _recordsSource == null
                        ? '本机还没有收尾入库的录像。'
                        : '现在这个筛选下没有录像。点上面那两个胶囊，选「全部」就都在了。'),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Palette.muted),
              ),
            )
          else
            for (final session in rows) ...[
              const Divider(height: 1),
              // 规格 §3.4.3 的七项：标签 / 缩略图 / 播放 / 单号 / 时间 / 时长 / 上传状态。
              _recordTile(session),
            ],
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Text('每页', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Palette.muted)),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _recordsPageSize,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 5, child: Text('5')),
                    DropdownMenuItem(value: 10, child: Text('10')),
                    DropdownMenuItem(value: 15, child: Text('15')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _recordsPageSize = value;
                      // 每页条数变了，原来的页码对应的内容已经不是同一批了。
                      _recordsPage = 0;
                    });
                  },
                ),
                const Spacer(),
                IconButton(
                  tooltip: '上一页',
                  icon: const Icon(Icons.chevron_left),
                  onPressed:
                      page > 0 ? () => setState(() => _recordsPage = page - 1) : null,
                ),
                Text('${page + 1}/$pageCount', style: Theme.of(context).textTheme.labelLarge),
                IconButton(
                  tooltip: '下一页',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: page < pageCount - 1
                      ? () => setState(() => _recordsPage = page + 1)
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 换筛选 / 换搜索词时**必须一起做**的那几件事。
  ///
  /// ⚠️ 三件，一件都不能漏：
  /// 1. **回到第一页** —— 停在第 7 页上多半是空的，看起来像「一条都没有」；
  /// 2. **清空选中** —— 这一条是安全相关：选中集是**看不见的**（被筛掉的那些
  ///    不在屏幕上），留着它再按【批量删除】，删掉的会包含用户此刻根本
  ///    看不到的录像。朝少删的那头落：宁可让他重选一次；
  /// 3. `setState`（由调用方那次包住）。
  ///
  /// ⚠️ 管理员（`_selected`）只在 [filtered] 里挑，所以清空之后
  /// 「已选 N 条」和屏幕上的勾**永远对得上**。
  void _applyFilter(VoidCallback change) {
    setState(() {
      change();
      _recordsPage = 0;
      _selected.clear();
    });
  }

  /// 「全部来源 / 发货视频 / 退货视频」那个胶囊。
  ///
  /// 用 `PopupMenuButton` 而不是 `DropdownButton`：下拉框要靠一个三角去认，
  /// 而胶囊上**直接写着当前选的是什么**（照草图）。
  Widget _sourceChip() {
    final selected = _recordsSource;

    return PopupMenuButton<BusinessType?>(
      key: const Key('records-source'),
      tooltip: '按来源筛选',
      onSelected: (value) => _applyFilter(() => _recordsSource = value),
      itemBuilder: (context) => [
        const PopupMenuItem<BusinessType?>(value: null, child: Text('全部来源')),
        for (final type in BusinessType.values)
          PopupMenuItem<BusinessType?>(value: type, child: Text(type.displayName)),
      ],
      child: Chip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        label: Text(
          '${selected == null ? '全部来源' : selected.displayName} ▾',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }

  /// 「全部日期 / 9月16日」那个胶囊。点开是系统日期选择器。
  ///
  /// ⚠️ 选中某一天之后，**退出这个筛选的出口是胶囊上那个 `×`**
  /// （`onDeleted`）—— 系统日期选择器上没有「不限日期」这一项，
  /// 不给出口的话，用户选了某一天就再也回不到全部了。
  Widget _dayChip() {
    final day = _recordsDay;

    return InputChip(
      key: const Key('records-day'),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      label: Text(
        '${day == null ? '全部日期' : dayStamp(day)} ▾',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onPressed: _pickDay,
      onDeleted: day == null ? null : () => _applyFilter(() => _recordsDay = null),
      deleteIcon: day == null ? null : const Icon(Icons.clear, size: 14),
    );
  }

  /// 选某一天。
  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _recordsDay ?? DateTime.now(),
      firstDate: DateTime(2020),
      // **今天之后选不出来** —— 还没到的日子不可能有录像，
      // 选得到它只会让用户以为「录像丢了」。
      lastDate: DateTime.now(),
    );

    if (picked == null || !mounted) return;
    _applyFilter(() => _recordsDay = picked);
  }

  /// 管理模式底下那一行：全选 / 已选几条 + 两个批量按钮。
  ///
  /// ⚠️ 「全选」全的是**当前筛选出来的那些**（屏幕上这些），不是全部录像 ——
  /// 用户看不见的东西被一起选上，再按【批量删除】就是灾难。
  /// [visible] 就是当前筛选后的那一串。
  Widget _manageBar(List<RecordingSession> visible) {
    final all = visible.isNotEmpty && _selected.length == visible.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 12, 2),
          child: Row(
            children: [
              TextButton(
                key: const Key('records-select-all'),
                onPressed: () => setState(() {
                  if (all) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll([for (final session in visible) session.sessionId]);
                  }
                }),
                child: Text(all ? '取消全选' : '全选'),
              ),
              const Spacer(),
              Text('已选 ${_selected.length} 条', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('records-batch-lock'),
                  onPressed:
                      (_settingsReady && _selected.isNotEmpty) ? _runBatchLock : null,
                  icon: const Icon(Icons.lock_outline, size: 18),
                  label: const Text('批量锁定'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('records-batch-delete'),
                  onPressed:
                      (_settingsReady && _selected.isNotEmpty) ? _runBatchDelete : null,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('批量删除'),
                  style: OutlinedButton.styleFrom(foregroundColor: Palette.danger),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 进 / 出管理模式。
  ///
  /// ⚠️ 出来时**清空选中**：留着的话下次进来会「上次勾的那些还勾着」，
  /// 而用户以为那是新的一次挑选。
}
