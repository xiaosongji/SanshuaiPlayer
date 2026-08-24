import CoreGraphics
import Foundation

actor JellyfinProvider: MusicSourceProvider {
  nonisolated let id: UUID
  nonisolated let sourceType: MusicSourceType = .jellyfin
  nonisolated let capabilities: Set<MusicProviderCapability> = [
    .home, .artists, .albums, .tracks, .playlists, .search, .lyrics, .favorites, .progress,
    .playlistEditing, .transcoding, .recentlyPlayed, .recentlyAdded, .resume,
  ]

  private nonisolated let server: MusicServer
  private let credentials: ProviderCredentials
  private let http: ProviderHTTPClient
  private let decoder: JSONDecoder
  private nonisolated let tokenStorage: TokenStorage
  private var userID: String?
  private var playSessionIDsByItemID: [String: String] = [:]

  init(server: MusicServer, credentials: ProviderCredentials, session: URLSession? = nil) {
    id = server.id
    self.server = server
    self.credentials = credentials
    http = ProviderHTTPClient(server: server, session: session)
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractional.date(from: value) { return date }
      let standard = ISO8601DateFormatter()
      if let date = standard.date(from: value) { return date }
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO-8601 date")
    }
    tokenStorage = TokenStorage(credentials.token)
    userID = credentials.remoteUserID
    if userID == nil, case .string(let savedUserID) = server.metadata["jellyfinUserID"] {
      userID = savedUserID
    }
  }

  func authenticate() async throws {
    if tokenStorage.value != nil, userID != nil {
      _ = try await systemInfo()
      return
    }
    guard let password = credentials.password else { throw MusicSourceError.authenticationFailed }
    var request = try request(
      path: "Users/AuthenticateByName", method: "POST", authenticated: false)
    request.httpBody = try JSONEncoder().encode(
      AuthenticationRequest(username: server.username, password: password))
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let response = try await http.decoded(
      AuthenticationResponse.self, for: request, decoder: decoder)
    guard !response.accessToken.isEmpty else { throw MusicSourceError.authenticationFailed }
    tokenStorage.value = response.accessToken
    userID = response.user.id
  }

  func refreshedCredentials() async -> ProviderCredentials? {
    guard let accessToken = tokenStorage.value else { return nil }
    return ProviderCredentials(
      password: credentials.password, token: accessToken, remoteUserID: userID)
  }

  func fetchServerInfo() async throws -> MusicServerInfo {
    try await ensureAuthenticated()
    let info = try await systemInfo()
    return .init(
      name: info.serverName ?? server.name, version: info.version, type: sourceType,
      capabilities: capabilities)
  }

  func fetchLibraries() async throws -> [MusicLibrary] {
    try await ensureAuthenticated()
    let values = try await itemsAt(path: "Users/\(requiredUserID())/Views", query: [:])
    return values.filter { $0.collectionType?.lowercased() == "music" }.map {
      MusicLibrary(id: $0.id, name: $0.name)
    }
  }

  func fetchArtists() async throws -> [MusicArtist] {
    try await albumArtists().map(mapArtist)
  }
  func fetchAlbums() async throws -> [MusicAlbum] {
    try await items(types: ["MusicAlbum"], fields: commonFields).map(mapAlbum)
  }
  func fetchSongs() async throws -> [MusicTrack] {
    try await items(types: ["Audio"], fields: commonFields).map(mapTrack)
  }
  func fetchPlaylists() async throws -> [MusicPlaylist] {
    try await items(types: ["Playlist"], fields: commonFields, scopeToDefaultLibrary: false).map(
      mapPlaylist)
  }

  func search(query: String) async throws -> MusicSearchResult {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
    async let valuesRequest = items(
      types: ["MusicAlbum", "Audio", "Playlist"], fields: commonFields,
      extra: ["SearchTerm": query, "Limit": "100"])
    async let artistsRequest = albumArtists(extra: ["SearchTerm": query, "Limit": "30"])
    let values = try await valuesRequest
    let artists = try await artistsRequest
    return .init(
      artists: artists.map(mapArtist),
      albums: values.filter { $0.itemType == "MusicAlbum" }.map(mapAlbum),
      tracks: values.filter { $0.itemType == "Audio" }.map(mapTrack),
      playlists: values.filter { $0.itemType == "Playlist" }.map(mapPlaylist))
  }

  func fetchArtist(id remoteID: String) async throws -> MusicArtistDetail {
    let artist = try await item(id: remoteID)
    let albums = try await items(
      types: ["MusicAlbum"], fields: commonFields, extra: ["ArtistIds": remoteID])
    let tracks = try await items(
      types: ["Audio"], fields: commonFields,
      extra: [
        "ArtistIds": remoteID, "Limit": "50", "SortBy": "PlayCount", "SortOrder": "Descending",
      ])
    return .init(
      artist: mapArtist(artist), albums: albums.map(mapAlbum), topTracks: tracks.map(mapTrack))
  }

  func fetchAlbum(id remoteID: String) async throws -> MusicAlbumDetail {
    let album = try await item(id: remoteID)
    let tracks = try await items(
      types: ["Audio"], fields: commonFields,
      extra: ["ParentId": remoteID, "SortBy": "ParentIndexNumber,IndexNumber"])
    return .init(album: mapAlbum(album), tracks: tracks.map(mapTrack))
  }

  func fetchPlaylist(id remoteID: String) async throws -> MusicPlaylistDetail {
    let playlist = try await item(id: remoteID)
    let tracks = try await itemsAt(
      path: "Playlists/\(remoteID)/Items", query: ["UserId": try requiredUserID()])
    return .init(playlist: mapPlaylist(playlist), tracks: tracks.map(mapTrack))
  }

  func fetchHomeSections() async throws -> [MusicSection] {
    async let resume = items(
      types: ["Audio"], fields: commonFields, extra: ["Filters": "IsResumable", "Limit": "30"])
    async let recent = items(
      types: ["Audio"], fields: commonFields,
      extra: [
        "Filters": "IsPlayed", "SortBy": "DatePlayed", "SortOrder": "Descending", "Limit": "30",
      ])
    async let latest = items(
      types: ["MusicAlbum"], fields: commonFields,
      extra: ["SortBy": "DateCreated", "SortOrder": "Descending", "Limit": "20"])
    async let playlists = fetchPlaylists()
    async let frequentAlbums = items(
      types: ["MusicAlbum"], fields: commonFields,
      extra: ["SortBy": "PlayCount", "SortOrder": "Descending", "Limit": "20"])
    async let frequentArtists = albumArtists(
      extra: ["SortBy": "PlayCount", "SortOrder": "Descending", "Limit": "20"])
    async let random = items(
      types: ["Audio"], fields: commonFields, extra: ["SortBy": "Random", "Limit": "30"])
    async let favoriteTracks = items(
      types: ["Audio"], fields: commonFields, extra: ["Filters": "IsFavorite", "Limit": "30"])
    async let favoriteAlbums = items(
      types: ["MusicAlbum"], fields: commonFields, extra: ["Filters": "IsFavorite", "Limit": "20"])
    async let favoriteArtists = items(
      types: ["MusicArtist"], fields: commonFields, extra: ["Filters": "IsFavorite", "Limit": "20"])
    var result: [MusicSection] = []
    if let values = try? await resume, !values.isEmpty {
      result.append(
        .init(
id: "resume", title: String(localized: "继续播放"), kind: .resume,
          items: values.map(mapTrack).map(MusicSectionItem.track)))
    }
    if let values = try? await recent, !values.isEmpty {
      result.append(
        .init(
id: "recent", title: String(localized: "最近播放"), kind: .recentlyPlayed,
          items: values.map(mapTrack).map(MusicSectionItem.track)))
    }
    if let values = try? await latest, !values.isEmpty {
      result.append(
        .init(
id: "latest", title: String(localized: "最近加入"), kind: .recentlyAdded,
          items: values.map(mapAlbum).map(MusicSectionItem.album)))
    }
    if let values = try? await playlists, !values.isEmpty {
      result.append(
        .init(
id: "playlists", title: String(localized: "我的歌单"), kind: .playlists,
          items: values.map(MusicSectionItem.playlist)))
    }
    if let values = try? await frequentAlbums, !values.isEmpty {
      result.append(
        .init(
id: "frequent-albums", title: String(localized: "常听专辑"), kind: .frequentAlbums,
          items: values.map(mapAlbum).map(MusicSectionItem.album)))
    }
    if let values = try? await frequentArtists, !values.isEmpty {
      result.append(
        .init(
id: "frequent-artists", title: String(localized: "常听艺人"), kind: .frequentArtists,
          items: values.map(mapArtist).map(MusicSectionItem.artist)))
    }
    if let values = try? await random, !values.isEmpty {
      result.append(
        .init(
id: "random", title: String(localized: "随机推荐"), kind: .random,
          items: values.map(mapTrack).map(MusicSectionItem.track)))
    }
    if let values = try? await favoriteTracks, !values.isEmpty {
      result.append(
        .init(
id: "favorite-tracks", title: String(localized: "喜欢的歌曲"), kind: .favoriteTracks,
          items: values.map(mapTrack).map(MusicSectionItem.track)))
    }
    if let values = try? await favoriteAlbums, !values.isEmpty {
      result.append(
        .init(
id: "favorite-albums", title: String(localized: "收藏专辑"), kind: .favoriteAlbums,
          items: values.map(mapAlbum).map(MusicSectionItem.album)))
    }
    if let values = try? await favoriteArtists, !values.isEmpty {
      result.append(
        .init(
id: "favorite-artists", title: String(localized: "收藏艺人"), kind: .favoriteArtists,
          items: values.map(mapArtist).map(MusicSectionItem.artist)))
    }
    return result
  }

  func fetchLyrics(for track: MusicTrack) async throws -> MusicLyrics? {
    let request = try await authenticatedRequest(path: "Audio/\(track.identity.remoteID)/Lyrics")
    do {
      let response = try await http.decoded(JellyfinLyrics.self, for: request, decoder: decoder)
      let lines = response.lyrics.map {
        MusicLyrics.Line(time: $0.start.map { TimeInterval($0) / 10_000_000 }, text: $0.text)
      }
      return lines.isEmpty
        ? nil
        : .init(
          displayArtist: track.artistName, displayTitle: track.title, language: nil, lines: lines,
          isSynced: lines.contains { $0.time != nil })
    } catch MusicSourceError.fileNotFound { return nil }
  }

  func streamURL(for track: MusicTrack, quality: StreamingQuality) async throws -> URL {
    try await ensureAuthenticated()
    guard let token = tokenStorage.value else { throw MusicSourceError.tokenExpired }
    // One session per item, reused across retries and quality fallbacks. Minting a fresh id on
    // every call leaked a server-side transcode session for each skipped track.
    let sessionID = playSessionID(for: track.identity.remoteID)
    var parameters = [
      "api_key": token, "UserId": try requiredUserID(), "DeviceId": deviceID,
      "PlaySessionId": sessionID,
    ]
    let needsCompatibilityTranscode = !track.isNativelyPlayableOnIOS
    let usesDirectStream =
      quality == .original
      || (quality == .lossless && !needsCompatibilityTranscode)
    if usesDirectStream {
      parameters["Static"] = "true"
    } else if quality == .lossless {
      parameters["Container"] = "flac"
      parameters["TranscodingContainer"] = "flac"
      parameters["AudioCodec"] = "flac"
      parameters["TranscodingProtocol"] = "http"
      parameters["MaxStreamingBitrate"] = "1411000"
    } else {
      let bitRate = quality.maximumBitRate ?? 320
      parameters["Container"] = "mp3"
      parameters["TranscodingContainer"] = "mp3"
      parameters["AudioCodec"] = "mp3"
      parameters["TranscodingProtocol"] = "http"
      parameters["MaxStreamingBitrate"] = String(bitRate * 1000)
    }
    return try url(
      path: "Audio/\(track.identity.remoteID)/\(usesDirectStream ? "stream" : "universal")",
      query: parameters)
  }

  /// The api_key query item is dropped in favour of the token header so the URL never carries a
  /// credential into caches or logs.
  private nonisolated func mediaRequestURL(_ url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    components.queryItems = components.queryItems?.filter { $0.name.lowercased() != "api_key" }
    return components.url ?? url
  }

  func loadMediaResource(at url: URL, range: String?) async throws -> MusicMediaResponse {
    var request = URLRequest(url: mediaRequestURL(url))
    request.timeoutInterval = 60
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    if let token = tokenStorage.value {
      request.setValue(token, forHTTPHeaderField: "X-MediaBrowser-Token")
    }
    do {
      return try await http.mediaResponse(
        for: request, retryPolicy: .transient(maxAttempts: 3))
    } catch let error as MusicSourceError
      where url.query?.contains("TranscodingProtocol") == true
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
    var request = URLRequest(url: mediaRequestURL(url))
    request.timeoutInterval = 60
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    if let token = tokenStorage.value {
      request.setValue(token, forHTTPHeaderField: "X-MediaBrowser-Token")
    }
    do {
      try await http.streamMediaResponse(
        for: request, retryPolicy: .transient(maxAttempts: 3),
        onResponse: onResponse, onData: onData)
    } catch let error as MusicSourceError
      where url.query?.contains("TranscodingProtocol") == true
    {
      if case .httpStatus = error { throw MusicSourceError.transcodingFailed }
      throw error
    }
  }

  func downloadMediaResource(at url: URL) async throws -> MusicMediaDownload {
    var request = URLRequest(url: mediaRequestURL(url))
    request.timeoutInterval = 180
    if let token = tokenStorage.value {
      request.setValue(token, forHTTPHeaderField: "X-MediaBrowser-Token")
    }
    do {
      return try await http.downloadResponse(
        for: request, retryPolicy: .transient(maxAttempts: 3))
    } catch let error as MusicSourceError
      where url.query?.contains("TranscodingProtocol") == true
    {
      if case .httpStatus = error { throw MusicSourceError.transcodingFailed }
      throw error
    }
  }

  nonisolated func artworkURL(for item: MusicArtworkItem, size: CGSize?) -> URL? {
    let remoteID: String =
      switch item {
      case .artist(let value): value.identity.remoteID
      case .album(let value): value.identity.remoteID
      case .track(let value): value.identity.remoteID
      case .playlist(let value): value.identity.remoteID
      }
    var query: [String: String] = ["quality": "90"]
    if let token = tokenStorage.value { query["api_key"] = token }
    if let size {
      query["maxWidth"] = String(Int(size.width))
      query["maxHeight"] = String(Int(size.height))
    }
    return try? url(path: "Items/\(remoteID)/Images/Primary", query: query)
  }

  func setFavorite(item: MusicLibraryItem, isFavorite: Bool) async throws {
    let remoteID: String =
      switch item {
      case .artist(let value): value.identity.remoteID
      case .album(let value): value.identity.remoteID
      case .track(let value): value.identity.remoteID
      }
    let userID = try requiredUserID()
    let request = try await authenticatedRequest(
      path: "Users/\(userID)/FavoriteItems/\(remoteID)", method: isFavorite ? "POST" : "DELETE")
    _ = try await http.data(for: request)
  }

  func createPlaylist(name: String, trackIDs: [String]) async throws -> MusicPlaylist {
    let request = try await authenticatedRequest(
      path: "Playlists", method: "POST",
      query: [
        "Name": name, "Ids": trackIDs.joined(separator: ","), "UserId": try requiredUserID(),
        "MediaType": "Audio",
      ])
    let result = try await http.decoded(PlaylistCreationResult.self, for: request, decoder: decoder)
    return mapPlaylist(try await item(id: result.id))
  }

  func updatePlaylist(id: String, name: String?, adding: [String], removingIndexes: [Int])
    async throws
  {
    if let name {
      let currentRequest = try await authenticatedRequest(
        path: "Users/\(requiredUserID())/Items/\(id)")
      let data = try await http.data(for: currentRequest)
      guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MusicSourceError.invalidResponse
      }
      payload["Name"] = name
      var request = try await authenticatedRequest(path: "Items/\(id)", method: "POST")
      request.httpBody = try JSONSerialization.data(withJSONObject: payload)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      _ = try await http.data(for: request)
    }
    if !adding.isEmpty {
      let request = try await authenticatedRequest(
        path: "Playlists/\(id)/Items", method: "POST",
        query: ["Ids": adding.joined(separator: ","), "UserId": try requiredUserID()])
      _ = try await http.data(for: request)
    }
    if !removingIndexes.isEmpty {
      let entries = try await itemsAt(
        path: "Playlists/\(id)/Items", query: ["UserId": try requiredUserID()])
      let entryIDs = removingIndexes.compactMap { index in
        entries.indices.contains(index) ? entries[index].playlistItemID : nil
      }
      if !entryIDs.isEmpty {
        let request = try await authenticatedRequest(
          path: "Playlists/\(id)/Items", method: "DELETE",
          query: ["EntryIds": entryIDs.joined(separator: ",")])
        _ = try await http.data(for: request)
      }
    }
  }

  func deletePlaylist(id: String) async throws {
    let request = try await authenticatedRequest(path: "Items/\(id)", method: "DELETE")
    _ = try await http.data(for: request)
  }

  func reportPlayback(_ event: PlaybackEvent) async throws {
    let path: String
    let body: PlaybackReport
    switch event {
    case .started(let track):
      _ = playSessionID(for: track.identity.remoteID)
      path = "Sessions/Playing"
      body = report(track: track, position: 0, isPaused: false)
    case .progress(let track, let position, _):
      path = "Sessions/Playing/Progress"
      body = report(track: track, position: position, isPaused: false)
    case .completed(let track):
      path = "Sessions/Playing/Stopped"
      body = report(track: track, position: track.duration, isPaused: false)
    case .stopped(let track, let position):
      path = "Sessions/Playing/Stopped"
      body = report(track: track, position: position, isPaused: true)
    }
    var request = try await authenticatedRequest(path: path, method: "POST")
    request.httpBody = try JSONEncoder().encode(body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    _ = try await http.data(for: request)
    switch event {
    case .completed(let track), .stopped(let track, _):
      playSessionIDsByItemID.removeValue(forKey: track.identity.remoteID)
    case .started, .progress:
      break
    }
  }

  private func playSessionID(for remoteID: String) -> String {
    if let existing = playSessionIDsByItemID[remoteID] { return existing }
    let sessionID = UUID().uuidString.lowercased()
    // Bound the map so a long queue of prefetched-but-never-played tracks cannot grow it
    // without limit; the oldest ids belong to tracks the server has already timed out.
    if playSessionIDsByItemID.count >= 16 { playSessionIDsByItemID.removeAll() }
    playSessionIDsByItemID[remoteID] = sessionID
    return sessionID
  }

  private var commonFields: [String] {
    ["Overview", "DateCreated", "Genres", "MediaSources", "MediaStreams", "Path", "ProviderIds"]
  }
  private func report(track: MusicTrack, position: TimeInterval, isPaused: Bool) -> PlaybackReport {
    .init(
      itemID: track.identity.remoteID, positionTicks: Int64(position * 10_000_000),
      isPaused: isPaused, canSeek: true, playMethod: "DirectStream",
      playSessionID: playSessionID(for: track.identity.remoteID))
  }
  private var deviceID: String { "universal-personal-music-\(id.uuidString.lowercased())" }
  private func ensureAuthenticated() async throws {
    if tokenStorage.value == nil || userID == nil { try await authenticate() }
  }
  private func requiredUserID() throws -> String {
    guard let userID else { throw MusicSourceError.tokenExpired }
    return userID
  }

  private func systemInfo() async throws -> SystemInfo {
    let request = try await authenticatedRequest(path: "System/Info")
    return try await http.decoded(SystemInfo.self, for: request, decoder: decoder)
  }
  private func item(id: String) async throws -> JellyfinItem {
    let request = try await authenticatedRequest(path: "Users/\(requiredUserID())/Items/\(id)")
    return try await http.decoded(JellyfinItem.self, for: request, decoder: decoder)
  }
  private func items(
    types: [String], fields: [String], extra: [String: String] = [:],
    scopeToDefaultLibrary: Bool = true
  ) async throws -> [JellyfinItem] {
    try await ensureAuthenticated()
    var query = extra
    query["Recursive"] = "true"
    query["IncludeItemTypes"] = types.joined(separator: ",")
    query["Fields"] = fields.joined(separator: ",")
    if scopeToDefaultLibrary, query["ParentId"] == nil, let libraryID = server.defaultLibraryID {
      query["ParentId"] = libraryID
    }
    return try await itemsAt(path: "Users/\(requiredUserID())/Items", query: query)
  }
  private func itemsAt(path: String, query: [String: String]) async throws -> [JellyfinItem] {
    let request = try await authenticatedRequest(path: path, query: query)
    return try await http.decoded(ItemsResponse.self, for: request, decoder: decoder).items
  }
  private func albumArtists(extra: [String: String] = [:]) async throws -> [JellyfinItem] {
    try await ensureAuthenticated()
    var query = extra
    query["UserId"] = try requiredUserID()
    query["Recursive"] = "true"
    query["Fields"] = ["Overview", "ChildCount", "DateCreated"].joined(separator: ",")
    if query["ParentId"] == nil, let libraryID = server.defaultLibraryID {
      query["ParentId"] = libraryID
    }
    return try await itemsAt(path: "Artists/AlbumArtists", query: query)
  }
  private func authenticatedRequest(
    path: String, method: String = "GET", query: [String: String] = [:]
  ) async throws -> URLRequest {
    try await ensureAuthenticated()
    return try request(path: path, method: method, query: query, authenticated: true)
  }

  private func request(
    path: String, method: String, query: [String: String] = [:], authenticated: Bool
  ) throws -> URLRequest {
    var result = URLRequest(url: try url(path: path, query: query))
    result.httpMethod = method
    result.setValue("application/json", forHTTPHeaderField: "Accept")
    var authorization =
      "MediaBrowser Client=\"Universal Personal Music\", Device=\"iPhone\", DeviceId=\"\(deviceID)\", Version=\"1.0\""
    if authenticated, let accessToken = tokenStorage.value {
      authorization += ", Token=\"\(accessToken)\""
    }
    result.setValue(authorization, forHTTPHeaderField: "X-Emby-Authorization")
    return result
  }

  private nonisolated func url(path: String, query: [String: String]) throws -> URL {
    guard
      var components = URLComponents(
        url: server.baseURL.appendingAPIPath(path), resolvingAgainstBaseURL: false)
    else { throw MusicSourceError.invalidAddress }
    components.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
    guard let url = components.url else { throw MusicSourceError.invalidAddress }
    return url
  }

  private nonisolated func mapArtist(_ value: JellyfinItem) -> MusicArtist {
    .init(
      identity: .init(providerID: id, remoteID: value.id, sourceType: sourceType), name: value.name,
      biography: value.overview, artworkURL: artwork(remoteID: value.id),
      albumCount: value.childCount,
      favoriteState: value.userData?.isFavorite == true ? .favorite : .notFavorite, metadata: [:])
  }
  private nonisolated func mapAlbum(_ value: JellyfinItem) -> MusicAlbum {
    .init(
      identity: .init(providerID: id, remoteID: value.id, sourceType: sourceType),
      artistID: value.artistItems?.first?.id, title: value.name,
artistName: value.albumArtist ?? value.artists?.first ?? String(localized: "未知艺人"),
      releaseDate: value.dateCreated, year: value.productionYear,
      artworkURL: artwork(remoteID: value.id), genreNames: value.genres ?? [],
      trackCount: value.childCount,
      duration: value.runTimeTicks.map { TimeInterval($0) / 10_000_000 },
      favoriteState: value.userData?.isFavorite == true ? .favorite : .notFavorite, metadata: [:])
  }
  private nonisolated func mapTrack(_ value: JellyfinItem) -> MusicTrack {
    var metadata =
      value.userData?.playbackPositionTicks.map {
        ["resumePosition": MetadataValue.decimal(TimeInterval($0) / 10_000_000)]
      } ?? [:]
    if let size = value.mediaSources?.first?.size, size > 0, size <= Int64(Int.max) {
      metadata["sizeBytes"] = .integer(Int(size))
    }
    return .init(
      identity: .init(providerID: id, remoteID: value.id, sourceType: sourceType),
      albumRemoteID: value.albumID, artistRemoteID: value.artistItems?.first?.id, title: value.name,
artistName: value.artists?.first ?? value.albumArtist ?? String(localized: "未知艺人"), albumTitle: value.album,
      discNumber: value.parentIndexNumber ?? 1, trackNumber: value.indexNumber ?? 0,
      duration: value.runTimeTicks.map { TimeInterval($0) / 10_000_000 } ?? 0,
      artworkURL: artwork(remoteID: value.albumID ?? value.id), lyrics: nil, isExplicit: false,
      favoriteState: value.userData?.isFavorite == true ? .favorite : .notFavorite,
      contentType: value.mediaSources?.first?.container, suffix: value.container,
      bitRate: value.mediaSources?.first?.bitrate.map { $0 / 1000 },
      metadata: metadata)
  }
  private nonisolated func mapPlaylist(_ value: JellyfinItem) -> MusicPlaylist {
    .init(
      identity: .init(providerID: id, remoteID: value.id, sourceType: sourceType), name: value.name,
      artworkURL: artwork(remoteID: value.id), trackCount: value.childCount ?? 0,
      duration: value.runTimeTicks.map { TimeInterval($0) / 10_000_000 }, isPublic: false,
      isEditable: true, metadata: [:])
  }
  private nonisolated func artwork(remoteID: String) -> URL? {
    var query = ["quality": "90"]
    if let token = tokenStorage.value { query["api_key"] = token }
    return try? url(path: "Items/\(remoteID)/Images/Primary", query: query)
  }
}

