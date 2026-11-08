import Foundation
import CoreLocation
import SwiftUI

enum AccentColorChoice: String, CaseIterable, Identifiable {
    case purple  = "purple"
    case blue    = "blue"
    case skyBlue = "skyBlue"
    case pink    = "pink"
    case green   = "green"
    case white   = "white"
    case orange  = "orange"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .purple:  return "Party Purple"
        case .blue:    return "Liberal Blue"
        case .skyBlue: return "Sky Blue"
        case .pink:    return "Racist Pink"
        case .green:   return "Gay Green"
        case .white:   return "Normal White"
        case .orange:  return "Orange"
        }
    }

    var color: Color {
        switch self {
        case .purple:  return Color(hex: "#A855F7")
        case .blue:    return Color(hex: "#1D3FAB")
        case .skyBlue: return Color(hex: "#38BDF8")
        case .pink:    return Color(hex: "#EC4899")
        case .green:   return Color(hex: "#22C55E")
        case .white:   return Color.white
        case .orange:  return Color(hex: "#FF7A1A")
        }
    }

    var swatch: Color { color }
}

enum BackgroundTheme: String, CaseIterable, Identifiable, Codable {
    case standard = "standard"
    case original = "original"
    case speakeasy = "speakeasy"
    case night    = "night"
    case orange   = "orange"
    case green    = "green"
    case pink     = "pink"
    case blue     = "blue"

    static var allCases: [BackgroundTheme] {
        [
            .standard,
            .night,
            .orange,
            .green,
            .pink,
            .blue,
        ]
    }

    var id: String { rawValue }

    var availableTheme: BackgroundTheme {
        switch self {
        case .original, .speakeasy:
            return .standard
        default:
            return self
        }
    }

    var label: String {
        switch self {
        case .standard: return "11B"
        case .original, .speakeasy: return "11B"
        case .night:    return "Night"
        case .orange:   return "Mallory Orange"
        case .green:    return "Forest"
        case .pink:     return "Rose"
        case .blue:     return "Ocean"
        }
    }
}


enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case activity
    case post
    case friends
    case admin
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .post: "Post"
        case .friends: "People"
        case .admin: "Admin"
        case .activity: "Activity"
        case .profile: "Profile"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .post: "camera.fill"
        case .friends: "person.2.fill"
        case .admin: "megaphone.fill"
        case .activity: "bell.badge.fill"
        case .profile: "person.crop.circle.fill"
        }
    }
}

enum ProfileOverlayRoute: Hashable, Identifiable {
    case editProfile
    case settings
    case viewerFriends
    case userProfile(UserProfile)

    var id: Self { self }
}

enum FriendsPageMode: String, CaseIterable, Identifiable, Hashable {
    case people
    case discover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: "Friends"
        case .discover: "Add Friends"
        }
    }
}

enum FeedScope: String, CaseIterable, Identifiable, Hashable {
    case friends
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .friends: "Friends"
        case .local: "Local"
        }
    }
}

enum AuthState {
    case signedOut
    case signedIn
}

/// Tracks whether the first bootstrap has completed so the root view can
/// distinguish "still loading" from "finished loading, signed out."
enum BootstrapPhase {
    case pending      // init -> first bootstrap in flight
    case ready        // first bootstrap finished (regardless of signed-in/out)
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case profile
    case permissions
    case invite
    case done
}

enum AuthEntryMode {
    case signUp
    case signIn

    var title: String {
        switch self {
        case .signUp: "Sign Up"
        case .signIn: "Sign In"
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .signUp: "Create Account"
        case .signIn: "Log In"
        }
    }

    var alternatePrompt: String {
        switch self {
        case .signUp: "Already have an account?"
        case .signIn: "New here?"
        }
    }

    var alternateActionTitle: String {
        switch self {
        case .signUp: "Sign In"
        case .signIn: "Sign Up"
        }
    }

    var eyebrowTitle: String {
        switch self {
        case .signUp: "Create Your Account"
        case .signIn: "Welcome Back"
        }
    }
}

enum PermissionState: String {
    case notDetermined = "Ask"
    case granted = "On"
    case denied = "Off"

