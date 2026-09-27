import 'upload_protocol.dart';
import 'uploader.dart';

/// 两次轮询之间的间隔。
///
/// 1 秒：再密一点只是在局域网上白跑请求，而电脑端那边是**人**在点弹窗 ——
/// 快这一秒没有任何意义。令牌 5 分钟才过期，多等一轮也不影响成败。
const enrollPollInterval = Duration(seconds: 1);

/// 扫到二维码之后，到「拿到凭据」之间的那段路（规格 §3.4.5 ①）。
///
/// ## 两步，而且顺序不能换
///
/// 1. **反复**调 `enroll/request` 报到并问批没批 —— 它**只报警不发货**，
///    所以「我还在等」的那几轮反复调它没有副作用；
/// 2. 批了之后才调一次 `enroll/claim` 领凭据 —— 凭据**只发一次**，
///    领走之后整张码作废，所以这一步**不能重放**。
///
/// ⚠️ 顺序反过来的话（先 claim 再等），每轮轮询都在调一个会发货的接口；
/// 而**只调 claim、不调 request** 的话，电脑端根本不知道谁来了，
/// 弹窗不会出现，用户会一直等一个永远没人做的决定。
///
/// 收在这里而不是写在界面上，是因为它**能被测**（`test/enrollment_test.dart`
/// 对着一个真的电脑端跑），而界面里那半只能靠真机。
class Enroller {
  const Enroller({
    required this.client,
    this.interval = enrollPollInterval,
    this.sleep = _defaultSleep,
  });

  final UploadClient client;

  /// 两次轮询之间等多久。
  final Duration interval;

  /// 等待本身。抽出来是为了让测试**不必真的等**。
  final Future<void> Function(Duration duration) sleep;

  /// 走完入网：报到 → 等批准 → 领凭据。
  ///
  /// [cancelled] 每轮之间问一次；用户按下取消、或者界面已经关掉，
  /// 就在这里停下 —— **返回 null 表示「用户不想等了」**，
  /// 与「电脑端还没批」（那是 [EnrollStatus.pending]）不是一回事，
  /// 所以不合成一个返回值。
  ///
  /// [onWaiting] 每等一轮报一次已经等了多久。界面拿它显示「已经等了 12 秒」——
  /// I3 的精神：等待也必须是**看得见的**，不能让用户对着一个转圈猜
  /// 「是不是卡住了」。
  ///
  /// 可能抛 [UploadFailure]：令牌不对、屏幕上那张码没了、或者连不上电脑端。
  /// 那几种都有各自的 `userHint`，界面直接照说。
  Future<EnrollOutcome?> enroll({
    required String deviceId,
    required String deviceName,
    required String token,
    required bool Function() cancelled,
    void Function(Duration waited)? onWaiting,
  }) async {
    var waited = Duration.zero;

    while (!cancelled()) {
      final outcome = await client.enrollRequest(
        deviceId: deviceId,
        deviceName: deviceName,
        token: token,
      );

      if (outcome.status == EnrollStatus.rejected) {
        // 电脑端**明确拒绝**了。停住 —— 别再问，也别去 claim：
        // 电脑端那边这条请求是留着的，再问多少次都是同一个答复。
        return outcome;
      }

      if (outcome.status == EnrollStatus.approved) {
        // 批了。领凭据 —— 这一步**只做一次**（凭据只发一次）。
        //
        // 这一步仍然可能拿回 pending / rejected：在「批准」与「领取」之间，
        // 电脑端上有人重新生成了一张二维码（那张码会作废整轮请求）。
        // 所以它的返回值同样要按处置看，不能当成「一定成功」。
        return await client.enrollClaim(deviceId: deviceId, token: token);
      }

      onWaiting?.call(waited);
      await sleep(interval);
      waited += interval;
    }

    return null;
  }

  /// 走完一次改名：报上新名字 → 等电脑端批准（规格 §3.4.5 ③）。
  ///
  /// ⚠️ 与 [enroll] 同形（轮询 + `cancelled` + `onWaiting`），但**只有一步** ——
  /// 改名**不换凭据**（换了的话那台手机下一次上传会撞 401，而它以为只是改了个名字）。
  ///
  /// ⚠️ 加了**等待上限**：电脑端可能一直没人点那个弹窗，而无限轮询会让
  /// 界面永远停在「正在等」—— 用户看不出是没人理还是程序卡了。
  /// 上限与入网那张码的 5 分钟同量级，理由也一样（都是**人**在另一头操作）。
  Future<EnrollOutcome?> requestRename({
    required String deviceName,
    required bool Function() cancelled,
    void Function(Duration waited)? onWaiting,
    Duration maxWait = const Duration(minutes: 5),
  }) async {
    var waited = Duration.zero;

    while (!cancelled() && waited < maxWait) {
      final outcome = await client.requestRename(deviceName: deviceName);

      if (outcome.status != EnrollStatus.pending) {
        return outcome;
      }

      onWaiting?.call(waited);
      await sleep(interval);
      waited += interval;
    }

    return null;
  }
}

Future<void> _defaultSleep(Duration duration) => Future<void>.delayed(duration);
