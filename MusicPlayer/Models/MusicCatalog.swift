import Foundation

struct MusicCatalog: Codable, Sendable {
  let artist: Artist
  let albums: [Album]
  let tracks: [Track]
  let featuredAlbumIDs: [UUID]

  static let empty = MusicCatalog(
    artist: Artist(id: UUID(), name: "", biography: nil, artworkURL: nil),
    albums: [],
    tracks: [],
    featuredAlbumIDs: []
  )

  func tracks(in album: Album) -> [Track] {
    tracks
      .filter { $0.albumID == album.id }
      .sorted {
        if $0.discNumber != $1.discNumber {
          return $0.discNumber < $1.discNumber
        }
        return $0.trackNumber < $1.trackNumber
      }
  }
}

struct Artist: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  let name: String
  let biography: String?
  let artworkURL: URL?
}

struct Album: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  let title: String
  let subtitle: String?
  let releaseDate: Date
  let artworkURL: URL?
  let accentHex: String?
  let isPublished: Bool
}

struct Track: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  let albumID: UUID
  let title: String
  let artistName: String
  let discNumber: Int
  let trackNumber: Int
  let durationSeconds: TimeInterval
  let artworkURL: URL?
  let lyrics: String?
  let isExplicit: Bool
}
