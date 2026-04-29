import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

private func liveActivityColor(from hex: String) -> Color {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
        return .white
    }

    return Color(
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255
    )
}

struct QuickPostLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuickPostLiveActivityAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
                .widgetURL(URL(string: context.attributes.deepLink))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    liveAvatar(context.state, size: 40)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    cameraCircle
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(context.state.headline)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Text(context.state.detail)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.76))
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)

                        cameraCircle
                    }
                    .padding(.vertical, 6)
                }
            } compactLeading: {
                liveAvatar(context.state, size: 20)
            } compactTrailing: {
                Image(systemName: "camera.fill")
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: "camera.fill")
                    .foregroundStyle(.white)
            }
            .widgetURL(URL(string: context.attributes.deepLink))
            .keylineTint(liveActivityColor(from: context.state.primaryHex))
        }
    }

    private var cameraCircle: some View {
        Image(systemName: "camera.fill")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(.white.opacity(0.14), in: Circle())
    }

    @ViewBuilder
    private func liveAvatar(
        _ state: QuickPostLiveActivityAttributes.ContentState,
        size: CGFloat
    ) -> some View {
        ZStack {
            if let avatarImageData = state.avatarImageData,
               let image = UIImage(data: avatarImageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let avatarRemoteURL = state.avatarRemoteURL,
                      let url = URL(string: avatarRemoteURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        avatarPlaceholder(state)
                    }
                }
            } else {
                avatarPlaceholder(state)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private func avatarPlaceholder(
        _ state: QuickPostLiveActivityAttributes.ContentState
    ) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    liveActivityColor(from: state.avatarPrimaryHex),
                    liveActivityColor(from: state.avatarSecondaryHex)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: state.avatarSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<QuickPostLiveActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            liveAvatar(size: 54)

            VStack(alignment: .leading, spacing: 6) {
                Text(context.state.headline)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(context.state.detail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            cameraCircle
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
        .activityBackgroundTint(.black.opacity(0.92))
        .activitySystemActionForegroundColor(.white)
    }

    private var cameraCircle: some View {
        Image(systemName: "camera.fill")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(.white.opacity(0.16), in: Circle())
    }

    @ViewBuilder
    private func liveAvatar(size: CGFloat) -> some View {
        ZStack {
            if let avatarImageData = context.state.avatarImageData,
               let image = UIImage(data: avatarImageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let avatarRemoteURL = context.state.avatarRemoteURL,
                      let url = URL(string: avatarRemoteURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        avatarPlaceholder
                    }
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private var avatarPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    liveActivityColor(from: context.state.avatarPrimaryHex),
                    liveActivityColor(from: context.state.avatarSecondaryHex)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: context.state.avatarSymbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}
