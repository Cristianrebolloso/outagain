import Foundation

@main struct PurchaseChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plus = PurchaseEntitlement(product_id: PurchaseCatalog.monthly, expires_at: now.addingTimeInterval(60), revoked_at: nil)
        let expired = PurchaseEntitlement(product_id: PurchaseCatalog.monthly, expires_at: now, revoked_at: nil)
        let owned = PurchaseEntitlement(product_id: PurchaseCatalog.backgroundID("blue")!, expires_at: nil, revoked_at: nil)
        let refunded = PurchaseEntitlement(product_id: owned.product_id, expires_at: nil, revoked_at: now)
        precondition(PurchaseAccess.allowsBackground("standard", entitlements: [], at: now))
        for name in PurchaseCatalog.backgroundNames {
            precondition(!PurchaseAccess.allowsBackground(name, entitlements: [], at: now))
            precondition(PurchaseAccess.allowsBackground(name, entitlements: [plus], at: now))
            precondition(!PurchaseAccess.allowsBackground(name, entitlements: [expired], at: now))
        }
        precondition(PurchaseAccess.allowsBackground("blue", entitlements: [expired, owned], at: now))
        precondition(!PurchaseAccess.allowsBackground("pink", entitlements: [expired, owned], at: now))
        precondition(!PurchaseAccess.allowsBackground("blue", entitlements: [refunded], at: now))
        precondition(!PurchaseAccess.hasPlus([owned], at: now))
        precondition(!PurchaseAccess.hasPlus([PurchaseEntitlement(product_id: PurchaseCatalog.yearly, expires_at: nil, revoked_at: nil)], at: now))
        precondition(!PurchaseAccess.allowsBackground("unknown", entitlements: [plus], at: now))
        precondition(!PurchaseAccess.allowsBackground("original", entitlements: [plus], at: now))
        precondition(PurchaseCatalog.allIDs.count == 7)
        print("PASS: free default, Plus access, expiry, permanent ownership, refunds, and unknown-product rejection")
    }
}
