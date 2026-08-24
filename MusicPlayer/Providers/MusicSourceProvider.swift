import CoreGraphics
import Foundation

protocol MusicSourceProvider: Sendable {
  var id: UUID { get }
  var sourceType: MusicSourceType { get }
  var capabilities: Set<MusicProviderCapability> { get }
  var mediaURLAllowsDirectPlayback: Bool { get }

  func authenticate() async throws
  func refreshedCredentials() async -> ProviderCredentials?
  func fetchServerInfo() async throws -> MusicServerInfo
  func fetchLibraries() async throws -> [MusicLibrary]
  func fetchHomeSections() async throws -> [MusicSection]
  func fetchArtists() async throws -> [MusicArtist]
  func fetchAlbums() async throws -> [MusicAlbum]
  func fetchSongs() async throws -> [MusicTrack]
  func fetchPlaylists() async throws -> [MusicPlaylist]
  func invalidateLibraryCache() async
  func search(query: String) async throws -> MusicSearchResult
  func fetchArtist(id: String) async throws -> MusicArtistDetail
  func fetchAlbum(id: String) async throws -> MusicAlbumDetail
  func fetchPlaylist(id: String) async throws -> MusicPlaylistDetail
  func fetchLyrics(for track: MusicTrack) async throws -> MusicLyrics?
  func streamURL(for track: MusicTrack, quality: StreamingQuality) async throws -> URL
  func loadMediaResource(at url: URL, range: String?) async throws -> MusicMediaResponse
  func streamMediaResource(
    at url: URL, range: String?,
    onResponse: @escaping @Sendable (MusicMediaResponseMetadata) async throws -> Bool,
    onData: @escaping @Sendable (Data) async throws -> Bool
  ) async throws
  func downloadMediaResource(at url: URL) async throws -> MusicMediaDownload
  func artworkURL(for item: MusicArtworkItem, size: CGSize?) -> URL?
  func setFavorite(item: MusicLibraryItem, isFavorite: Bool) async throws
  func createPlaylist(name: String, trackIDs: [String]) async throws -> MusicPlaylist
  func updatePlaylist(id: String, name: String?, adding: [String], removingIndexes: [Int])
    async throws
  func deletePlaylist(id: String) async throws
  func reportPlayback(_ event: PlaybackEvent) async throws
}

struct MusicMediaResponse: Sendable {
  let data: Data
  let statusCode: Int
  let mimeType: String?
  let expectedContentLength: Int64
  let headers: [String: String]

  var metadata: MusicMediaResponseMetadata {
    MusicMediaResponseMetadata(
      statusCode: statusCode, mimeType: mimeType,
      expectedContentLength: expectedContentLength, headers: headers)
  }
}

struct MusicMediaResponseMetadata: Sendable {
  let statusCode: Int
  let mimeType: String?
  let expectedContentLength: Int64
  let headers: [String: String]
}

struct MusicMediaDownload: Sendable {
  let temporaryURL: URL
  let statusCode: Int
  let mimeType: String?
  let expectedContentLength: Int64
  let headers: [String: String]
}

extension MusicSourceProvider {
  var mediaURLAllowsDirectPlayback: Bool { false }
  func refreshedCredentials() async -> ProviderCredentials? { nil }
  func fetchLyrics(for track: MusicTrack) async throws -> MusicLyrics? { nil }
  func invalidateLibraryCache() async {}
  func streamMediaResource(
    at url: URL, range: String?,
    onResponse: @escaping @Sendable (MusicMediaResponseMetadata) async throws -> Bool,
    onData: @escaping @Sendable (Data) async throws -> Bool
  ) async throws {
    let response = try await loadMediaResource(at: url, range: range)
    guard try await onResponse(response.metadata) else { return }
    _ = try await onData(response.data)
  }
  func downloadMediaResource(at url: URL) async throws -> MusicMediaDownload {
    let response = try await loadMediaResource(at: url, range: nil)
    let temporaryURL = FileManager.default.temporaryDirectory.appending(
      path: "music-download-\(UUID().uuidString.lowercased())")
    do {
      try response.data.write(
        to: temporaryURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      return MusicMediaDownload(
        temporaryURL: temporaryURL, statusCode: response.statusCode,
        mimeType: response.mimeType, expectedContentLength: response.expectedContentLength,
        headers: response.headers)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }
  func createPlaylist(name: String, trackIDs: [String]) async throws -> MusicPlaylist {
    throw MusicSourceError.unsupportedFeature
  }
  func updatePlaylist(id: String, name: String?, adding: [String], removingIndexes: [Int])
    async throws
  { throw MusicSourceError.unsupportedFeature }
  func deletePlaylist(id: String) async throws { throw MusicSourceError.unsupportedFeature }
}

struct ProviderCredentials: Sendable, Equatable {
  var password: String?
  var token: String?
  var remoteUserID: String?

  init(password: String? = nil, token: String? = nil, remoteUserID: String? = nil) {
    self.password = password
    self.token = token
    self.remoteUserID = remoteUserID
  }
}

struct ProviderFactory: Sendable {
  var make: @Sendable (MusicServer, ProviderCredentials) throws -> any MusicSourceProvider

  static let live = ProviderFactory { server, credentials in
    switch server.sourceType {
    case .openSubsonic: OpenSubsonicProvider(server: server, credentials: credentials)
    case .jellyfin: JellyfinProvider(server: server, credentials: credentials)
    case .existingNAS: ExistingNASProvider(server: server, credentials: credentials)
    case .local: LocalMusicProvider(server: server)
    }
  }
}
