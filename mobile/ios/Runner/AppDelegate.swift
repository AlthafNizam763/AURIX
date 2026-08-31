import Flutter
import UIKit

#if canImport(ActivityKit)
import ActivityKit
#endif

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
    DynamicIslandChannel.register(with: engineBridge.binaryMessenger)
  }
}

/// The iOS half of AURIX's Dynamic Island bridge.
///
/// ## What iOS actually offers
///
/// There is no equivalent of Android's overlay window, and there is no way to
/// ask for one — an app cannot draw over other apps, full stop. The real iOS
/// Dynamic Island is a **Live Activity**: a piece of UI declared by a WidgetKit
/// extension, rendered by the system in the cutout and on the Lock Screen, and
/// driven by the app through ActivityKit.
///
/// A Live Activity is therefore not something this file can conjure. Its layout
/// lives in a widget extension target, and its `ActivityAttributes` type has to
/// be compiled into both that extension and the app so the two agree on the
/// shape of the state being passed between them. Adding a target is an Xcode
/// project change, not a source change.
///
/// ## So this reports the truth
///
/// [capability] looks for an embedded WidgetKit extension and asks ActivityKit
/// whether Live Activities are permitted for this app, and answers with what it
/// finds. On a build with no extension it says `liveActivityExtensionMissing`,
/// the Dart side never calls `show`, and Settings explains that the island stays
/// inside AURIX on this device.
///
/// What iOS users get regardless — and what genuinely matters for the
/// background case — is unchanged and already working: `audio_service` owns the
/// Now Playing session, so the Lock Screen and Control Centre show the current
/// track, artwork and transport controls while AURIX is backgrounded, driven by
/// the same `PlayerController` as everything else.
///
/// The extension source and the exact Xcode steps are in `ios/LiveActivity/`.
/// Once it is added, this class is where the ActivityKit calls belong; the Dart
/// contract above it does not change.
enum DynamicIslandChannel {
  private static let name = "com.aurix.app/dynamic_island"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "capability":
        result(capability())

      // Unreachable while `capability` reports the surface as unusable — the
      // Dart controller checks before it draws. Answered rather than left to
      // `notImplemented` so a future build that changes the capability without
      // finishing the wiring fails loudly instead of silently doing nothing.
      case "show", "update", "syncPosition", "hide":
        result(
          FlutterError(
            code: "live_activity_unavailable",
            message: "No Live Activity extension is linked into this build. "
              + "See ios/LiveActivity/README.md.",
            details: capability()
          )
        )

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// What this build can do, in the vocabulary the Dart side parses.
  private static func capability() -> [String: Any] {
    guard hasLiveActivityExtension() else {
      return [
        "surface": "none",
        "reason": "liveActivityExtensionMissing",
        "granted": false,
      ]
    }

    #if canImport(ActivityKit)
    if #available(iOS 16.1, *) {
      let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
      return [
        "surface": "liveActivity",
        "reason": enabled ? "none" : "liveActivityDisabledByUser",
        // Never `true` until the ActivityKit calls above exist: claiming the
        // surface is usable is what would make Dart start calling `show`.
        "granted": false,
      ]
    }
    #endif

    // iOS 16.0 and below have no Live Activities at all.
    return [
      "surface": "none",
      "reason": "unsupportedPlatform",
      "granted": false,
    ]
  }

  /// Whether a WidgetKit extension is embedded in this build.
  ///
  /// Read from the bundle rather than assumed, because it is the one fact that
  /// changes when someone follows `ios/LiveActivity/README.md` — and the whole
  /// point of reporting a capability instead of a platform is that the answer
  /// tracks the build rather than the operating system.
  private static func hasLiveActivityExtension() -> Bool {
    guard let plugins = Bundle.main.builtInPlugInsURL,
      let contents = try? FileManager.default.contentsOfDirectory(
        at: plugins,
        includingPropertiesForKeys: nil
      )
    else { return false }

    return contents.contains { url in
      guard url.pathExtension == "appex",
        let bundle = Bundle(url: url),
        let info = bundle.infoDictionary?["NSExtension"] as? [String: Any],
        let point = info["NSExtensionPointIdentifier"] as? String
      else { return false }
      return point == "com.apple.widgetkit-extension"
    }
  }
}
