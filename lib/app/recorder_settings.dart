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
// 一行都没改，只是位置换了（内容多重集比对可证）。这里装的是设置：写盘（_updateSettings）、那几个读设置的小 getter、页面骨架、声音与连接那几张卡。
//
// ⚠️ 只有实例方法 / getter 能装进来：extension **不许声明实例字段**，
// 所以那些字段全留在壳的类体里 —— 同 library，这里不带前缀照样读得到。
// extension **也不许**不带前缀地引用被扩展类型的静态成员
// （`unqualified_reference_to_static_member_of_extended_type`，
// 2026-10-06 实测），所以下面这几个改成了**顶层**声明跟着搬过来。

extension on _RecorderPageState {


  /// 改设置：**先落盘，再刷界面**。
  ///
  /// [RecordingSettings] 只在 `_bootstrap` 里读过一次，之后每次改动都由这里
  /// 同步进去并写回盘。
  ///
  /// `_settings == null` 表示盘上的设置还没读出来。这时**直接不动** ——
  /// 改了也会被随后读出来的盘上值覆盖，等于改了没反应还看不出来。
  /// 设置页的控件在这一小段时间里是禁用的，见 [_settingsReady]。
  void _updateSettings({
    WorkMode? mode,
    StaticStopSetting? staticStop,
    DurationFallbackSetting? durationFallback,
    bool? voiceEnabled,
    RetentionSetting? retentionArchivedOutbound,
    RetentionSetting? retentionArchivedReturn,
    RetentionSetting? retentionUnarchivedOutbound,
    RetentionSetting? retentionUnarchivedReturn,
    VideoCodec? codec,
    VideoResolution? resolution,
    RecordingOrientation? orientation,
    WaybillMinLength? waybillMinLength,
    bool? recordAudio,
    bool? liveShareEnabled,
    // 采集页右上角那个实时共享按钮**自己**去对齐推流那一路（它要在按完之后
    // 拿到结果说一句实话），所以它传 false 跳过这里那一跳 ——
    // 两条 `_applyLiveShare` 叠着跑会各起一个 HTTP 服务，第二个必然端口被占。
    bool applyLiveShare = true,
  }) {
    final settings = _settings;
    if (settings == null) return;

    setState(() {
      if (mode != null) _mode = mode;
      if (staticStop != null) _staticStop = staticStop;
      if (durationFallback != null) _durationFallback = durationFallback;
      if (voiceEnabled != null) settings.voiceEnabled = voiceEnabled;
      if (retentionArchivedOutbound != null) {
        _retentionArchivedOutbound = retentionArchivedOutbound;
      }
      if (retentionArchivedReturn != null) {
        _retentionArchivedReturn = retentionArchivedReturn;
      }
      if (retentionUnarchivedOutbound != null) {
        _retentionUnarchivedOutbound = retentionUnarchivedOutbound;
      }
      if (retentionUnarchivedReturn != null) {
        _retentionUnarchivedReturn = retentionUnarchivedReturn;
      }
      if (codec != null) _codec = codec;
      if (resolution != null) _resolution = resolution;
      if (orientation != null) _orientation = orientation;

      // 这两项**不另立字段** —— 界面直接读 `_settings`（见 [_waybillMinLength]
      // 与 [_recordAudio]），所以这里只写回 settings 一处。
      if (waybillMinLength != null) settings.waybillMinLength = waybillMinLength;
      if (recordAudio != null) settings.recordAudio = recordAudio;
      if (liveShareEnabled != null) settings.liveShareEnabled = liveShareEnabled;

      settings.mode = _mode;
      settings.staticStop = _staticStop;
      settings.durationFallback = _durationFallback;
      settings.retentionArchivedOutbound = _retentionArchivedOutbound;
      settings.retentionArchivedReturn = _retentionArchivedReturn;
      settings.retentionUnarchivedOutbound = _retentionUnarchivedOutbound;
      settings.retentionUnarchivedReturn = _retentionUnarchivedReturn;
      settings.codec = _codec;
      settings.resolution = _resolution;
      settings.orientation = _orientation;
    });

    // ⚠️ **播报是唯一立刻生效的一项。**
    // 它不参与任何判定（只出声），而人是嫌吵才关的 ——
    // 让他「先结束工作再开始」是不合理的。
    // 其余各项（含**实时共享**）等下次「开始工作」，
    // 理由见设置页底部那块提示与 `实现决策.md` §17.3。
    if (voiceEnabled != null) _applyVoice();

    // 实时共享：**关掉是立刻就停的**，打开要等下次【开始工作】
    // （推流那一路是开会话时挂上去的第二路输出）。这里叫一下是为了
    // 让「关掉」当场生效、「打开」当场得到那句实话 —— 而不是让用户
    // 对着一个没有反应的开关猜。
    if (liveShareEnabled != null && applyLiveShare) {
      unawaited(_applyLiveShare());
    }

    // **不等它写完。** 写盘是几十毫秒的 I/O，而这是点一下开关就要走的路；
    // 失败了也不该拦住任何事 —— 设置读不出来/写不进去都不影响录制（I4）。
    unawaited(settings.save());
  }

