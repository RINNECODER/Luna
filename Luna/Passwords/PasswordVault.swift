import Foundation
import LocalAuthentication
import Security

/// Saved website logins in the macOS Keychain (internet-password items),
/// scoped per Luna profile. Reading a password requires Touch ID or the
/// Mac password, remembered for a few minutes.
final class PasswordVault {
    static let shared = PasswordVault()

    struct Credential: Identifiable, Hashable {
        var id: String { "\(host)\u{1F}\(username)" }
        let host: String
        let username: String
        let modified: Date?
    }

    enum VaultError: LocalizedError {
        case locked
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .locked: return "Passwords are locked."
            case .keychain(let status): return "Keychain error \(status)."
            }
        }
    }

    /// Four-char creator code marking items Luna created ("Luna").
    private static let creator: UInt32 = 0x4C75_6E61
    private static let unlockDuration: TimeInterval = 5 * 60

    private var unlockedUntil: Date = .distantPast
    private let neverSaveKey = "luna_passwords_never_save"

    nonisolated deinit {}

    // MARK: Hosts

    /// Normalizes a host so www.example.com and example.com share logins.
    static func normalize(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    // MARK: Unlock

    var isUnlocked: Bool { Date() < unlockedUntil }

    /// Asks for Touch ID / the Mac password unless recently unlocked.
    func unlock(reason: String) async -> Bool {
        if isUnlocked { return true }
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 60
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { unlockedUntil = Date().addingTimeInterval(Self.unlockDuration) }
            return ok
        } catch {
            return false
        }
    }

    func lock() { unlockedUntil = .distantPast }

    // MARK: Queries (no secrets)

    private func baseQuery(profile: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrCreator as String: Self.creator,
            kSecAttrSecurityDomain as String: profile.uuidString,
        ]
    }

    func credentials(profile: UUID, host: String? = nil) -> [Credential] {
        var query = baseQuery(profile: profile)
        if let host { query[kSecAttrServer as String] = Self.normalize(host) }
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { attrs in
            guard let server = attrs[kSecAttrServer as String] as? String else { return nil }
            return Credential(host: server, username: attrs[kSecAttrAccount as String] as? String ?? "",
                              modified: attrs[kSecAttrModificationDate as String] as? Date)
        }
        .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    // MARK: Secrets

    /// Returns the password only while unlocked.
    func password(for credential: Credential, profile: UUID) throws -> String? {
        guard isUnlocked else { throw VaultError.locked }
        var query = baseQuery(profile: profile)
        query[kSecAttrServer as String] = credential.host
        query[kSecAttrAccount as String] = credential.username
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    /// Whether `password` is already what's stored (no unlock needed: compares in Keychain).
    func isSaved(host: String, username: String, password: String, profile: UUID) -> Bool {
        var query = baseQuery(profile: profile)
        query[kSecAttrServer as String] = Self.normalize(host)
        query[kSecAttrAccount as String] = username
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return false }
        return String(data: data, encoding: .utf8) == password
    }

    func save(host: String, username: String, password: String, profile: UUID) throws {
        let server = Self.normalize(host)
        var match = baseQuery(profile: profile)
        match[kSecAttrServer as String] = server
        match[kSecAttrAccount as String] = username
        let data = Data(password.utf8)
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw VaultError.keychain(update) }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
        add[kSecAttrLabel as String] = "\(server) (Luna)"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    func delete(_ credential: Credential, profile: UUID) throws {
        var query = baseQuery(profile: profile)
        query[kSecAttrServer as String] = credential.host
        query[kSecAttrAccount as String] = credential.username
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }

    // MARK: Never save

    func isNeverSave(_ host: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: neverSaveKey) ?? []).contains(Self.normalize(host))
    }

    func setNeverSave(_ host: String, _ never: Bool) {
        var list = Set(UserDefaults.standard.stringArray(forKey: neverSaveKey) ?? [])
        if never { list.insert(Self.normalize(host)) } else { list.remove(Self.normalize(host)) }
        UserDefaults.standard.set(Array(list).sorted(), forKey: neverSaveKey)
    }

    // MARK: Import

    struct ImportResult {
        var imported = 0
        var skipped = 0
    }

    /// Imports Apple Passwords' CSV export (Title,URL,Username,Password,Notes,OTPAuth),
    /// which uses the same columns as Chrome's (name,url,username,password).
    func importCSV(_ text: String, profile: UUID) throws -> ImportResult {
        var result = ImportResult()
        let rows = Self.parseCSV(text)
        guard let header = rows.first?.map({ $0.lowercased() }),
              let urlCol = header.firstIndex(of: "url"),
              let userCol = header.firstIndex(of: "username"),
              let passCol = header.firstIndex(of: "password") else {
            throw VaultError.keychain(errSecParam)
        }
        for row in rows.dropFirst() {
            guard row.count > max(urlCol, userCol, passCol) else { result.skipped += 1; continue }
            let rawURL = row[urlCol].trimmingCharacters(in: .whitespaces)
            let url = URL(string: rawURL.contains("://") ? rawURL : "https://\(rawURL)")
            guard let host = url?.host, !host.isEmpty, !row[passCol].isEmpty else { result.skipped += 1; continue }
            try save(host: host, username: row[userCol], password: row[passCol], profile: profile)
            result.imported += 1
        }
        return result
    }

    /// RFC 4180 CSV (quoted fields, escaped quotes, newlines inside quotes).
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
