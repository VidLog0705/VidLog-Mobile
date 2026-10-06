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
// 一行都没改，只是位置换了（内容多重集比对可证）。这里装的是入网配对：扫码、试连、问电脑端地址。
//
// ⚠️ 只有实例方法 / getter 能装进来：extension 不许声明实例字段，
// 匿名 extension 的 static 成员又没有前缀可取（不可达），所以那些
// 字段与静态常量全留在壳的类体里 —— 同 library，这里不带前缀照样读得到。

extension on _RecorderPageState {

  /// 【扫码连接】：扫电脑端屏幕上那张二维码，报到、等它同意，再把凭据领回来。
  ///
  /// 规格 §3.4.5 ①（2026-09-24 改版）：**用户不需要手输任何东西**。
  ///
  /// 三步，中间的等待是**看得见的**：
  ///   1. 扫码 —— 拿到电脑端的地址与一次性令牌（[ScanConnectPage]）；
  ///   2. 反复报到、同时等电脑端上的人点【同意】—— 那一步在
  ///      `Enroller` 里，它有测试（`test/uploader_test.dart` 的入网那组）；
  ///   3. 领凭据、落盘，然后**提示用户编辑机位名**（规格 ①第 4 条）。
  ///
  /// ⚠️ **被拒绝要当场看见**（I3）：电脑端说不，这里就停下来把话说明白，
  /// 不是一直转圈。
  Future<void> _pairHost() async {
    final identity = _identity;
    if (identity == null) return;

    final payload = await ScanConnectPage.open(
      context,
      gateway: _gateway,
      // 相机在这个页面之前就开着的话**不能关** —— 那可能是录制中，
      // 或者发货栏的取景框还开着。关了就是掐掉别人的会话。
      closeCameraWhenDone: _coordinator?.isCameraOpen != true,
      // 那一页要按同一套规格摆画面、并且在**新开**相机时按它开 ——
      // 否则扫完码回来，留在会话上的是另一个分辨率。
      spec: _coordinator?.effectiveSpec ?? _requestedSpec(),
    );

    if (payload == null || !mounted) return; // 用户返回了，没扫

    await _enroll(identity: identity, host: payload.host, port: payload.port, token: payload.token);
  }

  /// 扫码之后到「拿到凭据」之间的那段路。
  ///
  /// [host] / [port] 来自二维码，但**地址允许被改**：规格 §3.4.5 ② 要求
  /// 「扫码连不上时允许手填地址」这条兜底留着 —— 一台机器可能同时插着有线、
  /// 无线、虚拟网卡，电脑端挑出来的那个地址不一定就是手机连得上的那个。
  /// 令牌仍然是被扫进来的那一张。
  Future<void> _enroll({
    required DeviceIdentity identity,
    required String host,
    required int port,
    required String token,
  }) async {
    var address = host.trim();

    while (true) {
      if (address.isEmpty) return;

      // 地址与端口落盘。换地址/端口 = 换一台电脑端 ⇒ `setHost` 会把旧凭据丢掉
      // （这是对的：那是**别的**电脑端签发的）。
      await identity.setHost(address: address, name: identity.hostName, port: port);

      if (!mounted) return;

      final attempt = await _attemptEnroll(
        identity: identity,
        address: address,
        port: port,
        token: token,
      );

      if (!mounted) return;

      final failure = attempt.failure;

      if (failure is UploadFailure && failure.code == UploadErrorCodes.network) {
        // 规格 §3.4.5 ②：**「扫码连不上时允许手填地址」这条兜底必须保留**。
        // 电脑端挑出来的地址不一定就是手机连得上的那个 —— 一台机器可能同时
        // 插着有线、无线、虚拟网卡，它挑的是「最像」的那个。
        //
        // ⚠️ 这里换的**只是地址**：令牌还是刚扫进来的那一张，没有重新扫。
        final edited = await _askHostAddress(current: '$address:$port');
        if (edited == null || edited.isEmpty || !mounted) return;

        address = edited;
        continue;
      }

      if (failure != null) {
        _snack(failure is UploadFailure ? failure.userHint : '连接失败：$failure');
        return;
      }

      final outcome = attempt.outcome;
      if (outcome == null) return; // 用户点了取消

      if (outcome.status == EnrollStatus.rejected) {
        // 规格 §3.4.5 ①：**拒绝要看得见**，而且不是「网络错误」那种说法。
        _snack('电脑端拒绝了这次连接。要重试的话，在电脑端上重新生成一张二维码再扫。');
        return;
      }

      final credential = outcome.credential;
      if (credential == null) {
        // 批准了却又没给凭据 —— 只可能是电脑端那边在这中间换了张码
        // （或者两端实现不一致）。**不当作成功**：没有凭据就是没入网。
        _snack('没有拿到凭据。请在电脑端上重新生成一张二维码，再扫一次。');
        return;
      }

      // **落盘**：只在内存里留着的凭据，重启一次就等于没入过网。
      await identity.setCredential(credential);

      if (!mounted) return;

      // 凭据换了 → 上传器必须重建（见 [_buildUploader]）。
      _buildUploader();
      setState(() => _status = '已连接');
      await _probeHost();

      if (!mounted) return;

      // 规格 §3.4.5 ①第 4 条：「同意 → 手机端提示**连接成功**，
      // 并让用户**编辑机位名**」。
      _snack('连接成功');
      await _editDeviceName();

      unawaited(_runUploads(manual: true));
      return;
    }
  }

