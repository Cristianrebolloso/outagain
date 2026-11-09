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
                        Text("Or get every background with Plus")
                            .font(AppTypography.rowSubtitle).foregroundStyle(.secondary)
                    }

                    VStack(spacing: 10) {
                        Text("Out Again+").font(AppTypography.brandHero)
                        Text(store.purchases.isPlus ? "Your membership is active" : "No ads. Every background. Your Plus badge.")
                            .font(AppTypography.rowSubtitle).foregroundStyle(.secondary)
                    }

                    NightPanel(cornerRadius: 28) {
                        VStack(alignment: .leading, spacing: 20) {
                            benefit("No ads", symbol: "sparkles", detail: "No sponsored cards in your feed.")
                            benefit("Every background", symbol: "paintpalette.fill", detail: "All backgrounds and customization while you're a member.")
                            benefit("Plus checkmark", symbol: "checkmark.seal.fill", detail: "A badge that shows you're an Out Again+ member.")
                            benefit("Out Again+", symbol: "plus.circle.fill", detail: "Your membership name appears inside the app.")
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
                            Text("Payment is charged to your Apple Account. Subscriptions renew automatically unless canceled at least 24 hours before the current period ends. Manage or cancel in your App Store account settings.")
                                .font(AppTypography.metadata).foregroundStyle(.secondary)
                        }
                    }

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
                    Text("Accent colors and the 11B background are always free. The Plus checkmark represents membership, not identity verification.")
                        .font(AppTypography.metadata).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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

    private func benefit(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title2).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppTypography.rowTitle)
                Text(detail).font(AppTypography.rowSubtitle).foregroundStyle(.secondary)
            }
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
            .disabled(store.purchases.isPurchasing)
        }
    }

    @ViewBuilder
    private func backgroundPurchase(_ theme: BackgroundTheme) -> some View {
        if store.purchases.canUse(theme) {
            Button("Use \(theme.label)") { store.backgroundTheme = theme; dismiss() }
                .buttonStyle(.glassProminent).controlSize(.large)
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
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(store.purchases.isPurchasing)
                Text("One-time purchase. Yours to keep without a subscription.")
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
                Spacer()
                NightPanel(cornerRadius: AppLayout.panelRadius) {
                    VStack(alignment: .leading, spacing: 20) {
                        Label(store.viewerIdentity.displayName, systemImage: "person.crop.circle.fill")
                            .font(AppTypography.feedAuthor)
                        Text("\(theme.label) preview").font(AppTypography.sheetTitle)
                        Text("This is how the background looks behind your cards.")
                            .font(AppTypography.rowSubtitle).foregroundStyle(.secondary)
                        Label("Your accent color stays the same", systemImage: "paintpalette.fill")
                            .font(AppTypography.rowSubtitle).foregroundStyle(store.accentColorChoice.color)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                Text("Background preview").font(AppTypography.metadata)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .glassEffect(in: Capsule())
            }
            .padding(28).frame(maxWidth: 560)
        }
        .foregroundStyle(.white)
    }
}
