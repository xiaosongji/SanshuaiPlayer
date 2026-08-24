import CoreGraphics
import CryptoKit
import Foundation

enum MusicSourceType: String, Codable, CaseIterable, Identifiable, Sendable {
  case openSubsonic
  case jellyfin
  case existingNAS
  case local

  var id: String { rawValue }

  var title: String {
    switch self {
    case .openSubsonic: "OpenSubsonic / Navidrome"
    case .jellyfin: "Jellyfin"
    case .existingNAS: String(localized: "现有 NAS")
    case .local: String(localized: "本机音乐")
    }
  }
}

enum MusicServerURLNormalizer {
  static func normalize(_ url: URL, for sourceType: MusicSourceType) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    components.query = nil
    components.fragment = nil
    var segments = components.path.split(separator: "/").map(String.init)
    if sourceType == .openSubsonic, segments.last?.lowercased() == "rest" { segments.removeLast() }
    if sourceType == .jellyfin,
      let webIndex = segments.firstIndex(where: { $0.lowercased() == "web" })
    {
      segments = Array(segments[..<webIndex])
    }
    components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
    return components.url ?? url
  }
}

struct MusicIdentity: Codable, Hashable, Sendable {
  let id: UUID
  let providerID: UUID
  let remoteID: String
  let sourceType: MusicSourceType

  init(id: UUID? = nil, providerID: UUID, remoteID: String, sourceType: MusicSourceType) {
    self.id = id ?? StableMusicID.make(providerID: providerID, remoteID: remoteID)
    self.providerID = providerID
    self.remoteID = remoteID
    self.sourceType = sourceType
  }
}

enum StableMusicID {
  static func make(providerID: UUID, remoteID: String) -> UUID {
    let digest = SHA256.hash(data: Data("\(providerID.uuidString.lowercased())|\(remoteID)".utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}

enum MetadataValue: Codable, Hashable, Sendable {
  case string(String)
  case integer(Int)
  case decimal(Double)
  case boolean(Bool)

  private enum CodingKeys: String, CodingKey { case type, value }
  private enum Kind: String, Codable { case string, integer, decimal, boolean }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .string: self = .string(try container.decode(String.self, forKey: .value))
    case .integer: self = .integer(try container.decode(Int.self, forKey: .value))
    case .decimal: self = .decimal(try container.decode(Double.self, forKey: .value))
    case .boolean: self = .boolean(try container.decode(Bool.self, forKey: .value))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .string(let value):
      try container.encode(Kind.string, forKey: .type)
      try container.encode(value, forKey: .value)
    case .integer(let value):
      try container.encode(Kind.integer, forKey: .type)
      try container.encode(value, forKey: .value)
    case .decimal(let value):
      try container.encode(Kind.decimal, forKey: .type)
      try container.encode(value, forKey: .value)
    case .boolean(let value):
      try container.encode(Kind.boolean, forKey: .type)
      try container.encode(value, forKey: .value)
    }
  }
}

typealias MusicMetadata = [String: MetadataValue]

enum FavoriteState: String, Codable, Sendable { case unknown, favorite, notFavorite }

enum StreamingQuality: String, Codable, CaseIterable, Identifiable, Sendable {
  case original, lossless, high, standard, dataSaver
  var id: String { rawValue }
  var title: String {
    switch self {
    case .original: String(localized: "原始质量")
    case .lossless: String(localized: "无损优先")
    case .high: String(localized: "高质量")
    case .standard: String(localized: "标准质量")
    case .dataSaver: String(localized: "省流量")
    }
  }
  var maximumBitRate: Int? {
    switch self {
    case .original: nil
    case .lossless: 1_411
    case .high: 320
    case .standard: 192
    case .dataSaver: 96
    }
  }
}

struct MusicServer: Codable, Identifiable, Hashable, Sendable {
  enum ConnectionStatus: String, Codable, Sendable { case unknown, connecting, online, offline }
  let id: UUID
  var name: String
  var baseURL: URL
  var sourceType: MusicSourceType
  var username: String
  var usesHTTPS: Bool
  var allowsSelfSignedCertificate: Bool
  var certificateFingerprint: String?
  var wifiQuality: StreamingQuality
  var transcodingEnabled: Bool
  var defaultLibraryID: String?
  var status: ConnectionStatus
  var lastConnectedAt: Date?
  var lastError: String?
  var metadata: MusicMetadata

