import Foundation

/// Recap dates describe the night; Activity timestamps describe the action.
nonisolated enum NotificationDates {
    enum Group: String, CaseIterable {
        case today = "Today"
        case thisWeek = "This Week"
        case thisMonth = "This Month"
        case older = "Older"
    }

    static func recapTitle(start: Date?, end: Date?, now: Date = .now,
                           calendar: Calendar = .autoupdatingCurrent) -> String {
        guard let start, let end, end > start else { return "Night recap" }
        if end <= now,
           let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(start, inSameDayAs: yesterday) {
            return "Last night's photos"
        }
        return "Photos from \(formatted(start, relativeTo: now, calendar: calendar, includesTime: false))"
    }

    static func group(for date: Date, now: Date = .now,
                      calendar: Calendar = .autoupdatingCurrent) -> Group {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if calendar.dateInterval(of: .weekOfYear, for: now)?.contains(date) == true { return .thisWeek }
        if calendar.dateInterval(of: .month, for: now)?.contains(date) == true { return .thisMonth }
        return .older
    }

    static func activityLabel(for date: Date, now: Date = .now,
                              calendar: Calendar = .autoupdatingCurrent) -> String {
        let elapsed = now.timeIntervalSince(date)
        // Only tolerate a few seconds of clock skew. A future timestamp must
        // not silently become "now" indefinitely.
        if elapsed < -60 { return formatted(date, relativeTo: now, calendar: calendar, includesTime: true) }
        if elapsed < 60 { return "now" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h ago" }
        return formatted(date, relativeTo: now, calendar: calendar, includesTime: true)
    }

    private static func formatted(_ date: Date, relativeTo now: Date,
                                  calendar: Calendar, includesTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let year = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "" : "y"
        formatter.setLocalizedDateFormatFromTemplate(includesTime ? "\(year)MMMdjm" : "\(year)MMMMd")
        return formatter.string(from: date)
    }
}

nonisolated enum NightCycleDates {
    /// Calendar wall times keep both boundaries at 7 AM on 23/25-hour days.
    static func window(containing reference: Date, calendar: Calendar = .autoupdatingCurrent) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: reference)
        let sevenAM = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: today)!
        let anchor = reference < sevenAM ? calendar.date(byAdding: .day, value: -1, to: today)! : today
        let nextDay = calendar.date(byAdding: .day, value: 1, to: anchor)!
        let start = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: anchor)!
        let end = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: nextDay)!
        return start...end
    }
}
