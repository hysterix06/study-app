import Foundation
import Security

/// Secrets (calendar feed URLs, Moodle token) live in the macOS Keychain, never in the database or logs.
///
/// A Keychain item trusts only the build that saved it, so macOS asks for the Mac's password whenever another build
/// reads it, once per read. Each secret is therefore read at most once per launch, and the app (`adoptsItems`) saves
/// what it read again under its own signature. With a development certificate that signature survives rebuilds, so
/// the password is asked once, not after every build.
public enum Keychain {
    /// STUDY_KEYCHAIN_SERVICE keeps development runs (screenshots, a second copy) away from the real secrets.
    public static let service = ProcessInfo.processInfo.environment["STUDY_KEYCHAIN_SERVICE"] ?? "com.studytracker.app"

    /// Set by the app at launch. The MCP server leaves it off, so the two never take an item from each other.
    nonisolated(unsafe) public static var adoptsItems = false

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    /// Secrets the student refused this launch: a background sync doesn't ask again every half hour.
    nonisolated(unsafe) private static var refused: Set<String> = []

    public static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query = baseQuery(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(add as CFDictionary, nil) == errSecSuccess, let owner = signer { UserDefaults.standard.set(owner, forKey: ownerKey(account)) }
        }
        lock.withLock { cache[account] = value; refused.remove(account) }
    }

    public static func get(_ account: String) -> String? {
        let (hit, wasRefused) = lock.withLock { (cache[account], refused.contains(account)) }
        if let hit { return hit }
        if wasRefused { return nil }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, let value = String(data: data, encoding: .utf8) else {
            if [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed].contains(status) {
                lock.withLock { _ = refused.insert(account) }
            }
            return nil
        }
        lock.withLock { cache[account] = value }
        if adoptsItems { adopt(value, account: account) }
        return value
    }

    /// Whether a secret is stored, without reading it. Only the secret itself is behind the Keychain's access
    /// check, so this never asks for the Mac's password and is safe to call while drawing views.
    public static func exists(_ account: String) -> Bool {
        if lock.withLock({ cache[account] }) != nil { return true }
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    public static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        lock.withLock { cache[account] = nil; refused.remove(account) }
        UserDefaults.standard.removeObject(forKey: ownerKey(account))
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Saves a secret this build just read again, so the item trusts this build from now on. Skipped when this build
    /// (or one with the same signature) already saved it. Deleting an item never asks for the password.
    private static func adopt(_ value: String, account: String) {
        guard let owner = signer, UserDefaults.standard.string(forKey: ownerKey(account)) != owner else { return }
        let query = baseQuery(account)
        guard SecItemDelete(query as CFDictionary) == errSecSuccess else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { UserDefaults.standard.set(owner, forKey: ownerKey(account)) }
    }

    private static func ownerKey(_ account: String) -> String { "keychain.owner.\(service).\(account)" }

    /// What a Keychain item checks a build against: its designated requirement. For a certificate-signed build that
    /// names the bundle ID and the certificate, so it stays the same across rebuilds; an ad hoc build's is its code hash.
    private static let signer: String? = {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }()
}
