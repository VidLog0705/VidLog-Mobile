import 'dart:async';

import 'package:flutter/material.dart';

import '../recording/recorder_gateway.dart';
import '../recording/recording_spec.dart';
import '../scanning/viewfinder.dart';
import '../upload/enroll_qr.dart';
import 'camera_preview.dart';

/// 【扫码连接】：对准电脑端屏幕上那张二维码，扫到就把它解出来交回去。
///
/// 规格 §3.4.5 ①：手机端**扫码** → 用码里的地址与令牌发起连接请求
/// （**用户不需要手输任何东西**）。
///
/// ## ⚠️ 这是**唯一**会打开二维码识别的地方
///
/// 规格 §3.4.5 ④：「只在『扫码连接』这个专用界面里开二维码识别，
/// 录制页仍然只认一维码」。理由是面单上和环境里的二维码不该被当成单号 ——
/// 那会把一整条 URL 灌进单号字段，而它是写进索引的。
///
/// 所以这里 [RecorderGateway.openCamera] 传 `qrOnly: true`，
/// 而离开时**必须把它换回去**（见 [_restoreCamera]）—— 否则用户接着回到
/// 发货栏，屏幕上是一张二维码的白名单在扫面单。
class ScanConnectPage extends StatefulWidget {
  const ScanConnectPage({
    super.key,
    required this.gateway,
    required this.closeCameraWhenDone,
    required this.spec,
  });

  final RecorderGateway gateway;

  /// **生效的**录制规格 —— 由调用方给（录制页手上就有）。
  ///
  /// 相机是**进程级的同一个会话**：这一页打开时它可能正开着（录制中、
  /// 或发货栏的取景框），那个会话的分辨率取决于用户选的规格。
  /// 这里按 9:16 硬摆的话，选了横屏的用户会看到一张被拉扁的画面，
  /// 而框画在上面跟着一起扁 —— 看起来「像那么回事」，实际判定范围是歪的。
  ///
  /// 相机这次若是**新开**的，也要按它开：不然扫完码回到录制页，
  /// 这一页留下的是另一个分辨率的会话，画面比例当场变。
  final RecordingSpec spec;

  /// 离开时要不要把相机关掉。
  ///
  /// 由调用方决定：**这个页面之前相机就开着的话不能关**（那可能是录制中，
  /// 或者是发货栏的取景框），关了就掐掉别人的会话。
  final bool closeCameraWhenDone;

  /// 打开这一页。扫到一张 VidLog 的码就返回它；用户返回就是 `null`。
  static Future<EnrollQrPayload?> open(
    BuildContext context, {
    required RecorderGateway gateway,
    required bool closeCameraWhenDone,
    required RecordingSpec spec,
  }) =>
      Navigator.of(context).push<EnrollQrPayload>(
        MaterialPageRoute(
          builder: (_) => ScanConnectPage(
            gateway: gateway,
            closeCameraWhenDone: closeCameraWhenDone,
            spec: spec,
          ),
        ),
      );

  @override
  State<ScanConnectPage> createState() => _ScanConnectPageState();
}

class _ScanConnectPageState extends State<ScanConnectPage> {
  /// 判定用的取景框。**与画出来的那个是同一个对象** ——
  /// 画一个框、按另一个范围判定，就会出现「看着放进去了，系统说不算」
  /// （规格 §3.2.2 要防的正是这个）。
  ///
  /// 用最大档：扫二维码时手机离屏幕多远都不好说，框小了用户得反复凑。
  ///
  /// 画面比例按**生效的规格**算 —— 与预览视图用的是同一个数，
  /// 所以画出来的框与判定的范围仍然严格一致（§3.2.2）。
  late final Viewfinder _viewfinder = Viewfinder.forPreset(
    ViewfinderPreset.large,
    aspectRatio: widget.spec.aspectRatio,
  );

  StreamSubscription<NativeRecorderEvent>? _events;

  /// 相机没起来时的原因。非空时整个预览区换成这句话。
  String? _problem;

  /// 扫到过「不是 VidLog 的码」。只提示，不打断 —— 环境里别的二维码
  /// 不该让这个界面弹一串错误。
  bool _sawForeignCode = false;

  /// 已经交回去了（或者正在交）—— 挡「同一帧里扫到两次」的重复 pop。
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_restoreCamera());
    super.dispose();
  }

  Future<void> _start() async {
    final gateway = widget.gateway;

    try {
      if (!await gateway.hasCameraPermission()) {
        final granted = await gateway.requestCameraPermission();
        if (!granted) {
          if (mounted) setState(() => _problem = '没有相机权限。去系统设置里给这个应用打开相机，再回来重试。');
          return;
        }
      }

      // ⚠️ 订阅**在开相机之前**挂上：反过来的话，相机起来那几十毫秒里
      // 扫到的东西没人接，而用户看到的是「扫了没反应」。
      _events ??= gateway.events.listen(_onEvent);

      await gateway.openCamera(qrOnly: true);
    } on Object catch (error) {
      if (mounted) setState(() => _problem = '相机没能打开：$error');
    }
  }

  /// 离开时把相机交回去。
  ///
  /// ⚠️ **先无条件把识码范围拨回一维码**，再决定关不关：
  /// 这个页面之前相机就开着的话（录制中、或者发货栏的取景框还开着），
  /// 不拨回去就等于**把二维码识别留在了别人的会话上** —— 用户回到发货栏，
  /// 屏幕上是一张二维码的白名单在扫面单。
  Future<void> _restoreCamera() async {
    try {
      await widget.gateway.openCamera();
      if (widget.closeCameraWhenDone) await widget.gateway.closeCamera();
    } on Object {
      // 收尾失败不该在退出时炸一下 —— 相机是尽力而为的资源。
    }
  }

  void _onEvent(NativeRecorderEvent event) {
    if (_done || event is! BarcodeDetectedEvent) return;

    // 框外的码一律不认 —— 与画出来的那个框严格一致（§3.2.2 的同一条规矩）。
    final inside = _viewfinder.acceptsRect(
      NormalizedRect(left: event.centerX, top: event.centerY, width: 0, height: 0),
    );
    if (!inside) return;

    final payload = EnrollQrPayload.tryParse(event.text);
    if (payload == null) {
      // 是别的二维码（商品上的、面单上的）。**不打断**，只把提示换掉。
      if (mounted && !_sawForeignCode) setState(() => _sawForeignCode = true);
      return;
    }

    _done = true;
    Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码连接')),
      body: Column(
        children: [
          Expanded(child: _problem == null ? _preview() : _problemView()),
          _hint(),
        ],
      ),
    );
  }

  Widget _preview() =>
      CameraPreview(viewfinder: _viewfinder, aspectRatio: widget.spec.aspectRatio);

  Widget _problemView() => Container(
        color: Colors.black87,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Text(
          _problem!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      );

  Widget _hint() => Container(
        width: double.infinity,
        color: Colors.black87,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '把电脑端屏幕上的二维码放进框里',
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Text(
              _sawForeignCode
                  ? '这不是 VidLog 的二维码 —— 要扫的是电脑端上点【连接电脑/手机】之后弹出的那一张。'
                  : '二维码在电脑端上点【连接电脑/手机】才会出现，5 分钟内有效。',
              style: TextStyle(
                color: _sawForeignCode ? Colors.orangeAccent : Colors.white60,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
}
