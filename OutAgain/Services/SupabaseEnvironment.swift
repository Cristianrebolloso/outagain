import Foundation

struct SupabaseEnvironment {
    var projectURL: String
    var anonKey: String
    var storageBucket: String

    static let placeholder = SupabaseEnvironment(
        projectURL: "https://replace-me.supabase.co",
        anonKey: "replace-with-anon-key",
        storageBucket: "moments"
    )

    var isConfigured: Bool {
        !projectURL.contains("replace-me") && !anonKey.contains("replace-with")
    }
}

protocol SocialBackendClient {
    func createInviteLink(for username: String) -> URL
}

struct MockSocialBackendClient: SocialBackendClient {
    let environment: SupabaseEnvironment

    func createInviteLink(for username: String) -> URL {
        let slug = UUID().uuidString.prefix(8).lowercased()
        return URL(string: "https://outagain.app/invite/\(username)-\(slug)")!
    }
}
