import XCTest
@testable import OutAgain

@MainActor
final class ActivityNotificationBundleTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    func testRepeatedPostActivityKeepsEveryDestinationAndReadState() {
        let postID = UUID()
        let commentID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let old = notification(kind: .reaction, date: start, postID: postID, isRead: true)
        let recent = notification(kind: .comment, date: start.addingTimeInterval(60), postID: postID, commentID: commentID)
        let bundles = ActivityNotificationBundle.make(from: [old, recent], calendar: calendar)
        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(bundles[0].notifications, [recent, old])
        XCTAssertEqual(bundles[0].latest.commentID, commentID)
        XCTAssertTrue(bundles[0].hasUnread)
    }

    func testDifferentDaysAndDifferentPostsStaySeparate() {
        let postID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            notification(kind: .reaction, date: start, postID: postID),
            notification(kind: .reaction, date: start.addingTimeInterval(86_400), postID: postID),
            notification(kind: .reaction, date: start, postID: UUID())
        ]
        let bundles = ActivityNotificationBundle.make(from: items, calendar: calendar)
        XCTAssertEqual(bundles.count, 3)
        XCTAssertEqual(bundles.first?.latest, items[1])
    }

    func testFriendRequestsAndRecapsNeverCollapseIntoPostActivity() {
        let postID = UUID()
        let now = Date()
        let items = [
            notification(kind: .friendRequest, date: now, postID: postID),
            notification(kind: .nightRecap, date: now, postID: postID),
            notification(kind: .reaction, date: now, postID: postID),
            notification(kind: .comment, date: now, postID: nil)
        ]
        XCTAssertEqual(ActivityNotificationBundle.make(from: items, calendar: calendar).count, 4)
    }

    private func notification(kind: NotificationKind, date: Date, postID: UUID?, commentID: UUID? = nil, isRead: Bool = false) -> AppNotification {
        AppNotification(id: UUID(), kind: kind, title: "Activity", detail: "", createdAt: date, isRead: isRead, postID: postID, commentID: commentID)
    }
}