  /// 盘上的设置读出来了没有。没读出来时设置页的控件全部禁用。
  bool get _settingsReady => _settings != null;

  /// 播报开没开。设置没读出来时按**开**算 —— 读不出来不该静默把提示功能关掉，
  /// 理由见 `RecordingSettings.voiceEnabled` 的注释。
  bool get _voiceOn => _settings?.voiceEnabled ?? true;

  /// 面单条码最短长度。读完设置之前按默认档（11 位）算。
  ///
  /// ⚠️ 与 [_voiceOn] 同一个写法（**读穿 `_settings`**，不另立一个字段）：
  /// 另立字段就成两份真相，而这两项都只在「开始工作」重建编排器时被读一次。
  WaybillMinLength get _waybillMinLength =>
      _settings?.waybillMinLength ?? WaybillMinLength.fallback;

  /// 录像文件带不带声音。读完设置之前按**开**算，理由见
  /// `RecordingSettings.recordAudio`。
  bool get _recordAudio => _settings?.recordAudio ?? true;

  /// **用户选的**录制规格（设置还没读出来时用默认档）。
  ///
  /// ⚠️ 与「实际用的那一档」不是一回事 —— 后者由编排器探测之后给出
  /// （[_coordinator]`.effectiveSpec`）。界面显示、索引记录都用后者。
  RecordingSpec _requestedSpec() =>
      _settings?.requestedSpec ?? RecordingSpec.standard;

