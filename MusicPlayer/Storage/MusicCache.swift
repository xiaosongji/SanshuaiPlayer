import CryptoKit
import Foundation

actor MusicCache {
  static let shared = MusicCache()
  enum Namespace: String, CaseIterable, Sendable {
    case metadata, recentBrowsing, searchHistory, queue, playbackHistory, loginState, artwork,
      media,
      lyrics
  }
  private let cacheRootURL: URL
  private let persistentRootURL: URL
  private(set) var mediaByteLimit: Int64
  private var hasPreparedStorage = false
  private var resourceIndexes: [UUID: ResourceIndex] = [:]
  private var resourceIndexFlushTasks: [UUID: Task<Void, Never>] = [:]

  init(
    rootURL: URL? = nil, persistentRootURL: URL? = nil,
    byteLimit: Int64 = 1_024 * 1_024 * 1_024,
    minimumByteLimit: Int64 = 64 * 1_024 * 1_024,
    mediaByteLimit: Int64 = 500 * 1_024 * 1_024
  ) {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let cacheRoot = rootURL ?? caches.appending(path: "UniversalPersonalMusic")
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    self.cacheRootURL = cacheRoot
    self.persistentRootURL =
      persistentRootURL
      ?? (rootURL == nil
        ? applicationSupport.appending(path: "UniversalPersonalMusic/DownloadedResources")
        : cacheRoot)
    let normalizedLimit = max(max(1, minimumByteLimit), byteLimit)
    self.mediaByteLimit = min(max(1, mediaByteLimit), normalizedLimit)
  }

  func prepare() throws { try prepareStorageIfNeeded() }
  func store<T: Encodable & Sendable>(_ value: T, serverID: UUID, namespace: Namespace, key: String)
    async throws
  {
    try prepareStorageIfNeeded()
    let url = fileURL(serverID: serverID, namespace: namespace, key: key)
    let data = try JSONEncoder.musicStorage.encode(value)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
  }
  func storeLyrics(_ value: MusicLyrics, serverID: UUID, key: String, owner: String) async throws {
    try await store(value, serverID: serverID, namespace: .lyrics, key: key)
    try recordResource(
      serverID: serverID, namespace: .lyrics,
      fileName: fileURL(serverID: serverID, namespace: .lyrics, key: key).lastPathComponent,
      owner: owner)
  }
  func load<T: Decodable & Sendable>(
    _ type: T.Type, serverID: UUID, namespace: Namespace, key: String
  ) throws -> T? {
    try prepareStorageIfNeeded()
    let url = fileURL(serverID: serverID, namespace: namespace, key: key)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let value = try JSONDecoder.musicStorage.decode(type, from: Data(contentsOf: url))
    touch(url)
    return value
  }
  func clear(serverID: UUID? = nil) throws {
    try prepareStorageIfNeeded()
    if let serverID {
      resourceIndexFlushTasks.removeValue(forKey: serverID)?.cancel()
      resourceIndexes.removeValue(forKey: serverID)
    } else {
      resourceIndexFlushTasks.values.forEach { $0.cancel() }
      resourceIndexFlushTasks.removeAll()
      resourceIndexes.removeAll()
    }
    let roots =
      cacheRootURL == persistentRootURL
      ? [cacheRootURL] : [cacheRootURL, persistentRootURL]
    for root in roots {
      let target = serverID.map { root.appending(path: $0.uuidString.lowercased()) } ?? root
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
    }
    if serverID == nil {
      hasPreparedStorage = false
      try prepareStorageIfNeeded()
    }
  }
  func artworkData(serverID: UUID, key: String) throws -> Data? {
    try prepareStorageIfNeeded()
    let binaryURL = binaryFileURL(
      serverID: serverID, namespace: .artwork, key: key, fileExtension: "image")
    if FileManager.default.fileExists(atPath: binaryURL.path) {
      touch(binaryURL)
      return try Data(contentsOf: binaryURL)
    }
    // 3.0.6 以前的封面以 JSON/Base64 存储。读取兼容格式，但新写入统一使用二进制。
    return try load(Data.self, serverID: serverID, namespace: .artwork, key: key)
  }
  func storeArtwork(
    _ data: Data, serverID: UUID, key: String, owner: String? = nil
  ) async throws {
    try prepareStorageIfNeeded()
    guard !data.isEmpty, data.count <= 12 * 1_024 * 1_024 else { return }
    let url = binaryFileURL(
      serverID: serverID, namespace: .artwork, key: key, fileExtension: "image")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    if let owner {
      try recordResource(
        serverID: serverID, namespace: .artwork, fileName: url.lastPathComponent, owner: owner)
    }
  }
  func removeArtwork(serverID: UUID, key: String) {
    try? prepareStorageIfNeeded()
    let binaryURL = binaryFileURL(
      serverID: serverID, namespace: .artwork, key: key, fileExtension: "image")
    let legacyURL = fileURL(serverID: serverID, namespace: .artwork, key: key)
    try? FileManager.default.removeItem(at: binaryURL)
    try? FileManager.default.removeItem(at: legacyURL)
    try? removeResourceRecord(
      serverID: serverID, namespace: .artwork,
      fileNames: [
        binaryURL.lastPathComponent, legacyURL.lastPathComponent,
      ])
  }
  func mediaURL(serverID: UUID, key: String, fileExtension: String?) -> URL? {
    try? prepareStorageIfNeeded()
    let url = binaryFileURL(
      serverID: serverID, namespace: .media, key: key, fileExtension: fileExtension)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    touch(url)
    return url
  }
  func mediaURL(serverID: UUID, key: String) -> URL? {
    try? prepareStorageIfNeeded()
    let directory = cacheRootURL.appending(path: serverID.uuidString.lowercased()).appending(
      path: Namespace.media.rawValue)
    let safe = safeKey(key)
    guard
      let candidates = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      ).filter({ $0.lastPathComponent == safe || $0.lastPathComponent.hasPrefix(safe + ".") }),
      let url = candidates.max(by: { modificationDate($0) < modificationDate($1) })
    else { return nil }
    touch(url)
    return url
  }
  func removeMedia(serverID: UUID, key: String) {
    try? prepareStorageIfNeeded()
    let directory = cacheRootURL.appending(path: serverID.uuidString.lowercased()).appending(
      path: Namespace.media.rawValue)
    let safe = safeKey(key)
    guard
      let candidates = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    for url in candidates
    where url.lastPathComponent == safe || url.lastPathComponent.hasPrefix(safe + ".") {
      try? FileManager.default.removeItem(at: url)
    }
  }
  func storeMedia(_ data: Data, serverID: UUID, key: String, fileExtension: String?) async throws {
    try prepareStorageIfNeeded()
    guard Int64(data.count) <= mediaByteLimit else { return }
    let url = binaryFileURL(
      serverID: serverID, namespace: .media, key: key, fileExtension: fileExtension)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    removeMediaVariants(key: key, except: url)
    try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    try await trimIfNeeded()
  }
  @discardableResult
  func storeMediaFile(
    at sourceURL: URL, serverID: UUID, key: String, fileExtension: String?
  ) async throws -> Bool {
    try prepareStorageIfNeeded()
    let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw MusicSourceError.invalidResponse }
    let size = Int64(values.fileSize ?? 0)
    guard size > 0, size <= mediaByteLimit else { return false }

    let url = binaryFileURL(
      serverID: serverID, namespace: .media, key: key, fileExtension: fileExtension)
    let stagingURL = url.deletingLastPathComponent().appending(
      path: ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).partial")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stagingURL) }
    try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUnlessOpen],
      ofItemAtPath: stagingURL.path)
    removeMediaVariants(key: key, except: url)
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: stagingURL)
    } else {
      try FileManager.default.moveItem(at: stagingURL, to: url)
    }
    try await trimIfNeeded()
    return true
  }
  func size() -> Int64 {
    try? prepareStorageIfNeeded()
    return fileEntries().reduce(0) { $0 + $1.size }
  }
  func usage() -> CacheUsage {
    try? prepareStorageIfNeeded()
    return fileEntries().reduce(into: CacheUsage()) { result, entry in
      if entry.namespace == .media {
        result.mediaBytes += entry.size
      } else {
        result.resourceBytes += entry.size
      }
    }
  }
  func trimIfNeeded() async throws {
    try prepareStorageIfNeeded()
    var entries = fileEntries().filter { $0.namespace == .media }.sorted {
      $0.lastUsedAt < $1.lastUsedAt
    }
    var total = entries.reduce(0) { $0 + $1.size }
    while total > mediaByteLimit, let oldest = entries.first {
      try? FileManager.default.removeItem(at: oldest.url)
      total -= oldest.size
      entries.removeFirst()
    }
  }
  func reconcilePersistentResources(serverID: UUID, retainingOwners: Set<String>) throws {
    try prepareStorageIfNeeded()
    var index = loadResourceIndex(serverID: serverID)
    var changed = false
    for identifier in Array(index.entries.keys) {
      guard var entry = index.entries[identifier] else { continue }
      let url = persistentRootURL.appending(path: serverID.uuidString.lowercased())
        .appending(path: entry.namespace).appending(path: entry.fileName)
      guard FileManager.default.fileExists(atPath: url.path) else {
        index.entries.removeValue(forKey: identifier)
        changed = true
        continue
      }
      if !entry.owners.isDisjoint(with: retainingOwners) {
        if entry.consecutiveMissingRefreshes != 0 {
          entry.consecutiveMissingRefreshes = 0
          index.entries[identifier] = entry
          changed = true
        }
        continue
      }
      entry.consecutiveMissingRefreshes += 1
      if entry.consecutiveMissingRefreshes >= 2 {
        try? FileManager.default.removeItem(at: url)
        index.entries.removeValue(forKey: identifier)
      } else {
        index.entries[identifier] = entry
      }
      changed = true
    }
    if changed {
      resourceIndexFlushTasks.removeValue(forKey: serverID)?.cancel()
      try saveResourceIndex(index, serverID: serverID)
    }
  }
  private func fileURL(serverID: UUID, namespace: Namespace, key: String) -> URL {
    let safe = safeKey(key)
    return root(for: namespace).appending(path: serverID.uuidString.lowercased()).appending(
      path: namespace.rawValue
    ).appending(path: safe + ".json")
  }
  private func binaryFileURL(
    serverID: UUID, namespace: Namespace, key: String, fileExtension: String?
  ) -> URL {
    let safe = safeKey(key)
    let suffix = fileExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? ""
    return root(for: namespace).appending(path: serverID.uuidString.lowercased()).appending(
      path: namespace.rawValue
    ).appending(path: suffix.isEmpty ? safe : "\(safe).\(suffix)")
  }
  private func safeKey(_ key: String) -> String {
    SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private func modificationDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
  }
  private func touch(_ url: URL) {
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
  }
  private func root(for namespace: Namespace) -> URL {
    namespace == .media ? cacheRootURL : persistentRootURL
  }
  private func removeMediaVariants(key: String, except retainedURL: URL) {
    let directory = retainedURL.deletingLastPathComponent()
    let safe = safeKey(key)
    guard
      let candidates = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    for url in candidates
    where url != retainedURL
      && (url.lastPathComponent == safe || url.lastPathComponent.hasPrefix(safe + "."))
    {
      try? FileManager.default.removeItem(at: url)
    }
  }
  private struct CacheEntry {
    let url: URL
    let size: Int64
    let lastUsedAt: Date
    let namespace: Namespace
  }
  private func fileEntries() -> [CacheEntry] {
    if cacheRootURL == persistentRootURL {
      return fileEntries(at: cacheRootURL)
    }
    return fileEntries(at: cacheRootURL) + fileEntries(at: persistentRootURL)
  }
  private func fileEntries(at rootURL: URL) -> [CacheEntry] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [
          .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey,
        ])
    else { return [] }
    let rootComponents = rootURL.standardizedFileURL.pathComponents
    return enumerator.compactMap { value in
      guard let url = value as? URL,
        let namespace = namespace(for: url, rootComponents: rootComponents),
        let values = try? url.resourceValues(forKeys: [
          .isRegularFileKey, .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey,
        ]), values.isRegularFile == true
      else { return nil }
      return CacheEntry(
        url: url, size: Int64(values.fileSize ?? 0),
        lastUsedAt: values.contentModificationDate ?? values.contentAccessDate ?? .distantPast,
        namespace: namespace
      )
    }
  }
  private func namespace(for url: URL, rootComponents: [String]) -> Namespace? {
    let components = url.standardizedFileURL.pathComponents
    let namespaceIndex = rootComponents.count + 1
    guard components.starts(with: rootComponents), components.indices.contains(namespaceIndex)
    else { return nil }
    return Namespace(rawValue: components[namespaceIndex])
  }

  private func prepareStorageIfNeeded() throws {
    guard !hasPreparedStorage else { return }
    if cacheRootURL != persistentRootURL {
      try FileManager.default.createDirectory(
        at: persistentRootURL, withIntermediateDirectories: true)
      var persistentURL = persistentRootURL
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try persistentURL.setResourceValues(values)
      try migrateLegacyResources()
    }
    hasPreparedStorage = true
  }

  private func migrateLegacyResources() throws {
    guard FileManager.default.fileExists(atPath: cacheRootURL.path) else { return }
    let serverDirectories = try FileManager.default.contentsOfDirectory(
      at: cacheRootURL, includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles])
    for serverDirectory in serverDirectories {
      guard
        (try? serverDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      else { continue }
      for namespace in Namespace.allCases where namespace != .media {
        let source = serverDirectory.appending(path: namespace.rawValue)
        guard FileManager.default.fileExists(atPath: source.path) else { continue }
        let destination = persistentRootURL.appending(path: serverDirectory.lastPathComponent)
          .appending(path: namespace.rawValue)
        try migrateDirectoryContents(from: source, to: destination)
        try? FileManager.default.removeItem(at: source)
      }
    }
  }

  private func migrateDirectoryContents(from source: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for item in try FileManager.default.contentsOfDirectory(
      at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    {
      let target = destination.appending(path: item.lastPathComponent)
      if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        try migrateDirectoryContents(from: item, to: target)
        try? FileManager.default.removeItem(at: item)
      } else if !FileManager.default.fileExists(atPath: target.path) {
        let staging = destination.appending(path: ".\(item.lastPathComponent).migration")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: item, to: staging)
        try FileManager.default.moveItem(at: staging, to: target)
        try FileManager.default.removeItem(at: item)
      } else {
        try? FileManager.default.removeItem(at: item)
      }
    }
  }

  private struct ResourceIndex: Codable {
    var entries: [String: ResourceEntry] = [:]
  }
  private struct ResourceEntry: Codable {
    let namespace: String
    let fileName: String
    var owners: Set<String>
    var consecutiveMissingRefreshes: Int
  }
  private func resourceIndexURL(serverID: UUID) -> URL {
    persistentRootURL.appending(path: serverID.uuidString.lowercased())
      .appending(path: "resource-index.json")
  }
  private func loadResourceIndex(serverID: UUID) -> ResourceIndex {
    if let cached = resourceIndexes[serverID] { return cached }
    let url = resourceIndexURL(serverID: serverID)
    guard let data = try? Data(contentsOf: url),
      let value = try? JSONDecoder.musicStorage.decode(ResourceIndex.self, from: data)
    else {
      let value = ResourceIndex()
      resourceIndexes[serverID] = value
      return value
    }
    resourceIndexes[serverID] = value
    return value
  }
  private func saveResourceIndex(_ index: ResourceIndex, serverID: UUID) throws {
    resourceIndexes[serverID] = index
    try writeResourceIndex(index, serverID: serverID)
  }
  private func writeResourceIndex(_ index: ResourceIndex, serverID: UUID) throws {
    let url = resourceIndexURL(serverID: serverID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder.musicStorage.encode(index).write(
      to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
  }
  private func resourceIdentifier(namespace: Namespace, fileName: String) -> String {
    "\(namespace.rawValue)|\(fileName)"
  }
  private func recordResource(
    serverID: UUID, namespace: Namespace, fileName: String, owner: String
  ) throws {
    guard namespace == .artwork || namespace == .lyrics, !owner.isEmpty else { return }
    var index = loadResourceIndex(serverID: serverID)
    let identifier = resourceIdentifier(namespace: namespace, fileName: fileName)
    if namespace == .lyrics {
      for existingIdentifier in Array(index.entries.keys) where existingIdentifier != identifier {
        guard var existing = index.entries[existingIdentifier],
          existing.namespace == namespace.rawValue,
          existing.owners.remove(owner) != nil
        else { continue }
        if existing.owners.isEmpty {
          let oldURL = persistentRootURL.appending(path: serverID.uuidString.lowercased())
            .appending(path: existing.namespace).appending(path: existing.fileName)
          try? FileManager.default.removeItem(at: oldURL)
          index.entries.removeValue(forKey: existingIdentifier)
        } else {
          index.entries[existingIdentifier] = existing
        }
      }
    }
    var entry =
      index.entries[identifier]
      ?? ResourceEntry(
        namespace: namespace.rawValue, fileName: fileName, owners: [],
        consecutiveMissingRefreshes: 0)
    entry.owners.insert(owner)
    entry.consecutiveMissingRefreshes = 0
    index.entries[identifier] = entry
    resourceIndexes[serverID] = index
    scheduleResourceIndexSave(serverID: serverID)
  }
  private func removeResourceRecord(
    serverID: UUID, namespace: Namespace, fileNames: [String]
  ) throws {
    var index = loadResourceIndex(serverID: serverID)
    var changed = false
    for fileName in fileNames {
      changed =
        index.entries.removeValue(
          forKey: resourceIdentifier(namespace: namespace, fileName: fileName)) != nil || changed
    }
    if changed {
      resourceIndexes[serverID] = index
      scheduleResourceIndexSave(serverID: serverID)
    }
  }
  private func scheduleResourceIndexSave(serverID: UUID) {
    resourceIndexFlushTasks.removeValue(forKey: serverID)?.cancel()
    resourceIndexFlushTasks[serverID] = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      await self?.flushResourceIndex(serverID: serverID)
    }
  }
  private func flushResourceIndex(serverID: UUID) {
    defer { resourceIndexFlushTasks.removeValue(forKey: serverID) }
    guard let index = resourceIndexes[serverID] else { return }
    try? writeResourceIndex(index, serverID: serverID)
  }
}

enum MusicResourceOwner {
  static func track(_ remoteID: String) -> String { "track:\(remoteID)" }
  static func album(_ remoteID: String) -> String { "album:\(remoteID)" }
  static func artist(_ remoteID: String) -> String { "artist:\(remoteID)" }
  static func playlist(_ remoteID: String) -> String { "playlist:\(remoteID)" }
}

struct CacheUsage: Equatable, Sendable {
  var mediaBytes: Int64 = 0
  var resourceBytes: Int64 = 0
  var totalBytes: Int64 { mediaBytes + resourceBytes }
}
