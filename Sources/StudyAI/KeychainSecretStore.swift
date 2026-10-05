#if canImport(Security)
import Foundation
import StudyCore

/// API keys in the macOS/iOS Keychain (the same service as the Moodle token). Drawing a view only ever calls
/// `exists`, which doesn't trigger a Keychain password prompt.
public struct KeychainSecretStore: SecretStore {
    public init() {}
    public func get(_ account: String) -> String? { Keychain.get(account) }
    public func set(_ value: String, account: String) { Keychain.set(value, account: account) }
    public func delete(_ account: String) { Keychain.delete(account) }
    public func exists(_ account: String) -> Bool { Keychain.exists(account) }
}
#endif
