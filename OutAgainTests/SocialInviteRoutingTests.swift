import XCTest
@testable import OutAgain

@MainActor
final class SocialInviteRoutingTests: XCTestCase {
    private let firstCode = "0123456789abcdef0123456789abcdef"
    private let secondCode = "fedcba9876543210fedcba9876543210"

    func testInviteWaitsThroughSignInAndProfileSetup() {
        withIsolatedStore { store in
            let viewer = store.viewer
            store.viewer = nil
            store.authState = .signedOut
            store.onboardingStep = .welcome

            XCTAssertTrue(store.receiveSocialInvite(link(firstCode)))
            XCTAssertEqual(store.pendingSocialInviteCode, firstCode)
            XCTAssertFalse(store.isSocialInvitePresented)

            store.viewer = viewer
            store.authState = .signedIn
            store.onboardingStep = .profile
            store.presentPendingSocialInvite()
            XCTAssertFalse(store.isSocialInvitePresented)

            store.promoteToLiveSession()
            store.presentPendingSocialInvite()
            XCTAssertTrue(store.isSocialInvitePresented)
            XCTAssertEqual(store.pendingSocialInviteCode, firstCode)
        }
    }

    func testClosingInviteDoesNotInterruptTheNextPost() {
        withIsolatedStore { store in
            XCTAssertTrue(store.receiveSocialInvite(link(firstCode)))
            XCTAssertTrue(store.isSocialInvitePresented)
            store.isSocialInvitePresented = false // User closes or swipes down.

            store.openPostFlow()
            store.closePostFlow()
            store.presentPendingSocialInvite() // Root's camera-dismissal callback.
            XCTAssertFalse(store.isSocialInvitePresented)
            XCTAssertEqual(store.pendingSocialInviteCode, firstCode)

            // Explicitly opening the link again is still a request to view it.
            XCTAssertTrue(store.receiveSocialInvite(link(firstCode)))
            XCTAssertTrue(store.isSocialInvitePresented)
        }
    }

    func testInviteReceivedDuringCaptureWaitsUntilCaptureCloses() {
        withIsolatedStore { store in
            store.openPostFlow()
            XCTAssertTrue(store.receiveSocialInvite(link(firstCode)))
            XCTAssertFalse(store.isSocialInvitePresented)
            XCTAssertTrue(store.isPostFlowPresented)
            store.closePostFlow()
            store.presentPendingSocialInvite()
            XCTAssertTrue(store.isSocialInvitePresented)
        }
    }

    func testInvalidURLDoesNotReplaceAPendingInvite() {
        withIsolatedStore { store in
            XCTAssertTrue(store.receiveSocialInvite(link(firstCode)))
            store.isSocialInvitePresented = false
            XCTAssertFalse(store.receiveSocialInvite("https://example.com/invite/?code=\(secondCode)"))
            XCTAssertEqual(store.pendingSocialInviteCode, firstCode)
            XCTAssertFalse(store.isSocialInvitePresented)
        }
    }

    func testOldAcceptanceCannotClearANewerInvite() {
        withIsolatedStore { store in
            XCTAssertTrue(store.receiveSocialInvite(link(firstCode)))
            XCTAssertTrue(store.receiveSocialInvite(link(secondCode)))
            store.clearPendingSocialInvite(matching: firstCode)
            XCTAssertEqual(store.pendingSocialInviteCode, secondCode)
            store.clearPendingSocialInvite(matching: secondCode)
            XCTAssertNil(store.pendingSocialInviteCode)
        }
    }

    func testMaintenanceDefersInviteWithoutLosingIt() {
        withIsolatedStore { store in
            store.appConfig["maintenance_mode_enabled"] = "true"
            XCTAssertTrue(store.shouldPresentMaintenanceScreen)
            XCTAssertTrue(store.receiveSocialInvite(link(firstCode)))
            XCTAssertFalse(store.isSocialInvitePresented)
            XCTAssertEqual(store.pendingSocialInviteCode, firstCode)

            store.appConfig["maintenance_mode_enabled"] = "false"
            store.presentPendingSocialInvite()
            XCTAssertTrue(store.isSocialInvitePresented)
        }
    }

    func testNotificationDestinationDefersInviteUntilDismissed() {
        withIsolatedStore { store in
            store.notificationDestination = .post(UUID(), commentID: UUID())
            XCTAssertTrue(store.receiveSocialInvite(link(firstCode)))
            XCTAssertFalse(store.isSocialInvitePresented)
            XCTAssertNotNil(store.notificationDestination)
            store.notificationDestination = nil
            store.presentPendingSocialInvite()
            XCTAssertTrue(store.isSocialInvitePresented)
        }
    }

    func testPresentedOrPendingPlayerDefersInvite() {
        for pending in [false, true] {
            withIsolatedStore { store in
                store.isMaddoxPlayerPresented = !pending
                store.pendingMaddoxPlayer = pending
                XCTAssertTrue(store.receiveSocialInvite(link(firstCode)))
                XCTAssertFalse(store.isSocialInvitePresented)
                store.isMaddoxPlayerPresented = false
                store.pendingMaddoxPlayer = false
                store.presentPendingSocialInvite()
                XCTAssertTrue(store.isSocialInvitePresented)
            }
        }
    }

    private func link(_ code: String) -> String {
        "outagain://invite?code=\(code)"
    }

    private func withIsolatedStore(_ body: (AppStore) -> Void) {
        let defaults = UserDefaults.standard
        let key = "OutAgain.pendingSocialInvite"
        let savedValue = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        let store = DuoLayoutFixtures.makeStore() // Unconfigured backend cannot reach production.
        defer {
            store.postFlowDismissalRepinTask?.cancel()
            if let savedValue { defaults.set(savedValue, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        body(store)
    }
}
