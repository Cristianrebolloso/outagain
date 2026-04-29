import SwiftUI

struct LiveActivityPromptSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    private var latestPost: MomentPost? {
        store.pendingLiveActivityPromptPost
    }

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(spacing: 20) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(width: 48, height: 5)
                    .padding(.top, 10)

                GlassEffectContainer(spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        SectionEyebrow(
                            title: "Live Activity",
                            detail: "Enable one-tap posting from your Lock Screen"
                        )

                        NightPanel(cornerRadius: 30, padding: 18, tint: accent.opacity(0.18)) {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 12) {
                                    Image(systemName: "bolt.circle.fill")
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundStyle(accent)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Jump back into the camera fast")
                                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.white)

                                        Text("Tap the Live Activity any time tonight and Out Again will open straight to Post.")
                                            .font(.system(size: 14, weight: .medium, design: .rounded))
                                            .foregroundStyle(AppTheme.softText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }

                                if let latestPost {
                                    Divider()
                                        .overlay(.white.opacity(0.08))

                                    HStack(spacing: 12) {
                                        Image(systemName: latestPost.drink.symbol)
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(width: 42, height: 42)
                                            .background(.white.opacity(0.08), in: Circle())

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Your latest post is live")
                                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                .foregroundStyle(.white)
                                            Text(promptContextText(for: latestPost))
                                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                                .foregroundStyle(AppTheme.softText)
                                        }
                                    }
                                }
                            }
                        }

                        VStack(spacing: 12) {
                            Button("Yes, Enable Live Activities") {
                                store.enableLiveActivities()
                            }
                            .buttonStyle(.glassProminent)
                            .tint(accent)

                            Button("No, Not Now") {
                                store.declineLiveActivitiesPrompt()
                            }
                            .buttonStyle(.glass)
                            .tint(.white.opacity(0.85))
                        }
                    }
                }
                .padding(.horizontal, 22)

                Spacer(minLength: 0)
            }
        }
        .presentationDetents([.height(438)])
        .presentationBackground(.clear)
        .presentationDragIndicator(.hidden)
    }

    private func promptContextText(for post: MomentPost) -> String {
        if let venue = post.venue {
            return "\(post.drink.name) at \(venue.name)"
        }

        return "Another tap can take you right back to the camera."
    }
}
