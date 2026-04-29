import SwiftUI

extension AppStore {
    /// Legacy shared key kept only for one-time migration into the new
    /// per-viewer storage namespace.
    private static let legacyCustomDrinksDefaultsKey = "OutAgain.CustomDrinks.v1"
    private static let legacyCustomDrinksDefaultsKeyPrefix = "OutAgain.CustomDrinks.v2."
    private static let legacyDrinkOrderKeyPrefix = "OutAgain.DrinkOrder.v1."
    private static let drinkCatalogDefaultsKeyPrefix = "OutAgain.DrinkCatalog.v1."
    private static let dirtyDrinkCatalogDefaultsKeyPrefix = "OutAgain.DrinkCatalogDirty.v1."
    /// UserDefaults key for the viewer's manually set profile favorite drink.
    static let profileFavoriteDrinkKey = "OutAgain.ProfileFavoriteDrink.v1"

    /// The viewer's self-declared favorite drink name, shown on their profile
    /// stats card. nil = not set yet; the UI shows a "Tap to add" prompt.
    var profileFavoriteDrinkName: String? {
        UserDefaults.standard.string(forKey: Self.profileFavoriteDrinkKey)
    }

    func setProfileFavoriteDrink(_ name: String?) {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            UserDefaults.standard.set(name, forKey: Self.profileFavoriteDrinkKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.profileFavoriteDrinkKey)
        }
    }

    /// The 8 drinks shown in the composer pill row, ranked by recency of
    /// actual use. Derives order from the viewer's post history so the drinks
    /// they reach for most often surface first. Falls back to the manual
    /// catalog order for drinks with no post history (new users, or drinks
    /// they added but haven't posted with yet).
    var composerDrinks: [DrinkTag] {
        var seen: Set<String> = []
        var recentlyUsed: [DrinkTag] = []

        for post in viewerPosts {
            let key = Self.normalizedDrinkName(post.drink.name)
            guard seen.insert(key).inserted else { continue }
            guard let catalogEntry = drinks.first(where: {
                Self.normalizedDrinkName($0.name) == key
            }) else { continue }
            recentlyUsed.append(catalogEntry)
            if recentlyUsed.count == 8 { break }
        }

        if recentlyUsed.count < 8 {
            let usedKeys = Set(recentlyUsed.map { Self.normalizedDrinkName($0.name) })
            let remaining = drinks.filter { !usedKeys.contains(Self.normalizedDrinkName($0.name)) }
            recentlyUsed.append(contentsOf: remaining.prefix(8 - recentlyUsed.count))
        }

        return recentlyUsed
    }

    /// Resolves the viewer's latest posted drink against the active catalog.
    /// If that drink has been removed, we intentionally treat the user as
    /// having no "repeat last" drink instead of resurfacing stale history.
    var latestPostedDrinkFromCatalog: DrinkTag? {
        guard let lastPostDrink = viewerPosts.first?.drink else { return nil }
        return drinks.first {
            Self.normalizedDrinkName($0.name) == Self.normalizedDrinkName(lastPostDrink.name)
        }
    }

    @discardableResult
    func addCustomDrink(named rawName: String) -> DrinkTag? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = Self.normalizedDrinkName(trimmed)
        guard !normalizedName.isEmpty else { return nil }

        var preferences = normalizedDrinkCatalogPreferences(drinkCatalogPreferences)
        preferences.deletedDrinkNames.removeAll { $0 == normalizedName }

        if let visible = drinks.first(where: { Self.normalizedDrinkName($0.name) == normalizedName }) {
            commitDrinkCatalogPreferences(preferences)
            selectDrink(visible)
            return visible
        }

        if let restoredSeed = SeedCatalog.drinks.first(where: {
            Self.normalizedDrinkName($0.name) == normalizedName
        }) {
            preferences.orderedDrinkNames.removeAll { $0 == normalizedName }
            preferences.orderedDrinkNames.insert(normalizedName, at: 0)
            commitDrinkCatalogPreferences(preferences)
            let resolved = drinks.first(where: { Self.normalizedDrinkName($0.name) == normalizedName }) ?? restoredSeed
            selectDrink(resolved)
            return resolved
        }

        if let existingCustom = preferences.customDrinks.first(where: {
            Self.normalizedDrinkName($0.name) == normalizedName
        }) {
            preferences.orderedDrinkNames.removeAll { $0 == normalizedName }
            preferences.orderedDrinkNames.insert(normalizedName, at: 0)
            commitDrinkCatalogPreferences(preferences)
            let resolved = drinks.first(where: { Self.normalizedDrinkName($0.name) == normalizedName }) ?? existingCustom
            selectDrink(resolved)
            return resolved
        }

        let drink = Self.canonicalDrinkTag(
            DrinkTag(
                id: UUID(),
                name: trimmed,
                subtitle: "Custom",
                symbol: "takeoutbag.and.cup.and.straw.fill",
                imageName: nil,
                primaryHex: "#2A1815",
                secondaryHex: "#B86831"
            )
        )

        preferences.customDrinks.removeAll { Self.normalizedDrinkName($0.name) == normalizedName }
        preferences.customDrinks.insert(drink, at: 0)
        preferences.orderedDrinkNames.removeAll { $0 == normalizedName }
        preferences.orderedDrinkNames.insert(normalizedName, at: 0)
        commitDrinkCatalogPreferences(preferences)

        guard let resolved = drinks.first(where: { Self.normalizedDrinkName($0.name) == normalizedName }) else {
            selectDrink(drink)
            return drink
        }
        selectDrink(resolved)
        return resolved
    }

    /// Rehydrates the locally cached drink catalog into memory before the first
    /// signed-in bootstrap finishes. This keeps the composer stable offline and
    /// gives us a migration path into account-backed storage.
    func hydrateCustomDrinks() {
        drinkCatalogPreferences = loadPersistedDrinkCatalogPreferences()
        lastSyncedDrinkCatalogPreferences = DrinkCatalogPreferences()
        refreshCatalogs()
    }

    func applyDrinkCatalogBootstrapPreferences(_ backendPreferences: DrinkCatalogPreferences) {
        let server = normalizedDrinkCatalogPreferences(backendPreferences)
        let local = loadPersistedDrinkCatalogPreferences()
        let isDirty = isPersistedDrinkCatalogDirty()

        let resolved: DrinkCatalogPreferences
        let shouldUpload: Bool

        if isDirty, !local.isEmpty {
            resolved = local
            shouldUpload = resolved != server
        } else if server.isEmpty, !local.isEmpty {
            resolved = local
            shouldUpload = true
        } else {
            resolved = server.isEmpty ? local : server
            shouldUpload = false
        }

        drinkCatalogPreferences = resolved
        lastSyncedDrinkCatalogPreferences = server
        savePersistedDrinkCatalogPreferences(resolved)
        setPersistedDrinkCatalogDirty(shouldUpload)

        if shouldUpload {
            Task { await syncDrinkCatalogPreferencesIfNeeded() }
        }
    }

    func removeDrink(_ drink: DrinkTag) {
        let normalizedName = Self.normalizedDrinkName(drink.name)
        postDraft.selectedDrinkIDs.removeAll { $0 == drink.id }

        var preferences = normalizedDrinkCatalogPreferences(drinkCatalogPreferences)
        preferences.customDrinks.removeAll { Self.normalizedDrinkName($0.name) == normalizedName }
        preferences.deletedDrinkNames.removeAll { $0 == normalizedName }
        preferences.deletedDrinkNames.append(normalizedName)
        preferences.orderedDrinkNames.removeAll { $0 == normalizedName }
        commitDrinkCatalogPreferences(preferences)
    }

    func moveDrinks(from source: IndexSet, to destination: Int) {
        drinks.move(fromOffsets: source, toOffset: destination)

        var preferences = normalizedDrinkCatalogPreferences(drinkCatalogPreferences)
        let customNames = Set(preferences.customDrinks.map { Self.normalizedDrinkName($0.name) })
        preferences.orderedDrinkNames = drinks.map { Self.normalizedDrinkName($0.name) }
        preferences.customDrinks = drinks.filter { customNames.contains(Self.normalizedDrinkName($0.name)) }
        commitDrinkCatalogPreferences(preferences, refreshCatalog: false)
    }

    func syncDrinkCatalogPreferencesIfNeeded() async {
        guard authState == .signedIn, let viewer else { return }

        let current = normalizedDrinkCatalogPreferences(drinkCatalogPreferences)
        guard isPersistedDrinkCatalogDirty() || current != lastSyncedDrinkCatalogPreferences else { return }

        do {
            try await backend.updateDrinkCatalogPreferences(current, for: viewer)
            lastSyncedDrinkCatalogPreferences = current
            savePersistedDrinkCatalogPreferences(current)
            setPersistedDrinkCatalogDirty(false)
        } catch {
            setPersistedDrinkCatalogDirty(true)
        }
    }

    static func normalizedDrinkName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func canonicalDrinkTag(_ drink: DrinkTag) -> DrinkTag {
        let normalizedName = normalizedDrinkName(drink.name)
        let isCustomDrink = normalizedDrinkName(drink.subtitle) == "custom"
        let resolvedImageName = isCustomDrink
            ? nil
            : (DrinkTag.resolvedImageName(for: drink.name) ?? drink.imageName)
        let resolvedSymbol: String

        if isCustomDrink {
            resolvedSymbol = "takeoutbag.and.cup.and.straw.fill"
        } else if normalizedName == "maddox" {
            resolvedSymbol = "person.fill"
        } else if normalizedName.hasSuffix("shot") || resolvedImageName == "DrinkShotglass" {
            resolvedSymbol = "bolt.fill"
        } else {
            resolvedSymbol = drink.symbol
        }

        return DrinkTag(
            id: drink.id,
            name: drink.name.trimmingCharacters(in: .whitespacesAndNewlines),
            subtitle: drink.subtitle,
            symbol: resolvedSymbol,
            imageName: resolvedImageName,
            primaryHex: drink.primaryHex,
            secondaryHex: drink.secondaryHex
        )
    }

    static func deduplicatedDrinks(_ drinks: [DrinkTag]) -> [DrinkTag] {
        var seen: Set<String> = []
        var unique: [DrinkTag] = []
        for drink in drinks {
            let canonicalDrink = canonicalDrinkTag(drink)
            let key = normalizedDrinkName(canonicalDrink.name)
            guard seen.insert(key).inserted else { continue }
            unique.append(canonicalDrink)
        }
        return unique
    }
}

