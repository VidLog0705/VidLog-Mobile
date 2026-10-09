// ignore_for_file: invalid_use_of_protected_member
//
// ⚠️ 上面这条是这套拆法**必须付的价**，不是图省事：`State.setState` 带
// `@protected`，而分析器不把 `extension on _RecorderPageState` 认作
// 「State 的子类内部」，于是本文件里每一处 `setState(` 都报这一条。
// 语言本身允许（同一个 library、编译通过、测试全绿）—— 那是 lint 的误报，
// 它判的是「在不在子类里」，认不出 extension。只收窄这一条规则，
// 不做 `ignore_for_file: all`。

part of 'recorder_page.dart';

// T26③ 第 2 轮第 3 刀：从 `recorder_page.dart` 整段搬过来的 —— **纯搬家**。
// 一行都没改，只是位置换了（内容多重集比对可证）。这里装的是录制控制与相机：协调器、动作、场景变化、变焦/对焦/手电、心跳、资源。
//
// ⚠️ 能装进来的只有实例方法 / getter：extension **不许声明实例字段**，
// 所以 88 个字段全都留在壳的类体里 —— 同 library，这里不带前缀照样读得到。
// 静态成员另说，见下面那段。

// ─────────────────────────────────────────────────────────────────────
// ⚠️ 下面两个常量是**顶层**声明，不是 `_RecorderPageState` 的静态成员 ——
// 这一条和 `recorder_format.dart` 里的纯函数同一个理由，但触发它的是另一条
// 规则：extension **不许**不带前缀地引用被扩展类型的静态成员，
// `dart analyze` 当场报 `unqualified_reference_to_static_member_of_extended_type`
// （2026-10-06 实测）。它们各自只有一个引用者，且都在本文件里，
// 所以直接改成顶层常量跟着搬过来 —— 调用点一个字都不用动。
// ─────────────────────────────────────────────────────────────────────

/// 滑动时两次重新对焦之间至少隔多久。
const _focusThrottle = Duration(milliseconds: 250);

/// 资源读取的间隔。**30 秒**是本仓标定的（规格没给数）：
/// 够快（电量从阈值掉到关机不止 30 秒），又不至于每秒过一趟通道。
const _resourcePollInterval = Duration(seconds: 30);

extension on _RecorderPageState {

