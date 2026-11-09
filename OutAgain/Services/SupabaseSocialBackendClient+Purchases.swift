import Foundation

extension SupabaseSocialBackendClient {
    func fetchPurchaseEntitlements(environment: String) async throws -> [PurchaseEntitlement] {
        try await sendRest(path: "store_entitlements", method: "GET", queryItems: [
            URLQueryItem(name: "select", value: "product_id,expires_at,revoked_at"),
            URLQueryItem(name: "environment", value: "eq.\(environment)")
        ], responseType: [PurchaseEntitlement].self)
    }

    func fetchPlusMembers() async throws -> [PlusMember] {
        try await sendRest(path: "plus_members", method: "GET", queryItems: [
            URLQueryItem(name: "select", value: "user_id,expires_at"),
            URLQueryItem(name: "expires_at", value: "gt.\(ISO8601DateFormatter().string(from: .now))")
        ], responseType: [PlusMember].self)
    }

    func verifyStorePurchase(signedTransaction: String) async throws {
        struct Request: Encodable { let signedTransaction: String }
        try await sendFunctionWithoutResponse(name: "verify-store-purchase", body: Request(signedTransaction: signedTransaction))
    }
}
