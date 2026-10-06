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
// 一行都没改，只是位置换了（内容多重集比对可证）。这里装的是实时共享：开关状态、起停、向电脑端报到。
//
// ⚠️ 只有实例方法 / getter 能装进来：extension 不许声明实例字段，
// 匿名 extension 的 static 成员又没有前缀可取（不可达），所以那些
// 字段与静态常量全留在壳的类体里 —— 同 library，这里不带前缀照样读得到。

extension on _RecorderPageState {

  /// 实时共享开着没有（设置里那一项；读不出来时按**关**算）。
  bool get _liveShareOn => _settings?.liveShareEnabled ?? false;

  Future<void> _applyLiveShare() async {
    if (_applyingLiveShare) {
      _liveShareAgain = true;
      return;
    }

    _applyingLiveShare = true;
    try {
      do {
        _liveShareAgain = false;
        await _applyLiveShareOnce();
      } while (_liveShareAgain);
    } finally {
      _applyingLiveShare = false;
    }
  }

  Future<void> _applyLiveShareOnce() async {
    final wanted = _liveShareOn && (_coordinator?.isWorking ?? false);

    if (!wanted) {
      await _liveShare?.stop();
      return;
    }

    final service = _liveShare ??= LiveService(
      gateway: ChannelLiveGateway(),
      counts: () => _liveCounter.counts(),
      announce: _announceToDesktop,
    );

    if (service.isRunning) return;

    final failure = await service.start();
    if (failure != null) {
      _reportLiveShareProblem(failure);
      return;
    }

    _reportLiveShareProblem(null);
  }

  /// 推流出事时**当场说一句**（起不来、被录制压力停掉）。
  ///
  /// ⚠️ 2026-10-03（需求方）：设置页那张「实时共享」卡整个删掉了 ——
  /// 那句话原先只有那张卡说得出口。改成**出事那一刻弹一条**，
  /// 采集页右上角那颗图标继续用变色表示「它现在有事」（按下去也还会再说一遍）。
  ///
  /// ⚠️ 删了卡还不出声，就成了规格 §3.8 第 3 条明禁的那种：
  /// 「刚才还有画面，怎么没了」而界面上一个字都没有。
  void _reportLiveShareProblem(String? problem) {
    if (!mounted) return;

    // 没变就别刷 —— 这条在每次「开始工作」上都会走一遍。
    if (_liveShareProblem != problem) {
      setState(() => _liveShareProblem = problem);
    }

    // 自愈了不打扰（图标自己会恢复）；出事才说。
    if (problem != null) _snack(problem);
  }

  /// 向电脑端报到（规格 §3.8 的机位发现）。
  ///
  /// ⚠️ **读的是当前那个 `_client`，不是建服务时捕获的那个** ——
  /// 重新配对 / 改地址之后上传器会整个重建，捕获旧的那个会把报到打到
  /// 一台已经不用的电脑上。
  Future<String?> _announceToDesktop(int port) async {
    final client = _client;
    if (client == null) return '还没配好电脑端';

    return client.announceLive(port);
  }
}
