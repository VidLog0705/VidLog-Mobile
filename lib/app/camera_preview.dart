import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../scanning/viewfinder.dart';

/// 原生预览视图的类型名。须与 iOS `RecorderPlugin.previewViewType` **和**
/// Android `RecorderChannel.PREVIEW_VIEW_TYPE` 一致。
const _previewViewType = 'vidlog/camera_preview';

/// 录像的画面比例（宽/高）。
///
/// 竖屏持机、会话 preset 是 1280×720、connection 转了 90°，
/// 所以实际录像是 720×1280。
///
/// **这个值必须与 [ScanGate] 用的那个一致** —— 见 [CameraPreview] 的说明。
const kVideoAspectRatio = 720 / 1280;

/// 相机预览 + **可见的取景框**。
///
/// 规格 §3.2.2：
/// > 画面出现**可见的取景框**；**只有框内的面单会被识别，框外一律忽略**。
///
/// 这两半必须是**同一件事**：画出来的框和实际判定的范围要严格一致，
/// 否则用户看着框把面单放进去、系统却说不算 —— 取证工具最不能有的行为。
///
/// ## 怎么保证一致
///
/// 1. 预览视图**按录像的画面比例**摆放（[kVideoAspectRatio]），
///    所以视频正好填满它、没有黑边也没有裁剪 ——
///    归一化坐标可以直接当控件坐标用
/// 2. 框的位置来自**同一个** [Viewfinder]（由调用方传进来，
///    也就是 [ScanGate] 正在用的那个）
///
/// 任何一边改了（视频比例、取景框档位），另一边会自动跟上，
/// 因为它们读的是同一份数据。
class CameraPreview extends StatelessWidget {
  const CameraPreview({super.key, required this.viewfinder});

  /// 正在生效的取景框。**必须与 `ScanGate` 用的是同一个对象。**
  final Viewfinder viewfinder;

  @override
  Widget build(BuildContext context) {
    // 预览是原生视图。两个手机端都实现了；桌面上跑（开发时）没有，
    // 那时如实显示「没预览」，而不是给一块黑屏让人以为坏了。
    if (!Platform.isIOS && !Platform.isAndroid) {
      return const _PreviewUnavailable();
    }

    return Center(
      child: AspectRatio(
        aspectRatio: kVideoAspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _nativePreview(context),
            // 框画在预览之上，用的是同一份归一化坐标。
            IgnorePointer(
              child: CustomPaint(painter: _ViewfinderPainter(viewfinder.rect)),
            ),
          ],
        ),
      ),
    );
  }

  /// 原生预览。
  ///
  /// Android 那边**必须走混合合成**（hybrid composition，也就是
  /// `initExpensiveAndroidView`）：预览是相机直接写进去的一路 Surface，
  /// 默认那条虚拟显示（virtual display）渲染不出它。
  ///
  /// ⚠️ 走错了的表现是**一块黑屏**，而且不会有任何报错 ——
  /// 真机上看到黑屏、取景框却画得好好的，先查这里和
  /// `MainActivity` 里注册工厂时那个 `isHybrid = true`。
  Widget _nativePreview(BuildContext context) {
    if (Platform.isIOS) {
      return const UiKitView(viewType: _previewViewType);
    }

    return PlatformViewLink(
      viewType: _previewViewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        // 预览不吃触摸：取景框在上面压着，缩放交给表盘。
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.translucent,
      ),
      onCreatePlatformView: (params) =>
          PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: params.viewType,
            layoutDirection: Directionality.of(context),
            onFocus: () => params.onFocusChanged(true),
          )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..create(),
    );
  }
}

class _PreviewUnavailable extends StatelessWidget {
  const _PreviewUnavailable();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black87,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: const Text(
        '这个平台还没有相机预览。\n（两个手机端都已实现；桌面端本来就不需要）',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white70, fontSize: 13),
      ),
    );
  }
}

/// 画取景框：框外压暗、框上一圈亮边。
///
/// 压暗这件事不只是好看 —— 它让「框内 / 框外」在视觉上**一眼可辨**，
/// 用户不用去猜边界在哪儿。
class _ViewfinderPainter extends CustomPainter {
  const _ViewfinderPainter(this.rect);

  /// 归一化坐标（0~1，原点左上）。
  final NormalizedRect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );

    // 框外压暗：整块画布减去框，用 even-odd 填充规则挖个洞。
    final scrim = Path()
      ..addRect(Offset.zero & size)
      ..addRect(frame)
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(
      scrim,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    // 框线
    canvas.drawRect(
      frame,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white,
    );

    // 四角加粗，便于对准
    const cornerLength = 26.0;
    final corner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..color = Colors.greenAccent;

    void line(Offset from, Offset to) => canvas.drawLine(from, to, corner);

    line(frame.topLeft, frame.topLeft + const Offset(cornerLength, 0));
    line(frame.topLeft, frame.topLeft + const Offset(0, cornerLength));
    line(frame.topRight, frame.topRight + const Offset(-cornerLength, 0));
    line(frame.topRight, frame.topRight + const Offset(0, cornerLength));
    line(frame.bottomLeft, frame.bottomLeft + const Offset(cornerLength, 0));
    line(frame.bottomLeft, frame.bottomLeft + const Offset(0, -cornerLength));
    line(frame.bottomRight, frame.bottomRight + const Offset(-cornerLength, 0));
    line(frame.bottomRight, frame.bottomRight + const Offset(0, -cornerLength));
  }

  @override
  bool shouldRepaint(_ViewfinderPainter oldDelegate) =>
      oldDelegate.rect != rect;
}
