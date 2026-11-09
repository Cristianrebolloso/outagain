import XCTest
import SwiftUI
import UIKit
@testable import OutAgain

/// Layout-only media fixtures. No ad request, impression, or click is generated.
@MainActor
final class FeedAdPresentationScreenshotTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/outagain-build12-ads", isDirectory: true)

    func testRenderNativeCreativeOrientationsWithVisibleControls() async throws {
        for (name, ratio) in [("portrait", CGFloat(9.0 / 16.0)), ("square", CGFloat(1)), ("landscape", CGFloat(16.0 / 9.0))] {
            let cardWidth: CGFloat = 260
            let native = FeedNativeAdUIView()
            native.configureAssets(headline: "A new place for your next night out", advertiser: "Layout fixture",
                                   icon: UIImage(systemName: "sparkles"), callToAction: "Learn more", aspectRatio: ratio)
            let media = try XCTUnwrap(native.mediaView)
            let image = UIImageView(image: fixtureImage(ratio: ratio, title: name.capitalized))
            image.contentMode = .scaleAspectFit
            image.isUserInteractionEnabled = false
            image.translatesAutoresizingMaskIntoConstraints = false
            media.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: media.leadingAnchor),
                image.trailingAnchor.constraint(equalTo: media.trailingAnchor),
                image.topAnchor.constraint(equalTo: media.topAnchor),
                image.bottomAnchor.constraint(equalTo: media.bottomAnchor)
            ])
            let contentSize = native.fittingSize(width: cardWidth - 32)
            let cardHeight = contentSize.height + 32
            let controller = UIViewController()
            controller.view.backgroundColor = UIColor(red: 0.015, green: 0.025, blue: 0.045, alpha: 1)
            let card = UIView(frame: CGRect(x: 16, y: 16, width: cardWidth, height: cardHeight))
            card.backgroundColor = .white.withAlphaComponent(0.10)
            card.layer.cornerRadius = 28
            card.layer.borderWidth = 1
            card.layer.borderColor = UIColor.white.withAlphaComponent(0.20).cgColor
            native.frame = CGRect(origin: CGPoint(x: 16, y: 16), size: contentSize)
            card.addSubview(native)
            controller.view.addSubview(card)
            try await withWindow(controller, size: CGSize(width: cardWidth + 32, height: cardHeight + 32)) { window in
                native.layoutIfNeeded()
                XCTAssertEqual(cardHeight, FeedAdMediaLayout.cardHeight(width: cardWidth), accuracy: 1)
                XCTAssertFalse(native.hasAmbiguousLayout)
                XCTAssertGreaterThanOrEqual(media.bounds.width, 120)
                XCTAssertGreaterThanOrEqual(media.bounds.height, 120)
                let assets = [native.mediaView, native.headlineView, native.callToActionView, native.iconView].compactMap { $0 }
                for asset in assets {
                    XCTAssertFalse(asset.isHidden)
                    XCTAssertTrue(native.bounds.insetBy(dx: -1, dy: -1).contains(asset.convert(asset.bounds, to: native)))
                }
                let headline = try XCTUnwrap(native.headlineView)
                let action = try XCTUnwrap(native.callToActionView)
                XCTAssertLessThanOrEqual(media.convert(media.bounds, to: native).maxY, headline.convert(headline.bounds, to: native).minY)
                XCTAssertLessThanOrEqual(headline.convert(headline.bounds, to: native).maxY, action.convert(action.bounds, to: native).minY)
                for label in descendants(of: native, type: UILabel.self) where label.text == "Sponsored" || label.text == "Advertisement" {
                    XCTAssertTrue(native.bounds.insetBy(dx: -1, dy: -1).contains(label.convert(label.bounds, to: native)))
                }
                try render(window, name: "native-\(name)-260")
            }
        }
    }

    func testRenderFallbackNormalAndLargestAccessibilityAtNarrowWidth() async throws {
        let store = DuoLayoutFixtures.makeStore()
        var normalHeight: CGFloat = 0
        for (name, dynamicType) in [("normal", DynamicTypeSize.large), ("accessibility5", DynamicTypeSize.accessibility5)] {
            let width: CGFloat = 260
            let content = FeedAdCardLayout { FeedHousePromoCard() }
                .primaryGlass(in: .roundedRect(cornerRadius: PostPhotoFormat.cornerRadius))
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .environment(store)
                .environment(\.appAccent, store.accentColorChoice.color)
                .environment(\.dynamicTypeSize, dynamicType)
                .preferredColorScheme(.dark)
                .background(Color.black)
                .ignoresSafeArea()
            let controller = UIHostingController(rootView: content)
            controller.view.backgroundColor = .black
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 10_000))
            XCTAssertTrue(size.height.isFinite)
            XCTAssertGreaterThanOrEqual(size.height, FeedAdMediaLayout.cardHeight(width: width))
            if dynamicType == .large {
                normalHeight = size.height
                XCTAssertEqual(size.height, FeedAdMediaLayout.cardHeight(width: width), accuracy: 1)
            } else {
                XCTAssertGreaterThan(size.height, normalHeight, "Accessibility text must expand the fallback rather than squeeze or overlap its controls")
            }
            try await withWindow(controller, size: CGSize(width: width, height: ceil(size.height))) { window in
                try render(window, name: "fallback-\(name)-260")
            }
        }
    }

    private func fixtureImage(ratio: CGFloat, title: String) -> UIImage {
        let size = ratio < 1 ? CGSize(width: 360, height: 360 / ratio) : CGSize(width: 360 * ratio, height: 360)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.08, green: 0.25, blue: 0.55, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.cyan.setStroke()
            context.cgContext.setLineWidth(8)
            context.cgContext.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.white, .paragraphStyle: paragraph]
            ("\(title)\nLayout fixture" as NSString).draw(in: CGRect(x: 20, y: size.height / 2 - 45, width: size.width - 40, height: 100), withAttributes: attributes)
        }
    }

    private func withWindow<Controller: UIViewController>(_ controller: Controller, size: CGSize,
                                                          operation: (UIWindow) throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        try operation(window)
    }

    private func descendants<T: UIView>(of view: UIView, type: T.Type) -> [T] {
        let own = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { descendants(of: $0, type: type) }
    }

    private func render(_ window: UIWindow, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