    var icon: String {
        switch self {
        case .notDetermined: "questionmark.circle.fill"
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        }
    }
}

enum UsernameAvailability: Equatable {
    case unchecked
    case checking
    case available(String, jokeSuggestion: String? = nil)
    case unavailable(String, suggestion: String?)
    case invalid(String)
    case failed(String)
}

enum ReactionKind: String, CaseIterable, Hashable, Identifiable, Codable {
    case cheers
    case spark
    case fire
    case dislike

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cheers: "heart.fill"
        case .spark: "sparkles"
        case .fire: "flame.fill"
        case .dislike: "hand.thumbsdown.fill"
        }
    }

    var title: String {
        switch self {
        case .cheers: "Like"
        case .spark: "Locked In"
        case .fire: "Heating Up"
        case .dislike: "Did not fw"
        }
    }
}

enum NotificationKind: String, Hashable {
    case friendPost
    case venuePulse
    case tagged
    case commentTagged
    case sharedMoment
    case comment
    case photoReply
    case reaction
    case commentLike
    case nearby
    case nightRecap
    case friendRequest
    case friendAccepted
    case profileVerified
    case announcement
    /// Sent to all members (except the creator) when they are added to a night group.
    case groupAdded

    var symbol: String {
        switch self {
        case .friendPost: "camera.fill"
        case .venuePulse: "mappin.and.ellipse"
        case .tagged: "person.crop.circle.badge.plus"
        case .commentTagged: "at.circle.fill"
        case .sharedMoment: "person.2.fill"
        case .comment: "ellipsis.message.fill"
        case .photoReply: "photo.on.rectangle.angled"
        case .reaction: "heart.fill"
        case .commentLike: "heart.text.square.fill"
        case .nearby: "location.fill"
        case .nightRecap: "photo.stack.fill"
        case .friendRequest: "person.badge.plus"
        case .friendAccepted: "checkmark.seal.fill"
        case .profileVerified: "checkmark.seal.fill"
        case .announcement: "megaphone.fill"
        case .groupAdded: "person.3.fill"
        }
    }

}

enum CameraCaptureMode: String {
    case back = "Back Camera"
    case front = "Front Camera"
    case ultraWide = "Ultra Wide"

    var systemImage: String {
        switch self {
        case .back: "camera.fill"
        case .front: "person.crop.square.fill"
        case .ultraWide: "camera.aperture"
        }
    }

    var toggled: CameraCaptureMode {
        switch self {
        case .back: .front
        case .front: .back
        case .ultraWide: .front
        }
    }

    /// Whether this mode uses the rear-facing side (ultrawide is also rear).
    var isRear: Bool {
        self == .back || self == .ultraWide
    }
}

struct AvatarStyle: Hashable, Codable {
    var symbol: String
    var primaryHex: String
    var secondaryHex: String
    var imageData: Data? = nil
    var remoteURL: URL? = nil
}

struct UserProfile: Identifiable, Hashable, Codable {
    let id: UUID
    var displayName: String
    var username: String
    var avatar: AvatarStyle
    var backgroundTheme: BackgroundTheme?
    var isCloseFriend: Bool
    var isVerified: Bool
    var isBanned: Bool

    init(
        id: UUID,
        displayName: String,
        username: String,
        avatar: AvatarStyle,
        backgroundTheme: BackgroundTheme? = nil,
        isCloseFriend: Bool,
        isVerified: Bool = false,
        isBanned: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.username = username
        self.avatar = avatar
        self.backgroundTheme = backgroundTheme
        self.isCloseFriend = isCloseFriend
        self.isVerified = isVerified
        self.isBanned = isBanned
    }

    var normalizedUsername: String {
        username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }

    static let placeholderCurrentUser = UserProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
        displayName: "You",
        username: "",
        avatar: AvatarStyle(
            symbol: "person.crop.circle.fill",
            primaryHex: "#D98B3D",
            secondaryHex: "#281916"
        ),
        isCloseFriend: true
    )
}

