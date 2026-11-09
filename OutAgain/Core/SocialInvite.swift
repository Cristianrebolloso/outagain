import Foundation

/// A server-issued, expiring invitation. Opening it never changes friendships.
struct SocialInvite: Codable, Hashable, Identifiable {
    var token: String
    var inviterID: UUID
    var inviterName: String
    var inviterUsername: String
    var groupID: UUID?
    var groupName: String?
    var expiresAt: Date

    var id: String { token }
    var url: URL {
        var components = URLComponents(string: "https://cristianrebolloso.github.io/invite/")!
        components.queryItems = [URLQueryItem(name: "code", value: token)]
        return components.url!
    }

    enum CodingKeys: String, CodingKey {
        case token
        case inviterID = "inviter_id", inviterName = "inviter_name"
        case inviterUsername = "inviter_username", groupID = "group_id"
        case groupName = "group_name", expiresAt = "expires_at"
    }
}

struct SocialInviteAcceptance: Codable, Hashable {
    var inviterID: UUID
    var groupID: UUID?
    var friendshipStatus: String

    enum CodingKeys: String, CodingKey {
        case inviterID = "inviter_id", groupID = "group_id"
        case friendshipStatus = "friendship_status"
    }
}

enum SocialInviteCode {
    static func normalized(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let code: String
        if let components = URLComponents(string: value),
           let scheme = components.scheme?.lowercased(),
           ["https", "outagain"].contains(scheme) {
            let host = components.host?.lowercased()
            let allowedHost = scheme == "outagain" ? host == "invite"
                : ["cristianrebolloso.github.io", "outagain.app", "www.outagain.app"].contains(host ?? "")
            guard allowedHost,
                  scheme == "outagain" || components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "invite",
                  let queryCode = components.queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
            code = queryCode.lowercased()
        } else {
            code = value.lowercased()
        }
        guard code.count == 32, code.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return code
    }
}
