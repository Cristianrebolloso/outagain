import Foundation
import Observation

@MainActor
@Observable
final class OfflineNoticeState {
    private(set) var isVisible = false
    @ObservationIgnored private var isOffline = false
    @ObservationIgnored private var pendingNotice: Task<Void, Never>?
    @ObservationIgnored private let delay: Duration

    init(delay: Duration = .seconds(15)) { self.delay = delay }

    func update(isOffline: Bool) {
        guard self.isOffline != isOffline else { return }
        self.isOffline = isOffline
        pendingNotice?.cancel()
        pendingNotice = nil
        if !isOffline {
            isVisible = false
            return
        }
        pendingNotice = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.isOffline, !Task.isCancelled else { return }
            self.isVisible = true
        }
    }
}
