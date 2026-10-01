import '../recording/business_type.dart';
import 'live_server.dart' show LiveCounts;

/// 这台手机**当场**扫了多少发货、多少退货（多画面每格下面那对 `F` / `T`）。
///
/// ## 起算点（需求方 2026-10-01 定的）
///
/// 「本次开始工作以来，到结束。以北京时间为准，00：01 开始至 23：59 分为一天，
/// 每天都重新计算。」
///
/// 落成两条：
///
/// 1. **点【开始工作】时归零**（[reset]，由页面在开始工作那一刻调）；
/// 2. **跨北京时间的自然日也归零**（每次读写时先比日期键，见 [_rollIfNeeded]）。
///    两者都要：一整天不重启的机器，光靠第 1 条永远归不了零。
///
/// ## ⚠️ 北京时间是**算出来**的，不读设备时区
///
/// 手机可能压根不在北京时区（`DateTime.now()` 给的是它自己的本机时间）。
/// 读设备时区的话，这台手机在别的时区把「今天」算错一天 ——
/// 而两个数字只是屏幕上的一行，错了没人看得出来。
/// 所以固定用 **UTC+8** 折算，与设备设置无关。
///
/// ## 为什么要有个类，而不是页面里两个 `int`
///
/// 跨日、按业务类型分桶、归零时机 —— 这三条都测得到，而它们全都
/// 只在特定时刻才显形（跨零点、发货与退货交替扫）。放页面里就只能靠真机守夜。
///
/// ⚠️ **它不是日志主体**（`AGENTS.md` §6.1 那张表里的「纯数据类型」那一行）：
/// 计数器本身没有状态机、不碰外部世界，跨日归零由**读它的那一端**看得见
/// （屏幕上那两个数变了）。真正的留痕在 [LiveService]：开推流 / 停推流 /
/// 因为录制压力被停掉，各一条。
class LiveCounter {
  LiveCounter({DateTime Function()? now}) : _now = now ?? DateTime.now {
    _day = beijingDayOf(_now());
  }

  /// 取当前时刻。**可注入**：跨日那一条只有把钟拨到零点之后才测得动。
  ///
  /// ⚠️ 返回值只当「现在是什么时刻」用，本机时区不参与计算
  /// （内部先 `.toUtc()` 再折算）。
  final DateTime Function() _now;

  /// 现在是北京时间的哪一天（`yyyy-MM-dd`）。日期键一变就归零。
  late String _day;

  int _outbound = 0;
  int _returned = 0;

  /// 扫到一件（相机识码或手工输入，只要**被采纳了**就算）。
  void record(BusinessType type) {
    _rollIfNeeded();

    if (type == BusinessType.returning) {
      _returned++;
    } else {
      _outbound++;
    }
  }

  /// 归零（点【开始工作】时调）。
  void reset() {
    _rollIfNeeded();
    _outbound = 0;
    _returned = 0;
  }

  /// 现在这两个数是多少。
  ///
  /// ⚠️ **读的时候也要比一次日期键**：零点那一刻多半没人扫码，
  /// 而屏幕上那两个数**必须自己归零** —— 否则它们会一直挂着昨天的数字，
  /// 直到下一个包裹进来才「跳」一下。那种错误在交接班时最容易被当真。
  LiveCounts counts() {
    _rollIfNeeded();
    return LiveCounts(outbound: _outbound, returned: _returned);
  }

  void _rollIfNeeded() {
    final today = beijingDayOf(_now());
    if (today == _day) return;

    _day = today;
    _outbound = 0;
    _returned = 0;
  }
}

/// 那一刻是北京时间的哪一天（`yyyy-MM-dd`）。
///
/// **固定 UTC+8**，不读设备时区 —— 理由见 [LiveCounter] 的类注释。
String beijingDayOf(DateTime instant) {
  final beijing = instant.toUtc().add(const Duration(hours: 8));

  final month = beijing.month.toString().padLeft(2, '0');
  final day = beijing.day.toString().padLeft(2, '0');

  return '${beijing.year}-$month-$day';
}
