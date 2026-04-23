import SwiftUI

struct NotificationsCenterView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionEyebrow(title: "Notifications", detail: "Only the signals that actually matter")

                    ForEach(store.notifications) { notification in
                        NightPanel {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: notification.kind.symbol)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(AppTheme.warmGold)
                                    .frame(width: 38, height: 38)
                                    .background(.white.opacity(0.05), in: Circle())

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(notification.title)
                                        .font(.system(.headline, design: .rounded, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text(notification.detail)
                                        .font(.system(.subheadline, design: .rounded))
                                        .foregroundStyle(AppTheme.softText)
                                    Text(notification.createdAt, style: .relative)
                                        .font(.system(.caption, design: .rounded))
                                        .foregroundStyle(AppTheme.warmGold.opacity(0.82))
                                }

                                Spacer()

                                if !notification.isRead {
                                    Circle()
                                        .fill(AppTheme.amber)
                                        .frame(width: 10, height: 10)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .background(AmbientBackground())
        }
    }
}