  /// 跑一次入网：报到 → 等批准 → 领凭据，中间用进度框把等待**显示出来**。
  ///
  /// 拆出来是因为它可能被跑两次：第一次连不上时，界面会问一个能手填的地址，
  /// 拿着**同一个令牌**再跑一次（规格 §3.4.5 ② 的兜底）。
  ///
  /// 返回值用记录而不是抛：调用方要区分「用户取消」（outcome 为空）
  /// 与「连不上」（failure 是 network）—— 后者是**唯一**该问地址的情况。
  Future<({EnrollOutcome? outcome, Object? failure})> _attemptEnroll({
    required DeviceIdentity identity,
    required String address,
    required int port,
    required String token,
  }) async {
    final navigator = Navigator.of(context);
    final waited = ValueNotifier(Duration.zero);

    var cancelled = false;
    var dialogClosed = false;
    void closeDialog() {
      if (dialogClosed) return;
      dialogClosed = true;
      if (mounted) navigator.pop();
    }

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('等电脑端同意'),
        content: ValueListenableBuilder<Duration>(
          valueListenable: waited,
          builder: (context, value, child) => Text(
            '连接请求已经发给电脑端了。\n\n'
            '请到那台电脑上点【同意】—— 屏幕上会弹出'
            '「${identity.deviceName} 申请连接」。\n\n'
            '已经等了 ${value.inSeconds} 秒。',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              closeDialog();
            },
            child: const Text('取消'),
          ),
        ],
      ),
    ));

    try {
      final outcome = await Enroller(client: UploadClient(address: address, port: port)).enroll(
        deviceId: identity.deviceId,
        deviceName: identity.deviceName,
        token: token,
        cancelled: () => cancelled,
        onWaiting: (value) => waited.value = value,
      );

      return (outcome: outcome, failure: null);
    } on Object catch (error) {
      return (outcome: null, failure: error);
    } finally {
      closeDialog();
      waited.dispose();
    }
  }

  /// 问一个能手填的电脑端地址（规格 §3.4.5 ② 的兜底）。
  ///
  /// 返回**主机部分**（端口不动）；用户取消返回 null。
  Future<String?> _askHostAddress({required String current}) async {
    final host = current.split(':').first;
    final controller = TextEditingController(text: host);

    final answer = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('连不上这台电脑'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '二维码里写的地址是 $current，手机连不上。\n\n'
              '一台电脑可能同时插着有线、无线和虚拟网卡，它挑出来的不一定是你能连上的那个。'
              '在电脑端上执行 ipconfig 看一下它的局域网地址，填在这里再试一次。',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: '电脑端地址', hintText: '192.168.1.23'),
              onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('算了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('再试一次'),
          ),
        ],
      ),
    );

    controller.dispose();
    return answer?.trim();
  }
}
