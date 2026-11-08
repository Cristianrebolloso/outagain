#if DEBUG
import Foundation
import UIKit

/// Exercises the production client and store through an intercepted URLSession.
/// No request reaches Supabase and no real user's session is changed.
@MainActor
enum BackendReliabilityChecks {
    static func run() async {
        do {
            try await check()
            FileHandle.standardError.write(Data("PASS: backend reliability — names/handles, photo publish, duplicate taps, lost responses, upload retries, draft recovery, canonical IDs and timestamps\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("FAIL: backend reliability — \(error)\n".utf8))
            assertionFailure("Backend reliability checks failed: \(error)")
        }
    }

    private static func check() async throws {
        let wire = ReliabilityWire()
        ReliabilityURLProtocol.handler = { request in try wire.respond(to: request) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReliabilityURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ReliabilityURLProtocol.handler = nil }
        let client = SupabaseSocialBackendClient(environment: .placeholder, urlSession: session)
        let viewer = UserProfile(id: UUID(), displayName: "QA Viewer", username: "qa_viewer",
            avatar: AvatarStyle(symbol: "person.fill", primaryHex: "#000000", secondaryHex: "#111111"), isCloseFriend: true)
        client.authSession = SupabaseAuthSession(access_token: "isolated-test-session", refresh_token: nil,
            expires_at: Date().addingTimeInterval(3600).timeIntervalSince1970, expires_in: 3600,
            token_type: "bearer", user: SupabaseAuthUser(id: viewer.id, email: nil))

        let names = try await client.searchUsers(matching: " Alex Morgan ", excluding: viewer)
        precondition(names.count == 1 && wire.lastSearch == "alex morgan")
        _ = try await client.searchUsers(matching: " @AL ", excluding: viewer)
        precondition(wire.lastSearch == "al", "Two-character handles must reach the server")
        let count = wire.searchCount
        let short = try await client.searchUsers(matching: "a", excluding: viewer)
        precondition(short.isEmpty && wire.searchCount == count)
        let searchStore = AppStore(backend: client)
        searchStore.viewer = viewer
        searchStore.friendSearchQuery = "Al"
        searchStore.searchForFriends()
        searchStore.friendSearchQuery = "Alex Morgan"
        searchStore.searchForFriends()
        precondition(searchStore.isSearchingFriends && searchStore.friendSearchResults.isEmpty)
        try await Task.sleep(for: .milliseconds(500))
        precondition(!searchStore.isSearchingFriends && searchStore.friendSearchResults.count == 1)
        precondition(wire.lastSearch == "alex morgan" && wire.searchCount == count + 1)
        searchStore.friendSearchQuery = "a"
        searchStore.searchForFriends()
        precondition(!searchStore.isSearchingFriends && searchStore.friendSearchResults.isEmpty)

        let photo = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 60)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 48, height: 60))
        }
        func request() -> MomentCreateRequest {
            MomentCreateRequest(author: viewer, drink: nil, venue: nil, location: nil,
                caption: "", taggedFriends: [], isSharedMoment: false,
                media: MomentMedia(photoData: photo, primaryHex: "#000000", secondaryHex: "#111111", symbol: "camera"))
        }
        let first = request()
        let post = try await client.publishMoment(first)
        precondition(post.id == first.id && post.createdAt.timeIntervalSince1970 == 1_793_184_600)
        precondition(post.drink == nil && post.caption.isEmpty && post.media.remotePhotoURL != nil)
        let repeatPost = try await client.publishMoment(first)
        precondition(repeatPost.id == post.id && wire.posts.count == 1 && wire.objects.count == 1)

        wire.mode = .loseInsertResponse
        let lostInsert = request()
        let recovered = try await client.publishMoment(lostInsert)
        precondition(recovered.id == lostInsert.id && wire.posts.count == 2)

        wire.mode = .loseUploadResponse
        let lostUpload = request()
        do { _ = try await client.publishMoment(lostUpload); preconditionFailure("Upload timeout must surface") }
        catch { precondition(wire.posts.count == 2) }
        _ = try await client.publishMoment(lostUpload)
        precondition(wire.posts.count == 3 && wire.objects.count == 3, "Upload retry must reuse its immutable object")

        wire.mode = .emptyInsertResponse
        do { _ = try await client.publishMoment(request()); preconditionFailure("Empty response must never invent a successful post") }
        catch { precondition(wire.posts.count == 3) }

        wire.mode = .failInsert
        let store = AppStore(backend: client)
        store.viewer = viewer
        store.liveActivityPreferences.setEnabled(false)
        store.isPostFlowPresented = true
        store.postDraft.capturedPhotoData = photo
        store.postDraft.caption = "Keep this draft"
        let draftID = store.postDraft.id
        await store.publishDraft()
        precondition(store.postDraft.id == draftID && store.postDraft.capturedPhotoData == photo)
        precondition(store.postDraft.caption == "Keep this draft" && store.postPublishError != nil)
        precondition(store.isPostFlowPresented && store.posts.isEmpty && !store.isPublishingDraft)
        wire.mode = .normal
        let sending = Task { await store.publishDraft() }
        for _ in 0..<100 where !store.isPublishingDraft { await Task.yield() }
        precondition(store.isPublishingDraft)
        await store.publishDraft() // A second tap while the first is awaiting I/O.
        await sending.value
        precondition(store.posts.count == 1 && store.posts[0].id == draftID)
        precondition(!store.isPostFlowPresented && store.postDraft.id != draftID && store.postPublishError == nil)
        precondition(wire.posts.count == 4, "Retry or duplicate taps created multiple posts")
    }
}

