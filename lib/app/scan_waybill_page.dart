import 'dart:async';

import 'package:flutter/material.dart';

import '../recording/recorder_gateway.dart';
import '../recording/recording_spec.dart';
import '../scanning/viewfinder.dart';
import 'camera_preview.dart';
import 'palette.dart';

/// 【扫码搜索】：扫一张面单，把单号填进备份页那个搜索框
/// （需求方 2026-09-27 照备份页草图定的）。
///
/// ## ⚠️ 它和【扫码连接】是**两个**页面，不是同一个加了个开关
///
/// | | 扫码连接 | 这一页 |
/// |---|---|---|
/// | 开相机时 | `qrOnly: true`（**只认二维码**） | 默认（**只认一维码**） |
/// | 认什么 | 能解成 VidLog 入网码的那一张 | 框里任何一个一维码 |
/// | 交回去 | 解出来的地址 + 令牌 | **原文** |
///
/// 合成一个页面就要把上面三样全做成参数，而「**这一页现在认什么码**」这件事
/// 就藏进参数里了 —— 那正是规格 §3.4.5 ④ 最怕的含糊：识别范围一错，
/// 面单上的二维码会把一整条 URL 灌进单号字段。
///
/// ⚠️ 与那一页同一条规矩：**离开时把识码范围拨回去**（见 [_restoreCamera]）。
/// 这一页开的本来就是一维码，拨不拨都一样 —— 但那句话今天对、明天不一定对，
/// 所以照写，别删。
class ScanWaybillPage extends StatefulWidget {
  const ScanWaybillPage({
    super.key,
    required this.gateway,
    required this.closeCameraWhenDone,
    required this.spec,
  });

  final RecorderGateway gateway;

  /// **生效的**录制规格。理由与 `ScanConnectPage` 逐字相同：
  /// 相机是进程级的同一个会话，这一页按 9:16 硬摆的话，选了横屏的用户
  /// 会看到一张被拉扁的画面，而框跟着一起扁 —— 判定范围就是歪的。
  final RecordingSpec spec;

  /// 离开时要不要把相机关掉。
  ///
  /// ⚠️ 由调用方决定：**这个页面之前相机就开着的话不能关** ——
  /// 那可能是录制中，或者是发货栏的取景框还开着。关了就是掐掉别人的会话。
  final bool closeCameraWhenDone;

  /// 打开这一页。扫到一张面单就返回那一串；用户返回就是 `null`。
  static Future<String?> open(
    BuildContext context, {
    required RecorderGateway gateway,
    required bool closeCameraWhenDone,
    required RecordingSpec spec,
  }) =>
      Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => ScanWaybillPage(
            gateway: gateway,
            closeCameraWhenDone: closeCameraWhenDone,
            spec: spec,
          ),
        ),
      );

  @override
  State<ScanWaybillPage> createState() => _ScanWaybillPageState();
}

class _ScanWaybillPageState extends State<ScanWaybillPage> {
  /// 判定用的取景框。**与画出来的那个是同一个对象**（规格 §3.2.2）——
  /// 画一个框、按另一个范围判定，就会出现「看着放进去了，系统说不算」。
  ///
  /// 用最大档：这一页是拿手机对着面单扫，距离不好说，框小了得反复凑。
  late final Viewfinder _viewfinder = Viewfinder.forPreset(
    ViewfinderPreset.large,
    aspectRatio: widget.spec.aspectRatio,
  );

  StreamSubscription<NativeRecorderEvent>? _events;

  /// 相机没起来时的原因。非空时整个预览区换成这句话。
  String? _problem;

  /// 已经交回去了 —— 挡「同一帧里报了两次」的重复 pop。
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
          if (mounted) {
            setState(() => _problem = '没有相机权限。去系统设置里给这个应用打开相机，再回来重试。');
          }
          return;
        }
      }

      // ⚠️ 订阅**在开相机之前**挂上：反过来的话，相机起来那几十毫秒里
      // 扫到的东西没人接，而用户看到的是「扫了没反应」。
      _events ??= gateway.events.listen(_onEvent);

      await gateway.openCamera();
    } on Object catch (error) {
      if (mounted) setState(() => _problem = '相机没能打开：$error');
    }
  }

  /// 离开时把相机交回去。
  ///
  /// ⚠️ **先无条件把识码范围拨回默认（只认一维码）**，再决定关不关 ——
  /// 这一页没改过范围，但这句话的意义不在于现在，而在于**以后谁照抄这一页**：
  /// 抄的时候少一行 `openCamera()`，二维码识别就留在别人的会话上了。
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

    // 框外的一律不认 —— 与画出来的那个框严格一致（§3.2.2 的同一条规矩）。
    final inside = _viewfinder.acceptsRect(
      NormalizedRect(left: event.centerX, top: event.centerY, width: 0, height: 0),
    );
    if (!inside) return;

    _done = true;
    Navigator.of(context).pop(event.text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码搜索')),
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
        color: Palette.veil,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Text(
          _problem!,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: Palette.onDarkSoft),
        ),
      );

  Widget _hint() => Container(
        width: double.infinity,
        color: Palette.veil,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '把面单上的条码放进框里',
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: Palette.onDark),
            ),
            const SizedBox(height: 4),
            Text(
              // 说清扫到之后会发生什么：用户扫这一下是为了搜，不是为了开录 ——
              // 不说的话他会以为扫面单就是要开始录像了（那是发货栏干的事）。
              '扫到就把单号填进搜索框，不会开始录像。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Palette.onDarkFaint),
            ),
          ],
        ),
      );
}