extension UserProfile {
    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case username
        case avatar
        case backgroundTheme
        case isCloseFriend
        case isVerified
        case isBanned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let username = try container.decode(String.self, forKey: .username)
        let avatar = try container.decode(AvatarStyle.self, forKey: .avatar)
        let backgroundTheme = try? container.decodeIfPresent(BackgroundTheme.self, forKey: .backgroundTheme)
        let isCloseFriend = try container.decode(Bool.self, forKey: .isCloseFriend)
        self.init(
            id: id,
            displayName: displayName,
            username: username,
            avatar: avatar,
            backgroundTheme: backgroundTheme ?? nil,
            isCloseFriend: isCloseFriend,
            isVerified: (try? container.decodeIfPresent(Bool.self, forKey: .isVerified)) ?? false,
            isBanned: (try? container.decodeIfPresent(Bool.self, forKey: .isBanned)) ?? false
        )
    }

    private static func normalizedUsername(_ username: String) -> String {
        username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }
}

struct DrinkTag: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var subtitle: String
    var symbol: String
    var primaryHex: String
    var secondaryHex: String
    /// When set, renders an asset-catalog image instead of the SF Symbol.
    /// Allows per-drink custom PNGs/JPEGs (beer photo, shot glass, etc.)
    /// without changing the symbol string used for backward-compat persistence.
    var imageName: String?
    /// When set, renders an emoji character instead of the SF Symbol or image.
    /// Takes precedence over imageName. Nil for custom user-added drinks,
    /// which fall back to the SF Symbol.
    var emoji: String?

    init(
        id: UUID,
        name: String,
        subtitle: String,
        symbol: String,
        imageName: String? = nil,
        emoji: String? = nil,
        primaryHex: String,
        secondaryHex: String
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.symbol = symbol
        self.imageName = imageName
        self.emoji = emoji
        self.primaryHex = primaryHex
        self.secondaryHex = secondaryHex
    }

    /// Resolves the asset-catalog image name for a drink based on its name.
    /// This is the single source of truth used by both the transport layer
    /// (when reconstructing drinks from backend records) and the custom drink
    /// creator — so any new asset mapping only needs to be added here.
    static func resolvedImageName(for name: String) -> String? {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "maddox" { return "DrinkMaddox" }
        if lower == "beer" { return "DrinkBeer" }
        if lower.hasSuffix("shot") { return "DrinkShotglass" }
        if lower.contains("everclear") || lower.contains("rumple") { return "DrinkShotglass" }
        return nil
    }

    /// Resolves an emoji for a drink by name. Checks exact catalog names first,
    /// then falls back to keyword matching so custom drinks like "Custom Water"
    /// or "Mango Energy Drink" resolve automatically without a picker.
    static func resolvedEmoji(for name: String) -> String? {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Exact matches for seed catalog drinks.
        switch lower {
        case "beer":                return "🍺"
        case "wine":                return "🍷"
        case "vodka cranberry":     return "🍹"
        case "seltzer":             return "🫧"
        case "margarita":           return "🍸"
        case "lemon drop shot":     return "🍋"
        case "espresso martini":    return "☕"
        case "drunk cig":           return "🚬"
        case "everclear shot":      return "⚡"
        case "rumple shot":         return "🌿"
        default:                    break
        }

        // Keyword rules evaluated in priority order — most specific first.
        // Each rule is a set of keywords that must ALL be present, paired
        // with the emoji to return when they match.
        let rules: [(keywords: [String], emoji: String)] = [
            // Specific cocktails / mixed drinks
            (["espresso", "martini"],           "☕"),
            (["lemon", "drop"],                 "🍋"),
            (["vodka", "cranberry"],            "🍹"),
            (["vodka", "soda"],                 "🫧"),
            (["vodka", "red bull"],             "⚡"),
            (["rum", "coke"],                   "🥤"),
            (["gin", "tonic"],                  "🍸"),
            (["moscow", "mule"],                "🍺"),
            (["whiskey", "sour"],               "🥃"),
            (["long island"],                   "🍹"),
            (["jungle juice"],                  "🍹"),
            (["hard lemonade"],                 "🍋"),
            (["hard seltzer"],                  "🫧"),
            (["white claw"],                    "🫧"),
            (["truly"],                         "🫧"),
            (["twisted tea"],                   "🍵"),
            (["four loko"],                     "⚡"),
            (["red bull"],                      "⚡"),
            (["monster"],                       "⚡"),
            (["celsius"],                       "⚡"),
            (["pre-workout"],                   "⚡"),
            (["pre workout"],                   "⚡"),
            (["energy"],                        "⚡"),
            (["mimosa"],                        "🥂"),
            (["champagne"],                     "🥂"),
            (["prosecco"],                      "🥂"),
            (["sangria"],                       "🍷"),
            (["rosé"],                          "🍷"),
            (["rose wine"],                     "🍷"),
            (["red wine"],                      "🍷"),
            (["white wine"],                    "🍷"),
            (["wine"],                          "🍷"),
            (["tequila", "shot"],               "🍋"),
            (["tequila"],                       "🍸"),
            (["mezcal"],                        "🍸"),
            (["margarita"],                     "🍸"),
            (["daiquiri"],                      "🍸"),
            (["cosmopolitan"],                  "🍸"),
            (["cosmo"],                         "🍸"),
            (["mojito"],                        "🍸"),
            (["pina colada"],                   "🍹"),
            (["piña colada"],                   "🍹"),
            (["mai tai"],                       "🍹"),
            (["tropical"],                      "🍹"),
            (["punch"],                         "🍹"),
            (["paloma"],                        "🍹"),
            (["aperol"],                        "🍊"),
            (["negroni"],                       "🍊"),
            (["old fashioned"],                 "🥃"),
            (["manhattan"],                     "🥃"),
            (["bourbon"],                       "🥃"),
            (["whiskey"],                       "🥃"),
            (["whisky"],                        "🥃"),
            (["scotch"],                        "🥃"),
            (["brandy"],                        "🥃"),
            (["cognac"],                        "🥃"),
            (["rum"],                           "🥃"),
            (["gin"],                           "🍸"),
            (["vodka"],                         "🍸"),
            (["shot"],                          "🥃"),
            (["beer"],                          "🍺"),
            (["lager"],                         "🍺"),
            (["ale"],                           "🍺"),
            (["ipa"],                           "🍺"),
            (["stout"],                         "🍺"),
            (["pilsner"],                       "🍺"),
            (["cider"],                         "🍺"),
            (["dos equis"],                     "🍺"),
            (["corona"],                        "🍺"),
            (["modelo"],                        "🍺"),
            (["heineken"],                      "🍺"),
            (["budweiser"],                     "🍺"),
            (["bud light"],                     "🍺"),
            (["miller"],                        "🍺"),
            (["coors"],                         "🍺"),
            (["stella"],                        "🍺"),
            (["guinness"],                      "🍺"),
            (["seltz"],                         "🫧"),
            (["sparkling"],                     "🫧"),
            (["kombucha"],                      "🫧"),
            // Non-alcoholic / misc
            (["coffee"],                        "☕"),
            (["espresso"],                      "☕"),
            (["latte"],                         "☕"),
            (["cappuccino"],                    "☕"),
            (["matcha"],                        "🍵"),
            (["tea"],                           "🍵"),
            (["boba"],                          "🧋"),
            (["bubble tea"],                    "🧋"),
            (["smoothie"],                      "🥤"),
            (["juice"],                         "🧃"),
            (["lemonade"],                      "🍋"),
            (["water"],                         "💧"),
            (["soda"],                          "🥤"),
            (["coke"],                          "🥤"),
            (["pepsi"],                         "🥤"),
            (["sprite"],                        "🥤"),
            (["gatorade"],                      "🥤"),
            (["powerade"],                      "🥤"),
            (["milk"],                          "🥛"),
            (["cig"],                           "🚬"),
            (["cigarette"],                     "🚬"),
            (["smoke"],                         "🚬"),
            // Cannabis
            (["edible"],                        "🍃"),
            (["weed"],                          "🍃"),
            (["cannabis"],                      "🍃"),
            (["marijuana"],                     "🍃"),
            (["joint"],                         "🍃"),
            (["blunt"],                         "🍃"),
            (["bong"],                          "🍃"),
            (["dab"],                           "🍃"),
            (["vape"],                          "🍃"),
            (["gummy"],                         "🍃"),
            (["thc"],                           "🍃"),
        ]

        for rule in rules {
            if rule.keywords.allSatisfy({ lower.contains($0) }) {
                return rule.emoji
            }
        }

        return nil
    }
}

