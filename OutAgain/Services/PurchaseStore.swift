import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class PurchaseStore {
    private(set) var products: [Product] = []
    private(set) var entitlements: [PurchaseEntitlement] = []
    private(set) var members: [PlusMember] = []
    private(set) var accountID: UUID?
    private(set) var hasLoadedEntitlements = false
    private(set) var isLoadingProducts = false
    private(set) var isPurchasing = false
    var message: String?
    private(set) var revision = 0
    private(set) var isPlus = false
    @ObservationIgnored private var backend: SocialBackendClient?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherRefresh = false

    func canUse(_ theme: BackgroundTheme) -> Bool {
        PurchaseAccess.allowsBackground(theme.availableTheme.rawValue, entitlements: entitlements)
    }
    func product(_ id: String) -> Product? { products.first { $0.id == id } }
    func isPlusMember(_ id: UUID) -> Bool {
        if id == accountID { return isPlus }
        return members.contains { $0.user_id == id && $0.expires_at > .now }
    }

    func switchAccount(to accountID: UUID?) {
        if self.accountID != accountID {
            self.accountID = accountID
            entitlements = []
            members = []
            isPlus = false
            hasLoadedEntitlements = false
            message = nil
            revision += 1
            refreshGeneration = UUID()
            refreshTask?.cancel()
            refreshTask = nil
            needsAnotherRefresh = false
        }
    }

    func configure(accountID: UUID?, backend: SocialBackendClient) async {
        switchAccount(to: accountID)
        self.backend = backend
        guard accountID != nil else { return }
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard let self else { return }
                    do { try await self.deliver(result) }
                    catch { self.message = "Your purchase is saved with Apple. Restore purchases to finish syncing it." }
                    await self.refresh()
                }
            }
        }
        await refresh()
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await Product.products(for: PurchaseCatalog.allIDs)
            if products.isEmpty { message = "Purchases aren't available from the App Store yet. Please try again later." }
        } catch { message = "Couldn't reach the App Store. Please try again." }
    }

    func refresh() async {
        guard accountID != nil, backend != nil else { return }
        if let refreshTask {
            // A transaction can arrive while a foreground refresh is reading
            // Apple's entitlement stream. Finish with a fresh pass, and make
            // every caller await that result before deciding what unlocked.
            needsAnotherRefresh = true
            await refreshTask.value
            return
        }
        let generation = refreshGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                guard self.refreshGeneration == generation, !Task.isCancelled else { return }
                self.needsAnotherRefresh = false
                await self.refreshEntitlements(generation: generation)
            } while self.refreshGeneration == generation && self.needsAnotherRefresh && !Task.isCancelled
        }
        refreshTask = task
        await task.value
        if refreshGeneration == generation { refreshTask = nil }
    }

    private func refreshEntitlements(generation: UUID) async {
        guard let accountID, let backend else { return }
        var environment = "Production"
        if let result = try? await StoreKit.AppTransaction.shared,
           case .verified(let appTransaction) = result, appTransaction.environment == .sandbox {
            environment = "Sandbox"
        }
        var local: [PurchaseEntitlement] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.appAccountToken == accountID,
                  PurchaseCatalog.allIDs.contains(transaction.productID),
                  !transaction.isUpgraded else { continue }
            local.append(Self.entitlement(transaction))
            try? await deliver(result)
        }
        guard self.accountID == accountID, refreshGeneration == generation else { return }
        // Apple-verified local entitlements keep already purchased benefits
        // available offline; no preference or client-supplied flag grants Plus.
        var resolved = local
        do {
            let remote = try await backend.fetchPurchaseEntitlements(environment: environment)
            guard self.accountID == accountID, refreshGeneration == generation else { return }
            resolved = remote + local.filter { item in !remote.contains { $0.product_id == item.product_id } }
            let currentMembers = try await backend.fetchPlusMembers()
            guard self.accountID == accountID, refreshGeneration == generation else { return }
            if members != currentMembers { members = currentMembers }
        } catch { /* Verified local purchases remain usable while offline. */ }
        guard self.accountID == accountID, refreshGeneration == generation else { return }
        if entitlements != resolved { entitlements = resolved }
        let hasPlus = PurchaseAccess.hasPlus(resolved)
        if isPlus != hasPlus { isPlus = hasPlus }
        if !hasLoadedEntitlements { hasLoadedEntitlements = true }
        revision += 1
    }

    func purchase(_ product: Product) async -> Bool {
        guard let accountID, !isPurchasing else { return false }
        isPurchasing = true
        message = nil
        defer { isPurchasing = false }
        do {
            switch try await product.purchase(options: [.appAccountToken(accountID)]) {
            case .success(let result):
                try await deliver(result)
                await refresh()
                return self.accountID == accountID && entitlements.contains { $0.product_id == product.id && $0.isActive() }
            case .pending:
                message = "Your purchase is awaiting approval. It will unlock automatically once approved."
            case .userCancelled: break
            @unknown default: message = "Please try your purchase again."
            }
        } catch { message = error.localizedDescription }
        return false
    }

    func restore() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        message = nil
        defer { isPurchasing = false }
        do {
            try await StoreKit.AppStore.sync()
            await refresh()
            message = entitlements.contains { $0.isActive() }
                ? "Your purchases have been restored."
                : "No purchases were found for this Out Again account. Use the account you originally purchased with."
        } catch { message = "Couldn't restore purchases. Please try again." }
    }

    private func deliver(_ result: VerificationResult<StoreKit.Transaction>) async throws {
        guard case .verified(let transaction) = result else { throw PurchaseError.unverified }
        guard PurchaseCatalog.allIDs.contains(transaction.productID) else { return }
        guard let accountID, transaction.appAccountToken == accountID else { throw PurchaseError.otherAccount }
        guard let backend else { throw PurchaseError.unavailable }
        #if DEBUG
        if transaction.environment == .xcode {
            await transaction.finish()
            return
        }
        #endif
        try await backend.verifyStorePurchase(signedTransaction: result.jwsRepresentation)
        guard self.accountID == accountID else { throw PurchaseError.otherAccount }
        await transaction.finish()
    }

    private static func entitlement(_ transaction: StoreKit.Transaction) -> PurchaseEntitlement {
        PurchaseEntitlement(product_id: transaction.productID, expires_at: transaction.expirationDate, revoked_at: transaction.revocationDate)
    }
}

enum PurchaseError: LocalizedError {
    case unverified, otherAccount, unavailable
    var errorDescription: String? {
        switch self {
        case .unverified: "Apple couldn't verify this purchase. Please try restoring purchases."
        case .otherAccount: "This purchase belongs to another Out Again account. Sign in to the account used to purchase it."
        case .unavailable: "Purchases are temporarily unavailable. Please try again later."
        }
    }
}
