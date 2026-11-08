import SwiftUI
import UIKit

@main
struct OutAgainApp: App {
    @UIApplicationDelegateAdaptor(OutAgainAppDelegate.self) private var appDelegate
    @State private var store: AppStore
    @State private var permissionCenter = PermissionCenter()
    @State private var feedAds = FeedAdStore()
    @State private var configurationError: String?

    init() {
        // Keep system navigation and Liquid Glass behavior; customize only type.
        let navigationTitle = UIFont(name: "GeneralSans-Semibold", size: 17)
            ?? UIFont.preferredFont(forTextStyle: .headline)
        let largeTitle = UIFont(name: "CabinetGrotesk-Bold", size: 34)
            ?? UIFont.preferredFont(forTextStyle: .largeTitle)
        UINavigationBar.appearance().titleTextAttributes = [
            .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: navigationTitle)
        ]
        UINavigationBar.appearance().largeTitleTextAttributes = [
            .font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: largeTitle)
        ]

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--duo-layout-preview") {
            _store = State(initialValue: DuoLayoutFixtures.makeStore())
            _configurationError = State(initialValue: nil)
            return
        }
        #endif
        // Give URLSession's shared cache enough room to hold avatars and post
        // photos in memory and on disk. AsyncImage uses URLSession under the
        // hood, so this makes every image load a cache hit after the first
        // fetch — avatars stop flickering and post photos appear instantly
        // on revisit. 50 MB memory / 250 MB disk is conservative for a social
        // feed; adjust up if the device can afford it.
        let imageCache = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 250 * 1024 * 1024
        )
        URLCache.shared = imageCache

        let environment = SupabaseEnvironment.current()

        // The app is a real Supabase client only. If a build is pointed at
        // placeholder values, surface a readable configuration screen instead
        // of pretending offline/local data is the product.
        guard environment.isConfigured else {
            _store = State(
                initialValue: AppStore(
                    backend: UnconfiguredBackend(environment: environment)
                )
            )
            _configurationError = State(
                initialValue: "This build is pointing at placeholder Supabase values. Use the production build settings or set valid SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY overrides."
            )
            return
        }

        let store = AppStore(
            backend: SupabaseSocialBackendClient(environment: environment)
        )
        _store = State(initialValue: store)
        _configurationError = State(initialValue: nil)

        // Bridge the AppStore into the app delegate so APNs callbacks can reach it.
        OutAgainAppDelegate.register(store: store)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let configurationError {
                    ConfigurationErrorView(message: configurationError)
                } else {
                    ContentView()
                        .environment(store)
                        .environment(permissionCenter)
                        .environment(feedAds)
                        .onChange(of: store.viewer?.id) { _, _ in feedAds.clearFeed() }
                        .onOpenURL { url in
                            store.handleIncomingURL(url)
                        }
                }
            }
            .background {
                if store.isDuoDevice { OutsideTapKeyboardDismissal() }
            }
            .font(AppTypography.body)
            .preferredColorScheme(.dark)
            .task {
                guard configurationError == nil, !store.isLayoutPreview else { return }
                await permissionCenter.reregisterRemoteNotificationsIfAuthorized()
            }
        }
    }
}

private struct ConfigurationErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.orange)

            Text("Out Again isn't configured yet")
                .font(AppTypography.sheetTitle)
                .foregroundStyle(.white)

            Text(message)
                .font(AppTypography.rowSubtitle)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
