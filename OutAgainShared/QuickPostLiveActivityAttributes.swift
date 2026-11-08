import ActivityKit
import Foundation

struct QuickPostLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var postCountToday: Int
        var createdAt: Date
    }

    var activityID: String
    var deepLink: String
}

enum QuickPostDeepLink {
    static let quickPostURL = URL(string: "outagain://quick-post")!
}