nonisolated private final class ReliabilityURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

nonisolated private final class ReliabilityWire: @unchecked Sendable {
    enum Mode { case normal, loseUploadResponse, loseInsertResponse, emptyInsertResponse, failInsert }
    var mode: Mode = .normal
    var posts: [String: [String: Any]] = [:]
    var objects: Set<String> = []
    var lastSearch = ""
    var searchCount = 0
    private let lock = NSLock()

    func respond(to request: URLRequest) throws -> (Int, Data) {
        try lock.withLock {
            let path = request.url!.path
            func json(_ status: Int, _ value: Any) throws -> (Int, Data) {
                (status, try JSONSerialization.data(withJSONObject: value))
            }
            if path.hasSuffix("/rpc/search_profiles") {
                let payload = try JSONSerialization.jsonObject(with: body(request)) as! [String: Any]
                lastSearch = payload["search_query"] as! String
                searchCount += 1
                return try json(200, [["id": "a0cc0000-0000-4000-8000-000000000002", "username": "alex", "display_name": "Alex Morgan"]])
            }
            if path.contains("/storage/v1/object/") {
                if objects.contains(path) { return try json(400, ["message": "The resource already exists"]) }
                objects.insert(path)
                if mode == .loseUploadResponse { mode = .normal; throw URLError(.timedOut) }
                return try json(200, ["Key": path])
            }
            guard path.hasSuffix("/posts") else { throw URLError(.unsupportedURL) }
            if request.httpMethod == "GET" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let id = query.first(where: { $0.name == "id" })!.value!.replacingOccurrences(of: "eq.", with: "").lowercased()
                return try json(200, posts[id].map { [$0] } ?? [])
            }
            precondition(request.value(forHTTPHeaderField: "Prefer") == "resolution=ignore-duplicates,return=representation")
            var row = (try JSONSerialization.jsonObject(with: body(request)) as! [[String: Any]])[0]
            let id = (row["id"] as! String).lowercased()
            if mode == .failInsert { return try json(503, ["message": "Temporary server outage"]) }
            if mode == .emptyInsertResponse { mode = .normal; return try json(200, []) }
            if posts[id] != nil { return try json(200, []) }
            row["created_at"] = "2026-10-28T10:50:00Z"
            posts[id] = row
            if mode == .loseInsertResponse { mode = .normal; throw URLError(.networkConnectionLost) }
            return try json(201, [row])
        }
    }

    private func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
#endif
