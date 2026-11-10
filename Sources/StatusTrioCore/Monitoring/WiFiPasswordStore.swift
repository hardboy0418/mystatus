import Foundation
import Security

/// App-owned Wi-Fi credential storage. Two deliberate boundaries, recorded in
/// `docs/superpowers/specs/2026-09-21-wifi-switching-deferred-design.md`:
///
/// - The store only ever touches Status Trio's own generic-password items. It
///   never reads the system "AirPort network password" items, so no keychain
///   authorization prompt can appear during an ordinary click.
/// - All reads use `kSecUseAuthenticationUIFail`, so a locked keychain or an
///   ACL mismatch surfaces as `.readFailed` instead of a system dialog.
protocol WiFiCredentialStoring: AnyObject {
    /// Resolves a credential only for a user-selected network. Callers must
    /// never invoke this while scanning nearby networks.
    func resolveCredential(for identity: WiFiNetworkIdentity) -> WiFiCredentialLookup
    /// Returns false on a Keychain write failure so the UI can report that the
    /// connection succeeded but the requested remembered-password save did not.
    func save(_ password: String, for identity: WiFiNetworkIdentity) -> Bool
    /// Removes the app's own item for one network ("Forget this network").
    func deleteCredential(for identity: WiFiNetworkIdentity)
    /// Removes every item the app owns. Used when the opt-in feature switch is
    /// turned off and the user chooses to clear stored passwords.
    func deleteAllCredentials()
}

final class KeychainWiFiPasswordStore: WiFiCredentialStoring, @unchecked Sendable {
    /// The bundle identifier is part of this item's ACL discriminator, so the
    /// service string must not be renamed — older builds' leftovers under the
    /// same service stay readable (design measurement 2).
    private let appService: String

    init(appService: String = "com.lingsmbp.StatusTrio.wifi-password") {
        self.appService = appService
    }

    func resolveCredential(for identity: WiFiNetworkIdentity) -> WiFiCredentialLookup {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(readQuery(for: identity) as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let password = String(data: data, encoding: .utf8),
                  !password.isEmpty else {
                return .readFailed
            }
            return .credential(password)
        case errSecItemNotFound:
            return .noCredential
        default:
            return .readFailed
        }
    }

    func save(_ password: String, for identity: WiFiNetworkIdentity) -> Bool {
        guard !password.isEmpty else { return false }
        let update = [kSecValueData as String: Data(password.utf8)]
        let updateStatus = SecItemUpdate(identityQuery(for: identity) as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        let addStatus = SecItemAdd(addAttributes(password, for: identity) as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        if addStatus == errSecDuplicateItem {
            return SecItemUpdate(identityQuery(for: identity) as CFDictionary, update as CFDictionary) == errSecSuccess
        }
        return false
    }

    func deleteCredential(for identity: WiFiNetworkIdentity) {
        SecItemDelete(identityQuery(for: identity) as CFDictionary)
    }

    func deleteAllCredentials() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appService
        ] as CFDictionary)
    }

    private func identityQuery(for identity: WiFiNetworkIdentity) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appService,
            // Preserve raw SSID whitespace and keep security classes distinct.
            kSecAttrAccount as String: "\(identity.security.rawValue):\(identity.ssid)"
        ]
    }

    private func readQuery(for identity: WiFiNetworkIdentity) -> [String: Any] {
        var query = identityQuery(for: identity)
        // Never raise a system prompt from this store.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        return query
    }

    private func addAttributes(_ password: String, for identity: WiFiNetworkIdentity) -> [String: Any] {
        var attributes = identityQuery(for: identity)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return attributes
    }
}

/// Keychain reads and writes are synchronous; the worker keeps them off the
/// main actor, serialized behind the connection flow that issues them.
final class WiFiCredentialWorker: @unchecked Sendable {
    private let store: any WiFiCredentialStoring
    private let queue = DispatchQueue(label: "StatusTrio.WiFiCredentialWorker")

    init(store: any WiFiCredentialStoring) {
        self.store = store
    }

    func resolve(
        _ identity: WiFiNetworkIdentity,
        completion: @escaping @Sendable (WiFiCredentialLookup) -> Void
    ) {
        queue.async { [store] in
            completion(store.resolveCredential(for: identity))
        }
    }

    func save(
        _ password: String,
        for identity: WiFiNetworkIdentity,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [store] in
            completion(store.save(password, for: identity))
        }
    }

    func delete(_ identity: WiFiNetworkIdentity) {
        queue.async { [store] in
            store.deleteCredential(for: identity)
        }
    }

    func deleteAll(completion: @escaping @Sendable () -> Void = {}) {
        queue.async { [store] in
            store.deleteAllCredentials()
            completion()
        }
    }
}
