import Foundation

extension AppStore {
    /// Retain an explicitly opened invite through sign-in and profile setup.
    /// Receiving a URL never sends a request or joins a group.
    @discardableResult
    func receiveSocialInvite(_ input: String) -> Bool {
        guard let code = SocialInviteCode.normalized(input) else { return false }
        pendingSocialInviteCode = code
        lastAutoPresentedSocialInviteCode = nil
        presentPendingSocialInvite()
        return true
    }

    func presentPendingSocialInvite() {
        guard isLive, let code = pendingSocialInviteCode,
              code != lastAutoPresentedSocialInviteCode, !isPostFlowPresented,
              notificationDestination == nil, !isMaddoxPlayerPresented, !pendingMaddoxPlayer,
              !shouldPresentMaintenanceScreen else { return }
        lastAutoPresentedSocialInviteCode = code
        isSocialInvitePresented = true
    }

    func clearPendingSocialInvite(matching code: String) {
        if pendingSocialInviteCode == code { pendingSocialInviteCode = nil }
    }
}
