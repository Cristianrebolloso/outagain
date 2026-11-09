import Foundation

extension SupabaseSocialBackendClient {
    func createSocialInvite(groupID: UUID?) async throws -> SocialInvite {
        try await sendRest(path: "rpc/create_social_invite", method: "POST",
                           body: CreateSocialInviteRequest(requested_group_id: groupID,
                                                           viewer_time_zone: TimeZone.current.identifier))
    }

    func resolveSocialInvite(token: String) async throws -> SocialInvite {
        let code = try validatedInviteCode(token)
        return try await sendRest(path: "rpc/resolve_social_invite", method: "POST",
                                  body: SocialInviteTokenRequest(invite_token: code))
    }

    func acceptSocialInvite(token: String) async throws -> SocialInviteAcceptance {
        let code = try validatedInviteCode(token)
        return try await sendRest(path: "rpc/accept_social_invite", method: "POST",
                                  body: SocialInviteTokenRequest(invite_token: code))
    }

    private func validatedInviteCode(_ token: String) throws -> String {
        guard let code = SocialInviteCode.normalized(token) else {
            throw SupabaseBackendError.requestFailed("That invite link isn't valid.", statusCode: 400)
        }
        return code
    }
}

private struct CreateSocialInviteRequest: Encodable {
    var requested_group_id: UUID?
    var viewer_time_zone: String
}
private struct SocialInviteTokenRequest: Encodable { var invite_token: String }