struct Venue: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var neighborhood: String
    var city: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct LocationSnapshot: Hashable, Codable {
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var capturedAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        horizontalAccuracy = max(location.horizontalAccuracy, 0)
        capturedAt = location.timestamp
    }

    init(latitude: Double, longitude: Double, horizontalAccuracy: Double, capturedAt: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.capturedAt = capturedAt
    }
}

struct Comment: Identifiable, Hashable, Codable {
    let id: UUID
    var author: UserProfile
    var text: String
    var createdAt: Date
    var kind: CommentKind = .text
    var photoData: Data? = nil
    var remotePhotoURL: URL? = nil
    var likeCount: Int = 0
    var isLikedByViewer: Bool = false
    var replyToCommentID: UUID? = nil
    var replyToDisplayName: String? = nil

    var hasPhotoAttachment: Bool {
        photoData != nil || remotePhotoURL != nil
    }
}

enum CommentKind: String, Hashable, Codable {
    case text
    case photo
    case gif
}

struct ReactionSummary: Hashable, Codable {
    var kind: ReactionKind
    var count: Int
    /// Profiles of the people who reacted with this kind. Kept alongside
    /// `count` rather than replacing it because the count is occasionally
    /// authoritative from a different source (e.g. an optimistic bump
    /// before the server confirms, or a cached aggregate in a feed that
    /// hasn't re-fetched reactors). When the list is empty, consumers
    /// should fall back to displaying `count` alone — the long-press
    /// reactor sheet simply won't open.
    var reactors: [UserProfile] = []
}

