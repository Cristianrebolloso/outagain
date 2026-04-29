import Foundation
import os.log

/// Lightweight instrumentation layer for Supabase HTTP calls.
///
/// Every call that goes through `SupabaseSocialBackendClient.perform(_:)` is
/// logged here with: the HTTP method, the path (REST table or RPC name), the
/// calling source if provided, and the wall-clock duration in milliseconds.
///
/// **How to read the output in Xcode:**
///   Filter the console by "SUPA" to see only Supabase call events.
///   Each line is tab-separated: timestamp | method | path | source | duration
///
/// **Removing logging in production:**
///   Wrap all `SupabaseCallLogger.log(...)` calls in `#if DEBUG` or set
///   `SupabaseCallLogger.isEnabled = false` at startup.
///
/// **Expected request budget (after optimisations):**
///   Cold launch:  ~7 DB calls (auth check, profile, feed RPC, friendships,
///                 notifications, FoF IDs, related profiles batch)
///   Foreground:   1 delta-notification poll every 60s (~200 bytes)
///   Full refresh: ~7 DB calls every 5 min
///   Post/react/comment: 1 write call each, no follow-up bootstrap
@MainActor
final class SupabaseCallLogger {
    static let shared = SupabaseCallLogger()

    // Set to false to silence all output in prod builds.
    // nonisolated(unsafe) is required under Swift 6 strict concurrency:
    // mutable stored properties on a @MainActor type cannot be nonisolated.
    nonisolated(unsafe) static var isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    nonisolated(unsafe) private let log = OSLog(subsystem: "com.outagain.app", category: "SUPA")

    // Rolling in-memory ledger for the session summary.
    private var entries: [Entry] = []

    struct Entry {
        var method: String
        var path: String
        var source: String
        var durationMs: Double
        var statusCode: Int
        var timestamp: Date
    }

    nonisolated func record(
        method: String,
        url: URL,
        source: String,
        durationMs: Double,
        statusCode: Int
    ) {
        guard Self.isEnabled else { return }

        // Extract just the path segment after /rest/v1/ or /auth/v1/ or
        // /storage/v1/ so the log lines stay short and scannable.
        let path = Self.shortPath(from: url)

        let line = String(format: "[SUPA] %@ %-30@ %-22@ %5.0f ms  HTTP %d",
                          method, path, source, durationMs, statusCode)
        os_log("%{public}@", log: log, type: .debug, line)

        // Also print to stderr so it appears in the Xcode console without
        // needing a filter — easier during active development.
        print(line)

        Task { @MainActor in
            entries.append(Entry(
                method: method,
                path: path,
                source: source,
                durationMs: durationMs,
                statusCode: statusCode,
                timestamp: Date()
            ))
        }
    }

    /// Print a summary of all calls since last reset to the console.
    /// Call this from `refreshAppData` or a debug button.
    @discardableResult
    func printSessionSummary() -> String {
        let total = entries.count
        let dbCalls  = entries.filter { !$0.path.hasPrefix("storage/") && !$0.path.hasPrefix("auth/") }.count
        let authCalls   = entries.filter { $0.path.hasPrefix("auth/") }.count
        let storageCalls = entries.filter { $0.path.hasPrefix("storage/") }.count
        let avgMs = entries.isEmpty ? 0 : entries.map(\.durationMs).reduce(0, +) / Double(entries.count)
        let maxMs = entries.map(\.durationMs).max() ?? 0

        let grouped = Dictionary(grouping: entries, by: \.path)
        let topPaths = grouped
            .map { (path: $0.key, count: $0.value.count, avgMs: $0.value.map(\.durationMs).reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.count > $1.count }
            .prefix(10)

        var lines: [String] = [
            "",
            "╔══ SUPABASE SESSION SUMMARY ══════════════════════════════╗",
            String(format: "  Total calls   : %d  (DB: %d | Storage: %d | Auth: %d)", total, dbCalls, storageCalls, authCalls),
            String(format: "  Avg latency   : %.0f ms   Max: %.0f ms", avgMs, maxMs),
            "  Top endpoints :"
        ]
        for entry in topPaths {
            lines.append(String(format: "    %-32@ %3dx  avg %.0f ms", entry.path, entry.count, entry.avgMs))
        }
        lines.append("╚══════════════════════════════════════════════════════════╝")
        lines.append("")

        let summary = lines.joined(separator: "\n")
        print(summary)
        return summary
    }

    func resetSession() {
        entries.removeAll()
    }

    // MARK: - Private

    private nonisolated static func shortPath(from url: URL) -> String {
        let str = url.absoluteString
        for prefix in ["/rest/v1/", "/auth/v1/", "/storage/v1/"] {
            if let range = str.range(of: prefix) {
                var path = String(str[range.upperBound...])
                // Strip query string for readability — keep the path only.
                if let q = path.range(of: "?") {
                    path = String(path[path.startIndex..<q.lowerBound])
                }
                let segment = prefix.contains("storage") ? "storage/\(path)" :
                              prefix.contains("auth")    ? "auth/\(path)" : path
                return String(segment.prefix(50))
            }
        }
        return String(url.path.prefix(50))
    }
}