private extension AppStore {
    func commitDrinkCatalogPreferences(
        _ preferences: DrinkCatalogPreferences,
        refreshCatalog: Bool = true
    ) {
        let normalized = normalizedDrinkCatalogPreferences(preferences)
        drinkCatalogPreferences = normalized
        savePersistedDrinkCatalogPreferences(normalized)
        setPersistedDrinkCatalogDirty(true)
        if refreshCatalog {
            refreshCatalogs()
        }
        Task { await syncDrinkCatalogPreferencesIfNeeded() }
    }

    func normalizedDrinkCatalogPreferences(_ preferences: DrinkCatalogPreferences) -> DrinkCatalogPreferences {
        let customDrinks = Self.deduplicatedDrinks(preferences.customDrinks)
        let customNames = Set(customDrinks.map { Self.normalizedDrinkName($0.name) })
        let seedNames = Set(SeedCatalog.drinks.map { Self.normalizedDrinkName($0.name) })
        let orderedNames = preferences.orderedDrinkNames.reduce(into: [String]()) { result, raw in
            let name = Self.normalizedDrinkName(raw)
            guard !name.isEmpty, !result.contains(name) else { return }
            guard seedNames.contains(name) || customNames.contains(name) else { return }
            result.append(name)
        }
        let deletedNames = preferences.deletedDrinkNames.reduce(into: [String]()) { result, raw in
            let name = Self.normalizedDrinkName(raw)
            guard !name.isEmpty, !result.contains(name) else { return }
            result.append(name)
        }

        return DrinkCatalogPreferences(
            customDrinks: customDrinks,
            deletedDrinkNames: deletedNames,
            orderedDrinkNames: orderedNames
        )
    }