struct EmailPasswordAuthDraft: Hashable {
    var mode: AuthEntryMode = .signUp
    var identifier: String = ""
    var password: String = ""
    var isSubmitting = false
}

struct OutboundNotificationDelivery: Identifiable, Hashable {
    let id: UUID
    var recipient: UserProfile
    var kind: NotificationKind
    var title: String
    var detail: String
    var createdAt: Date
}

struct MomentMedia: Hashable, Codable {
    var photoData: Data?
    var remotePhotoURL: URL? = nil
    var primaryHex: String
    var secondaryHex: String
    var symbol: String
    /// Width ÷ height of the photo. Seeded at post creation from local pixel
    /// data and preserved through every refresh so MomentMediaView can size
    /// the placeholder correctly before AsyncImage has loaded anything.
    /// nil = no photo, or ratio not yet known (legacy posts).
    var photoAspectRatio: CGFloat? = nil
}

struct MomentPost: Identifiable, Hashable, Codable {
    let id: UUID
    var author: UserProfile
    var drink: DrinkTag?
    var venue: Venue?
    var location: LocationSnapshot? = nil
    var caption: String
    var createdAt: Date
    var taggedFriends: [UserProfile]
    var isSharedMoment: Bool
    var media: MomentMedia
    var reactions: [ReactionSummary]
    var viewerReactionKinds: Set<ReactionKind> = []
    var comments: [Comment]
    /// Exact server-side count for the thread. `comments` may be only a preview
    /// subset in feed contexts to keep bootstrap payloads small.
    var commentCount: Int
    /// Becomes true once the full thread has been loaded explicitly.
    var hasLoadedFullCommentThread: Bool = false
    /// Reaction kinds whose reactor lists have been fully hydrated.
    var fullyLoadedReactionKinds: Set<ReactionKind> = []
    var presenceNote: String?
    var connectionPath: String?
    var contextReason: String?
    /// Optional so caches written before Local remain decodable.
    var isSharedLocally: Bool? = nil

    var resolvedCoordinate: CLLocationCoordinate2D? {
        location?.coordinate ?? venue?.coordinate
    }

