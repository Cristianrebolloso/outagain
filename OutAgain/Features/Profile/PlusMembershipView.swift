import SwiftUI
import StoreKit

struct PlusMembershipView: View {
    var background: BackgroundTheme?
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isPreviewPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let background {
                        Button { isPreviewPresented = true } label: {
                            AmbientBackground(overrideTheme: background)
                                .frame(height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 28))
                                .overlay(alignment: .bottomLeading) {
                                    Label("Preview \(background.label)", systemImage: "arrow.up.left.and.arrow.down.right")
                                        .font(AppTypography.rowTitle).padding(20)
                                }
                        }.buttonStyle(.plain)
                        backgroundPurchase(background)
                        Text("Out Again+")
                            .font(AppTypography.sectionTitle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }

                    if store.purchases.isPlus {
                        Label("Membership active", systemImage: "checkmark.circle.fill")
                            .font(AppTypography.rowTitle)
                    }

                    NightPanel(cornerRadius: 28) {
                        VStack(alignment: .leading, spacing: 20) {
                            benefit("Ad-free feed", symbol: "sparkles")
                            benefit("Every background", symbol: "paintpalette.fill")
                            benefit("Plus membership badge", symbol: "checkmark.seal.fill")
                            benefit("Out Again+ in the app", symbol: "plus.circle.fill")
                        }
                    }

                    if store.purchases.isPlus {
                        Button("Manage subscription") {
                            openURL(URL(string: "https://apps.apple.com/account/subscriptions")!)
                        }
                        .buttonStyle(.glass).controlSize(.large)
                    } else {
                        VStack(spacing: 12) {
                            purchaseButton(PurchaseCatalog.monthly, period: "month")
                            purchaseButton(PurchaseCatalog.yearly, period: "year")
                            if store.purchases.isLoadingProducts { ProgressView() }
                            Text("Billed to your Apple Account. Renews automatically unless canceled at least 24 hours before renewal. Manage in App Store settings.")
                                .font(AppTypography.metadata).foregroundStyle(.secondary)
                        }
                    }

                    Text("Background access lasts while subscribed.")
                        .font(AppTypography.metadata).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let message = store.purchases.message {
                        Text(message).font(AppTypography.rowSubtitle)
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .accessibilityIdentifier("purchaseMessage")
                    }
                    Button("Restore purchases") { Task { await store.purchases.restore() } }
                        .disabled(store.purchases.isPurchasing)
                    HStack(spacing: 24) {
                        Link("Privacy", destination: URL(string: "https://cristianrebolloso.github.io/outagain/privacy/")!)
                        Link("Terms", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    }
                    .font(AppTypography.metadata)
                }
                .frame(maxWidth: 520)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Color.black)
            .foregroundStyle(.white)
            .tint(store.accentColorChoice.color)
            .navigationTitle(background?.label ?? "Out Again+")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await store.purchases.loadProducts() }
        .fullScreenCover(isPresented: $isPreviewPresented) {
            if let background { BackgroundPreviewView(theme: background) }
        }
    }

    private func benefit(_ title: String, symbol: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.title2).frame(width: 30)
            Text(title).font(AppTypography.rowTitle)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func purchaseButton(_ id: String, period: String) -> some View {
        if let product = store.purchases.product(id) {
            Button {
                Task { _ = await store.purchases.purchase(product) }
            } label: {
                HStack {
                    Text(period == "month" ? "Monthly" : "Yearly")
                    Spacer()
                    Text("\(product.displayPrice) / \(period)")
                }
                .font(AppTypography.rowTitle).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(AppTheme.foregroundOnAccent(store.accentColorChoice.color))
            .disabled(store.purchases.isPurchasing)
        }
    }

    @ViewBuilder
    private func backgroundPurchase(_ theme: BackgroundTheme) -> some View {
        if store.purchases.canUse(theme) {
            Button("Use \(theme.label)") { store.backgroundTheme = theme; dismiss() }
                .buttonStyle(.glassProminent)
                .foregroundStyle(AppTheme.foregroundOnAccent(store.accentColorChoice.color))
                .controlSize(.large)
        } else if let id = PurchaseCatalog.backgroundID(theme.rawValue), let product = store.purchases.product(id) {
            VStack(spacing: 8) {
                Button("Buy \(theme.label) · \(product.displayPrice)") {
                    Task {
                        if await store.purchases.purchase(product) {
                            store.backgroundTheme = theme
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(AppTheme.foregroundOnAccent(store.accentColorChoice.color))
                .controlSize(.large)
                .disabled(store.purchases.isPurchasing)
                Text("One-time purchase. Keep it without Plus.")
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
            }
        }
    }
}

private struct BackgroundPreviewView: View {
    let theme: BackgroundTheme
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AmbientBackground(overrideTheme: theme)
            VStack(spacing: 28) {
                HStack {
                    Text(theme.label).font(AppTypography.sheetTitle)
                    Spacer()
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.large)
                }
                Spacer(minLength: 20)
                previewCard
                Spacer(minLength: 20)
            }
            .padding(28).frame(maxWidth: 560)
        }
        .foregroundStyle(.white)
    }

    private var previewCard: some View {
        let drinks = store.viewerDrinkCounts
        let total = drinks.reduce(0) { $0 + $1.count }
        return NightPanel(cornerRadius: AppLayout.panelRadius, padding: 24) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    AvatarView(avatar: store.viewerIdentity.avatar, size: 48)
                    VerifiedProfileLabel(profile: store.viewerIdentity) {
                        Text(store.viewerIdentity.displayName)
                            .font(AppTypography.feedAuthor)
                            .lineLimit(2)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Tonight").font(AppTypography.sectionTitle)
                    Spacer()
                    Text("\(total)")
                        .font(AppTypography.statTotal)
                        .foregroundStyle(store.accentColorChoice.color)
                    Text(total == 1 ? "drink" : "drinks")
                        .font(AppTypography.rowSubtitle)
                        .foregroundStyle(AppTheme.softText)
                }
                if drinks.isEmpty {
                    Text("No drinks posted tonight")
                        .font(AppTypography.rowSubtitle)
                        .foregroundStyle(AppTheme.softText)
                } else {
                    ForEach(Array(drinks.prefix(3).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 12) {
                            DrinkIconView(drink: item.drink, size: 32)
                            Text(item.drink.name).font(AppTypography.rowTitle)
                            Spacer(minLength: 8)
                            Text("\(item.count)")
                                .font(AppTypography.pill)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .foregroundStyle(AppTheme.foregroundOnAccent(store.accentColorChoice.color))
                                .background(store.accentColorChoice.color, in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
