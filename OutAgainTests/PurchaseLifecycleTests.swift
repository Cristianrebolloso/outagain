import XCTest
import StoreKit
import StoreKitTest
@testable import OutAgain

@MainActor
final class PurchaseLifecycleTests: XCTestCase {
    func testPurchasesExpiryRestoreRefundAndAccountIsolation() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "OutAgainProducts", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let backend = UnconfiguredBackend(environment: .placeholder)
        let account = UUID()
        let purchases = PurchaseStore()
        await purchases.configure(accountID: account, backend: backend)
        await purchases.loadProducts()
        XCTAssertEqual(Set(purchases.products.map(\.id)), PurchaseCatalog.allIDs)
        XCTAssertFalse(purchases.isPlus)
        XCTAssertTrue(purchases.canUse(.standard))
        XCTAssertFalse(purchases.canUse(.pink))

        let monthly = try XCTUnwrap(purchases.product(PurchaseCatalog.monthly))
        let purchasedPlus = await purchases.purchase(monthly)
        XCTAssertTrue(purchasedPlus)
        XCTAssertTrue(purchases.isPlus)
        XCTAssertTrue(purchases.canUse(.pink))

        let blueID = try XCTUnwrap(PurchaseCatalog.backgroundID("blue"))
        let permanent = try await session.buyProduct(identifier: blueID, options: [.appAccountToken(account)])
        try await waitForStoreKitState(of: blueID, accountID: account, isPresent: true)
        await purchases.refresh()
        XCTAssertTrue(purchases.canUse(.blue))

        try session.expireSubscription(productIdentifier: PurchaseCatalog.monthly)
        try await waitForStoreKitState(of: PurchaseCatalog.monthly, accountID: account, isPresent: false)
        await purchases.refresh()
        XCTAssertFalse(purchases.isPlus)
        XCTAssertFalse(purchases.canUse(.pink))
        XCTAssertTrue(purchases.canUse(.blue), "A separately purchased background survives Plus expiry")

        let restored = PurchaseStore()
        await restored.configure(accountID: account, backend: backend)
        await restored.restore()
        XCTAssertTrue(restored.canUse(.blue))
        XCTAssertEqual(restored.message, "Your purchases have been restored.")

        restored.switchAccount(to: UUID())
        await restored.refresh()
        XCTAssertFalse(restored.canUse(.blue), "Another app account cannot claim the Apple purchase")

        try session.refundTransaction(identifier: UInt(permanent.id))
        try await waitForStoreKitState(of: blueID, accountID: account, isPresent: false)
        await purchases.refresh()
        XCTAssertFalse(purchases.canUse(.blue), "A refunded background no longer grants access")

        let app = DuoLayoutFixtures.makeStore()
        await app.purchases.configure(accountID: app.viewer?.id, backend: backend)
        let appAccount = try XCTUnwrap(app.viewer?.id)
        let yearly = try await session.buyProduct(identifier: PurchaseCatalog.yearly, options: [.appAccountToken(appAccount)])
        try await waitForStoreKitState(of: PurchaseCatalog.yearly, accountID: appAccount, isPresent: true)
        await app.purchases.refresh()
        XCTAssertTrue(app.purchases.isPlus)
        XCTAssertFalse(app.areFeedAdsEnabled)
        XCTAssertEqual(app.appDisplayName, "Out Again+")
        try session.refundTransaction(identifier: UInt(yearly.id))
    }

    /// SKTestSession changes the test server synchronously, but StoreKit's
    /// client entitlement stream can still return its prior snapshot briefly.
    /// Await that external state, then make exactly one application refresh.
    /// Polling app assertions here would conceal an actual refresh defect.
    private func waitForStoreKitState(of productID: String, accountID: UUID, isPresent expected: Bool) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: .seconds(5))
        var observations = 0
        while clock.now < deadline {
            var isPresent = false
            for await result in StoreKit.Transaction.currentEntitlements {
                guard case .verified(let transaction) = result else { continue }
                if transaction.productID == productID, transaction.appAccountToken == accountID {
                    isPresent = true
                }
            }
            observations += 1
            if isPresent == expected {
                print("StoreKit \(expected ? "addition" : "removal") observed for \(productID) after \(observations) snapshots (\(started.duration(to: clock.now))).")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("StoreKit did not reflect \(productID)'s test-server \(expected ? "purchase" : "removal"); application refresh has not been evaluated.")
        throw NSError(domain: "PurchaseLifecycleTests.StoreKitSettlement", code: 1)
    }
}
