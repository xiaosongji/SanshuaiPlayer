import Foundation
import Security

/// Compatibility value used only by the legacy NAS HTTP adapter.
struct ServerConnection: Hashable, Sendable {
  let baseURL: URL
  let username: String
  let password: String
}

enum LegacyKeychainError: LocalizedError {
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      "无法读取旧版安全存储（Keychain \(status)）。"
    }
  }
}

/// Read-only access to the pre-Provider credential item. The migrator deliberately
/// leaves this item untouched so a failed migration never destroys the old login.
struct LegacyKeychainPasswordStore: Sendable {
  private let service: String
  private let account: String

  init(
    service: String = Bundle.main.bundleIdentifier ?? "PrivateAudioLibrary",
    account: String = "server-password"
  ) {
    self.service = service
    self.account = account
  }

  func read() throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
      let password = String(data: data, encoding: .utf8)
    else { throw LegacyKeychainError.keychain(status) }
    return password
  }
}
