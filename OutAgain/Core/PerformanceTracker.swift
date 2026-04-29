import Foundation

/// Before/after performance tracker for Supabase optimization work.
///
/// Usage:
///   1. Call `PerformanceTracker.shared.beginSession()` at app launch
///      (e.g., in `bootstrapFromBackendIfNeeded`).
///   2. Call `PerformanceTracker.shared.markFirstFeedVisible()` when
///      the first feed post appears on screen.
///   3. After a simulated user session, call `printReport()` to see
///      the full before/after summary.
///
/// This tracker complements `SupabaseCallLogger`, which records every
/// individual Supabase call. `PerformanceTracker` records the higher-level
/// session-wide metrics you'd report to a stakeholder.
///
/// **Target metrics after optimization:**
///   Cold launch → first feed visible   : < 1.5 s  (was ~3–5 s)
///   DB calls on cold launch             : ≤ 8      (was ~30+ with 20s poll)
///   Storage calls on cold launch        : 0        (URLs come from post rows)
///   DB calls in 60 min typical session : < 80     (was ~180 at 20s poll)
///   Average image upload size           : < 350 KB (was ~6–12 MB)
@MainActor
final class PerformanceTracker {
    static let shared = PerformanceTracker()

    // MARK: - Session state

    private var sessionStart: Date?
    private var firstFeedVisibleDate: Date?
    private var coldStartToFeedMs: Double?

    private var uploadSizesSampled: [Int] = []
    private var sessionLabel: String = "session"

    // MARK: - Public API

    /// Call at the very start of bootstrap — before any network call fires.
    func beginSession(label: String = "cold-launch") {
        sessionStart = Date()
        firstFeedVisibleDate = nil
        coldStartToFeedMs = nil
        uploadSizesSampled = []
        sessionLabel = label
        SupabaseCallLogger.shared.resetSession()
        print("[PERF] ── Session started: \(label) ──────────────────────")
    }

    /// Call when the first feed post card is rendered on screen.
    /// Typically from HomeFeedView's `onChange(of: store.homeFeedPosts)` when
    /// count transitions from 0 → >0, or from `onAppear` of the first card.
    func markFirstFeedVisible() {
        guard firstFeedVisibleDate == nil, let start = sessionStart else { return }
        let now = Date()
        firstFeedVisibleDate = now
        coldStartToFeedMs = now.timeIntervalSince(start) * 1000
        print(String(format: "[PERF] First feed visible in %.0f ms", coldStartToFeedMs!))
    }

    /// Record the byte size of an image before and after compression.
    func recordImageUpload(originalBytes: Int, compressedBytes: Int, kind: String) {
        uploadSizesSampled.append(compressedBytes)
        #if DEBUG
        let ratio = Double(originalBytes) / Double(max(compressedBytes, 1))
        print(String(format: "[PERF] Upload %-10@ %5d KB → %5d KB  (%.1fx)",
                     kind,
                     originalBytes / 1024,
                     compressedBytes / 1024,
                     ratio))
        #endif
    }

    /// Print a full session report. Call after a representative user session.
    @discardableResult
    func printReport() -> PerformanceReport {
        let callSummary = SupabaseCallLogger.shared.printSessionSummary()

        let timeToFeedStr = coldStartToFeedMs.map { String(format: "%.0f ms", $0) } ?? "—"
        let avgUploadKB = uploadSizesSampled.isEmpty ? 0 :
            uploadSizesSampled.reduce(0, +) / uploadSizesSampled.count / 1024

        let lines = [
            "",
            "╔══ PERFORMANCE REPORT (\(sessionLabel)) ════════════════════════╗",
            "  Cold start → first feed : \(timeToFeedStr)",
            "  Avg upload size          : \(avgUploadKB) KB  (n=\(uploadSizesSampled.count))",
            "  (See SUPABASE SESSION SUMMARY above for DB/Storage call counts)",
            "╚═══════════════════════════════════════════════════════════════╝",
            ""
        ]
        let report = lines.joined(separator: "\n")
        print(report)

        return PerformanceReport(
            sessionLabel: sessionLabel,
            coldStartToFeedMs: coldStartToFeedMs,
            avgUploadKB: avgUploadKB,
            uploadSampleCount: uploadSizesSampled.count
        )
    }
}

struct PerformanceReport {
    var sessionLabel: String
    var coldStartToFeedMs: Double?
    var avgUploadKB: Int
    var uploadSampleCount: Int
}

// MARK: - AppStore integration points

extension AppStore {
    /// Call this from `hydrateFeedFromCacheIfAvailable` to signal that the
    /// cached feed is on screen — this is "first meaningful paint" from cache.
    func trackCachedFeedVisible() {
        #if DEBUG
        PerformanceTracker.shared.markFirstFeedVisible()
        #endif
    }

    /// Call from the first `applyBootstrap` to mark when the live server
    /// data replaced the cached content.
    func trackLiveFeedApplied(postCount: Int) {
        #if DEBUG
        print(String(format: "[PERF] Live feed applied: %d posts", postCount))
        #endif
    }
}
