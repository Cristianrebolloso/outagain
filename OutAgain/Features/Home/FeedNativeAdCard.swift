import GoogleMobileAds
import SwiftUI
import UIKit

struct FeedNativeAdCard: View {
    @Environment(FeedAdStore.self) private var ads
    let anchorID: UUID

    var body: some View {
        if let slot = ads.slots[anchorID], slot.ad != nil || slot.measuredHeight > 0 {
            Group {
                if let ad = slot.ad {
                    FeedNativeAdContent(ad: ad)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if height > 0 { slot.measuredHeight = height }
                        }
                } else {
                    // A recycled offscreen creative reloads without collapsing
                    // the row above the reader's current scroll position.
                    Color.clear.frame(height: slot.measuredHeight)
                        .accessibilityHidden(true)
                }
            }
            .primaryGlass(in: .roundedRect(cornerRadius: PostPhotoFormat.cornerRadius))
            .accessibilityIdentifier("home.sponsored.\(anchorID.uuidString)")
            .onAppear { ads.appeared(slot) }
            .onDisappear { ads.disappeared(slot) }
        }
    }
}

/// All ad assets remain inside Google's NativeAdView. The SDK owns taps,
/// impression measurement, and AdChoices; there are no app-owned tap gestures.
private struct FeedNativeAdContent: UIViewRepresentable {
    let ad: NativeAd

    func makeUIView(context: Context) -> FeedNativeAdUIView { FeedNativeAdUIView() }

    func updateUIView(_ uiView: FeedNativeAdUIView, context: Context) {
        uiView.apply(ad)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FeedNativeAdUIView,
                     context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        uiView.mediaHeight.constant = min(360, max(160, (width - 32) / uiView.mediaAspectRatio))
        return uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }
}

private final class FeedNativeAdUIView: NativeAdView {
    private let advertiser = UILabel()
    private let headline = UILabel()
    private let bodyLabel = UILabel()
    private let icon = UIImageView()
    private let creative = MediaView()
    private let actionButton = UIButton(type: .system)
    private let attribution = UILabel()
    private(set) var mediaAspectRatio: CGFloat = 1.5
    lazy var mediaHeight = creative.heightAnchor.constraint(equalToConstant: 220)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        configure(advertiser, size: 15, weight: "Medium", style: .subheadline)
        advertiser.textColor = .white.withAlphaComponent(0.85)
        configure(headline, size: 20, weight: "Semibold", style: .headline)
        configure(bodyLabel, size: 15, weight: "Regular", style: .body)
        bodyLabel.textColor = .white.withAlphaComponent(0.85)
        attribution.font = AppTypography.feedAuthorUIFont
        attribution.adjustsFontForContentSizeCategory = true
        attribution.numberOfLines = 0
        attribution.text = "Sponsored"
        attribution.accessibilityLabel = "Sponsored advertisement"
        attribution.textColor = .white
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 12
        icon.clipsToBounds = true
        let iconWidth = icon.widthAnchor.constraint(equalToConstant: 50)
        iconWidth.priority = .init(999) // Optional icons can collapse inside the stack.
        NSLayoutConstraint.activate([
            iconWidth,
            icon.heightAnchor.constraint(equalToConstant: 50)
        ])

        let identity = UIStackView(arrangedSubviews: [attribution, advertiser])
        identity.axis = .vertical
        identity.spacing = 4
        let header = UIStackView(arrangedSubviews: [icon, identity])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12
        // Keep a clear area under the SDK's top-right AdChoices control.
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 32)

        creative.contentMode = .scaleAspectFit
        creative.backgroundColor = .black.withAlphaComponent(0.18)
        creative.layer.cornerRadius = 16
        creative.clipsToBounds = true
        mediaHeight.isActive = true

        var button = UIButton.Configuration.filled()
        button.baseBackgroundColor = .white
        button.baseForegroundColor = .black
        button.cornerStyle = .capsule
        button.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
        actionButton.configuration = button
        actionButton.titleLabel?.font = scaledFont(size: 17, weight: "Semibold", style: .headline)
        actionButton.titleLabel?.adjustsFontForContentSizeCategory = true
        let actionHeight = actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        actionHeight.priority = .init(999)
        actionHeight.isActive = true
        // Required by the SDK: it handles the click through NativeAdView.
        actionButton.isUserInteractionEnabled = false

        let stack = UIStackView(arrangedSubviews: [header, creative, headline, bodyLabel, actionButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])

        advertiserView = advertiser
        headlineView = headline
        bodyView = bodyLabel
        iconView = icon
        mediaView = creative
        callToActionView = actionButton
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func apply(_ ad: NativeAd) {
        guard nativeAd !== ad else { return }
        advertiser.text = ad.advertiser
        advertiser.isHidden = ad.advertiser == nil
        headline.text = ad.headline
        bodyLabel.text = ad.body
        bodyLabel.isHidden = ad.body == nil
        icon.image = ad.icon?.image
        icon.isHidden = ad.icon == nil
        creative.mediaContent = ad.mediaContent
        mediaAspectRatio = ad.mediaContent.aspectRatio > 0 ? ad.mediaContent.aspectRatio : 1.5
        actionButton.setTitle(ad.callToAction, for: .normal)
        actionButton.isHidden = ad.callToAction == nil
        // Associate last, after every displayed asset is registered/populated.
        nativeAd = ad
    }

    private func configure(_ label: UILabel, size: CGFloat, weight: String, style: UIFont.TextStyle) {
        label.font = scaledFont(size: size, weight: weight, style: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = .white
    }

    private func scaledFont(size: CGFloat, weight: String, style: UIFont.TextStyle) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for:
            UIFont(name: "GeneralSans-\(weight)", size: size) ?? .preferredFont(forTextStyle: style))
    }
}

struct FeedAdPrivacySettings: View {
    @Environment(FeedAdStore.self) private var ads

    var body: some View {
        if ads.isPrivacyOptionsRequired {
            Button {
                Task { await ads.presentPrivacyOptions() }
            } label: {
                Label("Ad privacy choices", systemImage: "hand.raised.fill")
                    .font(AppTypography.actionLabel)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .primaryGlass(in: .capsule, interactive: true)
            }
            .buttonStyle(.plain)
            .disabled(ads.isPresentingPrivacyOptions)
            .alert("Ad privacy choices", isPresented: Binding(
                get: { ads.privacyError != nil }, set: { if !$0 { ads.privacyError = nil } }
            )) {
                Button("OK", role: .cancel) { ads.privacyError = nil }
            } message: {
                Text(ads.privacyError ?? "")
            }
        }
    }
}
