import XCTest
import SwiftUI
import StoreKit
import StoreKitTest
import UIKit
@testable import OutAgain

/// Review artifacts of the shipped view, using StoreKit's local test catalog.
/// These screenshots prove the purchase UI, not App Store product approval.
@MainActor
final class PurchaseReviewScreenshotTests: XCTestCase {
    func testRenderPurchaseReviewScreens() async throws {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "OutAgainProducts", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.storefront = "USA"
        session.locale = Locale(identifier: "en_US")
        session.clearTransactions()
        defer { session.clearTransactions() }

        let store = DuoLayoutFixtures.makeStore()
        await store.purchases.configure(accountID: UUID(), backend: UnconfiguredBackend(environment: .placeholder))
        await store.purchases.loadProducts()
        XCTAssertEqual(Set(store.purchases.products.map(\.id)), PurchaseCatalog.allIDs)
        XCTAssertFalse(store.purchases.isPlus)
        XCTAssertEqual(store.purchases.product(PurchaseCatalog.monthly)?.price, Decimal(string: "0.99"))
        XCTAssertEqual(store.purchases.product(PurchaseCatalog.yearly)?.price, Decimal(10))
        for id in PurchaseCatalog.allIDs.subtracting([PurchaseCatalog.monthly, PurchaseCatalog.yearly]) {
            XCTAssertEqual(store.purchases.product(id)?.price, Decimal(string: "0.99"))
        }

        let directory = URL(fileURLWithPath: "/tmp/outagain-purchase-review", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screens: [(String, BackgroundTheme?)] = [
            ("out-again-plus", nil),
            ("background-night", .night),
            ("background-orange", .orange),
            ("background-green", .green),
            ("background-pink", .pink),
            ("background-blue", .blue)
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = .dark
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        for (name, theme) in screens {
            let view = PlusMembershipView(background: theme)
                .environment(store)
                .environment(\.appAccent, store.accentColorChoice.color)
                .environment(\.dynamicTypeSize, .large)
                .preferredColorScheme(.dark)
            let controller = UIHostingController(rootView: view)
            controller.view.backgroundColor = .black
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            // Let NavigationStack, the product-loading task and glass compositor
            // finish their first real presentation before capturing the window.
            try await Task.sleep(for: .milliseconds(600))
            window.layoutIfNeeded()

            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertEqual(image.size, CGSize(width: 390, height: 844))
            let data = try XCTUnwrap(image.pngData())
            try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        try "Rendered the actual PlusMembershipView with StoreKit test products. USA storefront: $0.99 monthly, $10.00 yearly, and $0.99 each permanent background. No production purchases were made.\n".write(to: directory.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }
}
