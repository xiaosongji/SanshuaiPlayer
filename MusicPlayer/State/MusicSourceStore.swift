import Foundation
import Observation

@MainActor
@Observable
final class MusicSourceStore {
  static let localServerID = UUID(uuidString: "00000000-0000-5000-8000-000000000001")!
  private(set) var servers: [MusicServer] = []
  private(set) var activeServerID: UUID?
  private(set) var provider: (any MusicSourceProvider)?
  private(set) var isRestoring = true
  private(set) var lastMigrationReport: String?
  private(set) var lastCredentialIssueAt: Date?
  private(set) var cacheSizeBytes: Int64 = 0
  private(set) var mediaCacheSizeBytes: Int64 = 0
  private(set) var resourceCacheSizeBytes: Int64 = 0

  private let repository: any ServerRepository
  private let vault: any CredentialVault
  private let factory: ProviderFactory
  private let cache: MusicCache
  private let defaults: UserDefaults

  init(
    repository: any ServerRepository = FileServerRepository(),
    vault: any CredentialVault = CredentialVaultFactory.live(), factory: ProviderFactory = .live,
    cache: MusicCache = .shared, defaults: UserDefaults = .standard
  ) {
    self.repository = repository
    self.vault = vault
    self.factory = factory
    self.cache = cache
    self.defaults = defaults
  }

  var activeServer: MusicServer? { servers.first { $0.id == activeServerID } }
  var hasReliableActiveSource: Bool {
    guard provider != nil, let activeServer else { return false }
    if activeServer.sourceType == .local { return true }
    return activeServer.lastConnectedAt != nil
  }
  var credentialVaultMode: CredentialVaultMode {
    (vault as? any CredentialVaultModeProviding)?.mode ?? .keychain
  }
  var isUsingEphemeralSimulatorCredentials: Bool {
    credentialVaultMode == .ephemeralSimulator
  }

  func restore() async {
    defer { isRestoring = false }
    do {
      let repository = repository
      var state = try await Task.detached(priority: .userInitiated) {
        try repository.load()
      }.value
      try? await cache.prepare()
      if state.servers.isEmpty, let migrated = try migrateLegacyConnection() {
        state.servers = [migrated]
        state.activeServerID = migrated.id
        try repository.save(state)
      }
      servers = state.servers
      activeServerID = state.activeServerID ?? state.servers.first?.id
      try activateProvider()
      updateCredentialStateMessageIfNeeded()
      await refreshCacheUsage()
      if let activeServerID {
        try? await cache.store(
          LoginCacheState(authenticated: provider != nil, checkedAt: Date()),
          serverID: activeServerID, namespace: .loginState, key: "current")
      }
    } catch {
      lastMigrationReport = String(
        localized: "恢复音乐源失败：\(MusicSourceError.map(error).localizedDescription)")
    }
  }

  func test(_ server: MusicServer, credentials: ProviderCredentials) async throws -> MusicServerInfo
  {
    var server = server
    server.baseURL = MusicServerURLNormalizer.normalize(server.baseURL, for: server.sourceType)
    let candidate = try factory.make(server, credentials)
    try await candidate.authenticate()
    let info = try await candidate.fetchServerInfo()
    try vault.save(await candidate.refreshedCredentials() ?? credentials, serverID: server.id)
    updateCredentialStateMessageIfNeeded()
    try? await cache.store(
      LoginCacheState(authenticated: true, checkedAt: Date()), serverID: server.id,
      namespace: .loginState, key: "current")
    return info
  }

  func testConnection(serverID: UUID) async throws -> MusicServerInfo {
    guard let index = servers.firstIndex(where: { $0.id == serverID }) else {
      throw MusicSourceError.invalidAddress
    }
    let credentials = try vault.read(serverID: serverID) ?? .init()
    do {
      let info = try await test(servers[index], credentials: credentials)
      servers[index].status = .online
      servers[index].lastConnectedAt = Date()
      servers[index].lastError = nil
      try persist()
      return info
    } catch {
      servers[index].status = .offline
      servers[index].lastError = MusicSourceError.map(error).localizedDescription
      try? persist()
      throw error
    }
  }

