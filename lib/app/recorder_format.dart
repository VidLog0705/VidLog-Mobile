part of 'recorder_page.dart';

// ─────────────────────────────────────────────────────────────────────
// 采集页那些「把值排成字」的纯函数。
//
// ⚠️ 它们是**顶层函数**，不是 `_RecorderPageState` 的成员 —— 本文件里
// 别的部分都不是这个形状，这是有原因的：
//
// T26③ 第 2 轮把 `recorder_page.dart`（6400 行）拆进同一个 library 的多个
// 文件。实例方法靠 part 文件里的 `extension on _RecorderPageState` 搬家：
// 同 library 的 extension 读得到私有成员，而且**跨 extension 调用不带前缀
// 就能解析**（连 tear-off 也不用加 `this.`）。
//
// 但**静态成员不能这么搬**：匿名 extension 的 `static` 成员没有名字可以当
// 前缀，等于不可达。2026-10-06 拿真编译器验过 —— `dart analyze` 当场报
// `undefined_method`。所以静态方法/常量一律改成**顶层**声明：类体与各
// extension 里都能不带前缀直接调，取的 tear-off 也一样（同样验过）。
//
// 于是**调用点一个字都不用改** —— 这正是「纯搬家、可逐行比对」能成立的前提。
// ─────────────────────────────────────────────────────────────────────

String _two(int value) => value.toString().padLeft(2, '0');

/// `MM-DD HH:mm`。备份页一行里塞得下，且不需要年份 —— 手机上的东西都是最近的。
///
/// 日期那一段走 [dayStamp]：搜索框要按**屏幕上真有的字**匹配，
/// 两处各写一套的话，写着 `09-23` 却搜不出来（见 `matchesQuery`）。
String _stamp(DateTime at) =>
    '${dayStamp(at)} ${_two(at.hour)}:${_two(at.minute)}';

/// `年/月/日/时/分/秒`，六段都要带（规格 §3.2.6）。
///
/// 与 [_stamp] 的区别不只是多几段：这是采集页正上方那个钟，
/// 它要能被**逐字念出来对着录像核**，所以年月日时分秒一段都不能省
/// （少一段就得靠猜是今年还是去年）。月/日/时/分/秒各补零到两位 ——
/// 不等宽的话这个钟每秒都在左右晃。
String _clockStamp(DateTime at) => '${at.year}/${_two(at.month)}/'
    '${_two(at.day)} ${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}';

/// `mm:ss`（超过一小时就是三位数的分钟，不折成小时 —— 一段录像不会是几小时）。
String _durationLabel(Duration d) =>
    '${_two(d.inMinutes)}:${_two(d.inSeconds % 60)}';

String _sizeLabel(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;

  if (bytes < kb) return '$bytes B';
  if (bytes < mb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / gb).toStringAsFixed(2)} GB';
}

/// [\_sizeLabel] 拆成「数字」和「单位」两半，给上面那张统计卡用。
///
/// ⚠️ **不是为了好看**：统计卡在窄屏上只有一百来像素宽，`6.90 GB`
/// 放不下 —— 会溢出，或者被省略号截成 `6.…`。而**数字被截断比难看糟得多**：
/// 用户会把它当成真的。拆开之后，缩的只有那个数字（`FittedBox`），
/// 单位照常显示，`GB` 这个量级信息不会丢。
///
/// ⚠️ 判据与 [\_sizeLabel] **同一套**（同一个 1024 进制、同一批阈值）——
/// 各写一套的话会出现「上面写着 6.9 GB、点进去写着 6.90 GB」。
({String value, String unit}) _sizeParts(int bytes) {
  final label = _sizeLabel(bytes);
  final split = label.indexOf(' ');

  // `_sizeLabel` 每一种输出都带一个空格（连 `123 B` 也是）。
  // 切不开就说明那个函数被改过了 —— 退回整串当数字，不崩、不猜。
  if (split < 0) return (value: label, unit: '');

  return (value: label.substring(0, split), unit: label.substring(split + 1));
}

/// 日志里的模式名。
///
/// ⚠️ 与设置页那三个胶囊**用同一批字**（2026-09-28 起）。两处各写一套的话，
/// 用户拿日志去对设置页会对不上 —— 同一个模式两个名字，是本仓反复警告过的坑。
String _modeLabel(WorkMode mode) => switch (mode) {
      WorkMode.continuousScan => '连续扫码',
      WorkMode.sameWaybillStop => '同码停录',
      WorkMode.scanThenStaticStop => '扫码静止停录',
    };

String _triggerLabel(StopTrigger trigger) => switch (trigger) {
      StopTrigger.manual => '手动',
      StopTrigger.sameWaybillRescan => '同码复扫',
      StopTrigger.sceneStatic => '画面静止',
      StopTrigger.durationFallback => '时长兜底',
      StopTrigger.resourceCritical => '资源告警',
      StopTrigger.processKilled => '进程被杀',
      StopTrigger.nextWaybill => '换件',
    };
