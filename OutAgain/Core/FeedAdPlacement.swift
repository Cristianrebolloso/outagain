import Foundation

/// Ads are additional feed rows. Real post IDs and their ordering never change.
enum FeedAdPlacement {
    // Six posts plus one ad: sponsored rows occupy positions 7, 14, 21, ...
    static let postsPerAd = 6

    static func anchors(in postIDs: [UUID]) -> [UUID] {
        postIDs.enumerated().compactMap { index, id in
            (index + 1).isMultiple(of: postsPerAd) ? id : nil
        }
    }

    static func nextAnchor(after index: Int, in postIDs: [UUID]) -> UUID? {
        guard postIDs.indices.contains(index) else { return nil }
        let boundary = ((index / postsPerAd) + 1) * postsPerAd - 1
        return postIDs.indices.contains(boundary) ? postIDs[boundary] : nil
    }
}

struct FeedAdRequestState: Equatable {
    let postIDs: [UUID]
    let enabled: Bool
}

enum FeedAdMediaLayout {
    static func aspectRatio(reported: CGFloat, imageSize: CGSize?) -> CGFloat {
        if reported.isFinite, reported > 0 { return reported }
        if let imageSize, imageSize.width.isFinite, imageSize.height.isFinite,
           imageSize.width > 0, imageSize.height > 0 {
            return imageSize.width / imageSize.height
        }
        return 1.5
    }

    /// Match a new 4:5 post plus its 44-point actions and 22-point footer padding.
    static func cardHeight(width: CGFloat) -> CGFloat { max(0, width) / 0.8 + 66 }

    static func mediaHeight(cardWidth: CGFloat, chromeHeight: CGFloat) -> CGFloat {
        max(120, cardHeight(width: cardWidth) - 32 - chromeHeight)
    }

    static func fittedMediaSize(in available: CGSize, aspectRatio: CGFloat) -> CGSize {
        let ratio = self.aspectRatio(reported: aspectRatio, imageSize: nil)
        let width = min(available.width, available.height * ratio)
        // The SDK's video surface must be at least 120 points in both axes.
        // Aspect-fit preserves the creative inside this surface, even for an
        // unusually narrow asset or missing/incorrect provider metadata.
        return CGSize(width: min(available.width, max(120, width)),
                      height: min(available.height, max(120, width / ratio)))
    }

}

struct FeedAdConfiguration {
    static func isEnabled(in config: [String: String]) -> Bool {
        config["feed_ads_enabled"] == "true"
    }

    static let testAppID = "ca-app-pub-3940256099942544~1458002511"
    static let testUnitID = "ca-app-pub-3940256099942544/3986624511"

    let unitID: String?

    init(mode: String, appID: String, unitID: String, allowsTestAds: Bool) {
        let validAppID = appID.range(of: #"^ca-app-pub-[0-9]{16}~[0-9]{10}$"#, options: .regularExpression) != nil
        if mode == "test", allowsTestAds, validAppID {
            self.unitID = Self.testUnitID
        } else if mode == "live",
                  validAppID,
                  unitID.range(of: #"^ca-app-pub-[0-9]{16}/[0-9]{10}$"#, options: .regularExpression) != nil,
                  !appID.contains("3940256099942544"),
                  !unitID.contains("3940256099942544"),
                  appID.split(separator: "~").first == unitID.split(separator: "/").first {
            self.unitID = unitID
        } else {
            self.unitID = nil
        }
    }

    static var current: Self {
        #if DEBUG
        let allowsTestAds = true
        #else
        let allowsTestAds = false
        #endif
        return Self(
            mode: Bundle.main.object(forInfoDictionaryKey: "OUTAGAIN_ADS_MODE") as? String ?? "disabled",
            appID: Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String ?? "",
            unitID: Bundle.main.object(forInfoDictionaryKey: "OUTAGAIN_NATIVE_AD_UNIT_ID") as? String ?? "",
            allowsTestAds: allowsTestAds
        )
    }
}
