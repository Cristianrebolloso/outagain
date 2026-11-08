import ActivityKit
import SwiftUI
import WidgetKit

struct QuickPostLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuickPostLiveActivityAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
                .widgetURL(URL(string: context.attributes.deepLink))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        Text("Tap to post on Out Again!")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        cameraCircle(size: 36)
                    }
                    .padding(.vertical, 6)
                }
            } compactLeading: {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.white)
            } compactTrailing: {
                Image(systemName: "camera.fill")
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: "camera.fill")
                    .foregroundStyle(.white)
            }
            .widgetURL(URL(string: context.attributes.deepLink))
        }
    }

    private func cameraCircle(size: CGFloat) -> some View {
        Image(systemName: "camera.fill")
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.white.opacity(0.14), in: Circle())
    }
}

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<QuickPostLiveActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Text("Tap to post on Out Again!")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            cameraCircle
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
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
}
