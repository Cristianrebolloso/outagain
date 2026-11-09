import XCTest
@testable import OutAgain

@MainActor
final class OfflineNoticeTests: XCTestCase {
    func testBriefDropoutNeverShowsNotice() async throws {
        let notice = OfflineNoticeState(delay: .milliseconds(200))
        notice.update(isOffline: true)
        XCTAssertFalse(notice.isVisible)
        try await Task.sleep(for: .milliseconds(50))
        notice.update(isOffline: false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(notice.isVisible)
    }

    func testRepeatedFailuresDoNotRestartDelayAndRecoveryHidesNotice() async throws {
        let notice = OfflineNoticeState(delay: .milliseconds(200))
        notice.update(isOffline: true)
        try await Task.sleep(for: .milliseconds(150))
        notice.update(isOffline: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(notice.isVisible)
        notice.update(isOffline: false)
        XCTAssertFalse(notice.isVisible)
    }

    func testNewOutageGetsItsOwnDelay() async throws {
        let notice = OfflineNoticeState(delay: .milliseconds(200))
        notice.update(isOffline: true)
        try await Task.sleep(for: .milliseconds(150))
        notice.update(isOffline: false)
        notice.update(isOffline: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(notice.isVisible)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(notice.isVisible)
        notice.update(isOffline: false)
    }
}
