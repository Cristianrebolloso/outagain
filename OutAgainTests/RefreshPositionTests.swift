import XCTest
import CoreGraphics
@testable import OutAgain

final class RefreshPositionTests: XCTestCase {
    func testReleasingAndScrollBounceKeepIndicatorAtItsLastPosition() {
        for distance in [CGFloat(60), 75, 120] {
            var position = GlassRefreshPosition()
            position.beginDrag()
            position.updatePull(distance)
            let releasedAt = position.offset
            position.pinForRefresh()
            for bounce in [CGFloat(40), 8, 0, -4] {
                position.updatePull(bounce)
                XCTAssertEqual(position.offset, releasedAt)
            }
        }
    }

    func testNextPullFollowsFingerAgain() {
        var position = GlassRefreshPosition()
        position.updatePull(90)
        position.pinForRefresh()
        let pinned = position.offset
        position.updatePull(0)
        position.beginDrag()
        XCTAssertEqual(position.offset, 0)
        position.updatePull(30)
        XCTAssertGreaterThan(position.offset, 0)
        XCTAssertLessThan(position.offset, pinned)
    }

    func testActionReturningBeforeExternalRefreshObservationKeepsGesturePosition() {
        var position = GlassRefreshPosition()
        position.updatePull(80)
        let id = position.beginGestureRefresh()
        let releasedAt = position.offset

        // The action returned after synchronously starting an externally
        // tracked request. Its completion is applied with the latest flag.
        position.completeAction(id, isRefreshing: true)
        position.observeExternalRefresh(true, isInteracting: false)
        position.updatePull(0)
        XCTAssertFalse(position.isRunningAction)
        XCTAssertEqual(position.gestureRefreshID, id)
        XCTAssertEqual(position.offset, releasedAt)

        position.observeExternalRefresh(false, isInteracting: false)
        XCTAssertNil(position.gestureRefreshID)
        XCTAssertEqual(position.offset, releasedAt, "Fade out at the released position")
        position.observeExternalRefresh(true, isInteracting: false)
        XCTAssertEqual(position.offset, 0, "A later programmatic refresh starts at the top")
    }

    func testExternalFlagFinishingBeforeActionDoesNotEndGestureOwnershipEarly() {
        var position = GlassRefreshPosition()
        position.updatePull(90)
        let id = position.beginGestureRefresh()
        position.observeExternalRefresh(true, isInteracting: false)
        position.observeExternalRefresh(false, isInteracting: false)
        XCTAssertTrue(position.isRunningAction)
        XCTAssertEqual(position.gestureRefreshID, id)
        position.completeAction(id, isRefreshing: false)
        XCTAssertFalse(position.isRunningAction)
        XCTAssertNil(position.gestureRefreshID)
        XCTAssertEqual(position.offset, 27)
    }

    func testDragSpanningRefreshCompletionCanResumeAtCurrentPull() {
        var position = GlassRefreshPosition()
        position.updatePull(120)
        let id = position.beginGestureRefresh()
        position.updatePull(30)
        position.completeAction(id, isRefreshing: false)
        position.beginDrag()
        XCTAssertEqual(position.offset, 9)
        position.updatePull(70)
        let secondID = position.beginGestureRefresh()
        XCTAssertNotEqual(id, secondID)
        XCTAssertEqual(position.offset, 21)
        position.completeAction(id, isRefreshing: false)
        XCTAssertTrue(position.isRunningAction, "An old completion cannot stop the next refresh")
        XCTAssertEqual(position.gestureRefreshID, secondID)
    }
}
