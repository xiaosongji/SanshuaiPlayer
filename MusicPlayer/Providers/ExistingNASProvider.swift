import CoreGraphics
import Foundation

actor ExistingNASProvider: MusicSourceProvider {
  nonisolated let id: UUID
  nonisolated let sourceType: MusicSourceType = .existingNAS
  nonisolated let capabilities: Set<MusicProviderCapability> = [
    .home, .artists, .albums, .tracks, .search,
  ]
  nonisolated let mediaURLAllowsDirectPlayback = true
  private let client: any MusicCatalogServing
  private let http: ProviderHTTPClient
  private nonisolated let legacyFavoriteIDs: Set<UUID>
  private nonisolated let legacySavedIDs: Set<UUID>
  private var cachedCatalog: MusicCatalog?

  init(
    server: MusicServer, credentials: ProviderCredentials, client: (any MusicCatalogServing)? = nil,
    defaults: UserDefaults = .standard
  ) {
    id = server.id
    let http = ProviderHTTPClient(server: server)
    self.http = http
    legacyFavoriteIDs = Set(
      (defaults.stringArray(forKey: "library.favoriteTrackIDs") ?? []).compactMap(
        UUID.init(uuidString:)))
    legacySavedIDs = Set(
      (defaults.stringArray(forKey: "library.savedTrackIDs") ?? []).compactMap(
        UUID.init(uuidString:)))
    self.client =
      client
      ?? MusicAPIClient(
        connection: ServerConnection(
          baseURL: server.baseURL, username: server.username, password: credentials.password ?? ""),
        http: http)
  }

  func authenticate() async throws { _ = try await catalog() }
  func fetchServerInfo() async throws -> MusicServerInfo {
    _ = try await catalog()
    return .init(
      name: "Private Audio Library", version: nil, type: sourceType, capabilities: capabilities)
  }
  func fetchLibraries() async throws -> [MusicLibrary] {
    _ = try await catalog()
    return [.init(id: "default", name: "NAS 音乐库")]
  }
  func fetchArtists() async throws -> [MusicArtist] { [mapArtist(try await catalog().artist)] }
  func fetchAlbums() async throws -> [MusicAlbum] { try await catalog().albums.map(mapAlbum) }
  func fetchSongs() async throws -> [MusicTrack] { try await catalog().tracks.map(mapTrack) }
  func fetchPlaylists() async throws -> [MusicPlaylist] { [] }
  func invalidateLibraryCache() async { cachedCatalog = nil }
  func search(query: String) async throws -> MusicSearchResult {
    let needle = query.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let artists = try await fetchArtists().filter {
      $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .contains(needle)
    }
    let albums = try await fetchAlbums().filter {
      $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .contains(needle)
    }
    let tracks = try await fetchSongs().filter {
      $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .contains(needle)
        || $0.artistName.folding(
          options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        ).contains(needle)
    }
    return .init(artists: artists, albums: albums, tracks: tracks, playlists: [])
  }
  func fetchArtist(id: String) async throws -> MusicArtistDetail {
    let artist = try await fetchArtists().first { $0.identity.remoteID == id }
    guard let artist else { throw MusicSourceError.fileNotFound }
    return .init(artist: artist, albums: try await fetchAlbums(), topTracks: try await fetchSongs())
  }
  func fetchAlbum(id: String) async throws -> MusicAlbumDetail {
    let album = try await fetchAlbums().first { $0.identity.remoteID == id }
    guard let album else { throw MusicSourceError.fileNotFound }
    return .init(album: album, tracks: try await fetchSongs().filter { $0.albumRemoteID == id })
  }
  func fetchPlaylist(id: String) async throws -> MusicPlaylistDetail {
    throw MusicSourceError.unsupportedFeature
  }
  func fetchHomeSections() async throws -> [MusicSection] {
    let source = try await catalog()
    let albums = source.albums.map(mapAlbum)
    let featured = albums.filter { source.featuredAlbumIDs.contains($0.id) }
    var sections =
      featured.isEmpty
      ? []
      : [
        MusicSection(
id: "featured", title: String(localized: "精选专辑"), kind: .frequentAlbums,
          items: featured.map(MusicSectionItem.album))
      ]
    let favorites = source.tracks.filter { legacyFavoriteIDs.contains($0.id) }.map(mapTrack)
    if !favorites.isEmpty {
      sections.append(
        .init(
id: "legacy-favorites", title: String(localized: "喜欢的歌曲"), kind: .favoriteTracks,
          items: favorites.map(MusicSectionItem.track)))
    }
    return sections
  }
  func streamURL(for track: MusicTrack, quality: StreamingQuality) async throws -> URL {
    guard let uuid = UUID(uuidString: track.identity.remoteID) else {
      throw MusicSourceError.playbackURLUnavailable
    }
    let encoding: MusicPlaybackEncoding? =
      switch quality {
      case .original, .lossless: nil
      case .high, .standard, .dataSaver: .mp3
      }
    return try await client.fetchPlaybackURL(for: uuid, encoding: encoding)
  }
  func loadMediaResource(at url: URL, range: String?) async throws -> MusicMediaResponse {
    var request = URLRequest(url: url)
    request.timeoutInterval = 60
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    return try await http.mediaResponse(
      for: request, retryPolicy: .transient(maxAttempts: 3))
  }
  func downloadMediaResource(at url: URL) async throws -> MusicMediaDownload {
    var request = URLRequest(url: url)
    request.timeoutInterval = 180
    return try await http.downloadResponse(
      for: request, retryPolicy: .transient(maxAttempts: 3))
  }
  nonisolated func artworkURL(for item: MusicArtworkItem, size: CGSize?) -> URL? {
    switch item {
    case .artist(let value): value.artworkURL
    case .album(let value): value.artworkURL
    case .track(let value): value.artworkURL
    case .playlist(let value): value.artworkURL
    }
  }
  func setFavorite(item: MusicLibraryItem, isFavorite: Bool) async throws {
    throw MusicSourceError.unsupportedFeature
  }
  func reportPlayback(_ event: PlaybackEvent) async throws {}
  private func catalog() async throws -> MusicCatalog {
    if let cachedCatalog { return cachedCatalog }
    do {
      let result = try await client.fetchCatalog()
      cachedCatalog = result
      return result
    } catch { throw MusicSourceError.map(error) }
  }
  private nonisolated func mapArtist(_ value: Artist) -> MusicArtist {
    .init(
      identity: .init(providerID: id, remoteID: value.id.uuidString, sourceType: sourceType),
      name: value.name, biography: value.biography, artworkURL: value.artworkURL, albumCount: nil,
      favoriteState: .unknown, metadata: [:])
  }
  private nonisolated func mapAlbum(_ value: Album) -> MusicAlbum {
    .init(
      identity: .init(providerID: id, remoteID: value.id.uuidString, sourceType: sourceType),
      artistID: nil, title: value.title, artistName: value.subtitle ?? "",
      releaseDate: value.releaseDate,
      year: Calendar.current.component(.year, from: value.releaseDate),
      artworkURL: value.artworkURL, genreNames: [], trackCount: nil, duration: nil,
      favoriteState: .unknown, metadata: value.accentHex.map { ["accentHex": .string($0)] } ?? [:])
  }
  private nonisolated func mapTrack(_ value: Track) -> MusicTrack {
    .init(
      identity: .init(providerID: id, remoteID: value.id.uuidString, sourceType: sourceType),
      albumRemoteID: value.albumID.uuidString, artistRemoteID: nil, title: value.title,
      artistName: value.artistName, albumTitle: nil, discNumber: value.discNumber,
      trackNumber: value.trackNumber, duration: value.durationSeconds, artworkURL: value.artworkURL,
      lyrics: value.lyrics, isExplicit: value.isExplicit,
      favoriteState: legacyFavoriteIDs.contains(value.id) ? .favorite : .notFavorite,
      contentType: nil, suffix: nil, bitRate: nil,
      metadata: legacySavedIDs.contains(value.id) ? ["legacySaved": .boolean(true)] : [:])
  }
}
