import Foundation
import CoreLocation

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .profile: "Profile"
        }
    }

    var symbol: String {
        switch self {
        case .home: "sparkles.tv"
        case .profile: "person.crop.circle"
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

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case profile
    case permissions
    case invite
    case done
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

enum ReactionKind: String, CaseIterable, Hashable {
    case cheers
    case spark
    case fire

    var symbol: String {
        switch self {
        case .cheers: "hands.clap.fill"
        case .spark: "sparkles"
        case .fire: "flame.fill"
        }
    }

    var title: String {
        switch self {
        case .cheers: "Cheers"
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

    var symbol: String {
        switch self {
        case .friendPost: "camera.fill"
        case .venuePulse: "mappin.and.ellipse"
        case .tagged: "person.crop.circle.badge.plus"
        case .sharedMoment: "person.2.fill"
        case .comment: "ellipsis.message.fill"
        case .photoReply: "photo.on.rectangle.angled"
        case .reaction: "hands.clap.fill"
        case .nearby: "location.fill"
        }
    }
}

enum CameraCaptureMode: String {
    case single = "Single Lens"
    case dualReady = "Dual Ready"
}

struct AvatarStyle: Hashable {
    var symbol: String
    var primaryHex: String
    var secondaryHex: String
    var imageData: Data? = nil
}

struct UserProfile: Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var username: String
    var avatar: AvatarStyle
    var isCloseFriend: Bool
}

struct DrinkTag: Identifiable, Hashable {
    let id: UUID
    var name: String
    var subtitle: String
    var symbol: String
    var primaryHex: String
    var secondaryHex: String
}

struct Venue: Identifiable, Hashable {
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

struct Comment: Identifiable, Hashable {
    let id: UUID
    var author: UserProfile
    var text: String
    var createdAt: Date
    var kind: CommentKind = .text
    var likeCount: Int = 0
    var isLikedByViewer: Bool = false
    var replyToCommentID: UUID? = nil
    var replyToDisplayName: String? = nil
}

enum CommentKind: Hashable {
    case text
    case photo
    case gif
}

struct ReactionSummary: Hashable {
    var kind: ReactionKind
    var count: Int
}

struct MomentMedia: Hashable {
    var photoData: Data?
    var primaryHex: String
    var secondaryHex: String
    var symbol: String
}

struct MomentPost: Identifiable, Hashable {
    let id: UUID
    var author: UserProfile
    var drink: DrinkTag
    var venue: Venue?
    var caption: String
    var createdAt: Date
    var taggedFriends: [UserProfile]
    var isSharedMoment: Bool
    var media: MomentMedia
    var reactions: [ReactionSummary]
    var comments: [Comment]
    var presenceNote: String?
    var connectionPath: String?
    var contextReason: String?
}

struct AppNotification: Identifiable, Hashable {
    let id: UUID
    var kind: NotificationKind
    var title: String
    var detail: String
    var createdAt: Date
    var isRead: Bool
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

struct OnboardingDraft {
    var displayName: String = "Cristian"
    var username: String = "afterhours"
    var profileImageData: Data? = nil
    var inviteLink: String = ""
}

struct PostDraft {
    var capturedPhotoData: Data? = nil
    var selectedDrinkID: UUID? = nil
    var selectedVenueID: UUID? = nil
    var caption: String = ""
    var taggedFriendIDs: Set<UUID> = []
    var isSharedMoment: Bool = false
    var sampleSymbol: String = "camera.aperture"
    var lensMode: CameraCaptureMode = .single
    var isUsingSampleCapture: Bool = false
}
