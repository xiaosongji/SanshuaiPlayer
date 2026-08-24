import Foundation

enum MusicPlaybackEncoding: String, Sendable {
  case mp3
}

protocol MusicCatalogServing: Sendable {
  func fetchCatalog() async throws -> MusicCatalog
  func fetchPlaybackURL(for trackID: UUID, encoding: MusicPlaybackEncoding?) async throws -> URL
}