  /// 重建编排器（换模式、重新开始工作）。
  ///
  /// ⚠️ **必须先释放旧的**（2026-09-22 修）。旧的订阅着 `gateway.events`，
  /// 只把字段覆盖掉的话那条订阅还活着 —— 从此每来一条原生事件，两个编排器
  /// 都会各自反应一次（各写一遍 manifest、各落一条打点）。按第二次【开始】
  /// 就会这样，而画面上看不出来。
  ///
  /// **相机不跟着关**（`releaseCamera: false`）：它是进程级的**同一个原生
  /// 会话**，跟换不换编排器无关。新编排器用 `cameraAlreadyOpen` 把这个事实
  /// 继承过去 —— 否则按下【开始】那一瞬间界面会以为相机没了、把取景画面
  /// 换回「相机还没开」那块提示，而且原生还要白重建一次捕获会话。
  Future<void> _buildCoordinator() async {
    // 相机开着的话，**连「它是按什么开的」一起继承**（`dispose` 之前读）。
    //
    // 只传「开着」是不够的：新编排器如果以为「从来没开过」，它开相机那一步
    // 就判不出「录音开关变了没有」，于是那一趟 `gateway.openCamera` 带着新的
    // 开关过去、原生却因为会话已经开着直接早退 —— 麦克风根本没加进去。
    // 结果是开关打开、文件里没有声音，而且一句话都不报（踩坑 #13）。
    final cameraWasOpen = _coordinator?.isCameraOpen ?? false;
    final appliedSpec = _coordinator?.appliedSpec;
    final appliedAudio = _coordinator?.appliedAudio;
    final appliedLive = _coordinator?.appliedLive;
    await _coordinator?.dispose(releaseCamera: false);

    _coordinator = RecordingCoordinator(
      gateway: _gateway,
      workspace: _workspace,
      finalizer: _finalizer,
      punchLog: _punchLog,
      // 错码保护触发的事件要落盘（规格 §6.1「必须保存的事实」里的「错误扫描」）。
      scanErrors: _scanErrors,
      mode: _mode,
      config: _config,
      cameraAlreadyOpen: cameraWasOpen,
      appliedSpec: appliedSpec,
      appliedAudio: appliedAudio,
      appliedLive: appliedLive,
      // ⚠️ 可信时钟（规格 §3.6.4）——**未校准不得开始录制**。
      // 传真的那个（不是 null）：`null` 是给测试留的「不设闸」。
      trustedClock: _clock,
      // 录制规格也在这里交给编排器 —— **必须在它开相机之前**：
      // 相机会话的分辨率是开会话时定死的（iOS 的 preset / 安卓选出来的
      // 输出尺寸），开着的时候改不了。进栏就自动开的那台相机也要按这一档开，
      // 否则「用户选了 4K、屏幕上却是 720P 的画面」要等下一个人按下【开始】
      // 才会对上。
      spec: _requestedSpec(),
      onAction: _onAction,
    )
      ..onBarcodeAccepted = _onBarcodeAccepted
      ..onBarcodeTooShort = _onBarcodeTooShort;

    // 可用性检查是异步的（要问原生），所以构造之后单独走一步 ——
    // 它同时把取景框的画面比例按生效的那一档算好（规格 §3.2.2 的连带项）。
    await _coordinator!.resolveRecordingSpec(_requestedSpec());
    _coordinator!.onFinalized = _onFinalized;
    _coordinator!.onSceneChanged = _onSceneChanged;
    _coordinator!.onPackageTrackingChanged = (left) =>
        _log(left ? '📦 包裹离开取景框' : '📦 包裹回到取景框');
    _coordinator!.onNativeFailure = (message) => _log('⚠️ $message');

    // 播音开关是**可变字段**，新建出来的编排器默认是「开」，
    // 所以要在这里补一次 —— 不然「开始工作」重建之后它会自己打开。
    _applyVoice();

    // 发货 / 退货也是可变字段（换段那些会话是在编排器里开起来的，
    // 而用户切栏不重建编排器）。新建出来的默认是 null，同样要补一次。
    _applyBusinessType();
  }

  /// 把当前的播报开关推给编排器（它自己不会去读设置）。
  void _applyVoice() {
    _coordinator?.voiceEnabled = _voiceOn;
  }

  /// 把「这一件是发货还是退货」推给编排器（它自己不会去读界面）。
  ///
  /// 与 [_applyVoice] 同一个理由、同一个时机：它在工作中可以改
  /// （发货↔退货互切不重建编排器），所以每次进采集栏都要推一次。
  void _applyBusinessType() {
    _coordinator?.businessType = _businessType;
  }

  /// 画面静下来 / 又动起来。
  ///
  /// 这条观测是给「静止停录」那两条验收用的：**静止计时从画面静下来那一刻起算**，
  /// 不是从开录起算。扫码时手机在手上、画面在动，所以「开录后 4 分钟才停」
  /// 完全可能是正确的（扫码 2 分钟 + 静止 2 分钟）。没有这条日志就分不清
  /// 它和「封顶失效」。
  void _onSceneChanged(bool isStatic) {
    // ⚠️ **问编排器「现在有没有在计静止」，别看静止档位开关。**
    //
    // 档位关掉时打这条是误导（真机上就是这么被误会的），所以这里要有一道闸 ——
    // 但闸的判据**不是**「档位开没开」：扫码静止停录有**它自己的 2 秒**，
    // 档位设成「关闭」时它的静止计时照样在跑。按档位判，这条日志会恰好在
    // 那个模式下被整个吃掉，而那正是最需要它的场合。
    //
    // 判据放在状态机那边（`StopController.isStaticTimingActive`），与真正
    // 决定停不停的那一份**共用同一个 getter** —— 两处各自写一遍的话，
    // 它们会从这里开始慢慢走岔。
    if (_coordinator?.stopController.isStaticTimingActive != true) return;

    _log(isStatic ? '👁 画面静止 —— 静止计时从现在起算' : '👁 画面恢复活动 —— 静止计时重置');
  }

