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

    override init() {
        super.init()
        Self.latestInstance = self
        if let pending = Self.pendingStoreAttachment {
            Self.pendingStoreAttachment = nil
            Task { @MainActor in
                self.store = pending
            }
        }
    }

    /// Called from `OutAgainApp.init` — if the delegate has already been constructed, attach
    /// immediately; otherwise buffer the store so we pick it up as soon as UIKit makes the delegate.
    @MainActor
    static func register(store: AppStore) {
        if let live = latestInstance {
            live.store = store
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

    // Show banners + sound even while foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }
}
