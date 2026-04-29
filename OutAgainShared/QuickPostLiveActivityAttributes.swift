import ActivityKit
import Foundation

struct QuickPostLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var headline: String
        var detail: String
        var primaryHex: String
        var secondaryHex: String
        var avatarSymbol: String
        var avatarPrimaryHex: String
        var avatarSecondaryHex: String
        var avatarImageData: Data?
        var avatarRemoteURL: String?
        var postCountToday: Int
        var createdAt: Date
    }

    var activityID: String
    var deepLink: String
}

enum QuickPostDeepLink {
    static let quickPostURL = URL(string: "outagain://quick-post")!
}
