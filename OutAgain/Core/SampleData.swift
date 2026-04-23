import Foundation

enum SampleData {
    static let seedViewer = UserProfile(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
        displayName: "Cristian",
        username: "afterhours",
        avatar: AvatarStyle(
            symbol: "moon.stars.fill",
            primaryHex: "#D98B3D",
            secondaryHex: "#3D241A"
        ),
        isCloseFriend: true
    )

    static let friends: [UserProfile] = [
        UserProfile(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
            displayName: "Mila",
            username: "milasips",
            avatar: AvatarStyle(symbol: "sparkles", primaryHex: "#F2A65A", secondaryHex: "#1B1412"),
            isCloseFriend: true
        ),
        UserProfile(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID(),
            displayName: "Jordan",
            username: "jordannight",
            avatar: AvatarStyle(symbol: "bolt.fill", primaryHex: "#C96B30", secondaryHex: "#251514"),
            isCloseFriend: true
        ),
        UserProfile(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444") ?? UUID(),
            displayName: "Ava",
            username: "avaafterdark",
            avatar: AvatarStyle(symbol: "star.fill", primaryHex: "#C27B47", secondaryHex: "#241717"),
            isCloseFriend: false
        ),
        UserProfile(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555") ?? UUID(),
            displayName: "Leo",
            username: "lowlightleo",
            avatar: AvatarStyle(symbol: "location.fill", primaryHex: "#B46A3A", secondaryHex: "#1B1313"),
            isCloseFriend: false
        )
    ]

    static let suggestedFriends: [UserProfile] = [
        UserProfile(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666") ?? UUID(),
            displayName: "Nina",
            username: "ninanearby",
            avatar: AvatarStyle(symbol: "heart.fill", primaryHex: "#D7915A", secondaryHex: "#201616"),
            isCloseFriend: false
        ),
        UserProfile(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777") ?? UUID(),
            displayName: "Theo",
            username: "theodowntown",
            avatar: AvatarStyle(symbol: "waveform.path.ecg", primaryHex: "#E5A86A", secondaryHex: "#231919"),
            isCloseFriend: false
        )
    ]

    static let drinks: [DrinkTag] = [
        DrinkTag(id: UUID(), name: "Mezcal Paloma", subtitle: "Bright + smoky", symbol: "sparkles", primaryHex: "#D98B3D", secondaryHex: "#43261B"),
        DrinkTag(id: UUID(), name: "Espresso Martini", subtitle: "Late-night classic", symbol: "moon.stars.fill", primaryHex: "#8C5A3C", secondaryHex: "#2A1815"),
        DrinkTag(id: UUID(), name: "Natural Wine", subtitle: "Easy pour", symbol: "wineglass.fill", primaryHex: "#964A59", secondaryHex: "#231518"),
        DrinkTag(id: UUID(), name: "Negroni", subtitle: "Bitter + polished", symbol: "flame.fill", primaryHex: "#B85431", secondaryHex: "#2B1717"),
        DrinkTag(id: UUID(), name: "Japanese Highball", subtitle: "Cold + clean", symbol: "drop.fill", primaryHex: "#DAA15A", secondaryHex: "#2A1C15"),
        DrinkTag(id: UUID(), name: "Beer", subtitle: "Easy first pick", symbol: "mug.fill", primaryHex: "#D9A441", secondaryHex: "#2A1A12")
    ]

    static let venues: [Venue] = [
        Venue(id: UUID(), name: "Sparrow", neighborhood: "River North", city: "Chicago", latitude: 41.8929, longitude: -87.6315),
        Venue(id: UUID(), name: "Juniper Room", neighborhood: "West Loop", city: "Chicago", latitude: 41.8856, longitude: -87.6482),
        Venue(id: UUID(), name: "Low Light", neighborhood: "Fulton Market", city: "Chicago", latitude: 41.8869, longitude: -87.6497),
        Venue(id: UUID(), name: "Cinder Club", neighborhood: "Wicker Park", city: "Chicago", latitude: 41.9085, longitude: -87.6791)
    ]

