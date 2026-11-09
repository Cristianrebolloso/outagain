import XCTest
@testable import OutAgain

@MainActor
final class PostFlowNavigationTests: XCTestCase {
    func testReviewBackPreservesDetailsThenCameraBackReturnsHome() {
        let store = makeStore()
        defer { store.postFlowDismissalRepinTask?.cancel() }
        store.selectedTab = .profile
        store.openPostFlow()
        store.applyCapturedPhoto(Data([1, 2, 3]), lensMode: .front)
        store.postDraft.caption = "Keep this caption"
        store.postDraft.selectedDrinkIDs = [UUID()]
        store.postDraft.taggedFriendIDs = [UUID()]
        store.postDraft.selectedVenueID = UUID()
        store.postDraft.shareLocally = true
        store.postDraft.location = LocationSnapshot(latitude: 30, longitude: -97, horizontalAccuracy: 10, capturedAt: .now)
        let draft = store.postDraft

        XCTAssertEqual(store.backFromPostFlow(), .camera)
        XCTAssertTrue(store.isPostFlowPresented)
        XCTAssertEqual(store.selectedTab, .post)
        XCTAssertNil(store.postDraft.capturedPhotoData)
        XCTAssertFalse(store.canPublishDraft)
        XCTAssertEqual(store.postDraft.id, draft.id)
        XCTAssertEqual(store.postDraft.caption, draft.caption)
        XCTAssertEqual(store.postDraft.selectedDrinkIDs, draft.selectedDrinkIDs)
        XCTAssertEqual(store.postDraft.taggedFriendIDs, draft.taggedFriendIDs)
        XCTAssertEqual(store.postDraft.selectedVenueID, draft.selectedVenueID)
        XCTAssertEqual(store.postDraft.location, draft.location)
        XCTAssertTrue(store.postDraft.shareLocally)

        XCTAssertEqual(store.backFromPostFlow(), .home)
        XCTAssertFalse(store.isPostFlowPresented)
        XCTAssertEqual(store.selectedTab, .home)
        XCTAssertEqual(store.postDraft.caption, "")
        // The cover's later dismissal callback must not restore Profile.
        store.finishPostFlowDismissal()
        XCTAssertEqual(store.selectedTab, .home)
    }

    func testUnconfirmedCaptureAndSampleBothReturnToCamera() {
        for isSample in [false, true] {
            let store = makeStore()
            defer { store.postFlowDismissalRepinTask?.cancel() }
            store.openPostFlow()
            store.postDraft.caption = "Keep my details"
            if isSample { store.useSampleCapture() }

            XCTAssertEqual(store.backFromPostFlow(hasPendingCapture: !isSample), .camera)
            XCTAssertTrue(store.isPostFlowPresented)
            XCTAssertFalse(store.postDraft.isUsingSampleCapture)
            XCTAssertEqual(store.postDraft.caption, "Keep my details")
        }
    }

    func testCameraBackReturnsHomeFromActivity() {
        let store = makeStore()
        defer { store.postFlowDismissalRepinTask?.cancel() }
        store.selectedTab = .activity
        store.openPostFlow()

        XCTAssertEqual(store.backFromPostFlow(), .home)
        XCTAssertFalse(store.isPostFlowPresented)
        XCTAssertEqual(store.selectedTab, .home)
    }

    func testBackCannotDiscardAPostWhilePublishing() {
        let store = makeStore()
        defer { store.postFlowDismissalRepinTask?.cancel() }
        store.openPostFlow()
        let photo = Data([1, 2, 3])
        store.applyCapturedPhoto(photo, lensMode: .back)
        store.isPublishingDraft = true

        XCTAssertEqual(store.backFromPostFlow(), .unchanged)
        XCTAssertTrue(store.isPostFlowPresented)
        XCTAssertEqual(store.postDraft.capturedPhotoData, photo)
    }

    private func makeStore() -> AppStore {
        // No authenticated backend or production network access.
        AppStore(backend: UnconfiguredBackend(environment: .placeholder))
    }
}
