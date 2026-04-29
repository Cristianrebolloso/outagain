import SwiftUI

@main
struct OutAgainApp: App {
    @UIApplicationDelegateAdaptor(OutAgainAppDelegate.self) private var appDelegate
    @State private var store: AppStore
    @State private var permissionCenter = PermissionCenter()
    @State private var configurationError: String?

    init() {
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

        // The app is a real Supabase client only — no offline or in-memory
        // fallback. If the environment is missing or incomplete, we surface a
        // readable configuration screen instead of silently pretending the app
        // works. This guarantees every byte the user sees came from the
        // backend.
        guard environment.isConfigured else {
            _store = State(
                initialValue: AppStore(
                    backend: UnconfiguredBackend(environment: environment)
                )
            )
            _configurationError = State(
                initialValue: "Missing Supabase configuration. Set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY in Info.plist before running the app."
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
                        .onOpenURL { url in
                            store.handleIncomingURL(url)
                        }
                }
            }
            .preferredColorScheme(.dark)
            .task {
                guard configurationError == nil else { return }
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
                .font(.system(.title2, design: .serif, weight: .bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
