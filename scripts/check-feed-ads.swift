import Foundation

@main
struct FeedAdChecks {
    static func main() {
        precondition(!FeedAdConfiguration.isEnabled(in: [:]))
        for value in ["false", "", "TRUE", "1", "invalid"] {
            precondition(!FeedAdConfiguration.isEnabled(in: ["feed_ads_enabled": value]))
        }
        precondition(FeedAdConfiguration.isEnabled(in: ["feed_ads_enabled": "true"]))
        precondition(FeedAdRequestState(postIDs: [], enabled: false) != FeedAdRequestState(postIDs: [], enabled: true))
        let posts = (1...100).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        for count in 0...100 {
            let page = Array(posts.prefix(count))
            let anchors = FeedAdPlacement.anchors(in: page)
            precondition(anchors.count == count / 6, "Wrong ad count for \(count) posts")
            precondition(anchors.enumerated().allSatisfy { offset, id in
                id == page[(offset + 1) * 6 - 1]
            }, "An ad displaced a real post")
        }
        let anchors = Set(FeedAdPlacement.anchors(in: posts))
        var adPositions: [Int] = []
        var row = 0
        for post in posts {
            row += 1
            if anchors.contains(post) { row += 1; adPositions.append(row) }
        }
        precondition(adPositions == Array(stride(from: 7, through: row, by: 7)), "Ads must be every seventh feed row")
        let firstPage = FeedAdPlacement.anchors(in: Array(posts.prefix(17)))
        let nextPage = FeedAdPlacement.anchors(in: Array(posts.prefix(31)))
        precondition(Array(nextPage.prefix(firstPage.count)) == firstPage, "Pagination moved existing slots")
        for index in posts.indices {
            let boundary = (index / 6 + 1) * 6 - 1
            let expected = posts.indices.contains(boundary) ? posts[boundary] : nil
            precondition(FeedAdPlacement.nextAnchor(after: index, in: posts) == expected)
        }
        precondition(FeedAdPlacement.nextAnchor(after: -1, in: posts) == nil)
        precondition(FeedAdPlacement.nextAnchor(after: 9, in: Array(posts.prefix(9))) == nil)
        let deleted = Array(posts.prefix(23)).filter { $0 != posts[3] }
        precondition(FeedAdPlacement.anchors(in: deleted) == [deleted[5], deleted[11], deleted[17]])

        func configuration(_ mode: String, _ app: String, _ unit: String, debug: Bool = false) -> FeedAdConfiguration {
            FeedAdConfiguration(mode: mode, appID: app, unitID: unit, allowsTestAds: debug)
        }
        let app = "ca-app-pub-1234567890123456~1234567890"
        let unit = "ca-app-pub-1234567890123456/1234567890"
        precondition(configuration("disabled", app, unit).unitID == nil)
        precondition(configuration("test", app, unit).unitID == nil, "Test ads enabled in Release")
        precondition(configuration("test", app, unit, debug: true).unitID == FeedAdConfiguration.testUnitID)
        precondition(configuration("test", "", unit, debug: true).unitID == nil)
        precondition(configuration("live", app, unit).unitID == unit)
        precondition(configuration("live", FeedAdConfiguration.testAppID, unit).unitID == nil)
        precondition(configuration("live", app, FeedAdConfiguration.testUnitID).unitID == nil)
        precondition(configuration("live", app, "ca-app-pub-9876543210987654/1234567890").unitID == nil)
        precondition(configuration("live", "$(ADMOB_APP_ID)", "$(OUTAGAIN_NATIVE_AD_UNIT_ID)").unitID == nil)
        precondition(configuration("live", "", "").unitID == nil)
        print("PASS: feed spacing, pagination, deletion, prefetch boundaries, and test/live configuration gates")
    }
}
