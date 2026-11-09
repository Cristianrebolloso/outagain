import GoogleMobileAds
import SwiftUI
import UIKit

struct FeedNativeAdCard: View {
    @Environment(FeedAdStore.self) private var ads
    @Environment(AppStore.self) private var store
    let anchorID: UUID

    var body: some View {
        if store.areFeedAdsEnabled, let slot = ads.slots[anchorID] {
            Group {
                if let ad = slot.ad {
                    FeedNativeAdContent(ad: ad)
                        // Inset the entire SDK view so its AdChoices corner is
                        // inside the glass card, including on rounded edges.
                        .padding(16)
                } else {
                    FeedAdCardLayout { FeedHousePromoCard() }
                }
            }
            .primaryGlass(in: .roundedRect(cornerRadius: PostPhotoFormat.cornerRadius))
            .accessibilityIdentifier("home.sponsored.\(anchorID.uuidString)")
            .onAppear { ads.appeared(slot) }
            .onDisappear { ads.disappeared(slot) }
        }
    }
}

/// The fallback shares the live card's regular-post footprint before an ad loads.
struct FeedAdCardLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let contentHeight = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: max(FeedAdMediaLayout.cardHeight(width: width), contentHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// App-owned fallback, never registered as a Google impression or click.
struct FeedHousePromoCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image("AppIconPreview")
                    .resizable().scaledToFit()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Out Again").font(AppTypography.feedAuthor)
                    Text("From Out Again").font(AppTypography.metadata)
                        .foregroundStyle(AppTheme.softText)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(colors: [.purple.opacity(0.45), .blue.opacity(0.15), .black.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 52, weight: .medium))
                    Text("Good nights deserve\nto be shared.")
                        .font(AppTypography.pageTitle)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { store.openPostFlow() } label: {
                ViewThatFits(in: .horizontal) {
                    Label("Take a photo", systemImage: "camera")
                        .fixedSize()
                    Text("Take a photo")
                        .multilineTextAlignment(.center)
                }
                .font(AppTypography.actionLabel)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.glass)
        }
        .foregroundStyle(.white)
        .padding(16)
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
        return uiView.fittingSize(width: width)
    }
}

final class FeedNativeAdUIView: NativeAdView {
    private let advertiser = UILabel()
    private let headline = UILabel()
    private let icon = UIImageView()
    private let creative = MediaView()
    private let mediaContainer = UIView()
    private lazy var creativeWidth = creative.widthAnchor.constraint(equalToConstant: 120)
    private lazy var creativeHeight = creative.heightAnchor.constraint(equalToConstant: 120)
    private let actionButton = UIButton(type: .system)
    private let attribution = UILabel()
    private(set) var mediaAspectRatio: CGFloat = 1.5
    private lazy var mediaHeight = mediaContainer.heightAnchor.constraint(equalToConstant: 220)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        configure(advertiser, size: 15, weight: "Medium", style: .subheadline)
        advertiser.textColor = .white.withAlphaComponent(0.85)
        configure(headline, size: 20, weight: "Semibold", style: .headline)
        headline.numberOfLines = 2
        headline.lineBreakMode = .byTruncatingTail
        advertiser.numberOfLines = 1
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

        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true

        mediaContainer.backgroundColor = .white.withAlphaComponent(0.035)
        mediaContainer.layer.cornerRadius = 16
        mediaContainer.clipsToBounds = true
        creative.translatesAutoresizingMaskIntoConstraints = false
        mediaContainer.addSubview(creative)
        NSLayoutConstraint.activate([
            creative.centerXAnchor.constraint(equalTo: mediaContainer.centerXAnchor),
            creative.centerYAnchor.constraint(equalTo: mediaContainer.centerYAnchor),
            creativeWidth, creativeHeight
        ])
        creative.contentMode = .scaleAspectFit
        creative.backgroundColor = .clear
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

        // The SDK places its required control in the bottom-right corner.
        // Reserve a separate footer so it cannot overlap the CTA or media.
        let footer = UIView()
        let disclosure = UILabel()
        configure(disclosure, size: 12, weight: "Medium", style: .caption1)
        disclosure.text = "Advertisement"
        disclosure.textColor = .white.withAlphaComponent(0.65)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(disclosure)
        NSLayoutConstraint.activate([
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            disclosure.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            disclosure.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor, constant: -40),
            disclosure.topAnchor.constraint(equalTo: footer.topAnchor),
            disclosure.bottomAnchor.constraint(equalTo: footer.bottomAnchor)
        ])

        let stack = UIStackView(arrangedSubviews: [header, mediaContainer, headline, actionButton, footer])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        advertiserView = advertiser
        headlineView = headline
        iconView = icon
        mediaView = creative
        callToActionView = actionButton
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func fittingSize(width: CGFloat) -> CGSize {
        headline.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 2
        mediaHeight.constant = 120
        let minimum = systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let chromeHeight = max(0, minimum.height - 120)
        mediaHeight.constant = FeedAdMediaLayout.mediaHeight(cardWidth: width + 32, chromeHeight: chromeHeight)
        return CGSize(width: width, height: chromeHeight + mediaHeight.constant)
    }

    override func layoutSubviews() {
        let size = FeedAdMediaLayout.fittedMediaSize(
            in: CGSize(width: max(0, bounds.width), height: mediaHeight.constant),
            aspectRatio: mediaAspectRatio)
        creativeWidth.constant = size.width
        creativeHeight.constant = size.height
        super.layoutSubviews()
    }

    func apply(_ ad: NativeAd) {
        guard nativeAd !== ad else { return }
        configureAssets(headline: ad.headline, advertiser: ad.advertiser, icon: ad.icon?.image,
                        callToAction: ad.callToAction, aspectRatio: FeedAdMediaLayout.aspectRatio(
                            reported: ad.mediaContent.aspectRatio,
                            imageSize: ad.mediaContent.mainImage?.size ?? ad.images?.first?.image?.size))
        creative.mediaContent = ad.mediaContent
        // Associate last, after every displayed asset is registered/populated.
        nativeAd = ad
    }

    func configureAssets(headline headlineText: String?, advertiser advertiserText: String?,
                         icon iconImage: UIImage?, callToAction: String?, aspectRatio: CGFloat) {
        advertiser.text = advertiserText
        advertiser.isHidden = advertiserText == nil
        headline.text = headlineText
        icon.image = iconImage
        icon.isHidden = iconImage == nil
        mediaAspectRatio = aspectRatio
        actionButton.setTitle(callToAction, for: .normal)
        actionButton.isHidden = callToAction == nil
        setNeedsLayout()
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
