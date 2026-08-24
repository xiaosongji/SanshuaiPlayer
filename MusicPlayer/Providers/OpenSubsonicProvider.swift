import CoreGraphics
import CryptoKit
import Foundation

actor OpenSubsonicProvider: MusicSourceProvider {
  nonisolated let id: UUID
  nonisolated let sourceType: MusicSourceType = .openSubsonic
  nonisolated let capabilities: Set<MusicProviderCapability> = [
    .home, .artists, .albums, .tracks, .playlists, .search, .lyrics, .favorites, .playlistEditing,
    .scrobbling, .transcoding, .random, .recentlyPlayed, .recentlyAdded, .frequent,
  ]
  // Keep progressive playback behind the provider loader so every cellular
  // range response is validated and delivered at the requested byte offset.
  nonisolated let mediaURLAllowsDirectPlayback = false

  private nonisolated let server: MusicServer
  private let credentials: ProviderCredentials
  private let http: ProviderHTTPClient
  private let decoder = JSONDecoder()
  private var cachedAlbums: [MusicAlbum]?
  private var cachedSongs: [MusicTrack]?
  private var albumLoadTask: Task<[MusicAlbum], Error>?
  private var songLoadTask: Task<[MusicTrack], Error>?

  init(server: MusicServer, credentials: ProviderCredentials, session: URLSession? = nil) {
    id = server.id
    self.server = server
    self.credentials = credentials
    http = ProviderHTTPClient(server: server, session: session)
  }

  func authenticate() async throws { _ = try await call(PingEnvelope.self, endpoint: "ping") }

  func fetchServerInfo() async throws -> MusicServerInfo {
    let response = try await call(PingEnvelope.self, endpoint: "ping").response
    guard response.status == "ok" else { throw mapSubsonicError(response.error) }
    return MusicServerInfo(
      name: server.name, version: response.version, type: sourceType, capabilities: capabilities)
  }

  func fetchLibraries() async throws -> [MusicLibrary] {
    let root = try await call(MusicFoldersEnvelope.self, endpoint: "getMusicFolders").response
    try validate(root.status, root.error)
    return (root.musicFolders?.musicFolder ?? []).map {
      MusicLibrary(id: String($0.id), name: $0.name)
    }
  }

  func fetchArtists() async throws -> [MusicArtist] {
    let root = try await call(ArtistsEnvelope.self, endpoint: "getArtists", query: libraryQuery())
      .response
    try validate(root.status, root.error)
    return (root.artists?.index ?? []).flatMap(\.artist).map(mapArtist)
  }

  func fetchAlbums() async throws -> [MusicAlbum] {
    if let cachedAlbums { return cachedAlbums }
    if let albumLoadTask { return try await albumLoadTask.value }
    let task = Task { try await loadAllAlbums() }
    albumLoadTask = task
    do {
      let albums = try await task.value
      cachedAlbums = albums
      albumLoadTask = nil
      return albums
    } catch {
      albumLoadTask = nil
      throw error
    }
  }

  private func loadAllAlbums() async throws -> [MusicAlbum] {
    var offset = 0
    var result: [MusicAlbum] = []
    while true {
      let page = try await albumList(type: "alphabeticalByName", size: 500, offset: offset)
      result.append(contentsOf: page)
      guard page.count == 500 else { return result }
      offset += page.count
    }
  }

  func fetchSongs() async throws -> [MusicTrack] {
    if let cachedSongs { return cachedSongs }
    if let songLoadTask { return try await songLoadTask.value }
    let task = Task { try await loadAllSongs() }
    songLoadTask = task
    do {
      let songs = try await task.value
      cachedSongs = songs
      songLoadTask = nil
      return songs
    } catch {
      songLoadTask = nil
      throw error
    }
  }

  private func loadAllSongs() async throws -> [MusicTrack] {
    do {
      return try await loadAllSongsUsingSearch()
    } catch let error as MusicSourceError
      where error == .incompatibleServer || error == .invalidResponse
    {
      // OpenSubsonic requires an empty search3 query for full-library sync. A few older
      // Subsonic servers do not implement it, so retain the album expansion as a compatibility
      // fallback without penalising Navidrome and other conforming servers.
      return try await loadAllSongsFromAlbums()
    }
  }

  private func loadAllSongsUsingSearch() async throws -> [MusicTrack] {
    let pageSize = 500
    var offset = 0
    var result: [MusicTrack] = []
    while true {
      let root = try await call(
        SearchEnvelope.self, endpoint: "search3",
        query: libraryQuery([
          "query": "", "artistCount": "0", "albumCount": "0",
          "songCount": String(pageSize), "songOffset": String(offset),
        ])
      ).response
      try validate(root.status, root.error)
      let page = (root.searchResult3?.song ?? []).map(mapTrack)
      result.append(contentsOf: page)
      guard page.count == pageSize else { return result }
      offset += page.count
    }
  }

  private func loadAllSongsFromAlbums() async throws -> [MusicTrack] {
    let albums = try await fetchAlbums()
    var result: [MusicTrack] = []
    for start in stride(from: 0, to: albums.count, by: 8) {
      let end = min(start + 8, albums.count)
      let batch = Array(albums[start..<end])
      let values = try await withThrowingTaskGroup(of: (Int, [MusicTrack]).self) { group in
        for (offset, album) in batch.enumerated() {
          group.addTask { [self] in
            let detail = try await fetchAlbum(id: album.identity.remoteID)
            return (offset, detail.tracks)
          }
        }
        var loaded: [(Int, [MusicTrack])] = []
        for try await value in group { loaded.append(value) }
        return loaded.sorted { $0.0 < $1.0 }
      }
      for value in values { result.append(contentsOf: value.1) }
    }
    return result
  }

  func fetchPlaylists() async throws -> [MusicPlaylist] {
    let root = try await call(PlaylistsEnvelope.self, endpoint: "getPlaylists").response
    try validate(root.status, root.error)
    return (root.playlists?.playlist ?? []).map(mapPlaylist)
  }

  func invalidateLibraryCache() async {
    albumLoadTask?.cancel()
    songLoadTask?.cancel()
    albumLoadTask = nil
    songLoadTask = nil
    cachedAlbums = nil
    cachedSongs = nil
  }

  func search(query: String) async throws -> MusicSearchResult {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
    let root = try await call(
      SearchEnvelope.self, endpoint: "search3",
      query: libraryQuery([
        "query": query, "artistCount": "30", "albumCount": "30", "songCount": "100",
      ])
    ).response
    try validate(root.status, root.error)
    let result = root.searchResult3
    return MusicSearchResult(
      artists: (result?.artist ?? []).map(mapArtist), albums: (result?.album ?? []).map(mapAlbum),
      tracks: (result?.song ?? []).map(mapTrack), playlists: [])
  }

  func fetchArtist(id remoteID: String) async throws -> MusicArtistDetail {
    let root = try await call(ArtistEnvelope.self, endpoint: "getArtist", query: ["id": remoteID])
      .response
    try validate(root.status, root.error)
    guard let artist = root.artist else { throw MusicSourceError.invalidResponse }
    return MusicArtistDetail(
      artist: mapArtist(artist), albums: (artist.album ?? []).map(mapAlbum), topTracks: [])
  }

  func fetchAlbum(id remoteID: String) async throws -> MusicAlbumDetail {
    let root = try await call(AlbumEnvelope.self, endpoint: "getAlbum", query: ["id": remoteID])
      .response
    try validate(root.status, root.error)
    guard let album = root.album else { throw MusicSourceError.invalidResponse }
    return MusicAlbumDetail(album: mapAlbum(album), tracks: (album.song ?? []).map(mapTrack))
  }

  func fetchPlaylist(id remoteID: String) async throws -> MusicPlaylistDetail {
    let root = try await call(
      PlaylistEnvelope.self, endpoint: "getPlaylist", query: ["id": remoteID]
    ).response
    try validate(root.status, root.error)
    guard let playlist = root.playlist else { throw MusicSourceError.invalidResponse }
    return MusicPlaylistDetail(
      playlist: mapPlaylist(playlist), tracks: (playlist.entry ?? []).map(mapTrack))
  }

  func fetchHomeSections() async throws -> [MusicSection] {
    async let recent = albumList(type: "recent", size: 20)
    async let newest = albumList(type: "newest", size: 20)
    async let frequent = albumList(type: "frequent", size: 20)
    async let random = randomSongs(size: 30)
    async let playlists = fetchPlaylists()
    async let starred = starredItems()
    var sections: [MusicSection] = []
    if let values = try? await recent, !values.isEmpty {
      sections.append(
        .init(
id: "recent", title: String(localized: "最近播放"), kind: .recentlyPlayed,
          items: values.map(MusicSectionItem.album)))
    }
    if let values = try? await newest, !values.isEmpty {
      sections.append(
        .init(
id: "newest", title: String(localized: "最近加入"), kind: .recentlyAdded,
          items: values.map(MusicSectionItem.album)))
    }
    if let values = try? await frequent, !values.isEmpty {
      sections.append(
        .init(
id: "frequent", title: String(localized: "常听专辑"), kind: .frequentAlbums,
          items: values.map(MusicSectionItem.album)))
    }
    if let values = try? await random, !values.isEmpty {
      sections.append(
.init(id: "random", title: String(localized: "随机推荐"), kind: .random, items: values.map(MusicSectionItem.track))
      )
    }
    if let values = try? await playlists, !values.isEmpty {
      sections.append(
        .init(
id: "playlists", title: String(localized: "我的歌单"), kind: .playlists,
          items: values.map(MusicSectionItem.playlist)))
    }
    if let values = try? await starred {
      if !values.tracks.isEmpty {
        sections.append(
          .init(
id: "favorite-tracks", title: String(localized: "喜欢的歌曲"), kind: .favoriteTracks,
            items: values.tracks.map(MusicSectionItem.track)))
      }
      if !values.albums.isEmpty {
        sections.append(
          .init(
id: "favorite-albums", title: String(localized: "收藏专辑"), kind: .favoriteAlbums,
            items: values.albums.map(MusicSectionItem.album)))
      }
      if !values.artists.isEmpty {
        sections.append(
          .init(
id: "favorite-artists", title: String(localized: "收藏艺人"), kind: .favoriteArtists,
            items: values.artists.map(MusicSectionItem.artist)))
      }
    }
    return sections
  }

  func fetchLyrics(for track: MusicTrack) async throws -> MusicLyrics? {
    if let structured = try? await fetchStructuredLyrics(for: track) { return structured }
    let root = try await call(
      LyricsEnvelope.self, endpoint: "getLyrics",
      query: ["artist": track.artistName, "title": track.title]
    ).response
    try validate(root.status, root.error)
    guard let text = root.lyrics?.value, !text.isEmpty else { return nil }
    return MusicLyrics(
      displayArtist: root.lyrics?.artist, displayTitle: root.lyrics?.title, language: nil,
      lines: text.split(separator: "\n", omittingEmptySubsequences: false).map {
        .init(time: nil, text: String($0))
      }, isSynced: false)
  }

  private func fetchStructuredLyrics(for track: MusicTrack) async throws -> MusicLyrics? {
    let root = try await call(
      StructuredLyricsEnvelope.self, endpoint: "getLyricsBySongId",
      query: ["id": track.identity.remoteID]
    ).response
    try validate(root.status, root.error)
    guard
      let value = root.lyricsList?.structuredLyrics.first(where: {
        $0.kind == nil || $0.kind == "main"
      }) ?? root.lyricsList?.structuredLyrics.first
    else { return nil }
    return MusicLyrics(
      displayArtist: value.displayArtist, displayTitle: value.displayTitle,
      language: value.lang == "xxx" ? nil : value.lang,
      lines: value.line.map {
        .init(time: $0.start.map { TimeInterval($0) / 1_000 }, text: $0.value)
      }, isSynced: value.synced)
  }

  func streamURL(for track: MusicTrack, quality: StreamingQuality) async throws -> URL {
    var query = ["id": track.identity.remoteID, "estimateContentLength": "true"]
    switch quality {
    case .original:
      break
    case .lossless:
      if !track.isNativelyPlayableOnIOS {
        query["maxBitRate"] = "320"
        query["format"] = "mp3"
      }
    case .high, .standard, .dataSaver:
      query["maxBitRate"] = String(quality.maximumBitRate ?? 320)
      query["format"] = "mp3"
    }
    return try endpointURL("stream", query: query)
  }

  func loadMediaResource(at url: URL, range: String?) async throws -> MusicMediaResponse {
    var request = URLRequest(url: url)
    request.timeoutInterval = 60
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    do {
      return try await http.mediaResponse(
        for: request, retryPolicy: .transient(maxAttempts: 3))
    } catch let error as MusicSourceError
      where url.query?.contains("format=") == true
    {
      if case .httpStatus = error { throw MusicSourceError.transcodingFailed }
      throw error
    }
  }

  func streamMediaResource(
    at url: URL, range: String?,
    onResponse: @escaping @Sendable (MusicMediaResponseMetadata) async throws -> Bool,
    onData: @escaping @Sendable (Data) async throws -> Bool
  ) async throws {
    var request = URLRequest(url: url)
    request.timeoutInterval = 60
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    do {
      try await http.streamMediaResponse(
        for: request, retryPolicy: .transient(maxAttempts: 3),
        onResponse: onResponse, onData: onData)
    } catch let error as MusicSourceError
      where url.query?.contains("format=") == true
    {
      if case .httpStatus = error { throw MusicSourceError.transcodingFailed }
      throw error
    }
  }

  func downloadMediaResource(at url: URL) async throws -> MusicMediaDownload {
    var request = URLRequest(url: url)
    request.timeoutInterval = 180
    do {
      return try await http.downloadResponse(
        for: request, retryPolicy: .transient(maxAttempts: 3))
    } catch let error as MusicSourceError
      where url.query?.contains("format=") == true
    {
      if case .httpStatus = error { throw MusicSourceError.transcodingFailed }
      throw error
    }
  }

  nonisolated func artworkURL(for item: MusicArtworkItem, size: CGSize?) -> URL? {
    let coverID: String? =
      switch item {
      case .artist(let value): value.metadata["coverArt"].stringValue
      case .album(let value): value.metadata["coverArt"].stringValue
      case .track(let value): value.metadata["coverArt"].stringValue
      case .playlist(let value): value.metadata["coverArt"].stringValue
      }
    guard let coverID else { return nil }
    var query = ["id": coverID]
    if let size { query["size"] = String(Int(max(size.width, size.height))) }
    return try? endpointURL("getCoverArt", query: query)
  }

  func setFavorite(item: MusicLibraryItem, isFavorite: Bool) async throws {
    let parameter: (String, String) =
      switch item {
      case .artist(let value): ("artistId", value.identity.remoteID)
      case .album(let value): ("albumId", value.identity.remoteID)
      case .track(let value): ("id", value.identity.remoteID)
      }
    _ = try await call(
      PingEnvelope.self, endpoint: isFavorite ? "star" : "unstar", query: [parameter.0: parameter.1]
    )
    cachedAlbums = nil
    cachedSongs = nil
  }

  func createPlaylist(name: String, trackIDs: [String]) async throws -> MusicPlaylist {
    let root = try await call(
      PlaylistEnvelope.self, endpoint: "createPlaylist", query: ["name": name],
      repeatedQuery: trackIDs.map { ("songId", $0) }
    ).response
    try validate(root.status, root.error)
    if let value = root.playlist { return mapPlaylist(value) }
    if let value = try await fetchPlaylists().first(where: { $0.name == name }) { return value }
    throw MusicSourceError.invalidResponse
  }

  func updatePlaylist(id: String, name: String?, adding: [String], removingIndexes: [Int])
    async throws
  {
    var query = ["playlistId": id]
    if let name { query["name"] = name }
    let repeated =
      adding.map { ("songIdToAdd", $0) } + removingIndexes.map { ("songIndexToRemove", String($0)) }
    _ = try await call(
      PingEnvelope.self, endpoint: "updatePlaylist", query: query, repeatedQuery: repeated)
  }

  func deletePlaylist(id: String) async throws {
    _ = try await call(PingEnvelope.self, endpoint: "deletePlaylist", query: ["id": id])
  }

  func reportPlayback(_ event: PlaybackEvent) async throws {
    let endpoint: String
    var query: [String: String]
    switch event {
    case .started(let track):
      endpoint = "scrobble"
      query = ["id": track.identity.remoteID, "submission": "false"]
    case .completed(let track):
      endpoint = "scrobble"
      query = ["id": track.identity.remoteID, "submission": "true"]
    case .progress(let track, let position, _), .stopped(let track, let position):
      endpoint = "savePlayQueue"
      query = [
        "id": track.identity.remoteID, "current": track.identity.remoteID,
        "position": String(Int(position * 1000)),
      ]
    }
    _ = try await call(PingEnvelope.self, endpoint: endpoint, query: query)
  }

  private func albumList(type: String, size: Int, offset: Int = 0) async throws -> [MusicAlbum] {
    let root = try await call(
      AlbumListEnvelope.self, endpoint: "getAlbumList2",
      query: libraryQuery(["type": type, "size": String(size), "offset": String(offset)])
    ).response
    try validate(root.status, root.error)
    return (root.albumList2?.album ?? []).map(mapAlbum)
  }

  private func randomSongs(size: Int) async throws -> [MusicTrack] {
    let root = try await call(
      RandomEnvelope.self, endpoint: "getRandomSongs", query: libraryQuery(["size": String(size)])
    ).response
    try validate(root.status, root.error)
    return (root.randomSongs?.song ?? []).map(mapTrack)
  }

  private func starredItems() async throws -> (
    artists: [MusicArtist], albums: [MusicAlbum], tracks: [MusicTrack]
  ) {
    let root = try await call(StarredEnvelope.self, endpoint: "getStarred2", query: libraryQuery())
      .response
    try validate(root.status, root.error)
    return (
      (root.starred2?.artist ?? []).map(mapArtist), (root.starred2?.album ?? []).map(mapAlbum),
      (root.starred2?.song ?? []).map(mapTrack)
    )
  }

  private func call<T: Decodable & Sendable>(
    _ type: T.Type, endpoint: String, query: [String: String] = [:],
    repeatedQuery: [(String, String)] = []
  ) async throws -> T {
    var request = URLRequest(
      url: try endpointURL(endpoint, query: query, repeatedQuery: repeatedQuery))
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return try await http.decoded(type, for: request, decoder: decoder)
  }

  private nonisolated func endpointURL(
    _ endpoint: String, query: [String: String], repeatedQuery: [(String, String)] = []
  ) throws -> URL {
    guard
      var components = URLComponents(
        url: server.baseURL.appendingAPIPath("rest/\(endpoint).view"),
        resolvingAgainstBaseURL: false)
    else { throw MusicSourceError.invalidAddress }
    let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    guard let password = credentials.password else { throw MusicSourceError.authenticationFailed }
    let digest = Insecure.MD5.hash(data: Data((password + salt).utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    var values = query
    values.merge([
      "u": server.username, "t": digest, "s": String(salt), "v": "1.13.0",
      "c": "UniversalPersonalMusic", "f": "json",
    ]) { old, _ in old }
    components.queryItems =
      values.sorted(by: { $0.key < $1.key }).map(URLQueryItem.init)
      + repeatedQuery.map { URLQueryItem(name: $0.0, value: $0.1) }
    guard let url = components.url else { throw MusicSourceError.invalidAddress }
    return url
  }

  private func validate(_ status: String, _ error: SubsonicErrorDTO?) throws {
    guard status == "ok" else { throw mapSubsonicError(error) }
  }
  private nonisolated func libraryQuery(_ values: [String: String] = [:]) -> [String: String] {
    var result = values
    if let libraryID = server.defaultLibraryID { result["musicFolderId"] = libraryID }
    return result
  }
  private func mapSubsonicError(_ error: SubsonicErrorDTO?) -> MusicSourceError {
    switch error?.code {
    case 40: return .authenticationFailed
    case 41: return .tokenExpired
    case 50: return .permissionDenied
    case 60, 70: return .incompatibleServer
    default: return .invalidResponse
    }
  }

  private nonisolated func mapArtist(_ dto: ArtistDTO) -> MusicArtist {
    .init(
      identity: .init(providerID: id, remoteID: dto.id, sourceType: sourceType), name: dto.name,
      biography: nil, artworkURL: coverURL(dto.coverArt), albumCount: dto.albumCount,
      favoriteState: dto.starred == nil ? .notFavorite : .favorite,
      metadata: dto.coverArt.map { ["coverArt": .string($0)] } ?? [:])
  }
  private nonisolated func mapAlbum(_ dto: AlbumDTO) -> MusicAlbum {
    .init(
      identity: .init(providerID: id, remoteID: dto.id, sourceType: sourceType),
artistID: dto.artistId, title: dto.name ?? dto.title ?? String(localized: "未知专辑"),
artistName: dto.artist ?? String(localized: "未知艺人"), releaseDate: nil, year: dto.year,
      artworkURL: coverURL(dto.coverArt), genreNames: dto.genre.map { [$0] } ?? [],
      trackCount: dto.songCount, duration: dto.duration.map(TimeInterval.init),
      favoriteState: dto.starred == nil ? .notFavorite : .favorite,
      metadata: dto.coverArt.map { ["coverArt": .string($0)] } ?? [:])
  }
  private nonisolated func mapTrack(_ dto: SongDTO) -> MusicTrack {
    var metadata = dto.coverArt.map { ["coverArt": MetadataValue.string($0)] } ?? [:]
    if let size = dto.size, size > 0, size <= Int64(Int.max) {
      metadata["sizeBytes"] = .integer(Int(size))
    }
    return .init(
      identity: .init(providerID: id, remoteID: dto.id, sourceType: sourceType),
      albumRemoteID: dto.albumId, artistRemoteID: dto.artistId, title: dto.title,
artistName: dto.artist ?? String(localized: "未知艺人"), albumTitle: dto.album, discNumber: dto.discNumber ?? 1,
      trackNumber: dto.track ?? 0, duration: TimeInterval(dto.duration ?? 0),
      artworkURL: coverURL(dto.coverArt), lyrics: nil, isExplicit: false,
      favoriteState: dto.starred == nil ? .notFavorite : .favorite, contentType: dto.contentType,
      suffix: dto.suffix, bitRate: dto.bitRate,
      metadata: metadata)
  }
  private nonisolated func mapPlaylist(_ dto: PlaylistDTO) -> MusicPlaylist {
    .init(
      identity: .init(providerID: id, remoteID: dto.id, sourceType: sourceType), name: dto.name,
      artworkURL: coverURL(dto.coverArt), trackCount: dto.songCount ?? dto.entry?.count ?? 0,
      duration: dto.duration.map(TimeInterval.init), isPublic: dto.`public` ?? false,
      isEditable: dto.owner == nil || dto.owner == server.username,
      metadata: dto.coverArt.map { ["coverArt": .string($0)] } ?? [:])
  }
  private nonisolated func coverURL(_ coverID: String?) -> URL? {
    guard let coverID else { return nil }
    return try? endpointURL("getCoverArt", query: ["id": coverID])
  }
}

extension Optional where Wrapped == MetadataValue {
  fileprivate var stringValue: String? { if case .string(let value) = self { value } else { nil } }
}
private struct SubsonicErrorDTO: Decodable {
  let code: Int?
  let message: String?
}
private struct BaseResponse: Decodable {
  let status: String
  let version: String?
  let error: SubsonicErrorDTO?
}
private struct PingEnvelope: Decodable {
  let response: BaseResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
private struct ArtistsDTO: Decodable { let index: [ArtistIndexDTO]? }
private struct ArtistIndexDTO: Decodable { let artist: [ArtistDTO] }
private struct ArtistDTO: Decodable {
  let id: String
  let name: String
  let coverArt: String?
  let albumCount: Int?
  let starred: String?
  let album: [AlbumDTO]?
}
private struct AlbumDTO: Decodable {
  let id: String
  let name: String?
  let title: String?
  let artist: String?
  let artistId: String?
  let coverArt: String?
  let songCount: Int?
  let duration: Int?
  let year: Int?
  let genre: String?
  let starred: String?
  let song: [SongDTO]?
}
private struct SongDTO: Decodable {
  let id: String
  let title: String
  let album: String?
  let artist: String?
  let albumId: String?
  let artistId: String?
  let coverArt: String?
  let duration: Int?
  let track: Int?
  let discNumber: Int?
  let contentType: String?
  let suffix: String?
  let bitRate: Int?
  let size: Int64?
  let starred: String?
}
private struct PlaylistDTO: Decodable {
  let id: String
  let name: String
  let owner: String?
  let `public`: Bool?
  let songCount: Int?
  let duration: Int?
  let coverArt: String?
  let entry: [SongDTO]?
}
private struct ArtistsResponse: Decodable {
  let status: String
  let error: SubsonicErrorDTO?
  let artists: ArtistsDTO?
}
private struct ArtistsEnvelope: Decodable {
  let response: ArtistsResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
private struct ArtistResponse: Decodable {
  let status: String
  let error: SubsonicErrorDTO?
  let artist: ArtistDTO?
}
private struct ArtistEnvelope: Decodable {
  let response: ArtistResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
private struct AlbumResponse: Decodable {
  let status: String
  let error: SubsonicErrorDTO?
  let album: AlbumDTO?
}
private struct AlbumEnvelope: Decodable {
  let response: AlbumResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
private struct AlbumListDTO: Decodable { let album: [AlbumDTO]? }
private struct AlbumListResponse: Decodable {
  let status: String
  let error: SubsonicErrorDTO?
  let albumList2: AlbumListDTO?
}
private struct AlbumListEnvelope: Decodable {
  let response: AlbumListResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
private struct PlaylistsDTO: Decodable { let playlist: [PlaylistDTO]? }
private struct PlaylistsResponse: Decodable {
  let status: String
  let error: SubsonicErrorDTO?
  let playlists: PlaylistsDTO?
}
private struct PlaylistsEnvelope: Decodable {
  let response: PlaylistsResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
private struct PlaylistResponse: Decodable {
  let status: String
  let error: SubsonicErrorDTO?
  let playlist: PlaylistDTO?
}
private struct PlaylistEnvelope: Decodable {
  let response: PlaylistResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
private struct SearchResultDTO: Decodable {
  let artist: [ArtistDTO]?
  let album: [AlbumDTO]?
  let song: [SongDTO]?
}
private struct SearchResponse: Decodable {
  let status: String
  let error: SubsonicErrorDTO?
  let searchResult3: SearchResultDTO?
}
private struct SearchEnvelope: Decodable {
  let response: SearchResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
private struct RandomSongsDTO: Decodable { let song: [SongDTO]? }
private struct RandomResponse: Decodable {
  let status: String
  let error: SubsonicErrorDTO?
  let randomSongs: RandomSongsDTO?
}
private struct RandomEnvelope: Decodable {
  let response: RandomResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
private struct StarredDTO: Decodable {
  let artist: [ArtistDTO]?
  let album: [AlbumDTO]?
  let song: [SongDTO]?
}
private struct StarredResponse: Decodable {
  let status: String
  let error: SubsonicErrorDTO?
  let starred2: StarredDTO?
}
private struct StarredEnvelope: Decodable {
  let response: StarredResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
private struct LyricsDTO: Decodable {
  let artist: String?
  let title: String?
  let value: String?
}
private struct LyricsResponse: Decodable {
  let status: String
  let error: SubsonicErrorDTO?
  let lyrics: LyricsDTO?
}
private struct LyricsEnvelope: Decodable {
  let response: LyricsResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
private struct MusicFolderDTO: Decodable {
  let id: Int
  let name: String
}
private struct MusicFoldersDTO: Decodable { let musicFolder: [MusicFolderDTO]? }
private struct MusicFoldersResponse: Decodable {
  let status: String
  let error: SubsonicErrorDTO?
  let musicFolders: MusicFoldersDTO?
}
private struct MusicFoldersEnvelope: Decodable {
  let response: MusicFoldersResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
private struct StructuredLyricsLineDTO: Decodable {
  let start: Int?
  let value: String
}
private struct StructuredLyricsDTO: Decodable {
  let displayArtist: String?
  let displayTitle: String?
  let lang: String?
  let synced: Bool
  let kind: String?
  let line: [StructuredLyricsLineDTO]
}
private struct StructuredLyricsListDTO: Decodable { let structuredLyrics: [StructuredLyricsDTO] }
private struct StructuredLyricsResponse: Decodable {
  let status: String
  let error: SubsonicErrorDTO?
  let lyricsList: StructuredLyricsListDTO?
}
private struct StructuredLyricsEnvelope: Decodable {
  let response: StructuredLyricsResponse
  enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
