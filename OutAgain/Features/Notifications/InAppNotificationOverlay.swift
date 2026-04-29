import SwiftUI

/// Liquid-glass toast banner that slides in from the top of the screen
/// whenever a social event arrives while the app is foregrounded.
///
/// One source feeds this overlay:
///   - `store.notifications` — server-pushed events (friend liked your post,
///     friend commented, incoming friend request, etc.)
///
/// Only events that arrive AFTER this view appears (i.e. during the current
/// session) trigger a banner. All IDs already in the store at first appear
/// are pre-seeded into `seenIDs` so old bootstrap notifications never fire.
///
/// Each banner auto-dismisses after 3.5 seconds. Swipe up to dismiss immediately.
/// If a second event fires while one banner is showing, it queues and shows after
/// the first clears.
struct InAppNotificationOverlay: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    /// The banner currently on screen (nil = nothing showing).
    @State private var current: BannerItem?
    /// Pending events waiting to show.
    @State private var queue: [BannerItem] = []
    /// Tracks IDs we've already shown so refreshes don't re-fire old events.
    /// Pre-seeded on first appear with all bootstrap IDs.
    @State private var seenIDs: Set<UUID> = []
    /// True after the initial seed pass — gates onChange from firing before seeding.
    @State private var didSeedInitialIDs = false
    /// Swipe-up drag offset for the current banner.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack {
            if let item = current {
                banner(for: item)
                    .offset(y: min(0, dragOffset))
                    .opacity(dragOffset < -20 ? max(0, 1 + dragOffset / 80) : 1)
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                if value.translation.height < 0 {
                                    dragOffset = value.translation.height
                                }
                            }
                            .onEnded { value in
                                if value.translation.height < -40 {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                        dragOffset = -160
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        dismissCurrent()
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
                    .zIndex(1)
            }
            Spacer()
        }
        .padding(.top, 8)
        .allowsHitTesting(current != nil)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: current?.id)
        .onAppear {
            // Seed all IDs currently in memory so bootstrap notifications
            // never fire as banners. If bootstrap hasn't resolved yet, this
            // seeds an empty set — the onChange handlers below handle that
            // case by seeding on the first call when not yet seeded.
            guard !didSeedInitialIDs else { return }
            didSeedInitialIDs = true
            for n in store.notifications { seenIDs.insert(n.id) }
        }
        .onChange(of: store.notifications) { oldValue, newValue in
            guard didSeedInitialIDs else { return }
            // If the store just went from empty → populated (bootstrap landed
            // after onAppear), the new IDs are all old — seed them silently.
            if oldValue.isEmpty && !newValue.isEmpty && seenIDs.isEmpty {
                for n in newValue { seenIDs.insert(n.id) }
                return
            }
            let fresh = newValue.filter { !seenIDs.contains($0.id) }
            for n in fresh {
                seenIDs.insert(n.id)
                enqueue(BannerItem(
                    id: n.id,
                    icon: n.kind.symbol,
                    title: n.title,
                    detail: n.detail,
                    actor: n.actor
                ))
            }
        }
    }

    // MARK: - Banner view

    @ViewBuilder
    private func banner(for item: BannerItem) -> some View {
        HStack(spacing: 12) {
            // Actor avatar or a generic icon
            if let actor = item.actor {
                AvatarView(avatar: actor.avatar, size: 40)
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 40, height: 40)
                    .background(accent.opacity(0.15), in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .padding(.horizontal, 16)
    }

    // MARK: - Queue management

    private func enqueue(_ item: BannerItem) {
        if current == nil {
            show(item)
        } else {
            queue.append(item)
        }
    }

    private func show(_ item: BannerItem) {
        dragOffset = 0
        current = item
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            dismissCurrent()
        }
    }

    private func dismissCurrent() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            current = nil
            dragOffset = 0
        }
        // Small delay so the exit animation finishes before next banner
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if let next = queue.first {
                queue.removeFirst()
                show(next)
            }
        }
    }

    // MARK: - Model

    struct BannerItem: Identifiable {
        let id: UUID
        let icon: String
        let title: String
        let detail: String
        let actor: UserProfile?
    }
}
