import Foundation

extension SupabaseSocialBackendClient {
    @MainActor
    func signInWithPasskey() async throws {
        let options: PasskeyOptions<PasskeyAuthenticationOptions> = try await sendPasskeyRequest(
            path: "passkeys/authentication/options", authenticated: false, body: [String: String]()
        )
        try validatePasskeyDomain(options.options.rpId)
        let authorization = PasskeyAuthorization(window: try PasskeyAuthorization.activeWindow())
        let credential = try await authorization.authenticate(options.options)
        let session: SupabaseAuthSession = try await sendPasskeyRequest(
            path: "passkeys/authentication/verify", authenticated: false,
            body: PasskeyVerifyRequest(challenge_id: options.challenge_id, credential: credential)
        )
        persistSession(session)
    }

    @MainActor
    func registerPasskey() async throws {
        let userID = try currentUserID()
        let options: PasskeyOptions<PasskeyRegistrationOptions> = try await sendPasskeyRequest(
            path: "passkeys/registration/options", authenticated: true, body: [String: String]()
        )
        try validatePasskeyDomain(options.options.rp.id)
        let authorization = PasskeyAuthorization(window: try PasskeyAuthorization.activeWindow())
        let credential = try await authorization.register(options.options)
        // A sign-out/account switch while the system sheet is open must not
        // complete enrollment against a different session.
        guard currentUserIDOptional == userID else { throw SupabaseBackendError.notAuthenticated }
        let _: AccountPasskey = try await sendPasskeyRequest(
            path: "passkeys/registration/verify", authenticated: true,
            body: PasskeyVerifyRequest(challenge_id: options.challenge_id, credential: credential)
        )
    }

    func listPasskeys() async throws -> [AccountPasskey] {
        try await ensureAuthenticatedSession()
        let request = try makeRequest(url: environment.authURL(path: "passkeys"), method: "GET", authenticated: true)
        return try decode([AccountPasskey].self, from: await perform(request))
    }

    func deletePasskey(id: UUID) async throws {
        try await ensureAuthenticatedSession()
        let request = try makeRequest(
            url: environment.authURL(path: "passkeys/\(id.uuidString.lowercased())"),
            method: "DELETE", authenticated: true
        )
        _ = try await perform(request)
    }

    private func validatePasskeyDomain(_ domain: String) throws {
        guard domain == environment.passkeyRelyingPartyID else { throw PasskeyError.invalidOptions }
    }

    private func sendPasskeyRequest<Response: Decodable, Body: Encodable>(
        path: String, authenticated: Bool, body: Body
    ) async throws -> Response {
        if authenticated { try await ensureAuthenticatedSession() }
        var request = try makeRequest(url: environment.authURL(path: path), method: "POST", authenticated: authenticated)
        request.httpBody = try encode(body)
        do {
            return try decode(Response.self, from: await perform(request))
        } catch SupabaseBackendError.requestFailed(let message, let status) where status == 404 && message.localizedCaseInsensitiveContains("disabled") {
            throw SupabaseBackendError.requestFailed("Passkeys aren't available right now. Sign in with your username or email and password.", statusCode: status)
        }
    }
}