  /// 一段录制收尾完成。
  ///
  /// **必须接这个**：停录时界面只来得及显示「正在收尾」，而收尾是异步的。
  /// 不接的话界面会**永远停在「正在收尾」**—— 看起来像卡住了，其实早就收完了。
  /// 真机上就是这么被误会的。
  Future<void> _onFinalized(FinalizeOutcome outcome) async {
    if (!mounted) return;

    // 收尾那条日志**照记**。⚠️ 位置在下面那个提前返回**之前** ——
    // 换段式连续扫时那个 return 会先跳走，而它跳走的正是「上一段收尾回来、
    // 下一段已经在录」这个**最常见的**路径。原来那句注释写的就是这个意思，
    // 只是顺序放反了，于是连续扫时这条日志一条都留不下来。
    _log(outcome.succeeded ? '✓ 已收尾入库' : '✗ 收尾失败：${outcome.failureReason}');

    // 刚入库的这一段立刻进上传队列（规格 §4.1 的状态图：已入库 → 进入上传队列）。
    // 同样要在这个提前返回之前 —— 连续扫恰恰是最需要「录完就传」的场景，
    // 那些段要是等到收工才排队，中间断一次电就全卡在手机里了。
    if (outcome.succeeded) unawaited(_runUploads());

    // 换段式连续扫（2026-09-22）：上一段收尾回来时，下一段**可能已经在录了**。
    // 这里要是照旧把状态刷成「已收尾」，画面上会显示「已收尾 · 索引里共 N 条」
    // —— 而相机正录着，用户看到的是假的。状态不动。
    if (_coordinator?.isRecording == true) return;

    await _refreshDiagnostics();
    if (!mounted) return;

    setState(() {
      _status = outcome.succeeded
          ? '已收尾 · 索引里共 $_entryCount 条'
          : '收尾失败：${outcome.failureReason}';
    });
  }

  // ─────────────────────────────────────────────
  // 状态机要的动作
  // ─────────────────────────────────────────────

