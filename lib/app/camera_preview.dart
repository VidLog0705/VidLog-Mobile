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
              child: CustomPaint(painter: ViewfinderPainter(viewfinder.rect)),
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

/// 画取景框：**只有四个角的括号**。
///
/// ## 为什么没有压暗、也没有整圈框线（需求方 2026-09-23 照界面草图裁决）
///
/// 这两样以前都有，是需求方照着他自己画的界面草图点的（草图里只画了四个角），
/// **不是顺手简化**。
///
/// 删之前先想清楚一件事，否则这个改动会悄悄毁掉 §3.2.2：
/// **压暗原本是拿来衬这四角的。** 以前四角是亮绿、周围一片黑，所以看得见；
/// 压暗一没，四角就直接压在**任意亮度**的实景上 —— 白色面单上画白角等于没画，
/// 而用户看不见框的后果是「看着放进去了，系统说不算」，正是这一节存在的原因。
/// 所以四角画**两层**：底下一层深色描边，上面一层白。
///
/// 两层这个手法与 §3.2.6 那个钟**完全同一个理由**（见 recorder_page 的钟）：
/// 底色不可控时，靠描边而不是靠颜色本身。
///
/// ⚠️ **别照着旧注释把压暗加回来。** 旧理由（「让框内框外一眼可辨」）写在
/// 代码里很久，看起来很像被人误删的 —— `test/viewfinder_painter_test.dart`
/// 专门挡这次「顺手恢复」。
class ViewfinderPainter extends CustomPainter {
  const ViewfinderPainter(this.rect);

  /// 归一化坐标（0~1，原点左上）。
  final NormalizedRect rect;

  /// 角臂长（逻辑像素）。
  ///
  /// **只剩四角之后，整个框的边界全靠这八段线交代** —— 臂短了就看不出框在哪儿，
  /// 用户会把面单放在角与角中间、以为在框内。所以它比原来那版的 26 略长。
  static const double armLength = 28;

  /// 白线线宽。描边层要更粗（两边各多出一半），白线才不会从描边边缘溢出来。
  static const double strokeWidth = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );

    // 外层深、内层白。顺序不能反 —— 反了白线会被盖掉一半。
    final halo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 4
      ..strokeCap = StrokeCap.round
      ..color = Colors.black.withValues(alpha: 0.6);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;

    for (final paint in [halo, stroke]) {
      void arm(Offset from, Offset to) => canvas.drawLine(from, to, paint);

      arm(frame.topLeft, frame.topLeft + const Offset(armLength, 0));
      arm(frame.topLeft, frame.topLeft + const Offset(0, armLength));
      arm(frame.topRight, frame.topRight + const Offset(-armLength, 0));
      arm(frame.topRight, frame.topRight + const Offset(0, armLength));
      arm(frame.bottomLeft, frame.bottomLeft + const Offset(armLength, 0));
      arm(frame.bottomLeft, frame.bottomLeft + const Offset(0, -armLength));
      arm(frame.bottomRight, frame.bottomRight + const Offset(-armLength, 0));
      arm(frame.bottomRight, frame.bottomRight + const Offset(0, -armLength));
    }
  }

  @override
  bool shouldRepaint(ViewfinderPainter oldDelegate) => oldDelegate.rect != rect;
}
