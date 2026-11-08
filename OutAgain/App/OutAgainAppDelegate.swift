import Foundation
import UIKit
import UserNotifications

/// Routes APNs registration callbacks from UIKit into the AppStore.
///
/// SwiftUI's `@UIApplicationDelegateAdaptor` lets us keep the main entry point as a `SwiftUI.App`
/// while still handling the low-level APNs callbacks that have no SwiftUI equivalent. UIKit
/// instantiates this class itself via the adaptor, so we expose a class-level registry that the
/// `OutAgainApp.init` method uses to hand over the AppStore right after constructing it.
final class OutAgainAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Latest live delegate instance — set by UIKit when the adaptor initializes.
    nonisolated(unsafe) private static var latestInstance: OutAgainAppDelegate?

    /// Store to wire up once the adaptor instance exists (or the token to buffer if it beats us to it).
    @MainActor private static var pendingStoreAttachment: AppStore?

    /// Published globally so tests and tools can reach the live delegate. In production, prefer
    /// calling `register(store:)` so we handle the race between `init` and the adaptor correctly.
    static var shared: OutAgainAppDelegate? { latestInstance }

    /// AppStore the delegate forwards events to. Set from `register(store:)`.
    @MainActor weak var store: AppStore?

    /// Token captured before the store was attached — replayed on `attach(store:)`.
    @MainActor private var pendingToken: Data?
    @MainActor private var pendingPushTarget: PendingPushTarget?

    override init() {
        super.init()
        Self.latestInstance = self
        if let pending = Self.pendingStoreAttachment {
            Self.pendingStoreAttachment = nil
            Task { @MainActor in
                self.attach(store: pending)
            }
        }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        DuoOrientationPolicy.supportedOrientations(for: window)
    }

    /// Called from `OutAgainApp.init` — if the delegate has already been constructed, attach
    /// immediately; otherwise buffer the store so we pick it up as soon as UIKit makes the delegate.
    @MainActor
    static func register(store: AppStore) {
        if let live = latestInstance {
            live.attach(store: store)
            if let token = live.pendingToken {
                live.pendingToken = nil
                Task { @MainActor in
                    await store.registerAPNsToken(token)
                }
            }
        } else {
            pendingStoreAttachment = store
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = .systemBlue
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            if let store {
                await store.registerAPNsToken(deviceToken)
            } else {
                pendingToken = deviceToken
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        print("APNs registration failed: \(error.localizedDescription)")
        #endif
    }

    @MainActor
    private func attach(store: AppStore) {
        self.store = store
        if let target = pendingPushTarget {
            pendingPushTarget = nil
            store.pendingPushTarget = target
            Task { await store.openPendingPushIfReady() }
        }
    }

    /// Retain a cold-launch target until authentication and bootstrap are ready.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let target = Self.notificationTarget(from: response.notification.request.content.userInfo)
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self else { return }
            guard let store = self.store else { self.pendingPushTarget = target; return }
            store.pendingPushTarget = target
            await store.openPendingPushIfReady()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Must return immediately with no system presentation. If we `await`
        // network work first, iOS can still show the default banner/sound in
        // parallel — doubling up with `InAppNotificationOverlay`.
        Task { @MainActor [weak self] in
            guard let self, let store = self.store else { return }
            await store.pollNewNotifications()
        }
        return UNNotificationPresentationOptions()
    }

    static func notificationTarget(from userInfo: [AnyHashable: Any]) -> PendingPushTarget {
        let values = (userInfo["outagain"] as? [AnyHashable: Any]) ?? userInfo
        func uuid(_ key: String) -> UUID? { (values[key] as? String).flatMap(UUID.init(uuidString:)) }
        func date(_ key: String) -> Date? {
            guard let value = values[key] as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        var recap: NightRecapRoute?
        if values["kind"] as? String == "nightRecap", let start = date("nightStart"), let end = date("nightEnd"), end > start, end.timeIntervalSince(start) <= 25 * 3600 {
            recap = NightRecapRoute(start: start, end: end, groupID: uuid("nightGroupId"))
        }
        return PendingPushTarget(notificationID: uuid("notificationId"), postID: uuid("postId"), commentID: uuid("commentId"), recap: recap)
    }
}