  void _onAction(RecorderAction action) {
    if (!mounted) return;

    switch (action) {
      case StartRecording():
        // ⚠️ **必须在这里重新起心跳**（2026-09-22 加）。下面是停录那一臂取消
        // 心跳的地方，而换段式连续扫让「停录」从一次/班变成了**一次/件** ——
        // 只在 `_startWorking` 里起一次的话，换完第一件之后
        // `handleHeartbeat` 再也不会被调用：【画面静止停录】与【时长兜底】
        // 双双失效、已录计时也不走了，而画面上一切正常。
        _startHeartbeat();
        setState(() {
          _status = '录制中';
          _askingToContinue = false;
        });
        _log('开录 · 模式 ${_modeLabel(_mode)}');

      case StopRecording(:final trigger):
        _heartbeat?.cancel();
        _heartbeat = null;
        setState(() {
          _status = '已停止（${_triggerLabel(trigger)}）· 正在收尾';
          _askingToContinue = false;
          _elapsed = Duration.zero;
        });
        _log('停录 · ${_triggerLabel(trigger)}');
        // 不在这里刷盘：收尾是异步的，这一刻盘上还没有这次会话 ——
        // 刷出来的是收尾前的旧数字，随后 `_onFinalized` 还会再刷一次
        // （那次才是对的）。留着只会让人误读。

      case WarnResource(:final reason):
        // 设备资源告警（规格 §3.1.1）—— 让用户看见「为什么突然停了」。
        //
        // ⚠️ 与 `Speak` 那条**不是一回事**：语音说过就没了，而这一条要在屏幕上
        // **留着**（它是 `_status`，会一直显示到下一次状态变化）——
        // 操作员错过那一句语音时，至少能从界面上看出是过热/电量/存储。
        setState(() => _status = '资源告警（$reason）· 正在收尾');
        _log('⚠️ 资源告警 · $reason');

        // 规格 §3.8 第 3 条（该让就让）：录制侧报压力 ⇒ **自动停掉推流**。
        //
        // ⚠️ 前两条（不阻塞、不传染）只挡得住**代码层面**的互相拖累；
        // 推流白耗的 CPU 与热量是**整机共享**的，那会实打实地让录制掉帧。
        // 这一条是三条里最后一道闸。**录制是证据，推流是便利。**
        if (_liveShare?.isRunning ?? false) {
          _reportLiveShareProblem('录制吃紧（$reason），已自动停掉实时共享。');
          unawaited(_liveShare?.notifyRecordingPressure(reason));
        }

      case Speak(:final prompt):
        // 播报本身在编排层里发给原生（`VoicePrompt.spokenText` 是唯一措辞来源），
        // 这里只留一条可见的日志。
        //
        // ⚠️ 播报关掉时日志**照记**，只是图标换成 🔇 —— 关掉的只是声音。
        // 那个图标也是真机验收时唯一能分辨「播报被关了」和「TTS 坏了」的线索：
        // 前者显示 🔇 而屏幕上有提示，后者显示 🔊 而一点声音都没有。
        _log('${_voiceOn ? "🔊" : "🔇"} ${prompt.spokenText}');

      case ShowDurationPrompt():
        setState(() => _askingToContinue = true);

      case HideDurationPrompt():
        setState(() => _askingToContinue = false);
    }
  }

  /// 原生层报来一次识码时记一行 —— 但**只记被采纳的**，
  /// 否则相机每秒报好几次会把事件列表刷爆。
  ///
  /// 这里不重复判定，只是把「Dart 层认了哪一次」显示出来：
  /// 真正决定采纳与否的是 `ScanGate`（框外忽略 + 去重），那层有测试。
  void _onBarcodeAccepted(WaybillNumber waybill) {
    _log('📷 扫到 $waybill');

    // 多画面每格下面那对 `F` / `T`（规格 §3.8 ⑥）。
    //
    // ⚠️ 用的是**粘性的** `_businessType`（跟着 `_workTab` 走），不是 `_tab`：
    // 人切到设置页翻一眼时换件也会开新段，那个新段落的标签用的就是 `_workTab`
    // —— 计数必须与**这段录像最后被打上什么标签**是同一个来源，
    // 否则屏幕上那个 `F` 会比录像里的标签多一件或少一件。
    _liveCounter.record(_businessType);
  }

  /// 扫到了，但**太短**，于是没录。
  ///
  /// ⚠️ 这一行不是可有可无的装饰：不加的话，用户对着一张真面单扫了半天，
  /// 屏幕上什么都不会发生 —— 而「框外」「太短」「还在画面里」这三种在界面上
  /// 长得**一模一样**，都是毫无反应。人只会得出「相机坏了」这一个结论。
  /// 说清楚是哪一种，才知道该去改设置还是该挪一下手机。
  void _onBarcodeTooShort(String text, int minLength) {
    _log('📷 扫到 $text，只有 ${text.length} 位、短于设定的 $minLength 位 —— 不触发录制');
  }

  /// 把系统那个麦克风授权框弹出来（录制声音开着时才问）。
  ///
  /// ⚠️ **结果故意不听**（不变量 I4）：没有麦克风权限只是「这一段没有音轨」，
  /// 绝不挡录像 —— 所以这里不设状态、不 return，与上面那段相机权限刚好相反。
  ///
  /// 唯一的目的是**让那个框出现**：不弹的话原生那边 `AVCaptureDeviceInput` /
  /// `AudioRecord` 会静静地失败，用户看到的就是一个「打开了却永远没声音」的
  /// 开关（踩坑 #13）。已经问过时两端原生都直接回当前答案、不再弹框。
  ///
  /// ⚠️ **必须在开相机会话之前**：麦克风是在配置会话那一步加进去的
  /// （`CameraSegmentRecorder.openCamera`），会话建好之后补不上。
  Future<void> _askForMicrophoneIfNeeded() async {
    if (!_recordAudio) return;
    await _gateway.requestMicrophonePermission();
  }

