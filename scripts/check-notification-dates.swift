import Foundation

@main
struct NotificationDateChecks {
    static func main() {
        let iso = ISO8601DateFormatter()
        func date(_ value: String) -> Date { iso.date(from: value)! }
        var chicago = Calendar(identifier: .gregorian)
        chicago.locale = Locale(identifier: "en_US")
        chicago.timeZone = TimeZone(identifier: "America/Chicago")!
        chicago.firstWeekday = 2
        chicago.minimumDaysInFirstWeek = 4
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        let now = date("2026-11-05T12:00:00-06:00")
        let previousNight = NightCycleDates.window(containing: date("2026-11-04T21:00:00-06:00"), calendar: chicago)
        func title(_ start: Date?, _ end: Date?, at reference: Date = now, calendar: Calendar = chicago) -> String {
            NotificationDates.recapTitle(start: start, end: end, now: reference, calendar: calendar)
        }
        check(title(previousNight.lowerBound, previousNight.upperBound) == "Last night's photos", "A completed night from yesterday gets the relative title")
        let halloween = NightCycleDates.window(containing: date("2026-10-31T21:00:00-05:00"), calendar: chicago)
        check(title(halloween.lowerBound, halloween.upperBound) == "Photos from October 31", "Old recaps must retain the night date")
        check(title(halloween.lowerBound, halloween.upperBound, at: date("2026-11-01T12:00:00-06:00")) == "Last night's photos", "The 25-hour fall-back night is still last night")
        check(title(halloween.lowerBound, halloween.upperBound, at: date("2026-11-02T00:00:00-06:00")) == "Photos from October 31", "Title must age out at midnight while open")
        check(title(previousNight.lowerBound, previousNight.upperBound, at: date("2026-11-05T03:00:00-06:00")) == "Photos from November 4", "An unfinished night must not be called last night")
        check(title(date("2025-10-31T07:00:00-05:00"), date("2025-11-01T07:00:00-05:00")) == "Photos from October 31, 2025", "Older years must be explicit")
        check(title(nil, nil) == "Night recap", "Missing bounds must not invent a date")
        check(title(now, previousNight.lowerBound) == "Night recap", "Invalid bounds must not invent a date")

        for (stamp, expectedHours) in [("2026-03-07T21:00:00-06:00", 23), ("2026-10-31T21:00:00-05:00", 25), ("2026-11-04T21:00:00-06:00", 24)] {
            let window = NightCycleDates.window(containing: date(stamp), calendar: chicago)
            check(chicago.component(.hour, from: window.lowerBound) == 7 && chicago.component(.hour, from: window.upperBound) == 7, "Both boundaries must stay at local 7 AM across DST")
            check(window.upperBound.timeIntervalSince(window.lowerBound) == Double(expectedHours * 3600), "Night duration must respect DST")
        }
        let early = NightCycleDates.window(containing: date("2026-11-01T06:59:59-06:00"), calendar: chicago)
        check(early == halloween, "After-midnight photos must stay with their original night")
        let atSeven = NightCycleDates.window(containing: date("2026-11-01T07:00:00-06:00"), calendar: chicago)
        check(atSeven.lowerBound == halloween.upperBound, "The cycle switches exactly at 7 AM")
        var pacific = chicago
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        check(title(date("2026-10-31T14:00:00Z"), date("2026-11-01T15:00:00Z"), calendar: pacific) == "Photos from October 31", "Real recap UTC boundaries must preserve the night date")
        check(date("2026-11-01T01:30:00-07:00") != date("2026-11-01T01:30:00-08:00"), "Repeated DST hours are distinct instants")
        check(date("2026-11-01T09:40:36Z") == date("2026-11-01T03:40:36-06:00"), "Post times must preserve the server instant when shown locally")

        for (age, expected) in [(0, "now"), (59, "now"), (60, "1m ago"), (3599, "59m ago"), (3600, "1h ago"), (86399, "23h ago")] {
            check(NotificationDates.activityLabel(for: now.addingTimeInterval(-Double(age)), now: now, calendar: chicago) == expected, "Relative age boundary \(age)")
        }
        let action = date("2026-10-31T21:47:00-05:00")
        let label = NotificationDates.activityLabel(for: action, now: now, calendar: chicago)
        check(label.contains("Oct 31") && label.contains("9:47") && label.contains("PM"), "Old activity must show the action's local date and time")
        check(NotificationDates.activityLabel(for: action, now: date("2026-10-31T21:47:30-05:00"), calendar: chicago) == "now", "Fresh action starts at now")
        check(NotificationDates.activityLabel(for: action, now: date("2026-10-31T21:49:00-05:00"), calendar: chicago) == "2m ago", "Refreshing the clock ages existing rows")
        check(NotificationDates.activityLabel(for: now.addingTimeInterval(3600), now: now, calendar: chicago) != "now", "Future data must not be hidden as now")
        check(NotificationDates.group(for: now, now: now, calendar: chicago) == .today, "Today's actions")
        check(NotificationDates.group(for: previousNight.lowerBound, now: now, calendar: chicago) == .thisWeek, "This calendar week")
        check(NotificationDates.group(for: date("2026-11-01T12:00:00-06:00"), now: now, calendar: chicago) == .thisMonth, "Earlier this month, before the current week")
        check(NotificationDates.group(for: action, now: now, calendar: chicago) == .older, "Last month's actions must not say This Month")
        print("PASS: \(checks) recap dates, local action times, calendar groups, midnight rollover, and DST checks")
    }
}
