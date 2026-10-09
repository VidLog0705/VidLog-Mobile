// ignore_for_file: invalid_use_of_protected_member
//
// ⚠️ 上面这条是这套拆法**必须付的价**，不是图省事：`State.setState` 带
// `@protected`，而分析器不把 `extension on _RecorderPageState` 认作
// 「State 的子类内部」，于是本文件里每一处 `setState(` 都报这一条。
// 语言本身允许（同一个 library、编译通过、测试全绿）—— 那是 lint 的误报，
// 它判的是「在不在子类里」，认不出 extension。只收窄这一条规则，
// 不做 `ignore_for_file: all`。

part of 'recorder_page.dart';

// T26③ 第 2 轮第 5 刀：从 `recorder_page.dart` 整段搬过来的 —— **纯搬家**。
// 一行都没改，只是位置换了（内容多重集比对可证）。这里装的是设置：录制规格与保留期那几张卡（4 个 blurb 与 _customSentinel 都在这里）。
//
// ⚠️ 只有实例方法 / getter 能装进来：extension **不许声明实例字段**，
// 所以那些字段全留在壳的类体里 —— 同 library，这里不带前缀照样读得到。
// extension **也不许**不带前缀地引用被扩展类型的静态成员
// （`unqualified_reference_to_static_member_of_extended_type`，
// 2026-10-06 实测），所以下面这几个改成了**顶层**声明跟着搬过来。


  String _modeTitle(WorkMode mode) => switch (mode) {
        WorkMode.continuousScan => '连续扫码 —— 换件换段',
        WorkMode.sameWaybillStop => '同码停录 —— 复扫同码就停',
        WorkMode.scanThenStaticStop => '扫码静止停录 —— 静止够时长才停',
      };


  String _modeBlurb(WorkMode mode) => switch (mode) {
        WorkMode.continuousScan =>
          '扫一张面单就开录；扫到「另一张」面单时，上一段立刻入库、'
              '紧接着为新面单开下一段，如此往复。\n'
              '停只能靠手动按【结束】，或者下面两个兜底机制。\n'
              '注意：这个模式没有错码保护 —— 画面里扫到别的条码会当场换段，'
              '一件包裹可能被切成两段。',
        WorkMode.sameWaybillStop =>
          '识别到单号就开录，复扫到同一个单号就停。'
              '三个模式里只有它不用人额外做什么就能自己停。\n'
              '扫到别的单号不会停、也不会换段 —— 那是错码保护（§3.3.2），'
              '只出声提醒，直到扫回本件面单才停。',
        WorkMode.scanThenStaticStop =>
          '识别到单号就开录。包裹要先离开画面、再回到画面，'
              '并且静止够下面设的时长才停。\n'
              '注意：这个模式下复扫同码不停，只认静止 —— '
              '这就是它和「同码停录」的区别。\n'
              '扫到别的单号不会停、也不会换段 —— 那是错码保护（§3.3.2），'
              '只出声提醒。',
      };


  /// 选中的那一档编码的一句话说明。
  ///
  /// ⚠️ H.265 那句里的**电脑端网页回放**限制是**必须留着**的：它是本机
  /// 真实存在的限制（见 `实现决策.md` 与母仓 §3.4），藏起来的话用户选了
  /// H.265、回头在电脑上播不了，只会以为录像坏了。
  String _codecBlurb(VideoCodec codec) => switch (codec) {
        VideoCodec.h264 =>
          '兼容性最好，几乎所有手机都能播放；文件体积约增加 30-40%。',
        VideoCodec.h265 =>
          '同画质下体积小一半左右。⚠️ 电脑端的网页回放对 H.265 支持不一致，'
              '可能播不了 —— 那时用系统播放器打开就行，录像本身没问题。',
      };


  /// 一档分辨率的一句话说明。句式照需求方那张图：`宽 × 高 · 30 帧 · 一句评价`。
  ///
  /// ⚠️ 写的**永远是横过来的那组尺寸**（`1280 × 720`），竖屏时也不换成
  /// `720 × 1280` —— 用户是按「720p」这个名字认档位的，需求方图上写的也是这组。
  String _resolutionBlurb(VideoResolution resolution) => switch (resolution) {
        VideoResolution.uhd4K => '3840 × 2160 · 30 帧 · 最清楚，也最占地方。',
        VideoResolution.p1080 => '1920 × 1080 · 30 帧 · 清楚与体积之间的折中。',
        VideoResolution.p720 => '1280 × 720 · 30 帧 · 更省空间、更流畅。',
      };


  /// 「自定义」在下拉里的哨兵值。**不会落盘** —— 选中它只是打开输入框。
  const _customSentinel = RetentionSetting(-1);

