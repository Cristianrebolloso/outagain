import Foundation
import XCTest
@testable import OutAgain

/// Real client/transport/decoder coverage with all URLSession traffic intercepted.
/// No Supabase endpoint, stored session, friendship or group is changed.
@MainActor
final class SocialInviteClientTests: XCTestCase {
    private let code = "0123456789abcdef0123456789abcdef"
    private let inviterID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let groupID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    func testCreateGroupInviteSendsGroupAndTimeZoneAndDecodesServerFields() async throws {
        try await withClient(path: "create_social_invite", response: inviteResponse) { client, wire in
            let invite = try await client.createSocialInvite(groupID: groupID)
            XCTAssertEqual(invite.token, code)
            XCTAssertEqual(invite.inviterID, inviterID)
            XCTAssertEqual(invite.inviterName, "Invite Test")
            XCTAssertEqual(invite.inviterUsername, "invite_test")
            XCTAssertEqual(invite.groupID, groupID)
            XCTAssertEqual(invite.groupName, "Friday")
            XCTAssertEqual(invite.expiresAt.timeIntervalSince1970, 1_794_709_800.125, accuracy: 0.001)

            let request = try XCTUnwrap(wire.requests.only)
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/rest/v1/rpc/create_social_invite")
            XCTAssertEqual((request.payload["requested_group_id"] as? String)?.lowercased(), groupID.uuidString.lowercased())
            let timeZone = try XCTUnwrap(request.payload["viewer_time_zone"] as? String)
            XCTAssertNotNil(TimeZone(identifier: timeZone))
        }
    }

    func testResolvingPastedLinkNormalizesCodeWithoutSendingAcceptance() async throws {
        try await withClient(path: "resolve_social_invite", response: inviteResponse) { client, wire in
            let pastedLink = " https://cristianrebolloso.github.io/invite/?code=\(code.uppercased())\n"
            let invite = try await client.resolveSocialInvite(token: pastedLink)
            XCTAssertEqual(invite.token, code)
            let request = try XCTUnwrap(wire.requests.only)
            XCTAssertEqual(request.path, "/rest/v1/rpc/resolve_social_invite")
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.payload["invite_token"] as? String, code)
            XCTAssertEqual(Set(request.payload.keys), ["invite_token"])
            XCTAssertFalse(wire.requests.contains { $0.path.hasSuffix("accept_social_invite") })
        }
    }

    func testAcceptSendsOnlyChosenTokenAndDecodesAcceptance() async throws {
        let response = """
        {"inviter_id":"\(inviterID.uuidString)","group_id":"\(groupID.uuidString)","friendship_status":"pending"}
        """
        try await withClient(path: "accept_social_invite", response: response) { client, wire in
            let result = try await client.acceptSocialInvite(token: code)
            XCTAssertEqual(result.inviterID, inviterID)
            XCTAssertEqual(result.groupID, groupID)
            XCTAssertEqual(result.friendshipStatus, "pending")
            let request = try XCTUnwrap(wire.requests.only)
            XCTAssertEqual(request.path, "/rest/v1/rpc/accept_social_invite")
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.payload["invite_token"] as? String, code)
            XCTAssertEqual(Set(request.payload.keys), ["invite_token"])
        }
    }

    func testUntrustedLinkIsRejectedBeforeAnyResolveOrAcceptRequest() async throws {
        try await withClient(path: "resolve_social_invite", response: inviteResponse) { client, wire in
            let untrusted = "https://example.com/invite/?code=\(code)"
            do {
                _ = try await client.resolveSocialInvite(token: untrusted)
                XCTFail("An unrelated host must not be treated as an invite")
            } catch {
                guard case SupabaseBackendError.requestFailed(_, statusCode: 400) = error else {
                    return XCTFail("Expected local input validation, got \(error)")
                }
            }
            do {
                _ = try await client.acceptSocialInvite(token: untrusted)
                XCTFail("An unrelated host must not send an acceptance")
            } catch {
                guard case SupabaseBackendError.requestFailed(_, statusCode: 400) = error else {
                    return XCTFail("Expected local input validation, got \(error)")
                }
            }
            XCTAssertTrue(wire.requests.isEmpty)
        }
    }

    private var inviteResponse: String {
        """
        {"token":"\(code)","inviter_id":"\(inviterID.uuidString)","inviter_name":"Invite Test","inviter_username":"invite_test","group_id":"\(groupID.uuidString)","group_name":"Friday","expires_at":"2026-11-15T02:30:00.125Z"}
        """
    }

    private func withClient(
        path: String,
        response: String,
        operation: (SupabaseSocialBackendClient, SocialInviteTestWire) async throws -> Void
    ) async throws {
        let wire = SocialInviteTestWire(expectedPath: "/rest/v1/rpc/\(path)", response: Data(response.utf8))
        SocialInviteTestURLProtocol.handler = { request in try wire.respond(to: request) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SocialInviteTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            SocialInviteTestURLProtocol.handler = nil
        }
        let client = SupabaseSocialBackendClient(environment: .placeholder, urlSession: session)
        // Replace the in-memory session without persisting or revoking anything.
        client.authSession = SupabaseAuthSession(
            access_token: "isolated-invite-test-session", refresh_token: nil,
            expires_at: Date().addingTimeInterval(3_600).timeIntervalSince1970,
            expires_in: 3_600, token_type: "bearer",
            user: SupabaseAuthUser(id: UUID(), email: nil)
        )
        try await operation(client, wire)
    }
}

nonisolated private final class SocialInviteTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw URLError(.unsupportedURL) }
            let data = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

nonisolated private final class SocialInviteTestWire: @unchecked Sendable {
    struct Request {
        let path: String
        let method: String?
        let payload: [String: Any]
    }
    private let expectedPath: String
    private let response: Data
    private let lock = NSLock()
    private var recorded: [Request] = []

    init(expectedPath: String, response: Data) {
        self.expectedPath = expectedPath
        self.response = response
    }

    var requests: [Request] { lock.withLock { recorded } }

    func respond(to request: URLRequest) throws -> Data {
        try lock.withLock {
            let payload = try JSONSerialization.jsonObject(with: body(request)) as? [String: Any] ?? [:]
            let path = request.url?.path ?? ""
            recorded.append(Request(path: path, method: request.httpMethod, payload: payload))
            guard path == expectedPath else { throw URLError(.unsupportedURL) }
            return response
        }
    }

    private func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