  /// 进采集栏时把相机打开（**不开始工作**）。
  ///
  /// 与 [_startWorking] 分开：进栏只给一个取景画面让人对准面单，
  /// 真的开始录还是要点【开始】。合在一起的话，进栏那一下就自己录起来了。
  Future<void> _openCameraForPreview() async {
    final coordinator = _coordinator;

    // 启动还没走完（`_bootstrap` 是异步的）。这里**不能硬开**：
    // `_workspace` 那些 `late` 字段还没赋值，开出来的编排器写不了盘。
    if (coordinator == null || _identity == null) {
      if (mounted) setState(() => _status = '还在读设备信息，稍等一下再进这一栏');
      return;
    }

    try {
      if (!await _gateway.hasCameraPermission()) {
        final granted = await _gateway.requestCameraPermission();
        if (!granted) {
          // 不崩、不装作开好了。**【开始】是重试路径** ——
          // 用户去设置里给了权限回来按下它就重来一遍。
          if (mounted) setState(() => _status = '没有相机权限');
          return;
        }
      }

      await _askForMicrophoneIfNeeded();

      await coordinator.openCamera();

      // 相机开起来之后才问得到设备范围（规格 §3.1.2）。
      await _readDeviceCapabilities();

      if (!mounted) return;
      setState(() {
        _zoom = 1; // 每次进栏回到 1 倍 —— 上一趟拖到 4 倍不该留给下一件
        // 表盘也收起来：它属于刚才那一趟（需求方 2026-09-22 收进【对焦】按钮）。
        _closeDial();
        _status = '把面单放进取景框';
      });
    } on Object catch (error) {
      // 开相机可能真的失败（没权限、相机被别的应用占着、设备忙）。
      // **如实显示**，不假装 —— 吞掉的话屏幕上就是一片没有画面的空白。
      if (mounted) setState(() => _status = '开相机失败：$error');
    }
  }