extension on _RecorderPageState {

  // ── ① 工作模式 ───────────────────────────────

  Widget _modeCard() {
    final scheme = Theme.of(context).colorScheme;

    return _settingCard(
      icon: Icons.check_box_outlined,
      title: '工作模式',
      blurb: '决定这一件什么时候算录完（规格 §3.3.1）。',
      children: [
        SegmentedButton<WorkMode>(
          segments: const [
            ButtonSegment(value: WorkMode.continuousScan, label: Text('连续扫码')),
            ButtonSegment(value: WorkMode.sameWaybillStop, label: Text('同码停录')),
            ButtonSegment(
                value: WorkMode.scanThenStaticStop, label: Text('扫码静止停录')),
          ],
          selected: {_mode},
          onSelectionChanged: _settingsReady
              ? (value) => _updateSettings(mode: value.first)
              : null,
        ),
        const SizedBox(height: 12),

        // 只讲**选中的那一个**。三个模式的说明同时铺出来，用户得先自己
        // 对号入座；而人真正要回答的问题是「我现在这个会怎么停」。
        Container(
          key: const Key('settings-mode-blurb'),
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Corners.note),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_modeTitle(_mode),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(_modeBlurb(_mode), style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),

        const Divider(height: 28),

        _settingRow(
          '面单条码最短长度',
          _settingDropdown<WaybillMinLength>(
            key: 'settings-waybill-min-length',
            value: _waybillMinLength,
            values: WaybillMinLength.values,
            label: (value) => value.label,
            onChanged: (value) => _updateSettings(waybillMinLength: value),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '相机扫到的条码短于这个位数就当成误识，不触发录制 —— '
          '挡的是货架条码、包装上的别的码、别家快递的面单这类东西。\n'
          '⚠️ 只管相机：手工敲进去的单号不受这一项限制。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  // ── ①b 录制规格（规格 §3.1.7）─────────────────

  /// 编码 / 分辨率 / 方向。
  ///
  /// ⚠️ 2026-09-28 起**拆成三张卡**（需求方那张图上是三张）。
  /// 在这之前它们是一张卡里三个 `Divider` 段。
  ///
  /// ## 三条界面规矩（拆卡后一条没松）
  ///
  /// ① 编码名**只写「H.265」**，不许出现 HEVC —— 名字由
  ///    `RecordingSpec.codecLabel` 一处产出（规格原话：两个名字混用会让用户
  ///    以为是两种不同的编码）。
  /// ② 帧率**没有选项**：规格是「上限 30、不提供选择」，所以每个档位的说明里
  ///    只把它写成一句话。摆一个只有一个选项的下拉是骗人的。
  /// ③ **实际用哪一档必须说出来**（规格：**回落必须可见**、**不得静默回落**），
  ///    见 [_resolutionCard] 底下那一块。
  Widget _codecCard() {
    return _settingCard(
      icon: Icons.code,
      title: '录像编码',
      blurb: '兼容优先，还是体积优先 —— 按播放环境和存储空间选。',
      children: [
        SegmentedButton<VideoCodec>(
          key: const Key('settings-codec'),
          segments: const [
            ButtonSegment(value: VideoCodec.h264, label: Text('H.264 兼容优先')),
            ButtonSegment(value: VideoCodec.h265, label: Text('H.265 更省空间')),
          ],
          selected: {_codec},
          onSelectionChanged: _settingsReady
              ? (value) => _updateSettings(codec: value.first)
              : null,
        ),
        const SizedBox(height: 8),
        Text(_codecBlurb(_codec), style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _resolutionCard() {
    final scheme = Theme.of(context).colorScheme;
    final effective = _coordinator?.effectiveSpec;
    final reason = _coordinator?.specFallbackReason;

    return _settingCard(
      icon: Icons.hd_outlined,
      title: '录像规格',
      blurb: '越大越清楚、也越占地方。清理时的容量预告按这一档算。',
      children: [
        SegmentedButton<VideoResolution>(
          key: const Key('settings-resolution'),
          segments: const [
            ButtonSegment(value: VideoResolution.uhd4K, label: Text('4K')),
            ButtonSegment(value: VideoResolution.p1080, label: Text('1080p')),
            ButtonSegment(value: VideoResolution.p720, label: Text('720p')),
          ],
          selected: {_resolution},
          onSelectionChanged: _settingsReady
              ? (value) => _updateSettings(resolution: value.first)
              : null,
        ),
        const SizedBox(height: 8),
        Text(_resolutionBlurb(_resolution), style: Theme.of(context).textTheme.bodySmall),

        const SizedBox(height: 16),

        // 「实际按 X 录制」—— 规格那句「不得静默回落」的落点。
        // ⚠️ 它说的是**整档规格**（编码 + 分辨率 + 方向），不只是分辨率 ——
        // 但它挂在三张卡里名字最对得上的这一张上。
        Container(
          key: const Key('settings-effective-spec'),
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: reason == null
                ? scheme.surfaceContainerHighest
                : context.palette.amberTint,
            borderRadius: BorderRadius.circular(Corners.note),
          ),
          child: Text(
            effective == null
                ? '实际用哪一档还没检查过。点【开始工作】时会真开一次相机试。'
                : reason == null
                    ? '实际按 ${effective.label} 录制。'
                    : '⚠️ 实际按 ${effective.label} 录制 —— 你选的是 ${_requestedSpec().label}。'
                        '$reason',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: reason == null ? null : context.palette.amber,
            ),
          ),
        ),
      ],
    );
  }

  Widget _orientationCard() {
    return _settingCard(
      icon: Icons.screen_rotation_outlined,
      title: '录像方向',
      blurb: '手机怎么拿就选哪个 —— 取景框和画面比例都跟着它走。',
      children: [
        SegmentedButton<RecordingOrientation>(
          key: const Key('settings-orientation'),
          segments: const [
            ButtonSegment(
                value: RecordingOrientation.landscapeLeft, label: Text('横左')),
            ButtonSegment(
                value: RecordingOrientation.portrait, label: Text('竖屏')),
            ButtonSegment(
                value: RecordingOrientation.landscapeRight, label: Text('横右')),
          ],
          selected: {_orientation},
          onSelectionChanged: _settingsReady
              ? (value) => _updateSettings(orientation: value.first)
              : null,
        ),
        const SizedBox(height: 8),
        Text(
          '水印跟着画面一起转，始终落在右上角、看得清。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  // ── ② 两个兜底档位 ───────────────────────────

  /// 卡片名照需求方那张图改成 `忘记停止录制时的自动兜底`（原来叫「防忘停录」）。
  /// 长了一截，但它把「这是干什么用的」直接说完了 —— 四个字的缩写说不完。
  ///
  /// ⚠️ **两个档位现在都是下拉**（图上就是下拉），`label` 由枚举自己给。
  Widget _fallbackCard() {
    return _settingCard(
      icon: Icons.timer_off_outlined,
      title: '忘记停止录制时的自动兜底',
      blurb: '两个兜底互相独立：关掉一个不影响另一个。任何一个到点，录制就停。',
      children: [
        _settingRow(
          '最长录制时长',
          _settingDropdown<DurationFallbackSetting>(
            key: 'settings-duration-fallback',
            value: _durationFallback,
            values: DurationFallbackSetting.values,
            label: (value) => value.label,
            onChanged: (value) => _updateSettings(durationFallback: value),
          ),
        ),
        const SizedBox(height: 6),

        // ⚠️ 这一段**必须是询问式**。需求方那张图上这里写的是
        // 「自动停止，到点前 30 秒语音提醒」，而裁决是**照规格 §3.3.4**
        // （先问、1 分钟没人理才停）。说明不跟着改的话，界面上就是一句假话 ——
        // 用户会站在原地等那句「还有 30 秒」，然后被直接停掉。
        Text(
          '不管画面动不动，录满这个时长就语音问一次'
          '「录制时间即将超时，是否需要停止录制？」：\n'
          '· 点【停止】→ 立刻停；\n'
          '· 点【继续】→ 接着录，之后每隔 5 分钟再问一次；\n'
          '· 问完 1 分钟没人理 → 自动停。',
          style: Theme.of(context).textTheme.bodySmall,
        ),

        const Divider(height: 28),

        _settingRow(
          '画面静止自动停止',
          _settingDropdown<StaticStopSetting>(
            key: 'settings-static-stop',
            value: _staticStop,
            values: StaticStopSetting.values,
            label: (value) => value.label,
            onChanged: (value) => _updateSettings(staticStop: value),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '画面一直不动、够这个时长就自动停。这一条不会出声提醒。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  // ── ②c 本地保留期：四个数 ─────────────────────

  /// 本地留多久 —— **发货 / 退货 × 已备份 / 未备份 = 四个数**（规格 §3.5.2.1）。
  ///
  /// ## ⚠️ 2026-09-28 起拆成两张卡
  ///
  /// 需求方 2026-09-24 点名要的摆法是「一张两行两列的表」，2026-09-28 那张
  /// 自绘的图上把它**改成了两张卡**（发货录像清理 / 退货录像清理，各两个下拉），
  /// 照图走。**四个 `Key` 一个没改** —— 换了摆法但没换设置项。
  ///
  /// ## ⚠️ 两列语义**相反**（这一块最要紧的一句话）
  ///
  /// - **已备份**：到期**真删本地副本**（先过 §3.5.4 回查），起算点 = 备份成功时刻；
  /// - **未备份**：到期**只标红、只催上传，永不自动删**，起算点 = 录完时刻。
  ///
  /// 后者是**唯一副本**（I2），删了就永久没了。这段话**必须**让用户看得到 ——
  /// 不写的话，用户要么以为「选了不保留却没反应」是坏了（踩坑 #13），
  /// 要么以为自己选了「马上删」而**不敢选**。
  ///
  /// ⚠️ 拆卡之后它没地方铺了（两张卡各写一遍就是四段重复的⚠️），
  /// 于是收进标题右边那个 `?` 里 —— **图上正好有一个 `?`**，这就是它该待的地方。
  /// 四条一句没删，只是不再常驻。
  ///
  /// ## 为什么手机端没有「归档层」那个下拉（电脑端有）
  ///
  /// 规格 §3.5.1 要求：归档层就是本机磁盘时**不提供**清理选项，
  /// 因为那时本地这份是唯一副本。**那个危险在手机上不存在** ——
  /// 手机的归档层是电脑端（局域网）/ NAS / 网盘，三者都在**别的设备**上。
  /// 所以这里不摆一个「归档层」下拉：它在这台机器上没有第二种可能，
  /// 摆上去就是个改了没反应的开关（踩坑 #13）。
  Widget _retentionCard({required bool outbound}) {
    final side = outbound ? '发货' : '退货';

    return _settingCard(
      icon: outbound
          ? Icons.local_shipping_outlined
          : Icons.assignment_return_outlined,
      title: '$side录像清理',
      blurb: '$side那批在手机上留多久。两个数互相独立 —— 改一个不动另一个。',
      trailing: IconButton(
        key: const Key('settings-retention-help'),
        tooltip: '保留期说明',
        icon: const Icon(Icons.help_outline, size: 20),
        onPressed: _showRetentionHelp,
      ),
      children: [
        // ⚠️ 顺序照图：**未备份**在上。这一栏才是用户真正会踩的那个 ——
        // 它永不自动删，「选了半天没反应」的疑问只会出在这里。
        _settingRow(
          '未备份保留',
          _retentionDropdown(
            outbound
                ? 'settings-retention-unarchived-outbound'
                : 'settings-retention-unarchived-return',
            outbound ? _retentionUnarchivedOutbound : _retentionUnarchivedReturn,
            (value) => _updateSettings(
              retentionUnarchivedOutbound: outbound ? value : null,
              retentionUnarchivedReturn: outbound ? null : value,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '⚠️ 这一栏永不自动删：还没备份上去的录像在手机上是唯一一份，'
          '删了就永久没了。它到期只提醒 —— 列表标红 + 顶部催上传。',
          style: Theme.of(context).textTheme.bodySmall,
        ),

        const Divider(height: 28),

        _settingRow(
          '备份后保留',
          _retentionDropdown(
            outbound
                ? 'settings-retention-archived-outbound'
                : 'settings-retention-archived-return',
            outbound ? _retentionArchivedOutbound : _retentionArchivedReturn,
            (value) => _updateSettings(
              retentionArchivedOutbound: outbound ? value : null,
              retentionArchivedReturn: outbound ? null : value,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '备份成功后，手机上的原片再留多久 —— 从「备份成功那一刻」起算，'
          '不是从录完起算。这一栏到点会真的删手机上的那份。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// 保留期的四条 ⚠️（需求方点名**必须保留**，只是收进 `?` 里）。
  ///
  /// 用对话框而不是展开/收起：这段字比卡片本身还长，铺在卡里会把两个
  /// 真正要改的下拉挤到屏幕外面去。
  Future<void> _showRetentionHelp() => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('settings-retention-help-dialog'),
          title: const Text('保留期怎么算'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '⚠️「备份后保留」那一栏：备份成功后，手机上的原片再留多久。'
                  '从「备份成功那一刻」起算，不是从录完起算。',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                SizedBox(height: 10),
                Text(
                  '⚠️「未备份保留」那一栏永不自动删除 —— 那是唯一一份，'
                  '删了就没了。它到期的动作只有提醒（列表标红 + 催上传），'
                  '从「录完那一刻」起算。',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                SizedBox(height: 10),
                Text(
                  '⚠️「不保留」不是立刻删：最近 24 小时内录的一律不动'
                  '（硬性豁免，关不掉），所以它实际是「备份成功后最快 24 小时清理」。',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                SizedBox(height: 10),
                Text(
                  '⚠️ 这一块记的是到期之后该怎么做，而手机端的自动清理还没接通 —— '
                  '今天不会有任何文件自动被删。想现在删就用备份页每一条右边的'
                  '垃圾桶图标（那会先跟电脑端核对，核对不上就不删）。'
                  '另外【被锁定】的证据永远不清。',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );

  Widget _retentionDropdown(
    String key,
    RetentionSetting value,
    ValueChanged<RetentionSetting> onChanged,
  ) {
    // ⚠️ 「自定义」不在列表里，而下拉的 `value` 必须能在 `items` 里找到 ——
    // 找不到会直接断言失败。所以自定义值临时补一个条目进去（显示成「45 天」），
    // 用户点开下拉再选就是换成了标准档位。
    final items = <RetentionSetting>[
      ...RetentionSetting.standard,
      if (value.isCustom) value,
    ];

    return DropdownButton<RetentionSetting>(
      key: Key(key),
      value: value,
      isDense: true,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      items: [
        for (final setting in items)
          DropdownMenuItem(value: setting, child: Text(setting.label)),
        // 「自定义」这一项不是一个值，是一个入口 —— 选中它只是打开输入框。
        DropdownMenuItem(
          value: _customSentinel,
          child: Text('自定义…', style: Theme.of(context).textTheme.labelLarge),
        ),
      ],
      // `_settingsReady`：盘上的设置还没读出来时不给改 ——
      // 改了会被随后读出来的盘上值覆盖，等于改了没反应还看不出来。
      onChanged: _settingsReady
          ? (v) async {
              if (v == null) return;
              if (identical(v, _customSentinel)) {
                final days = await _askCustomDays(value);
                if (days != null) onChanged(RetentionSetting.fromConfig(days));
                return;
              }
              onChanged(v);
            }
          : null,
    );
  }

  /// 问一个天数。返回 null 表示用户取消。
  Future<int?> _askCustomDays(RetentionSetting current) async {
    final controller = TextEditingController(
      text: current.days != null && current.isCustom ? '${current.days}' : '',
    );

    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义保留天数'),
        content: TextField(
          key: const Key('retention-custom-days'),
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            suffixText: '天',
            helperText: '填一个正整数天数（最多 3650 天）',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('retention-custom-ok'),
            onPressed: () {
              final days = int.tryParse(controller.text.trim());
              // ⚠️ 认不出的输入**不关窗也不猜** —— 关掉就等于「改了没反应」。
              if (days == null || days < 0 || days > RetentionSetting.maxDays) {
                return;
              }
              Navigator.of(context).pop(days);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );

    controller.dispose();
    return result;
  }

  // ── ③ 什么时候生效 ───────────────────────────

  /// 说清「现在改的东西什么时候起作用」。
  ///
  /// ⚠️ **这不是一句客套提示，是在补一个真实的静默。** 模式与档位是
  /// [RecordingCoordinator] 的**构造参数**（没有 setter），编排器只在
  /// 「开始工作」时重建（`_startWorking` 里的 `_buildCoordinator`）。
  /// 所以在工作中改设置，当前这一段仍然按旧设置走 —— 界面不说明的话，
  /// 用户改完看到没反应，只会以为开关坏了。
  ///
  /// **不改成「立刻生效」是有意的**：工作途中换编排器会把相机会话和界面状态
  /// 拆开（新编排器的 `isWorking` 是 false，而相机是真开着的），
  /// 那个态下「结束工作」也关不掉相机 —— 用一次模式切换换一个相机泄漏不值。
  ///
  /// ⚠️ 语音提示是**例外**，而且必须在这里写明 —— 否则这块提示本身就成了假话。
  /// 它不参与判定（只出声），关它是「现在太吵」而不是「下一段想这样录」。
  ///
  /// ⚠️ 2026-09-28 加的两项（**面单条码最短长度 / 录制声音**）都归
  /// 「等下次『开始工作』」那一组：两者都是 `_buildCoordinator` 重建编排器时
  /// 才被读一次（条码下限进 `ScanGate`、录制声音进 `startRecording` 的参数）。
  /// 列在这里不是客套 —— 用户改完没反应，只会以为开关坏了。
  Widget _whenCard() {
    final working = _coordinator?.isWorking ?? false;

    return Card(
      color: working ? context.palette.amberTint : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          // ⚠️ 全称句每加一个例外都要回头改一遍（踩坑 21）：2026-10-01 加
          // 【实时共享】时核对过一次 —— 它**属于**这一组（要等下次开始工作），
          // 不是例外，所以这两句只多列了一个名字，别的地方一个字没动。
          working
              ? '⚠️ 正在工作中。上面【工作模式】【忘记停止录制时的自动兜底】'
                  '【录像编码/规格/方向】【面单条码最短长度】【录制声音】'
                  '【实时共享】'
                  '改了这一段不生效 —— '
                  '等下次「开始工作」重建编排器时才按新设置走。'
                  '（【实时共享】改成「关」是立刻停的。）'
                  '【语音提示】不受这条限制，它立刻生效。'
              : '【工作模式】【忘记停止录制时的自动兜底】【录像编码/规格/方向】'
                  '【面单条码最短长度】【录制声音】【实时共享】'
                  '在点「开始工作」时生效。'
                  '改完直接去发货栏开始工作就行，不用退出去重进。\n'
                  '【语音提示】是立刻生效的。\n'
                  '【归档后的本地保留期】落在盘上就算数，但它现在还没有执行者 ——'
                  '在那之前任何文件都不会被删。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }

  /// 孤儿收尾结果的正文，收进「诊断」抽屉里。
  ///
  /// 原来它是一张常驻的琥珀色卡片。改成抽屉之后**没有降级**：
  /// 抽屉入口上的「诊断」两个字是常驻的，展开就在；而这张卡片的出现是
  /// 小概率事件（只有上次被杀过才有），常驻占着取景画面不值得。
  Widget _recoveredBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('启动时收尾的孤儿分段',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '这些是上次没录完就被中断的会话。它们已经收好尾、存好了。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        for (final outcome in _recovered)
          Text(
            '· ${outcome.succeeded ? "已收尾" : "失败"} · '
            '${outcome.segments.length} 段 · ${_triggerLabel(outcome.reason)}',
          ),
      ],
    );
  }
}
