import Foundation

struct SupabaseEnvironment {
    var projectURL: String
    var anonKey: String
    var storageBucket: String
    var avatarBucket: String
    var inviteBaseURL: String
    var passkeyRelyingPartyID: String = "outagain.app"

    static let embedded = SupabaseEnvironment(
        projectURL: "https://xissvzlusznqpxvwnwpu.supabase.co",
        anonKey: "sb_publishable_Pkns19omXhRZBw1A-2_9-A_t1wZ9Zd_",
        storageBucket: "moments",
        avatarBucket: "avatars",
        inviteBaseURL: "https://outagain.app/invite"
    )

    static let placeholder = SupabaseEnvironment(
        projectURL: "https://replace-me.supabase.co",
        anonKey: "replace-with-anon-key",
        storageBucket: "moments",
        avatarBucket: "avatars",
        inviteBaseURL: "https://outagain.app/invite"
    )

    static func current(bundle: Bundle = .main) -> SupabaseEnvironment {
        var environment = embedded
        environment.projectURL = value(
            forKeys: ["SUPABASE_URL", "SupabaseURL"],
            in: bundle
        ) ?? environment.projectURL
        environment.anonKey = value(
            forKeys: ["SUPABASE_PUBLISHABLE_KEY", "SUPABASE_ANON_KEY", "SupabaseAnonKey"],
            in: bundle
        ) ?? environment.anonKey
        environment.storageBucket = value(
            forKeys: ["SUPABASE_STORAGE_BUCKET", "SupabaseStorageBucket"],
            in: bundle
        ) ?? environment.storageBucket
        environment.avatarBucket = value(
            forKeys: ["SUPABASE_AVATAR_BUCKET", "SupabaseAvatarBucket"],
            in: bundle
        ) ?? environment.avatarBucket
        environment.inviteBaseURL = value(
            forKeys: ["OUTAGAIN_INVITE_BASE_URL", "OutAgainInviteBaseURL"],
            in: bundle
        ) ?? environment.inviteBaseURL
        environment.passkeyRelyingPartyID = value(
            forKeys: ["OUTAGAIN_PASSKEY_RP_ID"], in: bundle
        ) ?? environment.passkeyRelyingPartyID
        return environment
    }

    var isConfigured: Bool {
        !projectURL.contains("replace-me") && !anonKey.contains("replace-with")
    }

    var authBaseURL: URL {
        URL(string: normalizedProjectURL + "/auth/v1")!
    }

    var restBaseURL: URL {
        URL(string: normalizedProjectURL + "/rest/v1")!
    }

    var functionsBaseURL: URL {
        URL(string: normalizedProjectURL + "/functions/v1")!
    }

    var storageBaseURL: URL {
        URL(string: normalizedProjectURL + "/storage/v1")!
    }

    func authURL(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: authBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url!
    }

    func restURL(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: restBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url!
    }

    func functionURL(name: String) -> URL {
        functionsBaseURL.appendingPathComponent(name)
    }

    func storageObjectURL(bucket: String, objectPath: String, isPublic: Bool = false) -> URL {
        var url = storageBaseURL
            .appendingPathComponent("object")

        if isPublic {
            url.appendPathComponent("public")
        }

        url.appendPathComponent(bucket)

        for segment in objectPath.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }

        return url
    }

    private static func value(forKeys keys: [String], in bundle: Bundle) -> String? {
        for key in keys {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }

        return nil
    }

    private var normalizedProjectURL: String {
        var value = projectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