  init(
    id: UUID = UUID(), name: String, baseURL: URL, sourceType: MusicSourceType, username: String,
    usesHTTPS: Bool = true, allowsSelfSignedCertificate: Bool = false,
    certificateFingerprint: String? = nil, wifiQuality: StreamingQuality = .original,
    transcodingEnabled: Bool = true, defaultLibraryID: String? = nil,
    status: ConnectionStatus = .unknown,
    lastConnectedAt: Date? = nil, lastError: String? = nil, metadata: MusicMetadata = [:]
  ) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.sourceType = sourceType
    self.username = username
    self.usesHTTPS = usesHTTPS
    self.allowsSelfSignedCertificate = allowsSelfSignedCertificate
    self.certificateFingerprint = certificateFingerprint
    self.wifiQuality = wifiQuality
    self.transcodingEnabled = transcodingEnabled
    self.defaultLibraryID = defaultLibraryID
    self.status = status
    self.lastConnectedAt = lastConnectedAt
    self.lastError = lastError
    self.metadata = metadata
  }
}

struct MusicAccount: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  let serverID: UUID
  var username: String
  var displayName: String?
  var remoteUserID: String?
}

struct MusicServerInfo: Codable, Hashable, Sendable {
  let name: String
  let version: String?
  let type: MusicSourceType
  let capabilities: Set<MusicProviderCapability>
}

struct MusicArtist: Codable, Identifiable, Hashable, Sendable {
  let identity: MusicIdentity
  var name: String
  var biography: String?
  var artworkURL: URL?
  var albumCount: Int?
  var favoriteState: FavoriteState
  var metadata: MusicMetadata
  var id: UUID { identity.id }
}

struct MusicAlbum: Codable, Identifiable, Hashable, Sendable {
  let identity: MusicIdentity
  var artistID: String?
  var title: String
  var artistName: String
  var releaseDate: Date?
  var year: Int?
  var artworkURL: URL?
  var genreNames: [String]
  var trackCount: Int?
  var duration: TimeInterval?
  var favoriteState: FavoriteState
  var metadata: MusicMetadata
  var id: UUID { identity.id }
}

struct MusicTrack: Codable, Identifiable, Hashable, Sendable {
  let identity: MusicIdentity
  var albumRemoteID: String?
  var artistRemoteID: String?
  var title: String
  var artistName: String
  var albumTitle: String?
  var discNumber: Int
  var trackNumber: Int
  var duration: TimeInterval
  var artworkURL: URL?
  var lyrics: String?
  var isExplicit: Bool
  var favoriteState: FavoriteState
  var contentType: String?
  var suffix: String?
  var bitRate: Int?
  var metadata: MusicMetadata
  var id: UUID { identity.id }

  var estimatedFileSizeBytes: Int64? {
    if case .integer(let size) = metadata["sizeBytes"], size > 0 {
      return Int64(size)
    }
    guard let bitRate, bitRate > 0, duration > 0 else { return nil }
    return Int64((Double(bitRate) * 1_000 / 8 * duration).rounded(.up))
  }

  var isNativelyPlayableOnIOS: Bool {
    let nativeSuffixes = Set([
      "aac", "aif", "aiff", "caf", "flac", "m4a", "m4b", "mp3", "mp4", "wav",
    ])
    if let suffix, !suffix.isEmpty {
      return nativeSuffixes.contains(suffix.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased())
    }
    guard let contentType = contentType?.lowercased() else { return false }
    return Set([
      "audio/aac", "audio/aiff", "audio/flac", "audio/mp4", "audio/mpeg", "audio/wav",
      "audio/x-aiff", "audio/x-caf", "audio/x-flac", "audio/x-m4a", "audio/x-wav",
    ]).contains(contentType)
  }

