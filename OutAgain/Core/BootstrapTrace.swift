import Foundation
import os

/// Lightweight cold-start tracer. Logs phase transitions with millisecond
/// offsets from the first event, so a single grep through the device console
/// gives you a flame-graph-shaped readout of where bootstrap time is spent.
///
/// Compiled out in Release — `#if DEBUG` gates every public entry point so
/// the optimizer drops the calls entirely on TestFlight/App Store builds.
enum BootstrapTrace {
    private static let logger = Logger(subsystem: "OutAgain", category: "bootstrap")
    private static var firstEventTime: TimeInterval?
    private static let queue = DispatchQueue(label: "OutAgain.BootstrapTrace")

    /// Mark a phase boundary. The first call establishes t=0; subsequent
    /// calls are reported as offsets from that anchor. Use short, stable
    /// labels — they're how you'll filter the console output.
    static func mark(_ label: String) {
        #if DEBUG
        queue.sync {
            let now = Date().timeIntervalSince1970
            if firstEventTime == nil {
                firstEventTime = now
                logger.info("⏱ [+0ms] \(label) — t=0 anchor")
                return
            }
            let elapsed = (now - (firstEventTime ?? now)) * 1000
            logger.info("⏱ [+\(Int(elapsed))ms] \(label)")
        }
        #endif
    }

    /// Reset the trace anchor — call at the start of a fresh cold-start
    /// sequence so subsequent runs (e.g. after sign-out → sign-in) get
    /// a clean t=0 rather than continuing the original trace.
    static func reset() {
        #if DEBUG
        queue.sync {
            firstEventTime = nil
        }
        #endif
    }
}