    func distance(from viewerLocation: CLLocation?) -> CLLocationDistance? {
        guard let viewerLocation, let resolvedCoordinate else { return nil }
        let postLocation = CLLocation(
            latitude: resolvedCoordinate.latitude,
            longitude: resolvedCoordinate.longitude
        )
        return viewerLocation.distance(from: postLocation)
    }
}

struct AppNotification: Identifiable, Hashable {
    let id: UUID
    var kind: NotificationKind
    var title: String
    var detail: String
    var createdAt: Date
    var isRead: Bool
    var actor: UserProfile? = nil
    var postID: UUID? = nil
    var commentID: UUID? = nil
    var nightStart: Date? = nil
    var nightEnd: Date? = nil
    var nightGroupID: UUID? = nil

    var headline: String { headline(at: .now) }

    func headline(at date: Date) -> String {
        if kind == .nightRecap {
            return NotificationDates.recapTitle(start: nightStart, end: nightEnd, now: date)
        }
        return NotificationCopy.headline(kind: kind.rawValue, title: title)
    }
}

struct VenueActivity: Identifiable, Hashable {
    var venue: Venue
    var posts: [MomentPost]

    var id: UUID { venue.id }

    var activeFriends: [UserProfile] {
        var seen = Set<UUID>()
        return posts.compactMap { post in
            guard seen.insert(post.author.id).inserted else { return nil }
            return post.author
        }
    }
}

struct PresenceCluster: Identifiable, Hashable {
    let id: UUID
    var anchor: UserProfile
    var friends: [UserProfile]
    var venue: Venue?
    var updatedAt: Date
    var connectionPath: String?
    var contextReason: String?
    var relatedPostIDs: [UUID]

    var title: String {
        if friends.count <= 1 {
            return anchor.displayName
        }

        let others = max(friends.count - 1, 0)
        return others == 1 ? "\(anchor.displayName) + 1" : "\(anchor.displayName) + \(others)"
    }

    var subtitle: String {
        if let venue {
            return venue.name
        }

        return "Active now"
    }
}

struct PresenceSignal: Identifiable, Hashable {
    let id: UUID
    var user: UserProfile
    var createdAt: Date
}

struct WeeklyRecap: Hashable {
    var momentsPosted: Int
    var commonVenue: Venue?
    var nightsActive: Int
    var totalInteractions: Int
}

struct FriendRequest: Identifiable, Hashable {
    enum Direction: Hashable {
        case incoming
        case outgoing
    }

    let id: UUID
    var counterpart: UserProfile
    var direction: Direction
    var createdAt: Date
}

struct AppAnnouncement: Identifiable, Hashable {
    let id: UUID
    var title: String
    var message: String
    var imageUrl: URL?
    var createdAt: Date
}

enum AppAnnouncementAudience: String, CaseIterable, Identifiable, Hashable {
    case all
    case verified
    case selected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .verified: "Verified"
        case .selected: "Selected"
        }
    }

    var adminSummary: String {
        switch self {
        case .all: "All users"
        case .verified: "Verified users"
        case .selected: "Selected users"
        }
    }
}

enum AppAnnouncementDelivery: String, CaseIterable, Identifiable, Hashable {
    case inApp = "in_app"
    case push
    case both

    var id: String { rawValue }
    var includesPush: Bool { self != .inApp }
    var includesInApp: Bool { self != .push }

    var title: String {
        switch self {
        case .inApp: "In-App"
        case .push: "Push"
        case .both: "Both"
        }
    }

    var explanation: String {
        switch self {
        case .inApp: "Shows a pop-up when users open Out Again."
        case .push: "Sends to phones with notifications and Announcements enabled."
        case .both: "Shows an in-app pop-up and sends a push to phones with Announcements enabled."
        }
    }
}

struct AdminAppAnnouncement: Identifiable, Hashable {
    let id: UUID
    var title: String
    var message: String
    var audience: AppAnnouncementAudience
    var targetUsernames: [String]
    var recipientCount: Int
    var isActive: Bool
    var createdAt: Date
    var delivery: AppAnnouncementDelivery = .inApp
    var pushRecipientCount: Int = 0
    var pushAcceptedCount: Int = 0
    var pushFailureCount: Int = 0
    var pushSkippedCount: Int = 0
    var pushPendingCount: Int = 0

