import XCTest
import UIKit
@testable import OutAgain

@MainActor
final class FeedNativeAdLayoutTests: XCTestCase {
    func testCreativeOrientationCannotStretchTheCardOrHideItsControls() throws {
        let view = FeedNativeAdUIView()
        for cardWidth: CGFloat in [260, 320, 390, 420, 600] {
            for ratio: CGFloat in [0.1, 9.0 / 16.0, 1, 16.0 / 9.0, 10] {
                view.configureAssets(headline: "A new place for your next night out", advertiser: "Example advertiser",
                                     icon: UIImage(systemName: "sparkles"), callToAction: "Learn more", aspectRatio: ratio)
                let size = view.fittingSize(width: cardWidth - 32)
                view.frame = CGRect(origin: .zero, size: size)
                view.layoutIfNeeded()
                XCTAssertEqual(size.height + 32, cardWidth / 0.8 + 66, accuracy: 1)
                let media = try XCTUnwrap(view.mediaView)
                XCTAssertGreaterThanOrEqual(media.bounds.width, 120)
                XCTAssertGreaterThanOrEqual(media.bounds.height, 120)
                XCTAssertEqual(media.contentMode, .scaleAspectFit)
                for asset in [view.mediaView, view.headlineView, view.callToActionView, view.iconView].compactMap({ $0 }) {
                    let frame = asset.convert(asset.bounds, to: view)
                    XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Ad asset outside its card: \(frame)")
                    XCTAssertFalse(asset.isHidden)
                }
                XCTAssertFalse(view.hasAmbiguousLayout)
            }
        }
    }

    func testMissingOptionalAssetsKeepTheSameFootprint() {
        let view = FeedNativeAdUIView()
        view.configureAssets(headline: "A short headline", advertiser: nil, icon: nil,
                             callToAction: nil, aspectRatio: 9.0 / 16.0)
        let size = view.fittingSize(width: 328)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        XCTAssertEqual(size.height + 32, 516, accuracy: 1)
        XCTAssertTrue(view.iconView?.isHidden == true)
        XCTAssertTrue(view.callToActionView?.isHidden == true)
        XCTAssertFalse(view.mediaView?.isHidden == true)
    }
}