  func libraries(serverID: UUID) async throws -> [MusicLibrary] {
    guard let server = servers.first(where: { $0.id == serverID }) else {
      throw MusicSourceError.invalidAddress
    }
    let credentials = try vault.read(serverID: serverID) ?? .init()
    let candidate = try factory.make(server, credentials)
    try await candidate.authenticate()
    return try await candidate.fetchLibraries()
  }

  func setDefaultLibrary(serverID: UUID, libraryID: String?) throws {
    guard let index = servers.firstIndex(where: { $0.id == serverID }) else {
      throw MusicSourceError.invalidAddress
    }
    servers[index].defaultLibraryID = libraryID
    if activeServerID == serverID { try activateProvider() }
    try persist()
  }

  func recordConnectionResult(serverID: UUID, error: MusicSourceError?) {
    guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
    if let error {
      servers[index].status = .offline
      servers[index].lastError = error.localizedDescription
    } else {
      servers[index].status = .online
      servers[index].lastConnectedAt = Date()
      servers[index].lastError = nil
    }
    try? persist()
  }

  func add(_ server: MusicServer, credentials: ProviderCredentials) async throws {
    var saved = server
    saved.baseURL = MusicServerURLNormalizer.normalize(saved.baseURL, for: saved.sourceType)
    let candidate = try factory.make(saved, credentials)
    try await candidate.authenticate()
    let info = try await candidate.fetchServerInfo()
    saved.status = .online
    saved.lastConnectedAt = Date()
    saved.lastError = nil
    if let refreshed = await candidate.refreshedCredentials() {
      try vault.save(refreshed, serverID: server.id)
    } else {
      try vault.save(credentials, serverID: server.id)
    }
    updateCredentialStateMessageIfNeeded()
    servers.append(saved)
    activeServerID = saved.id
    provider = candidate
    try persist()
    lastMigrationReport = String(localized: "已连接 \(info.name)")
  }

  func addLocalSource() async throws {
    if servers.contains(where: { $0.id == Self.localServerID }) {
      try select(Self.localServerID)
      return
    }
    let server = MusicServer(
      id: Self.localServerID, name: String(localized: "本机音乐"),
      baseURL: URL(string: "localmusic://library")!,
      sourceType: .local, username: "", usesHTTPS: false, wifiQuality: .original,
      transcodingEnabled: false, status: .online,
      lastConnectedAt: Date())
    let candidate = try factory.make(server, .init())
    try await candidate.authenticate()
    servers.append(server)
    activeServerID = server.id
    provider = candidate
    try persist()
    lastMigrationReport = String(localized: "已启用本机音乐。导入的歌曲会复制到 App 的私有资料库。")
  }

  @discardableResult
  func importLocalFiles(_ urls: [URL]) async throws -> Int {
    try await importLocalFilesDetailed(urls).importedCount
  }

  func importLocalFilesDetailed(_ urls: [URL]) async throws -> LocalMusicImportReport {
    if !servers.contains(where: { $0.id == Self.localServerID }) {
      try await addLocalSource()
    } else if activeServerID != Self.localServerID {
      try select(Self.localServerID)
    }
    guard let local = provider as? LocalMusicProvider else {
      throw MusicSourceError.unsupportedFeature
    }
    return try await local.importFilesDetailed(urls)
  }

  func importLocalFolder(_ url: URL) async throws -> LocalMusicImportReport {
    if !servers.contains(where: { $0.id == Self.localServerID }) {
      try await addLocalSource()
    } else if activeServerID != Self.localServerID {
      try select(Self.localServerID)
    }
    guard let local = provider as? LocalMusicProvider else {
      throw MusicSourceError.unsupportedFeature
    }
    return try await local.importFolder(url)
  }

