import Foundation

extension AppStore {
    /// Forwards an APNs device token into the backend for the signed-in viewer.
    ///
    /// Called by `OutAgainAppDelegate` when UIKit hands us the token after
    /// `UIApplication.registerForRemoteNotifications()` succeeds. If the viewer isn't
    /// populated yet (cold launch before bootstrap completes), we stash the token locally
    /// and retry once the viewer lands.
    func registerAPNsToken(_ token: Data) async {
        pendingAPNsToken = token
        await flushPendingAPNsTokenIfPossible()
    }

    /// Called from `applyBootstrap` once the viewer is known so buffered tokens get
    /// registered on the first launch where the user just signed in.
    func flushPendingAPNsTokenIfPossible() async {
        guard let token = pendingAPNsToken, let viewer else {
            #if DEBUG
            if pendingAPNsToken == nil {
                print("[APNs] No pending token to flush.")
            } else if viewer == nil {
                print("[APNs] Pending token held — waiting for viewer bootstrap.")
            }
            #endif
            return
        }

        // APNs environment must match the entitlement that produced this
        // token. Debug builds use the development entitlement even on a real
        // iPhone connected through Xcode; Release/TestFlight/App Store builds
        // use production. Mismatching these is a silent push killer.
        let deviceEnvironment: DeviceEnvironment
        #if DEBUG
        deviceEnvironment = .development
        #else
        deviceEnvironment = .production
        #endif

        do {
            try await backend.registerDeviceToken(token, environment: deviceEnvironment, for: viewer)
            pendingAPNsToken = nil
            lastRegisteredAPNsToken = token
            #if DEBUG
            let tokenPreview = token.map { String(format: "%02x", $0) }.joined().prefix(12)
            print("[APNs] Registered device token \(tokenPreview)… for \(viewer.username) (\(deviceEnvironment)).")
            #endif
        } catch {
            #if DEBUG
            print("[APNs] Register failed: \(error.localizedDescription). Will retry on next bootstrap.")
            #endif
            // Keep the token buffered — the next app foreground / bootstrap will retry.
        }
    }

    /// Unregister on sign-out so the backend stops targeting this device.
    func unregisterAPNsTokenIfNeeded() async {
        guard let token = lastRegisteredAPNsToken, let viewer else { return }
        try? await backend.unregisterDeviceToken(token, for: viewer)
        lastRegisteredAPNsToken = nil
    }

    /// Debug-only self-test: asks the backend to insert a notification row
    /// addressed to the signed-in viewer so the push-dispatch chain
    /// (trigger -> pg_net -> edge function -> APNs) is exercised end-to-end.
    /// The outcome is recorded server-side in `public.push_attempts`. Any
    /// error surfaces through `socialErrorMessage` so the Profile diagnostics
    /// button reflects failures without the user needing to tail logs.
    func sendSelfTestNotification() async {
        do {
            try await backend.sendSelfTestNotification()
            #if DEBUG
            print("[APNs] Self-test notification inserted. Inspect public.push_attempts for dispatch status.")
            #endif
            // Pull fresh data so the in-app notifications list reflects the
            // row that was just inserted on the server.
            await refreshAppData(silenceErrors: true)
        } catch {
            socialErrorMessage = "Self-test push failed: \(error.localizedDescription)"
            #if DEBUG
            print("[APNs] Self-test failed: \(error.localizedDescription)")
            #endif
        }
    }
}
