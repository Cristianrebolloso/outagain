import ActivityKit
import Foundation
import UIKit

struct QuickPostLiveActivityPayload {
    var headline: String
    var detail: String
    var primaryHex: String
    var secondaryHex: String
    var avatarSymbol: String
    var avatarPrimaryHex: String
    var avatarSecondaryHex: String
    var avatarImageData: Data?
    var avatarRemoteURL: String?
    var postCountToday: Int
    var createdAt: Date
}

enum QuickPostLiveActivityManager {
    @discardableResult
    static func startOrUpdate(with payload: QuickPostLiveActivityPayload) async -> Bool {
        // Do not pre-check areActivitiesEnabled — that flag is false until the
        // user has been prompted at least once via Activity.request(). Guarding
        // on it prevents the system permission prompt from ever appearing.
        // Activity.request() handles all cases: triggers the prompt on first
        // call, succeeds silently if already authorized, and throws (caught by
        // try? below) if the user has denied or the system prevents it (e.g.
        // Low Power Mode).

        let avatarImageData = await resolvedAvatarImageData(from: payload)

        let attributes = QuickPostLiveActivityAttributes(
            activityID: "quick-post",
            deepLink: QuickPostDeepLink.quickPostURL.absoluteString
        )
        let content = ActivityContent(
            state: QuickPostLiveActivityAttributes.ContentState(
                headline: payload.headline,
                detail: payload.detail,
                primaryHex: payload.primaryHex,
                secondaryHex: payload.secondaryHex,
                avatarSymbol: payload.avatarSymbol,
                avatarPrimaryHex: payload.avatarPrimaryHex,
                avatarSecondaryHex: payload.avatarSecondaryHex,
                avatarImageData: avatarImageData,
                avatarRemoteURL: payload.avatarRemoteURL,
                postCountToday: payload.postCountToday,
                createdAt: payload.createdAt
            ),
            staleDate: Calendar.current.date(byAdding: .hour, value: 8, to: payload.createdAt)
        )

        if let existing = Activity<QuickPostLiveActivityAttributes>.activities.first {
            await existing.update(content)
            return true
        } else {
            do {
                try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                return true
            } catch {
                #if DEBUG
                print("[LiveActivity] Request failed: \(error.localizedDescription)")
                #endif
                return false
            }
        }
    }

    static func endAll() async {
        for activity in Activity<QuickPostLiveActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func resolvedAvatarImageData(
        from payload: QuickPostLiveActivityPayload
    ) async -> Data? {
        if let imageData = payload.avatarImageData,
           let thumbnailData = makeThumbnailData(from: imageData) {
            return thumbnailData
        }

        guard let avatarRemoteURL = payload.avatarRemoteURL,
              let url = URL(string: avatarRemoteURL)
        else {
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return makeThumbnailData(from: data)
        } catch {
            return nil
        }
    }

    private static func makeThumbnailData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let targetSize = CGSize(width: 120, height: 120)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let rendered = renderer.image { _ in
            let scale = max(targetSize.width / image.size.width, targetSize.height / image.size.height)
            let scaledSize = CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            let origin = CGPoint(
                x: (targetSize.width - scaledSize.width) / 2,
                y: (targetSize.height - scaledSize.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: scaledSize))
        }
        return rendered.jpegData(compressionQuality: 0.82)
    }
}
