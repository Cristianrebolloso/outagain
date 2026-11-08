import Foundation

/// Resolves the shortcut `1` / `1` email+password pair into locally configured
/// debug credentials.
///
/// The app no longer stores any real developer email/password in source
/// control. To enable the shortcut locally, set
/// `OUTAGAIN_DEV_SHORTCUT_EMAIL` and `OUTAGAIN_DEV_SHORTCUT_PASSWORD`
/// either as scheme environment variables or Info.plist keys on your own
/// machine. Nothing in the backend treats this account specially — it still
/// signs in through the normal auth endpoint and hits the same RLS rules as
/// any other user.
enum DeveloperTestAccount {
    /// Short-circuit string the developer types in either auth field.
    static let shortcutToken = "1"

    /// Whether the `1`/`1` shortcut is enabled.
    ///
    /// Enabled only for Debug builds, and only when local credentials have
    /// been configured outside the repo. A distributed Release binary will
    /// never attempt to resolve the shortcut.
    static var isEnabled: Bool {
        #if DEBUG
        return localCredentials != nil
        #else
        return false
        #endif
    }

    /// Returns the real credentials if both fields are the shortcut token,
    /// otherwise nil. The caller falls back to the user's literal input.
    static func resolve(email rawEmail: String, password rawPassword: String) -> (email: String, password: String)? {
        guard let localCredentials else { return nil }

        let trimmedEmail = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = rawPassword.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedEmail == shortcutToken, trimmedPassword == shortcutToken else {
            return nil
        }

        return localCredentials
    }

    private static var localCredentials: (email: String, password: String)? {
        #if DEBUG
        guard let email = configuredValue(for: "OUTAGAIN_DEV_SHORTCUT_EMAIL"),
              let password = configuredValue(for: "OUTAGAIN_DEV_SHORTCUT_PASSWORD") else {
            return nil
        }
        return (email: email, password: password)
        #else
        return nil
        #endif
    }

    private static func configuredValue(for key: String) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment[key] {
            let trimmed = environmentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let bundleValue = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmed = bundleValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }
}
