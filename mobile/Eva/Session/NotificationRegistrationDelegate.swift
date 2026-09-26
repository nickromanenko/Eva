import SwiftUI
import UIKit
import UserNotifications

/// The notification registration delegate (#79, A9): the app's half of push, and nothing
/// more. It registers for a remote-notification token and hands it to the Keychain, where
/// `AppSession` picks it up after a successful bootstrap and sends it to
/// `PUT /me/devices/{deviceId}`.
///
/// **No Firebase SDK** (GUARDRAILS 8): registering with APNs through UIKit is talking to
/// Apple, and the app still talks only to the Eva API — the token travels there over the
/// API's own route, never through a third-party SDK.
///
/// **The permission prompt is not shown here.** §9.4 leaves its timing open and forbids
/// showing it before the first thing that would benefit from it exists (an appointment with
/// a reminder, a finished Nutrition setup). `requestPermission()` is the seam a later slice
/// calls; until then `registerForRemoteNotifications` runs on its own, which fetches a token
/// without asking, so the device is known before the prompt ever matters.
final class NotificationRegistrationDelegate: NSObject,
    UIApplicationDelegate,
    UNUserNotificationCenterDelegate,
    ObservableObject {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        _ = KeychainTokenStore.shared.saveDeviceToken(Self.hex(deviceToken))
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Best-effort: nothing to show the user, and the next launch retries registration.
        // The token is an identifier, so the error is deliberately not inspected or logged.
    }

    /// The permission prompt, deferred (§9.4). A later slice calls this once a feature that
    /// needs notifications exists; it is never called at launch.
    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// The APNs token as a hex string — the form the API stores.
    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
