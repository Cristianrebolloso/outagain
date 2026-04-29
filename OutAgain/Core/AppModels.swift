import Foundation
import CoreLocation
import SwiftUI

enum AccentColorChoice: String, CaseIterable, Identifiable {
    case purple = "purple"
    case blue   = "blue"
    case pink   = "pink"
    case green  = "green"
    case white  = "white"
    case gold   = "gold"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .purple: return "Party Purple"
        case .blue:   return "Liberal Blue"
        case .pink:   return "Racist Pink"
        case .green:  return "Gay Green"
        case .white:  return "Normal White"
        case .gold:   return "Beer"
        }
    }

    var color: Color {
        switch self {
        case .purple: return Color(hex: "#A855F7")
        case .blue:   return Color(hex: "#3B82F6")
        case .pink:   return Color(hex: "#EC4899")
        case .green:  return Color(hex: "#22C55E")
        case .white:  return Color.white
        case .gold:   return Color(hex: "#F5C451")
        }
    }

    var swatch: Color { color }
}

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case friends
    case activity
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .friends: "Friends"
        case .activity: "Activity"
        case .profile: "Profile"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .friends: "person.2.fill"
        case .activity: "bell.badge.fill"
        case .profile: "person.crop.circle.fill"
        }
    }
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
    case friendsOfFriends

    var id: String { rawValue }

    var title: String {
        switch self {
        case .friends: "Friends"
        case .friendsOfFriends: "Friends of Friends"
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

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cheers: "heart.fill"
        case .spark: "sparkles"
        case .fire: "flame.fill"
        }
    }

    var title: String {
        switch self {
        case .cheers: "Like"
        case .spark: "Locked In"
        case .fire: "Heating Up"
        }
    }
}

enum NotificationKind: String, Hashable {
    case friendPost
    case venuePulse
    case tagged
    case sharedMoment
    case comment
    case photoReply
    case reaction
    case nearby
    case friendRequest
    case friendAccepted
    /// Sent to all members (except the creator) when they are added to a night group.
    case groupAdded

    var symbol: String {
        switch self {
        case .friendPost: "camera.fill"
        case .venuePulse: "mappin.and.ellipse"
        case .tagged: "person.crop.circle.badge.plus"
        case .sharedMoment: "person.2.fill"
        case .comment: "ellipsis.message.fill"
        case .photoReply: "photo.on.rectangle.angled"
        case .reaction: "heart.fill"
        case .nearby: "location.fill"
        case .friendRequest: "person.badge.plus"
        case .friendAccepted: "checkmark.seal.fill"
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
    var isCloseFriend: Bool

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

    init(
        id: UUID,
        name: String,
        subtitle: String,
        symbol: String,
        imageName: String? = nil,
        primaryHex: String,
        secondaryHex: String
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.symbol = symbol
        self.imageName = imageName
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
    var email: String = ""
    var password: String = ""
    var isSubmitting = false
}

struct ContactLookupSeed: Hashable {
    var displayName: String
    var emailHashes: [String] = []
    var phoneHashes: [String] = []
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
    var drink: DrinkTag
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
    var favoriteDrink: DrinkTag
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

struct SocialBootstrap: Hashable {
    var viewer: UserProfile?
    var drinkCatalogPreferences = DrinkCatalogPreferences()
    var friends: [UserProfile]
    var suggestedFriends: [UserProfile]
    var friendOfFriendIDs: Set<UUID> = []
    var incomingRequests: [FriendRequest] = []
    var outgoingRequests: [FriendRequest] = []
    var blockedUserIDs: Set<UUID> = []
    var blockedUsers: [UserProfile] = []
    var posts: [MomentPost]
    var notifications: [AppNotification]
}

struct NotificationPreferences: Codable, Hashable {
    // Kept to 1:1 the kinds the backend actually emits:
    //   friendRequests  -> notify_on_friend_request   (incl. accepts)
    //   friendPosts     -> notify_on_post             (fan-out to friends)
    //   commentsAndReplies -> comment trigger on posts
    //   likesAndReactions  -> reaction trigger on posts
    // No `nearbyActivity` toggle until a server-side nearby trigger exists —
    // exposing a toggle that controls nothing is worse than hiding the lever.
    var friendRequests = true
    var friendPosts = true
    var commentsAndReplies = true
    var likesAndReactions = true

    enum CodingKeys: String, CodingKey {
        case friendRequests
        case friendPosts = "friendMoments" // preserve existing UserDefaults key
        case commentsAndReplies
        case likesAndReactions
    }
}

struct DrinkCatalogPreferences: Codable, Hashable {
    var customDrinks: [DrinkTag] = []
    var deletedDrinkNames: [String] = []
    var orderedDrinkNames: [String] = []

    var isEmpty: Bool {
        customDrinks.isEmpty && deletedDrinkNames.isEmpty && orderedDrinkNames.isEmpty
    }
}

struct LiveActivityPreferences: Codable, Hashable {
    var isEnabled = false
    var lastPromptedDayKey: String?
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
    var capturedPhotoData: Data? = nil
    /// All drinks the viewer has selected for this post, in selection order.
    /// The first element is the "primary" drink used for post metadata and
    /// background color; additional drinks are displayed as co-selected pills.
    var selectedDrinkIDs: [UUID] = []
    var selectedVenueID: UUID? = nil
    var location: LocationSnapshot? = nil
    var caption: String = ""
    var taggedFriendIDs: Set<UUID> = []
    var isSharedMoment: Bool = false
    var sampleSymbol: String = "camera.aperture"
    var lensMode: CameraCaptureMode = .back
    var isUsingSampleCapture: Bool = false
}
