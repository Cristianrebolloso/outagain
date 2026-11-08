import Foundation

@main
struct FeedAdChecks {
    static func main() {
        let posts = (1...100).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        for count in 0...100 {
            let page = Array(posts.prefix(count))
            let anchors = FeedAdPlacement.anchors(in: page)
            precondition(anchors.count == count / 10, "Wrong ad count for \(count) posts")
            precondition(anchors.enumerated().allSatisfy { offset, id in
                id == page[(offset + 1) * 10 - 1]
            }, "An ad displaced a real post")
        }
        let firstPage = FeedAdPlacement.anchors(in: Array(posts.prefix(17)))
        let nextPage = FeedAdPlacement.anchors(in: Array(posts.prefix(31)))
        precondition(Array(nextPage.prefix(firstPage.count)) == firstPage, "Pagination moved existing slots")
        for index in posts.indices {
            precondition(FeedAdPlacement.nextAnchor(after: index, in: posts) == posts[(index / 10 + 1) * 10 - 1])
        }
        precondition(FeedAdPlacement.nextAnchor(after: -1, in: posts) == nil)
        precondition(FeedAdPlacement.nextAnchor(after: 9, in: Array(posts.prefix(9))) == nil)
        let deleted = Array(posts.prefix(23)).filter { $0 != posts[3] }
        precondition(FeedAdPlacement.anchors(in: deleted) == [deleted[9], deleted[19]])

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