    var audienceDescription: String {
        switch audience {
        case .all:
            return "All users"
        case .verified:
            return "Verified users"
        case .selected:
            guard !targetUsernames.isEmpty else { return "Selected users" }
            return targetUsernames.map { "@\($0)" }.joined(separator: ", ")
        }
    }
}

struct SocialBootstrap: Hashable {
    var viewer: UserProfile?
    var drinkCatalogPreferences = DrinkCatalogPreferences()
    var friends: [UserProfile]
    var suggestedFriends: [UserProfile]
    var homeFeedHasMore = false
    var friendOfFriendIDs: Set<UUID> = []
    /// Mutual friend count for each FoF candidate, keyed by their user ID.
    /// Used to display "1 mutual", "2 mutuals", etc. in the suggested friends UI.
    var mutualCounts: [UUID: Int] = [:]
    var incomingRequests: [FriendRequest] = []
    var outgoingRequests: [FriendRequest] = []
    var blockedUserIDs: Set<UUID> = []
    var blockedUsers: [UserProfile] = []
    var posts: [MomentPost]
    var tonightActivityPosts: [MomentPost] = []
    var nightSummaryPosts: [MomentPost] = []
    var tonightActivitySnapshotIsAuthoritative = false
    var nightSummarySnapshotIsAuthoritative = false
    var nightSummaryGroups: [NightGroup] = []
    var notifications: [AppNotification]
    var appAnnouncements: [AppAnnouncement] = []
    var appConfig: [String: String] = [:]
}

struct DrinkCatalogPreferences: Codable, Hashable {
    var customDrinks: [DrinkTag] = []
    var deletedDrinkNames: [String] = []
    var orderedDrinkNames: [String] = []

    var isEmpty: Bool {
        customDrinks.isEmpty && deletedDrinkNames.isEmpty && orderedDrinkNames.isEmpty
    }
}

struct ProfileEditorDraft: Hashable {
    var displayName: String = ""
    var username: String = ""
    var profileImageData: Data? = nil

    init() {}

    init(profile: UserProfile) {
        displayName = profile.displayName
        username = profile.username
        profileImageData = profile.avatar.imageData
    }
}

struct OnboardingDraft {
    var displayName: String = ""
    var username: String = ""
    var profileImageData: Data? = nil
    var inviteLink: String = ""
}

/// A lightweight, ephemeral group scoped to a single night.
/// Groups are backed by a Supabase `night_groups` table and visible to all
/// members via RLS policy: any user whose ID appears in `member_ids` can read
/// the row, only the creator can mutate it. Auto-expire on client: groups whose
/// `createdAt` falls outside the current tonight window are discarded on load
/// so the strip never surfaces stale groups from prior evenings.
struct NightGroup: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String        // optional; empty string means use "Group" fallback
    var creatorID: UUID     // the member who created the group; drives delete permission
    var memberIDs: [UUID]   // ordered: creator first, then added members
    var createdAt: Date

    /// Resolved display label: user-supplied name or the generic fallback.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Group" : trimmed
    }
}

struct PostDraft {
    var id = UUID()
    var shareLocally = false
    static let captionCharacterLimit = 120

    var capturedPhotoData: Data? = nil
    /// The currently selected drink for this post.
    /// Stored as an array for compatibility with older draft code, but the
    /// composer now keeps at most one selected drink ID at a time.
    var selectedDrinkIDs: [UUID] = []
    var selectedVenueID: UUID? = nil
    var location: LocationSnapshot? = nil
    var caption: String = ""
    var taggedFriendIDs: Set<UUID> = []
    var isSharedMoment: Bool = false
    var sampleSymbol: String = "camera.aperture"
    var lensMode: CameraCaptureMode = .back
    var isUsingSampleCapture: Bool = false

    static func limitedCaption(_ caption: String) -> String {
        String(caption.prefix(captionCharacterLimit))
    }
}
