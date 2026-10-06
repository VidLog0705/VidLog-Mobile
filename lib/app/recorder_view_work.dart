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

  /// 采集页：**取景铺满整页**，状态与操作是压在上面的浮层。
  ///
  /// ## 为什么从「取景钉住 + 其余滚动」改成全屏
  ///
  /// 需求方 2026-09-22：**页面全屏显示手机摄像头画面**。
  ///
  /// 改完全屏，原来那套 `CustomScrollView` + pinned 头**反而可以扔掉了** ——
  /// 它是为了绕开一个坑才存在的：「原生预览视图（`UiKitView`）不能放进滚动容器，
  /// iOS 上平台视图会逐帧重组，真机上的表现就是上下滑发卡」。
  /// 全屏之后取景是**底层铺满**、控件叠在上面（`Stack`），
  /// 滚动容器里压根没有平台视图了，那个坑自动消失。
  ///
  /// ## 三层，从下往上
  ///
  /// 1. **画面** —— 黑底 + 居中按 9:16 摆的预览
  /// 2. **顶部浮层** —— 状态、单号、已录时长、发货/退货标签、诊断计数
  /// 3. **底部浮层** —— 刻度盘、时长兜底询问、抽屉面板、操作按钮、抽屉入口
  ///
  /// ## ⚠️ 黑边是**故意留的**，不是没铺满
  ///
  /// 录像按生效的录制规格摆（竖屏 9:16、横屏 16:9）。
  /// `CameraPreview` 用的是 `Center` + `AspectRatio`，**不是 `BoxFit.cover`** ——
  /// 因为框的判定范围与画出来的框**共用同一份归一化坐标**（见 `camera_preview.dart`）。
  /// 裁掉两边会让「框内 / 框外」的口径跟着变，而用户看到的框会**骗人**。
  /// 需求方 2026-09-22 选了「保留黑边，不动判定」。
  ///
  /// 长屏（20:9）上下各约 75px 黑边；黑边本来就是黑的，远看就是满屏。
  Widget _workPage(bool recording, bool working) {
    final gate = _coordinator?.scanGate;

    // ⚠️ **判的是相机开没开，不是工作没工作**（2026-09-22 改）。
    // 「进栏就自动开相机、但还没开始工作」是现在的常态 —— 沿用
    // `working` 的话，用户进栏只会看到「相机还没开」那块提示，
    // 而相机其实开着、表盘也划不动。画的与判的仍是**同一份** `gate`。
    final showPreview = _coordinator?.isCameraOpen == true && gate != null;

    return Theme(
      // ⚠️ 这一层是**故意**的：压在实景上的控件不跟新配色走。
      // 谁把它拆掉，`test/widget_test.dart` 里那条冻结测试就会红。
      data: _cameraOverlayTheme,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        // 全屏取景是黑底，状态栏默认的深色字压在上面看不见。
        value: SystemUiOverlayStyle.light,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── ① 画面：铺满整页 ──
            ColoredBox(
              color: Palette.backdrop,
              child: showPreview
                  ? CameraPreview(
                      viewfinder: gate.viewfinder,
                      // 画面比例取自**实际**那一档（编排器探测之后的结论）——
                      // 与取景框同一份来源，两者才不会各自歪一点。
                      aspectRatio: _coordinator!.effectiveSpec.aspectRatio,
                    )
                  // ⚠️ 未校准时**换掉整块画面**（规格 §3.6.4）。
                  // 只把那句「相机还没开」留在原地的话，用户看到的是一个
                  // **看着一切正常**的界面，而按【开始】什么都不发生。
                  : (_clockBlockedReason != null
                      ? _clockBlockedScreen()
                      : _idleScreen()),
            ),

            // ── ② 顶部浮层：状态与诊断计数 ──
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _statusOverlay(recording, working),
            ),

            // ── ③ 底部浮层：刻度盘 + 询问 + 抽屉 + 操作 ──
            //
            // ⚠️ **不能写成 `Positioned(bottom: 0)`**，虽然只差这一层 `Align`。
            //
            // 只给 `bottom` 的 `Positioned` 传下来的是**无界高度**
            // （`RenderStack` 只在 top/bottom 都给、或给了 height 时才约束高度）。
            // 无界高度下 `RenderFlex` 走不到弹性分支 —— 于是列里的 `Flexible`
            // **完全不生效**，`_sheetBody()` 那个 `Flexible` 就是个摆设，
            // 键盘弹起来时面板顶部依旧从屏幕顶上冒出去（实测 y = -38）。
            //
            // `Positioned.fill` + `Align(bottomCenter)` 先把高度**框死在正文高度**内，
            // 再由 `Align` 松约束给孩子，`Flexible` 才真的能把面板压扁。
            Positioned.fill(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: _actionOverlay(recording, working, showPreview),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 相机还没开时铺在底层的提示。
  ///
  /// **不画一块假的取景框**：没开相机就没有画面，画个框在那儿等于告诉用户
  /// 「把面单放进去」，而他放进去什么都不会发生。
  Widget _idleScreen() => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '相机还没开。\n点下面的【开始】重试。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Palette.onDarkFaint, fontSize: 14, height: 1.6),
          ),
        ),
      );

  /// 未校准时的整块画面（规格 §3.6.4）。
  ///
  /// **说清三件事**（规格对界面的要求）：为什么不能录 / 怎么办 /
  /// **已有的录像照常**（检索、回放、导出、交付都不受影响）——
  /// 最后那句不能省：不说的话，用户会以为「整个应用废了」，
  /// 而其实只是**不能再录新的**。
  Widget _clockBlockedScreen() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.schedule, color: Palette.mediaWarn, size: 40),
              const SizedBox(height: 12),
              Text(
                _clockBlockedReason!,
                key: const Key('clock-blocked-reason'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Palette.onDark, fontSize: 15, height: 1.6),
              ),
              const SizedBox(height: 8),
              const Text(
                '视频里的时间必须能追溯到本机之外的某个来源 —— 否则改一下系统时间就能伪造'
                '「更早的证据」。联一次网取到时间之后，以后一直断网也能照常录。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Palette.onDarkFaint, fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 4),
              const Text(
                '⚠️ 只挡住新录：已有的录像照常可以检索、回放、导出、交付。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Palette.onDarkFaint, fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('clock-recalibrate'),
                onPressed: _starting ? null : _recalibrate,
                child: const Text('重新校准'),
              ),
            ],
          ),
        ),
      );

  /// 顶部浮层：谁在这儿、在录什么、录了多久、盘上什么情况。
  ///
  /// 前三项给操作员看，最后那行**诊断计数给真机验收看** ——
  /// 「打点 N 条」是打点那条验收唯一的当场凭据（打点与收尾是两条独立的链，
  /// 各要各的数字），所以它必须**不用点开任何东西**就能看见。
  Widget _statusOverlay(bool recording, bool working) {
    return _scrim(
      top: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 右上角：两个图标开关（需求方 2026-10-03）──
            //
            // ⚠️ 它们**独占一行**，不挤进时钟那一行、也不挤进状态行：
            // 时钟是 26 号字（一行几乎占满宽度），状态行还要放
            // 「录制中 / 已录 00:00 / 发货-退货」—— 再塞两个按钮进去，
            // 状态字会被挤成一两个字加省略号。代价是时钟往下让一行。
            _workSwitches(),

            // ── 画面**正上方**：实时时间 → 完整单号（规格 §3.2.6）──
            //
            // 居中、两行，压在状态行**上面**。放在这儿是因为它俩是同一类东西：
            // 都是给「事后对着录像核时间、核单号」用的当场凭据，
            // 而状态行讲的是「这台设备现在在干什么」，不是同一件事。
            Center(
              child: _strokedText(
                _clockStamp(_now),
                key: const Key('recorder-clock'),
                style: const TextStyle(
                  color: Palette.onDark,
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                  // ⚠️ 两个 Text 叠出来的是**同一个字符串**，行高必须一致，
                  // 否则描边层与填充层会错开半个像素、字看起来是糊的。
                  height: 1.1,
                ),
              ),
            ),

            // 第二行只在**录制中**才有内容（规格 §3.2.6）。
            //
            // 没在录时不放占位符、也不拿上一件的号凑数：那一行是「这一段录的
            // 是哪一件」，空着时它没有答案 —— 填一个进去，用户会以为录上了。
            if (recording && (_coordinator?.currentWaybill?.value.isNotEmpty ?? false)) ...[
              const SizedBox(height: 2),
              Center(child: _waybillLine(_coordinator!.currentWaybill!.value)),
            ],

            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  recording
                      ? Icons.fiber_manual_record
                      : (working ? Icons.photo_camera : Icons.stop_circle_outlined),
                  color: recording ? Palette.mediaRecord : Palette.onDarkSoft,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    // 「在工作（相机开着）」和「在录」是两回事，界面上要分得清。
                    //
                    // ⚠️ 单号**不在这儿**了（2026-09-22 晚些）：它挪到上面自成
                    // 一行 —— 挤在这一行里只能省略号收尾，而截断的单号
                    // 看起来仍然像个完整单号，抄下来就是错的。
                    recording ? '录制中' : _status,
                    style: const TextStyle(color: Palette.onDark, fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (recording) ...[
                  const SizedBox(width: 8),
                  Text(
                    '已录 ${_two(_elapsed.inMinutes)}:${_two(_elapsed.inSeconds % 60)}',
                    style: const TextStyle(
                      color: Palette.onDark,
                      fontSize: 20,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                // 这一件是发货还是退货。两栏的采集流程一模一样，
                // 操作员得能一眼看出自己在哪一栏 —— 否则录完了才发现归类错了。
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(_isReturn ? '退货' : '发货'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '工作区 $_sessionCount（未收尾 $_pendingCount）'
              ' · 索引 $_entryCount · 打点 $_punchCount',
              style: const TextStyle(color: Palette.onDarkSoft, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // ── 采集页右上角那两个图标开关（需求方 2026-10-03）──

  /// 右上角那一排：实时共享、手电筒。
  ///
  /// ⚠️ **两个都是真开关，画之前先问清楚**：
  /// - 实时共享：**一直画**。它是一条设置（按下去立刻有句实话回你，
  ///   见 [_toggleLiveShare]），相机没开也照样能开；
  /// - 手电筒：**设备没有闪光灯就不画**（[_torchUsable] 为假、或者还没问出来
  ///   都算没有）。踩坑 #13：不画按下去什么都不发生的假开关。
  ///
  /// 顺序是**手电筒在左、实时共享在右**：投屏那个常年开着不动，灯是一时一开
  /// 的，靠边的位置留给「平时不碰」的那个。
  Widget _workSwitches() {
    final liveOn = _liveShareOn;

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (_torchUsable == true) ...[
          _overlaySwitch(
            key: const Key('work-torch'),
            icon: _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
            on: _torchOn,
            tooltip: _torchOn ? '关掉手电筒' : '打开手电筒',
            onPressed: _toggleTorch,
          ),
          const SizedBox(width: 8),
        ],
        _overlaySwitch(
          key: const Key('work-live-share'),
          icon: liveOn ? Icons.cast_connected : Icons.cast,
          on: liveOn,
          // ⚠️ 起不来 / 被录制压力停掉时**换颜色**：原因那句话已经当场弹过了
          // （见 `_reportLiveShareProblem`；设置页那张卡 2026-10-03 删了）。
          // 这里留着是让「它现在有事」这个状态**一直看得见** —— 弹窗会自己走掉。
          // 不说的话，用户看到的就是「图标亮着，而电脑端没有我这台机位」。
          warning: _liveShareProblem != null,
          tooltip: liveOn ? '关掉实时共享' : '打开实时共享',
          onPressed: _toggleLiveShare,
        ),
      ],
    );
  }

  /// 压在取景画面上的那个圆形图标开关。
  ///
  /// ⚠️ 底色必须是**半透明深色**：压在实景上（顶灯、白墙、白面单），
  /// 一块不透明的浅底会在白面单上糊成一片 —— 与 [_strokedText] 同一个理由。
  /// 「开着」用主色（与表盘、抽屉同一支蓝），「出事了」用橙色。
  Widget _overlaySwitch({
    required Key key,
    required IconData icon,
    required bool on,
    required String tooltip,
    required VoidCallback onPressed,
    bool warning = false,
  }) {
    final primary = Theme.of(context).colorScheme.primary;

    return IconButton(
      key: key,
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 22),
      style: IconButton.styleFrom(
        backgroundColor: warning
            ? Palette.mediaWarn.withValues(alpha: 0.9)
            : on
                ? primary.withValues(alpha: 0.9)
                : Palette.backdrop.withValues(alpha: 0.45),
        foregroundColor: (on || warning) ? Palette.onDark : Palette.onDarkSoft,
      ),
    );
  }

  /// 手电筒开关。
  ///
  /// ⚠️ **先翻图标、失败再翻回来**：原生那边与对焦一样是尽力而为
  /// （相机可能刚好在关、系统可能不让），而图标亮着而灯没亮是最难解释的
  /// 一种「坏了」—— 用户会以为这台机器的手电筒坏了。
  Future<void> _toggleTorch() async {
    final wanted = !_torchOn;
    setState(() => _torchOn = wanted);

    try {
      await _gateway.setTorch(wanted);
      _log('手电筒${wanted ? '开' : '关'}了');
    } on Object catch (error) {
      if (mounted) setState(() => _torchOn = !wanted);
      _log('⚠️ 手电筒${wanted ? '开' : '关'}不了：$error');
    }
  }

  /// 实时共享开关。**2026-10-03 从设置页搬到这里**（需求方）：
  /// 工人是在取景的时候想开就开，不该为它跑一趟设置页。
  ///
  /// ⚠️ 它改的是**设置**，不是一个当场动作 —— 打开要等下次【开始工作】
  /// （推流那一路是开会话时接上的，中途接会打断正在录的那一段），
  /// 关掉是立刻停的。所以按完**必须说一句实话**：不说的话，这个按钮看起来
  /// 就是「亮了但什么都没发生」的假开关（踩坑 #13）。
  ///
  /// 那句实话**优先用原生给的**：安卓那边会说「还要等下一次【开始工作】才生效」，
  /// 这里再编一句就成了第二份说法。
  Future<void> _toggleLiveShare() async {
    // 盘上的设置还没读出来（开机头一两秒）—— 这时改不了任何设置，
    // 说了「已开」就是假话。如实说一句，与设置页那些控件禁用同一个道理。
    if (!_settingsReady) {
      _snack('设置还没读出来，稍等一下再按。');
      return;
    }

    final wanted = !_liveShareOn;

    _updateSettings(liveShareEnabled: wanted, applyLiveShare: false);
    await _applyLiveShare();

    if (!mounted) return;

    _snack(wanted
        ? (_liveShareProblem ??
            ((_liveShare?.isRunning ?? false)
                ? '实时共享已开：正在推流。'
                : '实时共享已开：下次点【开始工作】时开始推流。'))
        : '实时共享已关，已经停了。');
  }
}