    func loadPersistedDrinkCatalogPreferences() -> DrinkCatalogPreferences {
        migrateLegacyDrinkCatalogIfNeeded()

        guard let data = UserDefaults.standard.data(forKey: persistedDrinkCatalogKey),
              let decoded = try? JSONDecoder().decode(DrinkCatalogPreferences.self, from: data)
        else {
            return DrinkCatalogPreferences()
        }

        return normalizedDrinkCatalogPreferences(decoded)
    }

    func savePersistedDrinkCatalogPreferences(_ preferences: DrinkCatalogPreferences) {
        let normalized = normalizedDrinkCatalogPreferences(preferences)
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: persistedDrinkCatalogKey)
    }

    func isPersistedDrinkCatalogDirty() -> Bool {
        UserDefaults.standard.bool(forKey: persistedDrinkCatalogDirtyKey)
    }

    func setPersistedDrinkCatalogDirty(_ isDirty: Bool) {
        UserDefaults.standard.set(isDirty, forKey: persistedDrinkCatalogDirtyKey)
    }

    var persistedDrinkCatalogKey: String {
        Self.drinkCatalogDefaultsKeyPrefix + (viewer?.id.uuidString.lowercased() ?? "anonymous")
    }

    var persistedDrinkCatalogDirtyKey: String {
        Self.dirtyDrinkCatalogDefaultsKeyPrefix + (viewer?.id.uuidString.lowercased() ?? "anonymous")
    }

    var legacyCustomDrinksDefaultsKey: String {
        Self.legacyCustomDrinksDefaultsKeyPrefix + (viewer?.id.uuidString.lowercased() ?? "anonymous")
    }

    var legacyDrinkOrderKey: String {
        Self.legacyDrinkOrderKeyPrefix + (viewer?.id.uuidString.lowercased() ?? "anonymous")
    }

    func migrateLegacyDrinkCatalogIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.data(forKey: persistedDrinkCatalogKey) == nil else { return }

        let migrated = legacyDrinkCatalogPreferences()
        guard !migrated.isEmpty else { return }

        savePersistedDrinkCatalogPreferences(migrated)
        setPersistedDrinkCatalogDirty(true)
    }

    func legacyDrinkCatalogPreferences() -> DrinkCatalogPreferences {
        let defaults = UserDefaults.standard
        let customDrinks = loadLegacyCustomDrinks()
        let savedIDs = defaults.stringArray(forKey: legacyDrinkOrderKey) ?? []
        let catalogByID = Dictionary(
            uniqueKeysWithValues: (SeedCatalog.drinks + customDrinks).map { ($0.id.uuidString, $0) }
        )

        let orderedNames = savedIDs.compactMap { id in
            catalogByID[id].map { Self.normalizedDrinkName($0.name) }
        }

        let deletedSeedNames: [String]
        if savedIDs.isEmpty {
            deletedSeedNames = []
        } else {
            let savedIDSet = Set(savedIDs)
            deletedSeedNames = SeedCatalog.drinks.compactMap { drink in
                let id = drink.id.uuidString
                guard !savedIDSet.contains(id) else { return nil }
                return Self.normalizedDrinkName(drink.name)
            }
        }

        return normalizedDrinkCatalogPreferences(
            DrinkCatalogPreferences(
                customDrinks: customDrinks,
                deletedDrinkNames: deletedSeedNames,
                orderedDrinkNames: orderedNames
            )
        )
    }

    func loadLegacyCustomDrinks() -> [DrinkTag] {
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: legacyCustomDrinksDefaultsKey)
            ?? defaults.data(forKey: Self.legacyCustomDrinksDefaultsKey)

        guard let data,
              let decoded = try? JSONDecoder().decode([PersistedCustomDrink].self, from: data)
        else {
            return []
        }

        return Self.deduplicatedDrinks(decoded.map(\.tag))
    }
}

/// Codable shim kept for legacy migration from the previous local-only custom
/// drink store. New persistence uses `DrinkCatalogPreferences` directly.
private struct PersistedCustomDrink: Codable {
    let id: UUID
    let name: String
    let subtitle: String
    let symbol: String
    let imageName: String?
    let primaryHex: String
    let secondaryHex: String

    var tag: DrinkTag {
        AppStore.canonicalDrinkTag(
            DrinkTag(
                id: id,
                name: name,
                subtitle: subtitle,
                symbol: symbol,
                imageName: imageName,
                primaryHex: primaryHex,
                secondaryHex: secondaryHex
            )
        )
    }
}
