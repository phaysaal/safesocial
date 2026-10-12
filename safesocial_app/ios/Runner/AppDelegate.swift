import Flutter
import UIKit

/// Spheres runner.
///
/// Besides registering plugins, this is the APNs bridge: Dart asks to
/// register, iOS hands back a device token, and a background push (no alert,
/// no payload — `content-available` only) wakes Dart to sync. Everything the
/// user eventually sees is built on the device from decrypted content.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var apnsChannel: FlutterMethodChannel?
  private var deviceToken: String?
  private var pendingRegisterResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "spheres/apns",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "register":
        if let token = self.deviceToken {
          result(token)
        } else {
          self.pendingRegisterResult = result
          DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    apnsChannel = channel

    // Protected media. iOS has no window flag against screenshots, so
    // "secure" answers false and the viewer says so; what iOS does offer is
    // word after a screenshot and when recording starts, which hides the
    // picture at once.
    let screen = FlutterMethodChannel(
      name: "spheres/screen",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    screen.setMethodCallHandler { call, result in
      switch call.method {
      case "secure":
        result(false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main
    ) { _ in screen.invokeMethod("screenshot", arguments: nil) }
    NotificationCenter.default.addObserver(
      forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
    ) { _ in
      if UIScreen.main.isCaptured { screen.invokeMethod("recording", arguments: nil) }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    self.deviceToken = token
    if let pending = pendingRegisterResult {
      pending(token)
      pendingRegisterResult = nil
    }
    apnsChannel?.invokeMethod("token", arguments: token)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    if let pending = pendingRegisterResult {
      pending(FlutterError(code: "apns", message: error.localizedDescription, details: nil))
      pendingRegisterResult = nil
    }
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  /// A content-free background push. Dart syncs and answers when its window
  /// closes; iOS gives us about thirty seconds, so answer either way.
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    var finished = false
    let finish: (UIBackgroundFetchResult) -> Void = { outcome in
      if finished { return }
      finished = true
      completionHandler(outcome)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { finish(.newData) }
    guard let channel = apnsChannel else {
      finish(.noData)
      return
    }
    channel.invokeMethod("wake", arguments: nil) { _ in finish(.newData) }
  }
}
