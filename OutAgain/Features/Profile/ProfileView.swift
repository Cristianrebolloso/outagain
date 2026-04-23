import SwiftUI

struct ProfileView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                profileHeader
                tonightCard
                preferenceCard
                controlsCard

                SectionEyebrow(
                    title: "Your Moments",
                    detail: store.viewerPosts.isEmpty ? "Nothing posted yet" : "Recent history"
                )

                if store.viewerPosts.isEmpty {
                    EmptyStateCard(
                        title: "Your camera roll starts the story",
                        detail: "Use the floating camera button when the night actually has some signal.",
                        symbol: "camera.fill"
                    )
                } else {
                    LazyVStack(spacing: 18) {
                        ForEach(store.viewerPosts) { post in
                            MomentPostCard(post: post)
                        }
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
    }

    private var profileHeader: some View {
        NightPanel(
            cornerRadius: 36,
            padding: 22,
            tint: Color(hex: store.chromeTintHex).opacity(0.2),
            interactive: true
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    AvatarView(avatar: store.viewerIdentity.avatar, size: 84)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.viewerIdentity.displayName)
                            .font(.system(size: 32, weight: .bold, design: .serif))
                            .foregroundStyle(.white)
                        Text("@\(store.viewerIdentity.username)")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(AppTheme.softText)

                        if store.hasLiveSignal {
                            Label("\(store.activeNowCount) friends active now", systemImage: "bolt.fill")
                                .font(.system(.footnote, design: .rounded, weight: .semibold))
                                .foregroundStyle(AppTheme.warmGold)
                        } else {
                            Label("Quiet for now", systemImage: "moon.stars.fill")
                                .font(.system(.footnote, design: .rounded, weight: .semibold))
                                .foregroundStyle(AppTheme.softText)
                        }
                    }

                    Spacer()
                }

                HStack(spacing: 8) {
                    GlassPill(title: "\(store.friends.count) friends", icon: "person.2.fill")
                    GlassPill(title: "\(store.viewerPosts.count) moments", icon: "camera.fill")
                }
            }
        }
    }

    private var tonightCard: some View {
        NightPanel(cornerRadius: 32, padding: 18, tint: AppTheme.amber.opacity(0.16), interactive: true) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tonight")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(AppTheme.warmGold.opacity(0.86))
                            .tracking(1.5)
                        Text(store.hasLiveSignal ? "Your graph has signal" : "Quiet, but still invite-led")
                            .font(.system(size: 26, weight: .bold, design: .serif))
                            .foregroundStyle(.white)
                    }

                    Spacer()

                    if let url = inviteURL {
                        ShareLink(item: url) {
                            Label("Invite", systemImage: "square.and.arrow.up")
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        }
                        .buttonStyle(.glass)
                    }
                }

                if store.presenceClusters.isEmpty {
                    Text("When people you know are out, their presence shows here first. Until then, the graph stays tight instead of widening to strangers.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(AppTheme.softText)
                } else {
                    ForEach(store.presenceClusters.prefix(2)) { cluster in
                        HStack(alignment: .top, spacing: 14) {
                            AvatarPile(avatars: cluster.friends.map(\.avatar), size: 34, overlap: 11, limit: 4)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(cluster.title)
                                    .font(.system(.headline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(.white)

                                HStack(spacing: 8) {
                                    if let venue = cluster.venue {
                                        Label(venue.name, systemImage: "mappin.and.ellipse")
                                    } else {
                                        Label("Out right now", systemImage: "sparkles")
                                    }

                                    Text(cluster.updatedAt, style: .relative)
                                }
                                .font(.system(.footnote, design: .rounded, weight: .semibold))
                                .foregroundStyle(AppTheme.softText)

                                if let path = cluster.connectionPath {
                                    Text(path)
                                        .font(.system(.caption, design: .rounded, weight: .semibold))
                                        .foregroundStyle(AppTheme.warmGold)
                                }
                            }

                            Spacer()
                        }
                        .padding(14)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(AppTheme.line, lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    private var preferenceCard: some View {
        let recap = store.weeklyRecap

        return NightPanel(cornerRadius: 32, padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                SectionEyebrow(title: "Preferences", detail: "How your nights tend to feel")

                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        profileMetric(
                            title: "Favorite drink",
                            value: recap.favoriteDrink.name,
                            detail: recap.favoriteDrink.subtitle,
                            tint: Color(hex: recap.favoriteDrink.primaryHex)
                        )

                        profileMetric(
                            title: "Common place",
                            value: recap.commonVenue?.name ?? "Still forming",
                            detail: recap.commonVenue?.neighborhood ?? "A few more nights will shape this",
                            tint: AppTheme.rose
                        )
                    }

                    GridRow {
                        profileMetric(
                            title: "Nights active",
                            value: "\(recap.nightsActive)",
                            detail: "Distinct nights this week",
                            tint: AppTheme.amber
                        )

                        profileMetric(
                            title: "Social touchpoints",
                            value: "\(recap.totalInteractions)",
                            detail: "Comments and reactions",
                            tint: AppTheme.warmGold
                        )
                    }
                }
            }
        }
    }

    private var controlsCard: some View {
        NightPanel(cornerRadius: 28, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Trust stays simple")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)

                controlRow(
                    icon: "person.2.crop.square.stack.fill",
                    title: "Invite-led graph",
                    detail: "Growth stays anchored to contacts, invites, and mutual context."
                )
                controlRow(
                    icon: "hand.raised.fill",
                    title: "Report and block",
                    detail: "Moderation exists without becoming a primary surface."
                )
                controlRow(
                    icon: "lock.shield.fill",
                    title: "Plain-language privacy",
                    detail: "Photos, contacts, and location stay permissioned and contextual."
                )
            }
        }
    }

    private var inviteURL: URL? {
        URL(string: store.onboardingDraft.inviteLink)
    }

    private func profileMetric(title: String, value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundStyle(AppTheme.warmGold.opacity(0.84))
                .tracking(1.2)
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(detail)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(AppTheme.softText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .padding(14)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
    }

    private func controlRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.warmGold)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.05), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
            }
        }
    }
}