  func update(_ server: MusicServer, credentials: ProviderCredentials?) async throws {
    guard let index = servers.firstIndex(where: { $0.id == server.id }) else {
      throw MusicSourceError.invalidAddress
    }
    var updated = server
    updated.baseURL = MusicServerURLNormalizer.normalize(updated.baseURL, for: updated.sourceType)
    guard updated.sourceType == .local || updated.baseURL.scheme?.lowercased() == "https" else {
      throw MusicSourceError.invalidAddress
    }
    let credentialsToTest: ProviderCredentials
    if let credentials {
      credentialsToTest = credentials
    } else {
      credentialsToTest = try vault.read(serverID: updated.id) ?? .init()
    }
    _ = try await test(updated, credentials: credentialsToTest)
    servers[index] = updated
    try persist()
    if activeServerID == updated.id { try activateProvider() }
  }

  func select(_ serverID: UUID) throws {
    guard servers.contains(where: { $0.id == serverID }) else { return }
    activeServerID = serverID
    try activateProvider()
    try persist()
  }

  func remove(_ serverID: UUID, deleteCache: Bool) async throws {
    servers.removeAll { $0.id == serverID }
    try vault.delete(serverID: serverID)
    if deleteCache { try await cache.clear(serverID: serverID) }
    if activeServerID == serverID {
      activeServerID = servers.first?.id
      try activateProvider()
    }
    try persist()
    await refreshCacheUsage()
  }

  func refreshCacheUsage() async {
    let usage = await cache.usage()
    mediaCacheSizeBytes = usage.mediaBytes
    resourceCacheSizeBytes = usage.resourceBytes
    cacheSizeBytes = usage.totalBytes
  }
  func clearCache(serverID: UUID? = nil) async throws {
    try await cache.clear(serverID: serverID)
    await refreshCacheUsage()
  }

  private func activateProvider() throws {
    guard let activeServer else {
      provider = nil
      return
    }
    let credentials = try vault.read(serverID: activeServer.id) ?? ProviderCredentials()
    updateCredentialStateMessageIfNeeded()
    if activeServer.sourceType != .local, isUsingEphemeralSimulatorCredentials,
      credentials.password == nil, credentials.token == nil
    {
      provider = nil
      return
    }
    provider = try factory.make(activeServer, credentials)
  }

  private func updateCredentialStateMessageIfNeeded() {
    guard isUsingEphemeralSimulatorCredentials else { return }
    lastCredentialIssueAt = lastCredentialIssueAt ?? Date()
    lastMigrationReport = String(localized: "当前模拟器构建缺少 Keychain 签名权限。本次使用临时凭据；重启 App 后需重新输入。")
  }
  private func persist() throws {
    try repository.save(.init(schemaVersion: 1, servers: servers, activeServerID: activeServerID))
  }

  private func migrateLegacyConnection() throws -> MusicServer? {
    guard let rawURL = defaults.string(forKey: "server.baseURL"), let url = URL(string: rawURL),
      let username = defaults.string(forKey: "server.username")
    else { return nil }
    let server = MusicServer(
      name: "原有 NAS", baseURL: url, sourceType: .existingNAS, username: username,
      usesHTTPS: url.scheme?.lowercased() == "https", transcodingEnabled: false)
    let legacyVault = LegacyKeychainPasswordStore()
    if let password = try legacyVault.read() {
      try vault.save(.init(password: password, token: nil), serverID: server.id)
    }
    defaults.set(
      [
        "baseURL": rawURL, "username": username,
        "migratedAt": ISO8601DateFormatter().string(from: Date()),
      ], forKey: "migration.legacyNAS.backup")
    defaults.set(
      defaults.stringArray(forKey: "library.favoriteTrackIDs") ?? [],
      forKey: "migration.legacyNAS.favoriteTrackIDs.backup")
    defaults.set(
      defaults.stringArray(forKey: "library.savedTrackIDs") ?? [],
      forKey: "migration.legacyNAS.savedTrackIDs.backup")
    defaults.set(true, forKey: "migration.legacyNAS.completed")
    lastMigrationReport =
      url.scheme?.lowercased() == "https"
      ? String(localized: "已保留并迁移原有 NAS 配置；旧配置备份仍保留。")
      : String(localized: "已保留原有 NAS 配置，但旧地址不是 HTTPS。请编辑音乐源并配置安全地址后重新测试。")
    return server
  }
}

private struct LoginCacheState: Codable, Sendable {
  let authenticated: Bool
  let checkedAt: Date
}
