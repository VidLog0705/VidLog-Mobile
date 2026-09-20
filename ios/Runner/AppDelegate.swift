import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 原生录制器的通道。它不是 pub 包，所以 GeneratedPluginRegistrant 不会管它，
    // 得在这里手动挂上。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VidLogRecorder") {
      RecorderPlugin.register(with: registrar)
    }
  }
}