  var resumePosition: TimeInterval? {
    guard case .decimal(let value) = metadata["resumePosition"], value > 0 else { return nil }
    return value
  }
}

struct MusicPlaylist: Codable, Identifiable, Hashable, Sendable {
  let identity: MusicIdentity
  var name: String
  var artworkURL: URL?
  var trackCount: Int
  var duration: TimeInterval?
  var isPublic: Bool
  var isEditable: Bool
  var metadata: MusicMetadata
  var id: UUID { identity.id }
}

struct MusicGenre: Codable, Identifiable, Hashable, Sendable {
  let name: String
  var trackCount: Int?
  var albumCount: Int?
  var id: String { name }
}

struct MusicLibrary: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let name: String
}

struct MusicLyrics: Codable, Hashable, Sendable {
  struct Line: Codable, Hashable, Sendable {
    let time: TimeInterval?
    let text: String
  }
  let displayArtist: String?
  let displayTitle: String?
  let language: String?
  let lines: [Line]
  let isSynced: Bool
}

struct MusicSearchResult: Codable, Hashable, Sendable {
  var artists: [MusicArtist]
  var albums: [MusicAlbum]
  var tracks: [MusicTrack]
  var playlists: [MusicPlaylist]
  static let empty = Self(artists: [], albums: [], tracks: [], playlists: [])
}

struct MusicArtistDetail: Codable, Hashable, Sendable {
  let artist: MusicArtist
  let albums: [MusicAlbum]
  let topTracks: [MusicTrack]
}
struct MusicAlbumDetail: Codable, Hashable, Sendable {
  let album: MusicAlbum
  let tracks: [MusicTrack]
}
struct MusicPlaylistDetail: Codable, Hashable, Sendable {
  let playlist: MusicPlaylist
  let tracks: [MusicTrack]
}

enum MusicSectionKind: String, Codable, Sendable {
  case recentlyPlayed, resume, recentlyAdded, frequentAlbums, frequentArtists, random,
    favoriteTracks, favoriteAlbums, favoriteArtists, playlists
}
enum MusicSectionItem: Codable, Hashable, Sendable {
  case track(MusicTrack)
  case album(MusicAlbum)
  case artist(MusicArtist)
  case playlist(MusicPlaylist)
}
struct MusicSection: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let kind: MusicSectionKind
  let items: [MusicSectionItem]
}

struct PlaybackQueue: Codable, Hashable, Sendable {
  var tracks: [MusicTrack]
  var currentIndex: Int?
  var updatedAt: Date
}
struct PlaybackHistory: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  let serverID: UUID
  let track: MusicTrack
  let playedAt: Date
  let position: TimeInterval
  let completed: Bool
}

enum PlaybackEvent: Hashable, Sendable {
  case started(track: MusicTrack)
  case progress(track: MusicTrack, position: TimeInterval, duration: TimeInterval)
  case completed(track: MusicTrack)
  case stopped(track: MusicTrack, position: TimeInterval)
}

enum MusicLibraryItem: Hashable, Sendable {
  case artist(MusicArtist)
  case album(MusicAlbum)
  case track(MusicTrack)
}
enum MusicArtworkItem: Hashable, Sendable {
  case artist(MusicArtist)
  case album(MusicAlbum)
  case track(MusicTrack)
  case playlist(MusicPlaylist)
}

enum MusicProviderCapability: String, Codable, Hashable, Sendable {
  case home, artists, albums, tracks, playlists, search, lyrics, favorites, playlistEditing,
    scrobbling, progress, transcoding, random, recentlyPlayed, recentlyAdded, frequent, resume
}