  /// 设置页：工作模式 → 两个兜底档位 → 验收工具。
  ///
  /// ## 这一页的两条规矩
  ///
  /// ① **改了立刻落盘。** 落盘之前这些值只活在内存里，重启就回默认档位 ——
  ///    而「时长兜底档位交给用户自己选」是需求方 2026-09-21 特意要的，
  ///    每次开 App 都抹掉等于没做。
  ///
  /// ② **验收工具必须长得不像产品设置。** 「时长兜底加速」会把**真实录制**的
  ///    首次询问压到 20 秒。它要是和别的开关长一样，验收完忘了关，
  ///    正常录 4 分钟的活 20 秒就被问一次「是否停止」。
  Widget _settingsPage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _settingsHeader(),
        const SizedBox(height: 16),
        _modeCard(),
        const SizedBox(height: 12),
        _retentionCard(outbound: true),
        const SizedBox(height: 12),
        _retentionCard(outbound: false),
        const SizedBox(height: 12),
        _cleanupLogCard(),
        const SizedBox(height: 12),
        _codecCard(),
        const SizedBox(height: 12),
        _resolutionCard(),
        const SizedBox(height: 12),
        _orientationCard(),
        const SizedBox(height: 12),
        _recordAudioCard(),
        const SizedBox(height: 12),
        _fallbackCard(),
        const SizedBox(height: 12),
        _voiceCard(),
        const SizedBox(height: 12),
        _netdiskCard(),
        const SizedBox(height: 12),
        _aboutCard(),
        const SizedBox(height: 12),
        _acceptanceCard(),
        const SizedBox(height: 12),
        _whenCard(),
      ],
    );
  }

  // ── 设置页的通用件 ───────────────────────────

  /// 页头：**实心蓝圆角方块（白色齿轮）+ 设置 + 一句说明**，压在一块浅蓝底上。
  ///
  /// ⚠️ 有了它，设置栏就**不要 AppBar 了**（见 `build` 里那条）——
  /// 留着会有两个「设置」上下叠着。
  Widget _settingsHeader() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.palette.blueTint,
        borderRadius: BorderRadius.circular(Corners.header),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              // ⚠️ 实心蓝块读 `primarySolid`，不是 `primary` —— 后者在暗色下是
              // 一支**浅蓝**（它要在暗底上当字用），压白字等于看不见。
              color: context.palette.primarySolid,
              borderRadius: BorderRadius.circular(Corners.card),
            ),
            child: const Icon(Icons.settings, color: Palette.onDark, size: 26),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('设置',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
              SizedBox(height: 2),
              Text('系统配置与功能管理', style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ],
      ),
    );
  }

  /// 设置页那一列卡片的统一外壳：**实心蓝圆角方块 + 白色字形**，右边标题与说明。
  ///
  /// ⚠️ 与备份页的 `_statCard`（浅色**圆**底 + 彩色字形）**故意不一样**。
  /// 那不是疏漏：两页各照自己那张图做，谁也别去改谁。
  Widget _settingCard({
    required IconData icon,
    required String title,
    String? blurb,
    Widget? trailing,
    required List<Widget> children,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: context.palette.primarySolid,
                    borderRadius: BorderRadius.circular(Corners.iconBox),
                  ),
                  child: Icon(icon, color: Palette.onDark, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ⚠️ 卡片标题走 `titleMedium`（字号与 `bold` 都在
                      // `app/text_scale.dart` 那份里）。改前这里是一句裸
                      // `TextStyle(fontWeight: FontWeight.bold)` —— 它继承
                      // 环境字号（`bodyMedium`，14），而备份页那张卡与记录卡头
                      // 早就是 `titleMedium`(16)：同一个角色两个大小，
                      // 全靠这一支收拢。
                      Text(title,
                          style: Theme.of(context).textTheme.titleMedium),
                      if (blurb != null) ...[
                        const SizedBox(height: 2),
                        Text(blurb, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }

  /// 卡片里的一行：左边一个标签，右边一个控件。
  Widget _settingRow(String label, Widget control) {
    return Row(
      children: [
        Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
        const SizedBox(width: 8),
        Expanded(child: control),
      ],
    );
  }

  /// 档位下拉。**设置页现在一律用下拉**（需求方那张图上是下拉）——
  /// 三个档位类型共用一个，免得三处各写一遍 `DropdownButton` 的样板。
  ///
  /// `_settingsReady`：盘上的设置还没读出来时不给改 —— 改了会被随后读出来的
  /// 盘上值覆盖，等于改了没反应还看不出来。
  Widget _settingDropdown<T>({
    required String key,
    required T value,
    required List<T> values,
    required String Function(T) label,
    required ValueChanged<T> onChanged,
  }) {
    return DropdownButton<T>(
      key: Key(key),
      value: value,
      isDense: true,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      items: [
        for (final option in values)
          DropdownMenuItem(value: option, child: Text(label(option))),
      ],
      onChanged: _settingsReady
          ? (selected) {
              if (selected != null) onChanged(selected);
            }
          : null,
    );
  }

  // ── ②b 语音提示 ──────────────────────────────

  /// 语音播报开关（需求方 2026-09-22 点名的）。
  ///
  /// ⚠️ **关掉的只是声音，不是提示。** 「单号不同，请核对」那类提示在屏幕上
  /// 照旧出现、事件日志照旧记（日志图标从 🔊 变 🔇）。关播报不等于关提示 ——
  /// 否则用户关掉声音的同时也把错码保护的唯一线索关掉了。
  ///
  /// 卡片名照需求方那张图改成 `语音提示`（原来叫「语音播报」），并加上 `试听`。
  Widget _voiceCard() {
    return _settingCard(
      icon: Icons.volume_up_outlined,
      title: '语音提示',
      blurb: '离线自动使用系统语音 —— 不联网、不带音频素材（规格 §3.3.6）。',
      children: [
        Row(
          children: [
            TextButton.icon(
              key: const Key('settings-voice-preview'),
              onPressed:
                  (_settingsReady && _coordinator != null) ? _previewVoice : null,
              icon: const Icon(Icons.volume_up, size: 18),
              label: const Text('试听'),
            ),
            const Spacer(),
            Switch(
              key: const Key('settings-voice-switch'),
              value: _voiceOn,
              onChanged: _settingsReady
                  ? (value) => _updateSettings(voiceEnabled: value)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '管的是这台手机现在出不出声：扫到不是同一件的包裹时出声提醒，'
          '表盘滑过刻度时的「咔哒」声也归它。旁边有人、或者嫌吵时关掉。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          '关掉只是不出声：屏幕上的提示和事件日志照旧，日志前面的图标会从 🔊 变成 🔇。'
          '立刻生效，不用重新开始工作 —— 它是唯一一项不用等的设置。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        // 这一行会随状态换内容：没有编排器时先说清「试听为什么按不动」，
        // 有编排器时改说最容易混的那件事（它管不到录像文件）。
        Text(
          _coordinator == null
              ? '⚠️ 试听暂时是灰的：语音通道要等第一次点【开始工作】才接上。'
              : '⚠️ 它管不到录像文件里有没有声音 —— 那是下面「录制声音」那一项。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// 试听：念那句真会播报的「开始录像」。
  ///
  /// ⚠️ **必须走编排器那一个发声漏斗**（`RecordingCoordinator.speak`），
  /// 不在这一页自己判一次 `_voiceOn` —— 那样就有了**第二道闸**，而
  /// `recording_coordinator.dart:679` 明确警告过：闸有两道、通路有两条的话，
  /// 「关掉播报」迟早会有一半失灵。
  ///
  /// ⚠️ 措辞**直接用 `VoicePrompt.startRecording`**，不为试听新造一个枚举值 ——
  /// 那个枚举存在的意义就是「措辞只有一处」，再抄一遍「开始录像」就是第二处。
  ///
  /// ⚠️ **不查许可。** 手机端整条链路没有任何许可判断（`04-许可设计.md`：手机端免费），
  /// 试听也不许是第一个。
  Future<void> _previewVoice() async {
    await _coordinator?.speak(VoicePrompt.startRecording);
  }

  // ── ②d 录制声音（需求方 2026-09-28 新增）──────

  /// 录像**文件里**带不带声音。
  ///
  /// ⚠️ 图标是**麦克风**不是喇叭 —— 需求方 2026-09-28 看过之后点名换的：
  /// 喇叭会和上面「语音提示」那张卡混起来，而这是**两件不同的事**
  /// （一个管这台手机出不出声，一个管录进去的文件里有没有音轨）。
  ///
  /// ⚠️ 它**等下次「开始工作」**才生效（跟着编排器重建走），见 [_whenCard]。
  Widget _recordAudioCard() {
    return _settingCard(
      icon: Icons.mic_none,
      title: '录制声音',
      blurb: '关闭后录像不带声音。',
      children: [
        SwitchListTile(
          key: const Key('settings-record-audio-switch'),
          contentPadding: EdgeInsets.zero,
          value: _recordAudio,
          onChanged: _settingsReady
              ? (value) => _updateSettings(recordAudio: value)
              : null,
          title: Text(_recordAudio ? '开启' : '关闭'),
          subtitle: const Text(
            '与「语音提示」是两件事：那一项管这台手机出不出声，'
            '这一项只管录像文件里有没有音轨。两个可以同时开 —— '
            '那时播报会被录进录像里。',
          ),
        ),
      ],
    );
  }

  // ── ②e 网盘视频 / 关于我们：两个二级页的入口 ───

  /// 一行 + 右箭头 → 二级页。**不改 `_tab` 那套** —— 照本页已有的先例
  /// `Navigator.push` 推上去，页里带 `AppBar` 返回。
  Widget _linkCard({
    required IconData icon,
    required String title,
    required String blurb,
    required VoidCallback onTap,
  }) {
    return _settingCard(
      icon: icon,
      title: title,
      blurb: blurb,
      children: [
        ListTile(
          key: Key('settings-link-$title'),
          contentPadding: EdgeInsets.zero,
          title: const Text('打开'),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: onTap,
        ),
      ],
    );
  }

  Widget _netdiskCard() => _linkCard(
        icon: Icons.cloud_outlined,
        title: '网盘视频',
        blurb: '把录像上传到网盘之后，按单号查回来播放。',
        onTap: _openNetdiskPage,
      );

  Widget _aboutCard() => _linkCard(
        icon: Icons.info_outline,
        title: '关于我们',
        blurb: '版本号、一句话介绍，以及把日志导出来发给我们。',
        onTap: _openAboutPage,
      );

  /// 清理流水（T24）—— 紧挨着上面那两条保留期：**「清什么」和「清过什么」
  /// 是同一件事的两面**，隔开摆的话用户找不到。
  Widget _cleanupLogCard() => _linkCard(
        icon: Icons.receipt_long_outlined,
        title: '清理流水',
        blurb: '清掉的和没清掉的每一条，都记着时间和原因。',
        onTap: _openCleanupLogPage,
      );

  void _openNetdiskPage() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // ⚠️ 把 `_client` 与 `_rootPath` 带过去：借令牌要走前者（没配对时是
        // null，那一页会如实说明并只留「自己登录」），令牌与下载都落在后者下面。
        builder: (context) => NetdiskPage(
          client: _client,
          rootPath: _rootPath,
          // 扫面单复用同一个页面与同一套相机协调 —— 尤其
          // `closeCameraWhenDone`：录制中、或发货栏取景框开着时**不能关**相机，
          // 那会掐掉别人的会话。
          onScan: (pageContext) => ScanWaybillPage.open(
            pageContext,
            gateway: _gateway,
            closeCameraWhenDone: _coordinator?.isCameraOpen != true,
            spec: _coordinator?.effectiveSpec ?? _requestedSpec(),
          ),
        ),
      ),
    );
  }

  void _openAboutPage() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 导出那件事**借这里的 state 干**（包里那几样只有这一页有）。
        builder: (context) =>
            AboutPage(onExportLogs: () => _exportDiagnostics(share: true)),
      ),
    );
  }

  void _openCleanupLogPage() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // ⚠️ `_sessions` 是**当下**那一份快照：流水里那些已经被删掉的条目不在这里，
        // 而它们正该显示「（无单号）」—— 它就是那本账存在的意义。
        builder: (context) => CleanupLogPage(
          rootPath: _rootPath,
          sessions: _sessions,
        ),
      ),
    );
  }
}