    static var posts: [MomentPost] {
        let mila = friends[0]
        let jordan = friends[1]
        let ava = friends[2]
        let leo = friends[3]
        let nina = suggestedFriends[0]
        let theo = suggestedFriends[1]

        return [
            MomentPost(
                id: UUID(),
                author: mila,
                drink: drinks[0],
                venue: venues[0],
                caption: "Warm booth, low lights, and the room just tipped from casual into worth joining.",
                createdAt: .now.addingTimeInterval(-18 * 60),
                taggedFriends: [ava],
                isSharedMoment: true,
                media: MomentMedia(photoData: nil, primaryHex: "#281713", secondaryHex: "#B86831", symbol: "sun.max.fill"),
                reactions: [
                    ReactionSummary(kind: .cheers, count: 18),
                    ReactionSummary(kind: .spark, count: 9)
                ],
                comments: [
                    Comment(id: UUID(), author: jordan, text: "Pulling up in ten.", createdAt: .now.addingTimeInterval(-12 * 60), likeCount: 3),
                    Comment(id: UUID(), author: ava, text: "Photo reply", createdAt: .now.addingTimeInterval(-8 * 60), kind: .photo, likeCount: 1, replyToDisplayName: "Jordan")
                ],
                presenceNote: "Mila and Ava are together right now",
                connectionPath: nil,
                contextReason: "Close friends together"
            ),
            MomentPost(
                id: UUID(),
                author: nina,
                drink: drinks[3],
                venue: venues[0],
                caption: "Met Mila’s crew downstairs and the energy is climbing fast.",
                createdAt: .now.addingTimeInterval(-11 * 60),
                taggedFriends: [mila, theo],
                isSharedMoment: true,
                media: MomentMedia(photoData: nil, primaryHex: "#1B1112", secondaryHex: "#A25536", symbol: "sparkles"),
                reactions: [
                    ReactionSummary(kind: .spark, count: 6),
                    ReactionSummary(kind: .cheers, count: 4)
                ],
                comments: [
                    Comment(id: UUID(), author: mila, text: "This is the room.", createdAt: .now.addingTimeInterval(-7 * 60), likeCount: 2)
                ],
                presenceNote: "Friends-of-friends are anchored through Mila right now",
                connectionPath: "Via Mila + Jordan",
                contextReason: "Same venue now"
            ),
            MomentPost(
                id: UUID(),
                author: jordan,
                drink: drinks[1],
                venue: venues[1],
                caption: "One martini, one fast room check, still deciding if this becomes the spot.",
                createdAt: .now.addingTimeInterval(-46 * 60),
                taggedFriends: [leo],
                isSharedMoment: false,
                media: MomentMedia(photoData: nil, primaryHex: "#1C1412", secondaryHex: "#8D5E43", symbol: "moon.zzz.fill"),
                reactions: [
                    ReactionSummary(kind: .fire, count: 11),
                    ReactionSummary(kind: .cheers, count: 7)
                ],
                comments: [
                    Comment(id: UUID(), author: leo, text: "Packed but still moving.", createdAt: .now.addingTimeInterval(-34 * 60), likeCount: 1)
                ],
                presenceNote: "Jordan and Leo are nearby",
                connectionPath: nil,
                contextReason: "Close friend pulse"
            ),
            MomentPost(
                id: UUID(),
                author: ava,
                drink: drinks[2],
                venue: venues[2],
                caption: "Soft lights, loud booth, zero plans besides staying out.",
                createdAt: .now.addingTimeInterval(-2.5 * 60 * 60),
                taggedFriends: [leo],
                isSharedMoment: true,
                media: MomentMedia(photoData: nil, primaryHex: "#241518", secondaryHex: "#8C5061", symbol: "star.circle.fill"),
                reactions: [
                    ReactionSummary(kind: .spark, count: 14),
                    ReactionSummary(kind: .cheers, count: 5)
                ],
                comments: [],
                presenceNote: "Leo reposted this moment",
                connectionPath: nil,
                contextReason: "Earlier tonight"
            )
        ]
    }

    static var presenceSignals: [PresenceSignal] {
        let jordan = friends[1]
        let leo = friends[3]
        let theo = suggestedFriends[1]

        return [
            PresenceSignal(
                id: UUID(),
                user: jordan,
                createdAt: .now.addingTimeInterval(-5 * 60)
            ),
            PresenceSignal(
                id: UUID(),
                user: leo,
                createdAt: .now.addingTimeInterval(-14 * 60)
            ),
            PresenceSignal(
                id: UUID(),
                user: theo,
                createdAt: .now.addingTimeInterval(-9 * 60)
            )
        ]
    }

    static var notifications: [AppNotification] {
        [
            AppNotification(
                id: UUID(),
                kind: .venuePulse,
                title: "Mila just posted at Sparrow",
                detail: "This is the core coordination signal: close friend, live venue, worth checking.",
                createdAt: .now.addingTimeInterval(-10 * 60),
                isRead: false
            ),
            AppNotification(
                id: UUID(),
                kind: .photoReply,
                title: "Ava photo replied to Mila’s moment",
                detail: "Replies stay tied to the feed so the night keeps moving in one place.",
                createdAt: .now.addingTimeInterval(-8 * 60),
                isRead: false
            ),
            AppNotification(
                id: UUID(),
                kind: .friendPost,
                title: "Jordan just posted at Juniper Room",
                detail: "Close-friend post signals outrank reactions and passive activity.",
                createdAt: .now.addingTimeInterval(-36 * 60),
                isRead: true
            ),
            AppNotification(
                id: UUID(),
                kind: .reaction,
                title: "Low-signal reactions bundled",
                detail: "Ava and 4 others reacted to your last moment.",
                createdAt: .now.addingTimeInterval(-2.5 * 60 * 60),
                isRead: true
            )
        ]
    }
}
