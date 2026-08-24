import Foundation
import Security

protocol CredentialVault: Sendable {
  func save(_ credentials: ProviderCredentials, serverID: UUID) throws
  func read(serverID: UUID) throws -> ProviderCredentials?
  func delete(serverID: UUID) throws
}

enum CredentialVaultMode: String, Sendable {
  case keychain
  case ephemeralSimulator
}

protocol CredentialVaultModeProviding: Sendable {
  var mode: CredentialVaultMode { get }
}

enum CredentialVaultFactory {
  static func live() -> any CredentialVault {
    #if targetEnvironment(simulator)
      return SimulatorFallbackCredentialVault(primary: KeychainCredentialVault())
    #else
      return KeychainCredentialVault()
    #endif
  }
}

struct KeychainCredentialVault: CredentialVault, Sendable {
  private let service: String

  init(
    service: String = (Bundle.main.bundleIdentifier ?? "UniversalPersonalMusic") + ".credentials"
  ) {
    self.service = service
  }

  func save(_ credentials: ProviderCredentials, serverID: UUID) throws {
    let payload = try JSONEncoder().encode(
      CredentialPayload(
        password: credentials.password, token: credentials.token,
        remoteUserID: credentials.remoteUserID))
    let query = baseQuery(serverID: serverID)
    let attributes: [String: Any] = [
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: payload,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw MusicSourceError.keychainFailure(status) }
    var insertion = query
    insertion.merge(attributes) { _, new in new }
    let addStatus = SecItemAdd(insertion as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw MusicSourceError.keychainFailure(addStatus) }
  }

  func read(serverID: UUID) throws -> ProviderCredentials? {
    var query = baseQuery(serverID: serverID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data else {
      throw MusicSourceError.keychainFailure(status)
    }
    let payload = try JSONDecoder().decode(CredentialPayload.self, from: data)
    return ProviderCredentials(
      password: payload.password, token: payload.token, remoteUserID: payload.remoteUserID)
  }

  func delete(serverID: UUID) throws {
    let status = SecItemDelete(baseQuery(serverID: serverID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MusicSourceError.keychainFailure(status)
    }
  }

  private func baseQuery(serverID: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: serverID.uuidString.lowercased(),
    ]
  }
}

/// Keeps production credentials in Keychain, but lets an unsigned Simulator session continue
/// after Security has actually returned `errSecMissingEntitlement`. The fallback is process-only.
final class SimulatorFallbackCredentialVault: CredentialVault, CredentialVaultModeProviding,
  @unchecked Sendable
{
  private let primary: any CredentialVault
  private let ephemeral: InMemoryCredentialVault
  private let allowsFallback: Bool
  private let lock = NSLock()
  private var currentMode: CredentialVaultMode = .keychain

  init(
    primary: any CredentialVault, ephemeral: InMemoryCredentialVault = .init(),
    allowsFallback: Bool = true
  ) {
    self.primary = primary
    self.ephemeral = ephemeral
    self.allowsFallback = allowsFallback
  }

  var mode: CredentialVaultMode { lock.withLock { currentMode } }

  func save(_ credentials: ProviderCredentials, serverID: UUID) throws {
    if mode == .ephemeralSimulator {
      try ephemeral.save(credentials, serverID: serverID)
      return
    }
    do {
      try primary.save(credentials, serverID: serverID)
    } catch {
      guard shouldFallback(for: error) else { throw error }
      activateFallback()
      try ephemeral.save(credentials, serverID: serverID)
    }
  }

  func read(serverID: UUID) throws -> ProviderCredentials? {
    if mode == .ephemeralSimulator { return try ephemeral.read(serverID: serverID) }
    do {
      return try primary.read(serverID: serverID)
    } catch {
      guard shouldFallback(for: error) else { throw error }
      activateFallback()
      return try ephemeral.read(serverID: serverID)
    }
  }

  func delete(serverID: UUID) throws {
    if mode == .ephemeralSimulator {
      try ephemeral.delete(serverID: serverID)
      return
    }
    do {
      try primary.delete(serverID: serverID)
    } catch {
      guard shouldFallback(for: error) else { throw error }
      activateFallback()
      try ephemeral.delete(serverID: serverID)
    }
  }

  private func shouldFallback(for error: Error) -> Bool {
    guard allowsFallback else { return false }
    guard case MusicSourceError.keychainFailure(let status) = error else { return false }
    return status == errSecMissingEntitlement
  }

  private func activateFallback() {
    lock.withLock { currentMode = .ephemeralSimulator }
  }
}

private struct CredentialPayload: Codable {
  let password: String?
  let token: String?
  let remoteUserID: String?
}

final class InMemoryCredentialVault: CredentialVault, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID: ProviderCredentials] = [:]
  func save(_ credentials: ProviderCredentials, serverID: UUID) throws {
    lock.withLock { values[serverID] = credentials }
  }
  func read(serverID: UUID) throws -> ProviderCredentials? { lock.withLock { values[serverID] } }
  func delete(serverID: UUID) throws { _ = lock.withLock { values.removeValue(forKey: serverID) } }
}
