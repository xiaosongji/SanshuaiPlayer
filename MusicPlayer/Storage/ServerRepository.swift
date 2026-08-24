import Foundation

struct StoredServerState: Codable, Sendable {
  var schemaVersion: Int
  var servers: [MusicServer]
  var activeServerID: UUID?
  static let empty = Self(schemaVersion: 1, servers: [], activeServerID: nil)
}

protocol ServerRepository: Sendable {
  func load() throws -> StoredServerState
  func save(_ state: StoredServerState) throws
}

struct FileServerRepository: ServerRepository, Sendable {
  let fileURL: URL

  init(fileURL: URL? = nil) {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    self.fileURL = fileURL ?? base.appending(path: "UniversalPersonalMusic/servers.json")
  }

  func load() throws -> StoredServerState {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
    return try JSONDecoder.musicStorage.decode(
      StoredServerState.self, from: Data(contentsOf: fileURL))
  }

  func save(_ state: StoredServerState) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder.musicStorage.encode(state).write(
      to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
  }
}

final class InMemoryServerRepository: ServerRepository, @unchecked Sendable {
  private let lock = NSLock()
  private var value: StoredServerState
  init(_ value: StoredServerState = .empty) { self.value = value }
  func load() throws -> StoredServerState { lock.withLock { value } }
  func save(_ state: StoredServerState) throws { lock.withLock { value = state } }
}

extension JSONEncoder {
  static var musicStorage: JSONEncoder {
    let value = JSONEncoder()
    value.dateEncodingStrategy = .iso8601
    value.outputFormatting = [.sortedKeys]
    return value
  }
}
extension JSONDecoder {
  static var musicStorage: JSONDecoder {
    let value = JSONDecoder()
    value.dateDecodingStrategy = .iso8601
    return value
  }
}
