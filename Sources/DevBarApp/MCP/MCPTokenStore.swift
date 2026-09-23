import Foundation
import Security

/// The HTTP credential lives in the login Keychain, outside config.json and its backup.
protocol MCPTokenProviding {
    func load() throws -> String?
    func loadOrCreate() throws -> String
    func rotate() throws -> String
}

struct MCPTokenStore: MCPTokenProviding {
    private let service = "com.calo.DevBar.MCP"
    private let account = "localhost"

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw TokenStoreError.keychain(status)
        }
        return token
    }

    func loadOrCreate() throws -> String {
        if let existing = try load() { return existing }
        let token = try generate()
        try save(token)
        return token
    }

    func rotate() throws -> String {
        let token = try generate()
        try save(token)
        return token
    }

    private func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw TokenStoreError.randomFailed
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func save(_ token: String) throws {
        let data = Data(token.utf8)
        let existing = try load()
        let status: OSStatus
        if existing == nil {
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            status = SecItemAdd(attributes as CFDictionary, nil)
        } else {
            status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private enum TokenStoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case randomFailed

    var errorDescription: String? {
        switch self {
        case let .keychain(status): "Could not access the DevBar MCP token in Keychain (\(status))."
        case .randomFailed: "Could not generate a secure DevBar MCP token."
        }
    }
}
