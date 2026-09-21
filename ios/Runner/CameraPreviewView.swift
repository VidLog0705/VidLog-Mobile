import AVFoundation
import Flutter
import UIKit

/// 相机预览视图（原生侧）。
///
/// 规格 §3.2.2 要求点「开始工作」后**画面出现可见的取景框** ——
/// 没有预览就没有取景框可言，用户也没法把面单对准框。
///
/// ## 为什么共用同一个会话
///
/// 预览层挂的是**录制器的那个 `AVCaptureSession`**，不是另开一个。
/// 分成两个会互相抢相机；而且更根本的是 ——
/// **用户看到的画面必须就是录下来的画面**，否则取景框画的框和实际裁剪的范围
/// 会对不上，取证就成了笑话。
final class CameraPreviewView: NSObject, FlutterPlatformView {

    private let container: PreviewContainerView

    init(frame: CGRect, recorderProvider: @escaping () -> CameraSegmentRecorder?) {
        container = PreviewContainerView(recorderProvider: recorderProvider)
        super.init()
        container.frame = frame
    }

    func view() -> UIView { container }
}

/// 承载 `AVCaptureVideoPreviewLayer` 的 view。
private final class PreviewContainerView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass 保证了它就是预览层。
        layer as! AVCaptureVideoPreviewLayer
    }

    private let recorderProvider: () -> CameraSegmentRecorder?

    init(recorderProvider: @escaping () -> CameraSegmentRecorder?) {
        self.recorderProvider = recorderProvider
        super.init(frame: .zero)

        backgroundColor = .black

        // `.resizeAspectFill`：填满屏幕、允许裁掉溢出部分。
        // 取景框是按**归一化坐标**画的，所以只要预览层填满这个 view，
        // 框画在哪、判定就管到哪 —— 两边用的是同一套坐标。
        previewLayer.videoGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不从 nib 加载")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // **每次布局都重新挂一遍会话。** 视图可能在相机打开之前就被创建了
        // （Flutter 建视图与 Dart 调 openCamera 的先后没有保证），
        // 挂一次就撒手的话会一直是黑屏。挂的是同一个对象时赋值是廉价的。
        guard let session = recorderProvider()?.captureSession else { return }

        if previewLayer.session !== session {
            previewLayer.session = session
        }

        // 预览方向要和录制方向一致，否则用户看到的是横的、录下来却是正的（或反过来）。
        if #available(iOS 17.0, *) {
            let angle: CGFloat = 90
            if let connection = previewLayer.connection,
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else if let connection = previewLayer.connection,
                  connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}

/// Flutter 侧的视图工厂。
final class CameraPreviewFactory: NSObject, FlutterPlatformViewFactory {

    private let recorderProvider: () -> CameraSegmentRecorder?

    init(recorderProvider: @escaping () -> CameraSegmentRecorder?) {
        self.recorderProvider = recorderProvider
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        CameraPreviewView(frame: frame, recorderProvider: recorderProvider)
    }
}
