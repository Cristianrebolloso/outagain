import Foundation

/// Runtime starter catalog for a brand-new real account.
///
/// This file intentionally contains only neutral seed metadata the app needs
/// before the backend has any personalized history: drink options and venues.
/// Fake people, posts, notifications, and activity fixtures do not belong in
/// the runtime path anymore.
enum SeedCatalog {
    /// Default drink catalog, tuned to what the target demographic actually
    /// orders. Order matters because this is the first row a brand-new user
    /// sees before their own history re-sorts the composer.
    static let drinks: [DrinkTag] = [
        DrinkTag(id: UUID(), name: "Beer",             subtitle: "Lager, IPA, whatever's cold",  symbol: "waterbottle.fill",          imageName: "DrinkBeer",       primaryHex: "#D9A441", secondaryHex: "#2A1A12"),
        DrinkTag(id: UUID(), name: "Wine",             subtitle: "Red, white, rosé",              symbol: "wineglass.fill",            primaryHex: "#964A59", secondaryHex: "#231518"),
        DrinkTag(id: UUID(), name: "Vodka Cranberry",  subtitle: "Classic",                       symbol: "drop.fill",                 primaryHex: "#C0365A", secondaryHex: "#2A0D14"),
        DrinkTag(id: UUID(), name: "Seltzer",          subtitle: "White Claw, Truly, any",        symbol: "bubbles.and.sparkles.fill", primaryHex: "#7FB3C7", secondaryHex: "#17202A"),
        DrinkTag(id: UUID(), name: "Margarita",        subtitle: "Salt, no salt, up to you",      symbol: "sparkles",                  primaryHex: "#B7D06B", secondaryHex: "#1F2817"),
        DrinkTag(id: UUID(), name: "Espresso Martini", subtitle: "Second wind",                   symbol: "moon.stars.fill",           primaryHex: "#8C5A3C", secondaryHex: "#2A1815"),
        DrinkTag(id: UUID(), name: "Whiskey",          subtitle: "Neat or on the rocks",          symbol: "flame.fill",                primaryHex: "#B07A3A", secondaryHex: "#241610"),
        DrinkTag(id: UUID(), name: "Everclear Shot",   subtitle: "Godspeed",                      symbol: "bolt.fill",                 imageName: "DrinkShotglass",  primaryHex: "#C8D6E5", secondaryHex: "#1B2430"),
        DrinkTag(id: UUID(), name: "Rumple Shot",      subtitle: "Peppermint schnapps",           symbol: "snowflake",                 imageName: "DrinkShotglass",  primaryHex: "#5BA89E", secondaryHex: "#0F2220"),
    ]

    static let venues: [Venue] = [
        Venue(id: UUID(), name: "Sparrow", neighborhood: "River North", city: "Chicago", latitude: 41.8929, longitude: -87.6315),
        Venue(id: UUID(), name: "Juniper Room", neighborhood: "West Loop", city: "Chicago", latitude: 41.8856, longitude: -87.6482),
        Venue(id: UUID(), name: "Low Light", neighborhood: "Fulton Market", city: "Chicago", latitude: 41.8869, longitude: -87.6497),
        Venue(id: UUID(), name: "Cinder Club", neighborhood: "Wicker Park", city: "Chicago", latitude: 41.9085, longitude: -87.6791)
    ]
}
