import Foundation

enum PurchaseCatalog {
    static let monthly = "com.cristian.OutAgain.plus.monthly"
    static let yearly = "com.cristian.OutAgain.plus.yearly"
    static let subscriptions: Set<String> = [monthly, yearly]
    static let backgroundNames = ["night", "orange", "green", "pink", "blue"]
    static func backgroundID(_ name: String) -> String? {
        backgroundNames.contains(name) ? "com.cristian.OutAgain.background.\(name)" : nil
    }
    static let allIDs = subscriptions.union(backgroundNames.compactMap(backgroundID))
}

struct PurchaseEntitlement: Codable, Equatable {
    let product_id: String
    let expires_at: Date?
    let revoked_at: Date?

    func isActive(at date: Date = .now) -> Bool {
        guard PurchaseCatalog.allIDs.contains(product_id), revoked_at == nil else { return false }
        if PurchaseCatalog.subscriptions.contains(product_id) {
            return expires_at.map { $0 > date } ?? false
        }
        return true
    }
}

struct PlusMember: Decodable, Equatable {
    let user_id: UUID
    let expires_at: Date
}

enum PurchaseAccess {
    static func hasPlus(_ entitlements: [PurchaseEntitlement], at date: Date = .now) -> Bool {
        entitlements.contains { PurchaseCatalog.subscriptions.contains($0.product_id) && $0.isActive(at: date) }
    }

    static func allowsBackground(_ name: String, entitlements: [PurchaseEntitlement], at date: Date = .now) -> Bool {
        if name == "standard" { return true }
        guard let productID = PurchaseCatalog.backgroundID(name) else { return false }
        return hasPlus(entitlements, at: date) || entitlements.contains { $0.product_id == productID && $0.isActive(at: date) }
    }
}