private final class TokenStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String?
  init(_ value: String?) { stored = value }
  var value: String? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

private struct AuthenticationRequest: Encodable {
  let username: String
  let password: String
  enum CodingKeys: String, CodingKey {
    case username = "Username"
    case password = "Pw"
  }
}
private struct AuthenticationResponse: Decodable {
  struct UserDTO: Decodable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
  }
  let user: UserDTO
  let accessToken: String
  enum CodingKeys: String, CodingKey {
    case user = "User"
    case accessToken = "AccessToken"
  }
}
private struct SystemInfo: Decodable {
  let serverName: String?
  let version: String?
  enum CodingKeys: String, CodingKey {
    case serverName = "ServerName"
    case version = "Version"
  }
}
private struct ItemsResponse: Decodable {
  let items: [JellyfinItem]
  enum CodingKeys: String, CodingKey { case items = "Items" }
}
private struct PlaylistCreationResult: Decodable {
  let id: String
  enum CodingKeys: String, CodingKey { case id = "Id" }
}
private struct JellyfinItem: Decodable {
  struct UserDataDTO: Decodable {
    let isFavorite: Bool?
    let playbackPositionTicks: Int64?
    enum CodingKeys: String, CodingKey {
      case isFavorite = "IsFavorite"
      case playbackPositionTicks = "PlaybackPositionTicks"
    }
  }
  struct ArtistItemDTO: Decodable {
    let name: String?
    let id: String
    enum CodingKeys: String, CodingKey {
      case name = "Name"
      case id = "Id"
    }
  }
  struct MediaSourceDTO: Decodable {
    let container: String?
    let bitrate: Int?
    let size: Int64?
    enum CodingKeys: String, CodingKey {
      case container = "Container"
      case bitrate = "Bitrate"
      case size = "Size"
    }
  }
  let id: String
  let name: String
  let itemType: String?
  let collectionType: String?
  let overview: String?
  let album: String?
  let albumID: String?
  let albumArtist: String?
  let artists: [String]?
  let artistItems: [ArtistItemDTO]?
  let productionYear: Int?
  let dateCreated: Date?
  let genres: [String]?
  let childCount: Int?
  let runTimeTicks: Int64?
  let parentIndexNumber: Int?
  let indexNumber: Int?
  let container: String?
  let mediaSources: [MediaSourceDTO]?
  let userData: UserDataDTO?
  let playlistItemID: String?
  enum CodingKeys: String, CodingKey {
    case id = "Id"
    case name = "Name"
    case itemType = "Type"
    case collectionType = "CollectionType"
    case overview = "Overview"
    case album = "Album"
    case albumID = "AlbumId"
    case albumArtist = "AlbumArtist"
    case artists = "Artists"
    case artistItems = "ArtistItems"
    case productionYear = "ProductionYear"
    case dateCreated = "DateCreated"
    case genres = "Genres"
    case childCount = "ChildCount"
    case runTimeTicks = "RunTimeTicks"
    case parentIndexNumber = "ParentIndexNumber"
    case indexNumber = "IndexNumber"
    case container = "Container"
    case mediaSources = "MediaSources"
    case userData = "UserData"
    case playlistItemID = "PlaylistItemId"
  }
}
private struct JellyfinLyrics: Decodable {
  struct Line: Decodable {
    let text: String
    let start: Int64?
    enum CodingKeys: String, CodingKey {
      case text = "Text"
      case start = "Start"
    }
  }
  let lyrics: [Line]
  enum CodingKeys: String, CodingKey { case lyrics = "Lyrics" }
}
private struct PlaybackReport: Encodable {
  let itemID: String
  let positionTicks: Int64
  let isPaused: Bool
  let canSeek: Bool
  let playMethod: String
  let playSessionID: String?
  enum CodingKeys: String, CodingKey {
    case itemID = "ItemId"
    case positionTicks = "PositionTicks"
    case isPaused = "IsPaused"
    case canSeek = "CanSeek"
    case playMethod = "PlayMethod"
    case playSessionID = "PlaySessionId"
  }
}
