import AppKit
import Foundation
import Security

/// Where keys grabbed by Luna go: a Keychain generic password (service "Luna API Keys",
/// account "<service>/<key name>", visible in Keychain Access) plus the clipboard.
/// Values only ever arrive from `SecretCapture` and leave through `copy`; callers outside get
/// an opaque handle like `‹secret:3›`. Nothing here logs or returns a value to a model.
final class SecretVault {
    static let shared = SecretVault()
    static let defaultService = "Luna API Keys"
    static let autoClearKey = "luna_grab_clipboard_autoclear"
    static let autoClearSeconds: TimeInterval = 90

    struct Item: Equatable, Identifiable {
        let account: String
        let created: Date?
        var id: String { account }
    }

    struct Saved: Equatable {
        let handle: String
        /// "Luna API Keys / <account>", as Keychain Access shows it.
        let keychainItem: String
        let account: String
    }

    enum VaultError: LocalizedError {
        case keychain(OSStatus)
        var errorDescription: String? {
            if case .keychain(let s) = self { return "Keychain error \(s)." }
            return nil
        }
    }

    let service: String
    let pasteboard: NSPasteboard
    private var nextHandle = 1

    init(service: String = SecretVault.defaultService, pasteboard: NSPasteboard = .general) {
        self.service = service
        self.pasteboard = pasteboard
    }

    /// Saves (or replaces) the value, copies it, and returns a handle. The value is not kept in memory.
    func store(_ value: String, account: String) throws -> Saved {
        let data = Data(value.utf8)
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(service): \(account)"
            add[kSecAttrDescription as String] = "API key saved by Luna"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw VaultError.keychain(status) }
        } else if update != errSecSuccess {
            throw VaultError.keychain(update)
        }
        putOnPasteboard(value)
        let handle = "‹secret:\(nextHandle)›"
        nextHandle += 1
        return Saved(handle: handle, keychainItem: "\(service) / \(account)", account: account)
    }

    /// Saved keys without their values, newest first.
    func items() -> [Item] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { attrs in
            (attrs[kSecAttrAccount as String] as? String).map {
                Item(account: $0, created: attrs[kSecAttrCreationDate as String] as? Date)
            }
        }
        .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    /// Copies a saved key to the clipboard (Settings → Copy).
    @discardableResult
    func copy(account: String) -> Bool {
        guard let value = value(account: account) else { return false }
        putOnPasteboard(value)
        return true
    }

    func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    /// The stored value; only for `copy` and tests that compare it. Never return it to a model.
    func value(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Optional (Settings, default off): clears the clipboard after 90 s unless something else was copied.
    private func putOnPasteboard(_ value: String) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        guard UserDefaults.standard.bool(forKey: Self.autoClearKey) else { return }
        let count = pasteboard.changeCount
        let board = pasteboard
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoClearSeconds) {
            if board.changeCount == count { board.clearContents() }
        }
    }
}
