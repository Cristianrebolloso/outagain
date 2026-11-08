import SwiftUI

/// Server-driven launch announcement. These are account-scoped messages from
/// Supabase, not APNs pushes: the app fetches unseen announcements during
/// bootstrap and records a receipt as soon as the viewer sees one.
struct AppAnnouncementOverlay: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    private var announcement: AppAnnouncement? {
        store.appAnnouncements.first
    }

    var body: some View {
        ZStack {
            if let announcement {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .transition(.opacity)

                NightPanel(cornerRadius: 28, padding: 22) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            Image(systemName: "megaphone.fill")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 38, height: 38)
                                .background(accent, in: Circle())

                            Text(announcement.title)
                                .font(AppTypography.sheetTitle)
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(announcement.message)
                            .font(AppTypography.body)
                            .foregroundStyle(AppTheme.softText)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)

                        if let imageUrl = announcement.imageUrl {
                            AsyncImage(url: imageUrl) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 180)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                case .failure:
                                    EmptyView()
                                case .empty:
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(.white.opacity(0.06))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 180)
                                        .overlay(ProgressView().tint(.white.opacity(0.4)))
                                @unknown default:
                                    EmptyView()
                                }
                            }
                        }

                        Button {
                            store.dismissAppAnnouncement(announcement)
                        } label: {
                            Text("Dismiss")
                                .font(AppTypography.rowTitle)
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(accent, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Capsule())
                    }
                }
                .padding(.horizontal, AppLayout.screenPadding)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .allowsHitTesting(announcement != nil)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: announcement?.id)
        .onAppear {
            markCurrentAnnouncementPresented()
        }
        .onChange(of: announcement?.id) { _, _ in
            markCurrentAnnouncementPresented()
        }
    }

    private func markCurrentAnnouncementPresented() {
        guard let announcement else { return }
        store.markAppAnnouncementPresented(announcement)
    }
}
