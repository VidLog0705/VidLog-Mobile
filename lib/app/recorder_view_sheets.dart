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

  /// 白色描边字：**画两层** —— 底下那层只描边，上面那层只填充。
  ///
  /// 为什么不直接给白字加个阴影：取景画面是**实景**，底色不可控。
  /// 仓库顶灯、白墙、白面单 —— 整片白的时候纯白字就是看不见。
  /// 而看不见的时间比没有时间更糟：用户会以为设备卡死了。
  /// 深色描边在任何底色上都留得住字的轮廓。
  ///
  /// `clipBehavior: Clip.none` 是必须的：`Stack` 默认会把内容裁到自己的尺寸，
  /// 而描边有一半在字形轮廓**外面**，裁掉就变成了细一圈的填充字。
  Widget _strokedText(
    String text, {
    required Key key,
    required TextStyle style,
    Color strokeColor = Palette.backdrop,
    double strokeWidth = 3,
  }) {
    return Stack(
      key: key,
      clipBehavior: Clip.none,
      children: [
        Text(
          text,
          style: style.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..color = strokeColor,
          ),
        ),
        Text(text, style: style),
      ],
    );
  }

  /// 当前这一件的**完整**单号（规格 §3.2.6）。
  ///
  /// ⚠️ **不许省略、不许截断**：这里刻意**没有** `maxLines`、**没有**
  /// `overflow: ellipsis`。一个被截掉尾巴的单号看起来仍然像一个完整单号 ——
  /// 操作员照着抄就会抄下一个错的，而这种错当场看不出来（这正是这条要求
  /// 存在的理由）。太长就让它换行，宁可占两行也不给一个假的完整。
  Widget _waybillLine(String waybill) => Text(
        waybill,
        key: const Key('recorder-waybill'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Palette.mediaRecord, fontWeight: FontWeight.w700, letterSpacing: 1),
      );

  /// 底部浮层：刻度盘 → 时长兜底询问 → 抽屉面板 → 操作按钮 → 抽屉入口。
  ///
  /// ## 为什么刻度盘在**这一列里**、而不是 `Positioned` 贴边
  ///
  /// 这一列的高度是变的（抽屉开合、询问弹不弹）。刻度盘如果按固定 `bottom`
  /// 贴边，迟早会被某个高度的抽屉盖住 —— 而「盖住」在真机上表现为
  /// **表盘突然消失**，看起来像坏了。
  /// 放进这一列就永远不会重叠，它自己会被推上去。
  ///
  /// 位置仍然在**右下、贴右缘**，与规格 §3.1.2 的「屏幕边缘的半圆刻度盘」一致：
  /// 右手拇指从边缘划过来顺手，也不挡取景框中心（面单必须放进中心框才认）。
  Widget _actionOverlay(bool recording, bool working, bool showPreview) {
    return _scrim(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 表盘摊开时占**最上面**，整块压住取景画面上方。
            //
            // ⚠️ 它必须留在这一列里、**不能改成叠在画面上的浮层**：
            // 压在取景框正中会挡住条码（面单必须放进中心框才认得到），
            // 而挡住的后果用户只会看到「扫不出来」，看不出是界面盖的。
            // ⚠️ 门控是 `working`（点了【结束】就消失），不是 [showPreview]。
            // 需求方 2026-09-22 晚些：「对焦功能只在发货或者退货页面点开始后
            // 点结束前才触发对焦」。相机开着、却没开始工作时把【对焦】按钮
            // **整个藏掉** —— 留一个点了不生效的按钮，用户只会当成坏了。
            //
            // ⚠️ 录制中它**锁上并变灰**（T5）：表盘是「调一下看看」的控件，
            // 而录制中随手改焦段会把这一段录成前虚后实 —— 那一段是**证据**。
            if (showPreview && working && _dialOpen)
              _locked(
                recording,
                Align(
                  alignment: Alignment.centerRight,
                  child: ZoomDial(
                    ratio: _zoom,
                    minZoom: _minZoom,
                    maxZoom: _maxZoom,
                    onChanged: _onZoomChanged,
                    onEnd: _onZoomEnd,
                  ),
                ),
              ),

            // 时长兜底询问。**放在抽屉面板上面**，这样抽屉开着它也看得见 ——
            // 一个会被抽屉挡住的「是否停止」问询，用户会当它不存在。
            if (_askingToContinue) _durationPrompt(),

            // `Flexible` 是为了小屏 / 键盘弹起来时**面板先让位**，而不是整列溢出。
            // 下面那排按钮和抽屉入口必须一直够得着 —— 它们一没，页面上就没有
            // 任何出口了（`mainAxisSize: min` 的列溢出时是直接从底部裁掉）。
            if (_workSheet != null)
              Flexible(child: _locked(recording, _sheetBody())),

            // ── **底部只有一个操作按钮**（需求方 2026-09-22 裁决 #6）──
            //
            // 绿【开始】↔ 红【结束】，一个控件两副面孔。以前这里是两个并排的
            // 按钮，外加一个「停止当前录制（相机继续开着）」——
            // 那个是规格 §3.3.2:183 **明文禁止**的「手动结束当前单」按钮，
            // 之前一直挂在页面上。连续扫改成换段式之后它更没有任何存在理由了。
            //
            // 时长兜底那个【停止】/【继续】问询还在（规格 §3.3.4），
            // 但它只在问询时出现，不是常驻按钮。
            // 【对焦】按钮 —— **底部【开始】按钮的右上方**（需求方 2026-09-22 裁决）。
            //
            // 它就摆在这一列里、【开始】的正上方且靠右，于是天然落在那个角落上，
            // 不用 Stack、不会重叠、也不会在小屏上把【开始】挤出去。
            //
            // 只在**相机开着、而且在工作**时出现：没画面时调焦没意义，
            // 而没在工作时按需求方的裁决就是不该能调（见上面表盘那一处）。
            //
            // ⚠️ 录制中锁上并变灰（T5），理由与表盘同一句。
            if (showPreview && working)
              _locked(
                recording,
                Align(
                  alignment: Alignment.centerRight,
                  child: _focusButton(),
                ),
              ),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: working ? _stopWorking : (_starting ? null : _startWorking),
                icon: Icon(working ? Icons.stop : Icons.play_arrow),
                label: Text(working ? '结束' : '开始'),
                style: FilledButton.styleFrom(
                  // ⚠️ 这是本仓自己画的**实心**按钮，字是白的（`onDark`），
                  // 所以读 `*Solid` 那一组 —— 它们在两套主题下都够深。
                  backgroundColor:
                      working ? context.palette.dangerSolid : context.palette.greenSolid,
                  foregroundColor: Palette.onDark,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),

            // ⚠️ 抽屉入口锁上并变灰（T5）。
            //
            // ⚠️ **上面那个【结束】不在锁的范围里**，它是录制本身的控制 ——
            // 锁了它就没有任何出口了（`_actionOverlay` 的注释里写着这一条）。
            // 右上角那两个开关也不锁（需求方 2026-10-04）：录到一半发现灯没开、
            // 或者要临时开推流，不该先停下来。
            _locked(recording, _sheetTabs()),
          ],
        ),
      ),
    );
  }

  /// 【对焦】按钮：**方形、半透明**，点一下摊开表盘、再点一下收起。
  ///
  /// 需求方 2026-09-22 点名的形状是「方形半透明按钮」。颜色用中性的
  /// 半透明黑而不是主题色：它压在**取景画面**上，主题色在浅色主题下
  /// 会是一块浅底、白图标看不见（表盘读数那边踩过同一个坑）。
  ///
  /// **摊开与否是它自己说出来的**（图标与底色都变）：表盘占的那块地方
  /// 在收起时是空的，如果按钮本身毫无变化，用户会怀疑刚才那下点没点上。
  Widget _focusButton() {
    final open = _dialOpen;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        width: 56,
        height: 56,
        child: Material(
          color: open ? Palette.backdrop.withValues(alpha: 0.55)
                      : Palette.backdrop.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(Corners.note),
          child: InkWell(
            key: const Key('recorder-focus-button'),
            borderRadius: BorderRadius.circular(Corners.note),
            // 收起时把三个字段一起清掉（见 `_closeDial` 的说明）。
            // 摊开时不清：那样每次点开都从「没响过」开始，第一下滑动必定响一声，
            // 而用户只是把面板收了又开。
            onTap: () => setState(() {
              if (_dialOpen) {
                _closeDial();
              } else {
                _dialOpen = true;
              }
            }),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.center_focus_strong,
                  size: 22,
                  color: Palette.onDark.withValues(alpha: open ? 1.0 : 0.85),
                ),
                const SizedBox(height: 2),
                Text(
                  '对焦',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Palette.onDark),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 录制中把一块次要控件**锁住，并让它看得出来被锁了**（改造清单 T5）。
  ///
  /// ## 为什么是两半，不是一半
  ///
  /// **`AbsorbPointer` 只拦不灰。** 只用它的话，按钮看着和平时一模一样、
  /// 点下去什么都不发生 —— 那正是踩坑 #13 的假开关，也正是不该做的那个版本：
  /// 用户会以为界面卡死了，然后把 App 杀掉重开，而**那一段录制还在跑**。
  ///
  /// 反过来只用 `Opacity` 也不够：那样只是「看着灰了」，真按下去照样生效 ——
  /// 而这几块控件被锁的理由是**它们会动到正在录的这一段**（改焦段、改工作模式、
  /// 手动录入单号），不是「看着不好看」。
  ///
  /// 所以：`AbsorbPointer` 是真拦的那道闸，`Opacity` 是让用户一眼看出来的那道。
  ///
  /// ## 为什么用 `Opacity` 而不是换一套灰配色
  ///
  /// Material 的禁用态本来就是「内容按 38% 不透明度画」，这里照抄这个数。
  /// 更要紧的是：这一块的底是**实景画面**（仓库顶灯、白墙、白面单），
  /// 不可控 —— 换配色解决不了「压在什么底上」，降不透明度可以。
  ///
  /// ## 谁不在锁的范围里（锁错了就是另一类事故）
  ///
  /// - **底部那个【结束】按钮**：录制本身的控制。锁了它，页面上就没有出口了。
  /// - **时长兜底询问的那对【停止】/【继续】**：同上，它是录制流程自己的问询。
  /// - **右上角的手电筒与实时共享**（需求方 2026-10-04 点名）：
  ///   录到一半发现灯没开、或者要临时开推流，不该先停下来再开。
  /// - **底部导航栏**：本来就不锁。`_onTabChanged` 的注释里写着理由 ——
  ///   手指误滑到设置就掐掉一段正在录的像，比多开一会儿糟糕得多。
  Widget _locked(bool locked, Widget child) => locked
      ? AbsorbPointer(child: Opacity(opacity: 0.38, child: child))
      : child;

  /// 压在画面上的一层：上/下两端深、中间透明。
  ///
  /// 用渐变而不是整块纯色，是为了**中间那段取景尽可能干净** ——
  /// 操作员是透过这块屏看面单的。
  ///
  /// [top] 为真时方向反过来（顶部浮层用）。
  Widget _scrim({required Widget child, bool top = false}) {
    const solid = 0.72;
    const clear = 0.0;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: top ? Alignment.bottomCenter : Alignment.topCenter,
          end: top ? Alignment.topCenter : Alignment.bottomCenter,
          colors: [
            Palette.backdrop.withValues(alpha: clear),
            Palette.backdrop.withValues(alpha: solid),
          ],
        ),
      ),
      child: SafeArea(top: top, bottom: !top, child: child),
    );
  }

  /// 时长兜底询问（规格 §3.3.4）。
  Widget _durationPrompt() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.palette.amberTint,
        borderRadius: BorderRadius.circular(Corners.card),
      ),
      child: Column(
        children: [
          const Text(
            '录制时间即将超时，是否需要停止录制？',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              FilledButton(
                onPressed: () =>
                    _coordinator?.onDurationPromptAnswered(continueRecording: false),
                child: const Text('停止'),
              ),
              OutlinedButton(
                onPressed: () =>
                    _coordinator?.onDurationPromptAnswered(continueRecording: true),
                child: const Text('继续'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 抽屉入口。展开的那一块显示 `▾`，其余显示 `▸`。
  ///
  /// 每个入口带 `Key`：面板标题里也含「手动输入」这四个字，按下之后
  /// `find.textContaining` 会同时命中入口和面板，测试没法点。
  Widget _sheetTabs() {
    Widget tab(_WorkSheet sheet, String label) => Expanded(
          child: TextButton(
            key: Key('work-sheet-${sheet.name}'),
            onPressed: () => setState(
              () => _workSheet = _workSheet == sheet ? null : sheet,
            ),
            child: Text(
              '$label ${_workSheet == sheet ? '▾' : '▸'}',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Palette.onDarkSoft),
            ),
          ),
        );

    return Row(
      children: [
        tab(_WorkSheet.manual, '手动输入'),
        // 条数跟着日志走，所以只有这一个入口需要订阅 ——
        // 整页 `setState` 换成这一个 `TextButton` 重建。
        ValueListenableBuilder<List<String>>(
          valueListenable: AppLog.instance.tail,
          builder: (context, events, child) =>
              tab(_WorkSheet.events, '事件 ${events.length}'),
        ),
        tab(_WorkSheet.diagnostics, '诊断'),
      ],
    );
  }

  Widget _sheetBody() {
    return _panel(
      switch (_workSheet!) {
        _WorkSheet.manual => _manualEntrySheet(),
        // 固定高度 + 内部自滚：这块**不能**用 `SingleChildScrollView` 包，
        // 里面是 `ListView`，两个都可滚会直接报「高度无界」。
        _WorkSheet.events => SizedBox(height: 140, child: _eventsList()),
        _WorkSheet.diagnostics => ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(child: _diagnosticsBody()),
          ),
      },
    );
  }

  /// 抽屉面板：**不透明**的浅色卡片。
  ///
  /// 操作条可以半透明（那是按钮，认得形状就行），**正文不行** ——
  /// 12 号字压在一幅画面很乱的取景上根本读不出来。
  Widget _panel(Widget child) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(Corners.card),
      ),
      child: child,
    );
  }

  /// 「手动输入单号」—— 规格 §3.2.2 要求的兜底。
  ///
  /// > 框内始终识别不到时，用户必须能手动输入单号兜底，**且不打断当前录制**。
  ///
  /// 「不打断」指的是**不经过停录**：这个面板是叠在画面上的，录制一直在跑。
  Widget _manualEntrySheet() {
    // 自己可滚：外面那层 `Flexible` 会给它一个上界，内容超过就内部滚，
    // 而不是把下面那排按钮顶出屏幕。
    return SingleChildScrollView(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('手动输入（扫码失灵时的兜底）',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          '框里一直认不出来时，直接手动输单号就行 —— 不会打断正在录的。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _waybillController,
          decoration: const InputDecoration(
            labelText: '单号',
            helperText: '在录时输入并点下面按钮 = 复扫；未录时 = 开一段新的。',
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _coordinator?.isWorking == true ? _simulateScan : null,
          icon: const Icon(Icons.keyboard),
          label: const Text('当作扫到了这个单号'),
        ),
      ],
      ),
    );
  }

  /// 事件列表。
  ///
  /// **它内部没有平台视图，滚起来是顺的** —— 这也是它敢放在取景画面上的原因。
  Widget _eventsList() {
    return ValueListenableBuilder<List<String>>(
      valueListenable: AppLog.instance.tail,
      builder: (context, events, child) {
        if (events.isEmpty) {
          return Center(child: Text('（还没有事件）', style: Theme.of(context).textTheme.bodySmall));
        }

        return ListView.builder(
          itemCount: events.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(events[index], style: Theme.of(context).textTheme.bodySmall),
          ),
        );
      },
    );
  }

  /// 诊断：盘上的实况与收尾结果。
  ///
  /// 这些数字真机验收时**要盯着看**，所以给它们一个固定的去处，
  /// 而不是散在各处等人找。
  /// 日志级别。
  ///
  /// ⚠️ <b>放在**诊断面板**里，不是设置页</b>：设置页是照设计图做的，图上没有这一项
  /// （「不许有任何未经我允许的更改」）。而这一格是**本仓自己的诊断面** ——
  /// 真机上遇到问题时人本来就会翻到这里。
  ///
  /// ⚠️ 改完**立刻生效、不必重装** —— 那正是它存在的理由：
  /// 等我们发一个新包就等于那条日志永远拿不到。
  Widget _logLevelRow() => ValueListenableBuilder<AppLogLevel>(
        valueListenable: _logLevel,
        builder: (context, current, _) => Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('日志级别', style: Theme.of(context).textTheme.bodySmall),
            for (final level in AppLogLevel.values)
              ChoiceChip(
                label: Text(level.wire),
                selected: level == current,
                onSelected: (_) {
                  AppLog.instance.setMinLevel(level);
                  _logLevel.value = level;
                },
              ),
          ],
        ),
      );

  Widget _diagnosticsBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _logLevelRow(),
        const Divider(height: 20),
        Text('工作区 $_sessionCount 个会话（未收尾 $_pendingCount）'),
        Text('索引 $_entryCount 条 · 打点 $_punchCount 条'),
        const SizedBox(height: 8),
        Text(
          '单段时长 ${RecordingCoordinator.defaultSegmentDuration.inMinutes} 分钟 —— '
          '崩溃最多丢这一段，所以每录满一段就自动封一个文件',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_recovered.isNotEmpty) ...[
          const Divider(height: 20),
          _recoveredBody(),
        ],
        const Divider(height: 20),
        // 一键诊断包（`AGENTS.md` §6：日志要能导出为诊断包，用户一键打包发回）。
        // 放在**已有的**诊断抽屉里，不新增界面面。
        //
        // ⚠️ 2026-10-03 起生成后**顺手弹系统分享面板**（与【关于我们】那一颗
        // 同一件事）。改这一下的理由：Android 那边这个文件落在 app 私有目录，
        // 以前只有一句「自己去找」——而**那句提示分不出「用户找不到」和
        // 「用户没找」**，等于这条路上只有 iOS 走得通（见
        // `DiagnosticsPackage` 的类注释）。多这一步就条条路都走得通了。
        FilledButton.tonal(
          onPressed: () async {
            final note = await _exportDiagnostics(share: true);
            if (mounted) setState(() => _diagnosticsNote = note);
          },
          child: const Text('导出诊断包'),
        ),
        const SizedBox(height: 4),
        Text(
          _diagnosticsNote ?? '遇到问题时点它，把它发回来。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// 生成诊断包并说清**它落在哪**。返回要在界面上显示的那句话。
  ///
  /// ⚠️ iOS 上路径不用解释：`Info.plist` 里已有 `UIFileSharingEnabled`，
  /// 那个目录就是「文件 → 我的 iPhone → VidLog」。Android 是弱侧，
  /// 所以顺带把路径**显示出来并可复制**（用户能自己去找）。
  ///
  /// [share] 为真时**顺手把它交给系统分享面板**（需求方 2026-10-03：
  /// 「手机端日志导出后可以使用手机自带分享功能」）。
  /// ⚠️ 分享没成**不等于没导出** —— 两句话分开说，路径照给：
  /// 笼统说一句「失败」会让用户以为文件也没了。
}
