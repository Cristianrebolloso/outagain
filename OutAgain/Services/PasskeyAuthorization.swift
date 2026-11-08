import AuthenticationServices
import Foundation
import UIKit

struct AccountPasskey: Decodable, Identifiable {
    let id: UUID
    let friendly_name: String?
    let created_at: Date
    let last_used_at: Date?

    var displayName: String { friendly_name ?? "Passkey" }
}

enum PasskeyError: LocalizedError {
    case cancelled
    case invalidOptions
    case noWindow

    var errorDescription: String? {
        switch self {
        case .cancelled: return nil
        case .invalidOptions: return "Couldn't start passkey sign-in. Please try again."
        case .noWindow: return "Return to Out Again and try again."
        }
    }
}

struct PasskeyOptions<Options: Decodable>: Decodable {
    let challenge_id: UUID
    let options: Options
}

struct PasskeyAuthenticationOptions: Decodable {
    let challenge: String
    let rpId: String
    let allowCredentials: [PasskeyDescriptor]?
}

struct PasskeyRegistrationOptions: Decodable {
    struct RelyingParty: Decodable { let id: String }
    struct User: Decodable { let id: String; let name: String }
    let challenge: String
    let rp: RelyingParty
    let user: User
    let excludeCredentials: [PasskeyDescriptor]?
}

struct PasskeyDescriptor: Decodable { let id: String }

struct PasskeyCredential: Encodable {
    struct Response: Encodable {
        let clientDataJSON: String
        var attestationObject: String?
        var authenticatorData: String?
        var signature: String?
        var userHandle: String?
        var transports: [String]?
    }
    let id: String
    let rawId: String
    let type = "public-key"
    let authenticatorAttachment = "platform"
    let clientExtensionResults: [String: String] = [:]
    let response: Response
}

struct PasskeyVerifyRequest: Encodable {
    let challenge_id: UUID
    let credential: PasskeyCredential
}

enum PasskeyEncoding {
    static func decode(_ value: String) throws -> Data {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { throw PasskeyError.invalidOptions }
        return data
    }

    static func encode(_ value: Data) -> String {
        value.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Retained across the system sheet so its weak delegate and continuation stay alive.
@MainActor
final class PasskeyAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<PasskeyCredential, Error>?
    private var controller: ASAuthorizationController?
    private let window: UIWindow

    init(window: UIWindow) { self.window = window }

    static func activeWindow() throws -> UIWindow {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows).first(where: \.isKeyWindow)
        else { throw PasskeyError.noWindow }
        return window
    }

    func authenticate(_ options: PasskeyAuthenticationOptions) async throws -> PasskeyCredential {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.rpId)
        let request = provider.createCredentialAssertionRequest(challenge: try PasskeyEncoding.decode(options.challenge))
        request.userVerificationPreference = .required
        if let descriptors = options.allowCredentials {
            request.allowedCredentials = try descriptors.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: try PasskeyEncoding.decode($0.id))
            }
        }
        return try await perform(request)
    }

    func register(_ options: PasskeyRegistrationOptions) async throws -> PasskeyCredential {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.rp.id)
        let request = provider.createCredentialRegistrationRequest(
            challenge: try PasskeyEncoding.decode(options.challenge),
            name: options.user.name,
            userID: try PasskeyEncoding.decode(options.user.id)
        )
        request.userVerificationPreference = .required
        request.excludedCredentials = try (options.excludeCredentials ?? []).map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: try PasskeyEncoding.decode($0.id))
        }
        return try await perform(request)
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> PasskeyCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let credential: PasskeyCredential
        if let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            let id = PasskeyEncoding.encode(assertion.credentialID)
            credential = PasskeyCredential(id: id, rawId: id, response: .init(
                clientDataJSON: PasskeyEncoding.encode(assertion.rawClientDataJSON),
                authenticatorData: PasskeyEncoding.encode(assertion.rawAuthenticatorData),
                signature: PasskeyEncoding.encode(assertion.signature),
                userHandle: PasskeyEncoding.encode(assertion.userID)
            ))
        } else if let registration = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
                  let attestation = registration.rawAttestationObject {
            let id = PasskeyEncoding.encode(registration.credentialID)
            credential = PasskeyCredential(id: id, rawId: id, response: .init(
                clientDataJSON: PasskeyEncoding.encode(registration.rawClientDataJSON),
                attestationObject: PasskeyEncoding.encode(attestation),
                transports: ["internal", "hybrid"]
            ))
        } else {
            finish(.failure(PasskeyError.invalidOptions))
            return
        }
        finish(.success(credential))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            finish(.failure(PasskeyError.cancelled))
        } else {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<PasskeyCredential, Error>) {
        let pending = continuation
        continuation = nil
        controller = nil
        pending?.resume(with: result)
    }
}
