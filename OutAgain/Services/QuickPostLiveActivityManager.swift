import ActivityKit
import Foundation

struct QuickPostLiveActivityPayload {
    var postCountToday: Int
    var createdAt: Date
    var cycleEnd: Date
}

enum QuickPostLiveActivityManager {
    @discardableResult
    static func startOrUpdate(with payload: QuickPostLiveActivityPayload) async -> Bool {
        // The app defaults on, but the system's Live Activities switch remains
        // authoritative. A denied request is not an invitation to prompt again.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }

        let attributes = QuickPostLiveActivityAttributes(
            activityID: "quick-post",
            deepLink: QuickPostDeepLink.quickPostURL.absoluteString
        )
        let content = ActivityContent(
            state: QuickPostLiveActivityAttributes.ContentState(
                postCountToday: payload.postCountToday,
                createdAt: payload.createdAt
            ),
            staleDate: payload.cycleEnd
        )

        await endExpiredActivities(now: payload.createdAt)

        let activities = Activity<QuickPostLiveActivityAttributes>.activities
        if let existing = activities.first(where: {
            isInSameLiveActivityCycle($0.content.state.createdAt, as: payload.createdAt)
        }) {
            await existing.update(content)
            scheduleEnd(at: payload.cycleEnd)
            return true
        } else {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }

            let didStart = await requestActivity(attributes: attributes, content: content)
            if didStart {
                scheduleEnd(at: payload.cycleEnd)
            }
            return didStart
        }
    }

    static func endExpiredActivities(now: Date = .now) async {
        for activity in Activity<QuickPostLiveActivityAttributes>.activities {
            let cycleEnd = liveActivityCycleWindow(reference: activity.content.state.createdAt).upperBound
            if now >= cycleEnd {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    static func endAll() async {
        for activity in Activity<QuickPostLiveActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func requestActivity(
        attributes: QuickPostLiveActivityAttributes,
        content: ActivityContent<QuickPostLiveActivityAttributes.ContentState>
    ) async -> Bool {
        do {
            _ = try Activity.request(
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

    private static func scheduleEnd(at cycleEnd: Date) {
        let secondsUntilEnd = cycleEnd.timeIntervalSinceNow
        guard secondsUntilEnd > 0 else {
            Task {
                await endExpiredActivities()
            }
            return
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(secondsUntilEnd * 1_000_000_000))
            await endExpiredActivities()
        }
    }

    private static func isInSameLiveActivityCycle(_ candidate: Date, as reference: Date) -> Bool {
        let window = liveActivityCycleWindow(reference: reference)
        return candidate >= window.lowerBound && candidate < window.upperBound
    }

    private static func liveActivityCycleWindow(reference: Date) -> ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let hour = calendar.component(.hour, from: reference)
        let anchorDay: Date
        if hour < 7 {
            anchorDay = calendar.date(byAdding: .day, value: -1, to: reference) ?? reference
        } else {
            anchorDay = reference
        }

        let startOfAnchor = calendar.startOfDay(for: anchorDay)
        let start = calendar.date(byAdding: .hour, value: 7, to: startOfAnchor) ?? anchorDay
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfAnchor) ?? anchorDay
        let end = calendar.date(byAdding: .hour, value: 7, to: nextDay) ?? nextDay

        return start...end
    }
}