  /// 开始工作：**开相机、送预览、显示取景框。不录。**
  ///
  /// 规格 §3.2.2 的流程是「点开始工作 → 出现取景框 → 扫到面单才开录」。
  /// 之前把「开相机」和「开录」合成一步，表现是点了按钮屏幕上什么都没有、
  /// 但其实已经在录 —— 用户既看不到画面、也没法把面单对准。
  Future<void> _startWorking() async {
    if (_starting) return;
    setState(() => _starting = true);

    try {
      if (!await _gateway.hasCameraPermission()) {
        final granted = await _gateway.requestCameraPermission();
        if (!granted) {
          setState(() => _status = '没有相机权限');
          return;
        }
      }

      await _askForMicrophoneIfNeeded();

      await _buildCoordinator(); // 换模式下重建，配置跟着走

      // ⚠️ 这里传的必须是**设备标识**，不是本机名（契约 §1.1 步骤 2 把两者分开：
      // 标识用来认设备，名字用来给人看）。以前这里写死 `'this-device'` ——
      // 结果**所有手机在电脑端都叫同一个名字**，根本分不开是哪台录的。
      // 标识是不变的，所以改名不会篡改历史录像的来源。
      // 录制规格也在这里交给编排器（规格 §3.1.7：**录制前可选、录制中不可改**）。
      // 它会先做一次真实的可用性检查，跑不通就回落到真能跑的那一档 ——
      // 结论落在 `_coordinator.effectiveSpec` / `specFallbackReason` 上，
      // 回落**当场记一条日志**（`recording_spec_probe.dart`），**不静默回落**
      // —— 2026-10-09 设置页那行显示删掉之后，日志就是剩下的那一面。
      await _coordinator!.startWorking(
        sourceDeviceId: _identity!.deviceId,
        spec: _requestedSpec(),
      );

      // 规格 §3.3.6：点【开始】→ 播「开始工作」，**不滴**（需求方 2026-09-22 裁决）。
      //
      // 为什么在这里、不在 `startWorking` 里：这句的起因是「用户按了那个按钮」，
      // 不是「状态机走到了某个状态」—— 与上面 [modeAnnouncementFor] 那两句
      // 是同一类东西，所以走同一条路（`RecordingCoordinator.speak`，不经状态机）。
      // 塞进 `startWorking` 的话，所有需要「在工作状态」的测试都会平白多出一句播报。
      //
      // 位置在 `startWorking` **之后**：相机没开起来就不该说「开始工作」。
      await _coordinator!.speak(VoicePrompt.startWorking);

      // 计数器从这一刻起算（需求方 2026-10-01：「本次开始工作以来，到结束」）。
      // ⚠️ 在 `startWorking` **之后**归零：相机没开起来就不算开始工作，
      // 而那一条路径会 `return`（上面几处），不该把上一班的数字抹掉。
      _liveCounter.reset();

      // 实时共享（规格 §3.8）：相机刚开起来，现在才推得动。
      unawaited(_applyLiveShare());

      _log('开始工作 · 模式 ${_modeLabel(_mode)}');
      _startHeartbeat();

      // 相机开起来之后才问得到设备上限（规格 §3.1.2）——
      // 表盘的刻度要画到设备的真实上限，不然划到底是 8 倍、画面却停在 2 倍。
      await _readDeviceCapabilities();

      if (mounted) {
        setState(() => _status = '把面单放进取景框');
      }
    } on Object catch (error) {
      if (mounted) setState(() => _status = '开始失败：$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// 点【重新校准】：先取公网时间，取不到就提示可以跟电脑端备份一次。
  Future<void> _recalibrate() async {
    setState(() => _status = '正在取公网时间…');

    final ok = await _clock?.tryCalibrateFromPublicTime() ?? false;

    if (!mounted) return;

    setState(() => _status = ok
        ? '已校准，可以开始录制'
        : '取不到公网时间。连上电脑端成功备份一次也能校准（那条路不需要公网）');
  }

  /// 相机开起来之后问一次设备能力：变焦范围（定表盘两端，规格 §3.1.2）
  /// 与**有没有闪光灯**（定右上角那个手电筒按钮画不画）。
  ///
  /// **拿不到就用默认值**：问了不代表问得到（Android 端的通道还没接上、
  /// 或者相机刚开、设备还没报能力）。为这个把「开始工作」弄失败是本末倒置。
  ///
  /// 范围的取舍与不变量收在 [zoomRangeFrom] 里（有测试）——
  /// 这里只负责把问到的两个数递过去。
  Future<void> _readDeviceCapabilities() async {
    double? min;
    double? max;
    try {
      max = await _gateway.maxZoom();
      min = await _gateway.minZoom();
    } on Object {
      // 一样失败就一样按默认值办：两端各自兜底，不必知道是谁抛的。
      min = null;
      max = null;
    }

    // ⚠️ **单独一个 try**：闪光灯那一条在装的是旧包时必然抛
    // （通道上没这个方法），而那时变焦范围是问得到的 ——
    // 合成一个 try 会让「手电筒没有」连带把表盘刻度也打回默认值。
    bool? torch;
    try {
      torch = await _gateway.hasTorch();
    } on Object catch (error) {
      // 不留痕的话，「这台手机为什么没有手电筒按钮」就没有任何地方能回答
      //（旧包、通道没接上都走到这儿）。一次【开始工作】一条，淹不了日志。
      _log('⚠️ 问不到这台设备有没有闪光灯：$error');
      torch = null;
    }

    if (!mounted) return;
    setState(() {
      final (lower, upper) = zoomRangeFrom(min, max);
      _minZoom = lower;
      _maxZoom = upper;
      // ⚠️ 灯跟着相机设备：新会话起来时它**一定是灭的**，所以这里无条件归位。
      // 不归位的话，上一趟开着灯、这一趟图标亮着而灯不亮。
      _torchOn = false;
      _torchUsable = torch;
    });
  }

  /// 收起表盘。**只改字段，不 setState** —— 调用方要么本来就在 `setState`
  /// 里，要么直接把本方法递给 `setState`。
  ///
  /// 三个字段一起清：摊开状态、拨轮声记的「上一格」、对焦节流的时钟。
  /// 少清后两个不会出大事，但「第一下响不响取决于上一趟拖到哪」这种事
  /// 没必要留着 —— 那正是真机验收时会怀疑「拨轮声坏了」的东西。
  void _closeDial() {
    _dialOpen = false;
    _lastDetentTick = null;
    _lastFocusAt = null;
  }

  /// 用户滑动半圆刻度盘。
  Future<void> _onZoomChanged(double ratio) async {
    // 先更新表盘再发命令：原生变焦是异步的，等它回来再画会明显跟手不上。
    setState(() => _zoom = ratio);

    // ── 拨轮声 ──
    //
    // 跟着**语音播报**那个开关（它是全 App 唯一的声音开关）：用户说「嫌吵」
    // 的时候要能一次关掉所有声音，而不是发现还有个表盘在响。
    // ⚠️ 设置页那张卡的说明里必须写清这一点，否则那句话就变成假话。
    final tick = (ratio * 10).round();
    if (tick != _lastDetentTick) {
      _lastDetentTick = tick;
      if (_voiceOn) {
        unawaited(_gateway.playDetentSound().catchError(
          (Object error) => _log('⚠️ 拨轮声失败：$error'),
        ));
      }
    }

    try {
      await _gateway.setZoom(ratio);
    } on Object catch (error) {
      // 变焦失败不该中断录制（原生层也是这个态度），只留一条日志。
      _log('⚠️ 变焦失败：$error');
    }

    await _refocusThrottled();
  }

  /// 手指从表盘上抬起：**补一次对焦**。
  ///
  /// 滑动过程中是节流着对的，手指停下的那一刻才是最终位置 ——
  /// 那一下必须让它实，不然用户看到的是「松手之后画面才是清楚的」。
  Future<void> _onZoomEnd() async {
    _lastFocusAt = DateTime.now();
    await _refocus();
  }

  /// 节流版的 [_refocus]（见 [_focusThrottle]）。
  Future<void> _refocusThrottled() async {
    final now = DateTime.now();
    final last = _lastFocusAt;
    if (last != null && now.difference(last) < _focusThrottle) return;

    _lastFocusAt = now;
    await _refocus();
  }

  /// 重新对焦到画面正中。规格 §3.1.2：「无论怎么滑都自动对焦」。
  ///
  /// 倍率一变，原来对好的那点就不实了 —— 所以每滑一段都要重对一次。
  /// 失败只记一条日志：对不上焦是小事，**不能让它把录制搞坏**（I4 的精神）。
  Future<void> _refocus() async {
    try {
      await _gateway.focusNow();
    } on Object catch (error) {
      _log('⚠️ 对焦失败：$error');
    }
  }

  /// 结束工作：停掉在录的那段、关相机。
  Future<void> _stopWorking() async {
    _heartbeat?.cancel();
    _heartbeat = null;

    // 实时共享跟着停：相机马上要关了，没有画面可推（规格 §3.8）。
    // ⚠️ **不等它**：推流的收尾（收编码器、关 HTTP）是几百毫秒的事，
    // 而用户按了【结束】要立刻听到那句播报 —— 等它就是把「滞」加到反馈上。
    unawaited(_liveShare?.stop());

    // 规格 §3.3.6：点【结束】→ 播「停止工作」，**不滴**（同上）。
    //
    // ⚠️ **播在收尾之前**：`stopWorking` 里要等落库（写 manifest、封段），
    // 那是磁盘 I/O，几百毫秒起步。放在后面的话用户按完按钮要先愣一下才听到
    // 声音 —— 而那一下「滞」正是他要的反馈本身。
    await _coordinator?.speak(VoicePrompt.stopWorking);

    try {
      await _coordinator?.stopWorking();
    } on Object catch (error) {
      if (mounted) setState(() => _status = '结束失败：$error');
    }

    if (mounted) {
      setState(() {
        _status = '已结束工作';
        _askingToContinue = false;
        _elapsed = Duration.zero;
        _closeDial(); // 结束工作 = 相机要关了，表盘没有存在的余地
      });
    }
    await _refreshDiagnostics();
  }

  /// 心跳驱动那些「时间到了就发生」的判定（静止、时长兜底）。
  /// 没有它，画面完全不动时没有任何事件，超时永远不会触发。
  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_coordinator?.handleHeartbeat());

      final elapsed = _coordinator?.elapsed ?? Duration.zero;

      if (mounted) {
        // 时长从编排器取 —— 它用单调时钟，墙钟在这儿算不出正确的值。
        setState(() => _elapsed = elapsed);
      }

      // 资源告警（规格 §3.1.1）：存储将满 / 低电量 / 过热 ⇒ 提前告警 + 主动收尾。
      //
      // ⚠️ **节流到 30 秒一次**：心跳是每秒的，而这三样变化的时间尺度是**分钟**
      // （电量、剩余空间、温度都不会一秒一变）。每秒过一趟原生通道是白花钱 ——
      // 而这个仓已经因为「白跑的定时器」吃过一次亏（§39.4 那条 flake）。
      final now = DateTime.now();
      final last = _resourcesReadAt;
      if (last == null || now.difference(last) >= _resourcePollInterval) {
        _resourcesReadAt = now;
        unawaited(_readResources());
      }
    });
  }

  /// 读一次资源并喂给状态机（规格 §3.1.1）。
  ///
  /// ⚠️ **缺失的项不填 0**：原生回的空 Map 或少数几项就是「那些项不参与判定」。
  /// 判据在 `StopController._onResource`（那里逐个判 `!= null`）。
  Future<void> _readResources() async {
    final Map<Object?, Object?> raw;

    try {
      raw = await _gateway.readResources();
    } on Object catch (error) {
      // 读不到不是错误（老包没有这个方法、平台异常）—— 这一轮就不喂。
      _log('读资源失败：$error');
      return;
    }

    if (!mounted) return;

    final thermal = raw['thermal'];

    await _coordinator?.onResourceReported(
      freeStorageBytes: raw['freeStorageBytes'] as int?,
      batteryPercent: raw['batteryPercent'] as int?,
      // ⚠️ 原生报的是**档位序号**（与 `ThermalLevel` 一一对齐，两边都由轻到重）。
      // 用 `fromConfig` 解析：它认得 int 与名字两种写法，越界回落 `nominal`。
      thermal: thermal == null ? null : ThermalLevel.fromConfig(thermal),
    );
  }

  /// 模拟一次扫码。
  ///
  /// **摄像头识码已经接上了**（iOS 用系统自带的 Vision），但这个按钮仍然有用：
  /// 它走的是[PunchSource.manualEntry]，且不经过 [ScanGate] 的框内判定 ——
  /// 验状态机时不必去凑一张恰好落在取景框里的面单。
  /// 错码保护验的是状态机：首扫 A 开录、扫 B 只提示不停、扫回 A 才停。
  Future<void> _simulateScan() async {
    final waybill = WaybillNumber.tryParse(_waybillController.text);
    if (waybill == null) {
      setState(() => _status = '单号无效');
      return;
    }

    await _coordinator?.onWaybillDetected(waybill,
        source: PunchSource.manualEntry);
  }
}
