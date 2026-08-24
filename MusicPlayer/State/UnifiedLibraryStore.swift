import Foundation
import Observation

@MainActor
@Observable
final class UnifiedLibraryStore {
  private(set) var homeSections: [MusicSection] = []
  private(set) var artists: [MusicArtist] = []
  private(set) var albums: [MusicAlbum] = []
  private(set) var tracks: [MusicTrack] = []
  private(set) var playlists: [MusicPlaylist] = []
  private(set) var searchResult: MusicSearchResult = .empty
  private(set) var searchHistory: [String] = []
  private(set) var isLoading = false
  private(set) var isSearching = false
  private(set) var errorMessage: String?

  private let provider: any MusicSourceProvider
  private let cache: MusicCache
  private let onlineLyrics: any OnlineLyricsFetching
  private let automaticRefreshInterval: TimeInterval
  private let connectionReporter: @MainActor (MusicSourceError?) -> Void
  private var hasLoaded = false
  private var refreshRequestVersion = 0
  private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    provider: any MusicSourceProvider, cache: MusicCache = .shared,
    onlineLyrics: any OnlineLyricsFetching = OnlineLyricsService.shared,
    automaticRefreshInterval: TimeInterval = 6 * 60 * 60,
    connectionReporter: @escaping @MainActor (MusicSourceError?) -> Void = { _ in }
  ) {
    self.provider = provider
    self.cache = cache
    self.onlineLyrics = onlineLyrics
    self.automaticRefreshInterval = automaticRefreshInterval
    self.connectionReporter = connectionReporter
  }

  var capabilities: Set<MusicProviderCapability> { provider.capabilities }
  var favoriteTracks: [MusicTrack] {
    tracks.filter { $0.favoriteState == .favorite }
  }
  func isFavorite(_ track: MusicTrack) -> Bool {
    tracks.first(where: { $0.id == track.id })?.favoriteState == .favorite
      || searchResult.tracks.first(where: { $0.id == track.id })?.favoriteState == .favorite
      || track.favoriteState == .favorite
  }
  func artworkURL(for item: MusicArtworkItem, size: CGSize? = nil) -> URL? {
    let primary = provider.artworkURL(for: item, size: size)
    let fallback = ExternalArtworkFallback.url(for: item)
    if let primary, let fallback { return ArtworkURLFallback.attaching(fallback, to: primary) }
    return primary ?? fallback
  }
  func albumDetail(id: String) async throws -> MusicAlbumDetail {
    let value = try await provider.fetchAlbum(id: id)
    await recordRecent("album:\(id)")
    return .init(
      album: withArtworkFallback(value.album),
      tracks: value.tracks.map(withArtworkFallback))
  }
  func artistDetail(id: String) async throws -> MusicArtistDetail {
    let value = try await provider.fetchArtist(id: id)
    await recordRecent("artist:\(id)")
    return .init(
      artist: withArtworkFallback(value.artist),
      albums: value.albums.map(withArtworkFallback),
      topTracks: value.topTracks.map(withArtworkFallback))
  }
  func playlistDetail(id: String) async throws -> MusicPlaylistDetail {
    let value = try await provider.fetchPlaylist(id: id)
    await recordRecent("playlist:\(id)")
    return .init(
      playlist: value.playlist, tracks: value.tracks.map(withArtworkFallback))
  }
  func playbackQueue(for album: MusicAlbum) async -> [MusicTrack] {
    let local = tracks.filter {
      $0.albumRemoteID == album.identity.remoteID
        || ($0.albumRemoteID == nil
          && $0.albumTitle?.localizedCaseInsensitiveCompare(album.title) == .orderedSame
          && $0.artistName.localizedCaseInsensitiveCompare(album.artistName) == .orderedSame)
    }
    let sorted = sortAlbumTracks(local)
    if !sorted.isEmpty {
      await recordRecent("album:\(album.identity.remoteID)")
      return sorted
    }
    guard let detail = try? await albumDetail(id: album.identity.remoteID) else { return [] }
    return sortAlbumTracks(detail.tracks)
  }
  func playbackQueue(for artist: MusicArtist) async -> [MusicTrack] {
    let artistKey = ArtistPresentationPolicy.normalizedName(artist.name)
    let local = tracks.filter {
      $0.artistRemoteID == artist.identity.remoteID
        || ArtistPresentationPolicy.normalizedName($0.artistName) == artistKey
    }
    if !local.isEmpty {
      await recordRecent("artist:\(artist.identity.remoteID)")
      return sortArtistTracks(local)
    }
    guard let detail = try? await artistDetail(id: artist.identity.remoteID) else { return [] }
    return sortArtistTracks(detail.topTracks)
  }
  func lyrics(for track: MusicTrack) async throws -> MusicLyrics? {
    let cacheKey = resolvedLyricsCacheKey(for: track)
    if let cached = try? await cache.load(
      MusicLyrics.self, serverID: provider.id, namespace: .lyrics, key: cacheKey),
      let sanitized = LyricsQuality.sanitized(cached)
    {
      return sanitized
    }

    var serverFallback: MusicLyrics?
    do {
      if let value = try await provider.fetchLyrics(for: track),
        let sanitized = LyricsQuality.sanitized(value)
      {
        if LyricsQuality.isSynchronized(sanitized) {
          try? await cache.storeLyrics(
            sanitized, serverID: provider.id, key: cacheKey,
            owner: MusicResourceOwner.track(track.identity.remoteID))
          return sanitized
        }
        serverFallback = sanitized
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      // Missing or unsupported server lyrics should not block independent online fallbacks.
    }
    let resolved = try await onlineLyrics.fetchLyrics(for: track) ?? serverFallback
    if let resolved {
      try? await cache.storeLyrics(
        resolved, serverID: provider.id, key: cacheKey,
        owner: MusicResourceOwner.track(track.identity.remoteID))
    }
    return resolved
  }
  @discardableResult
  func createPlaylist(name: String) async throws -> MusicPlaylist {
    let playlist = try await provider.createPlaylist(name: name, trackIDs: [])
    upsertPlaylist(playlist)
    await persistSnapshot()
    return playlist
  }
  func renamePlaylist(id: String, name: String) async throws {
    try await provider.updatePlaylist(id: id, name: name, adding: [], removingIndexes: [])
    if let index = playlists.firstIndex(where: { $0.identity.remoteID == id }) {
      playlists[index].name = name
      syncPlaylistSection()
      await persistSnapshot()
    }
  }
  func add(_ track: MusicTrack, to playlist: MusicPlaylist) async {
    do {
      try await provider.updatePlaylist(
        id: playlist.identity.remoteID, name: nil, adding: [track.identity.remoteID],
        removingIndexes: [])
      if let index = playlists.firstIndex(where: {
        $0.identity.remoteID == playlist.identity.remoteID
      }) {
        playlists[index].trackCount += 1
        syncPlaylistSection()
        await persistSnapshot()
      }
    } catch { errorMessage = MusicSourceError.map(error).localizedDescription }
  }
  func removeFromPlaylist(id: String, indexes: [Int]) async throws {
    try await provider.updatePlaylist(id: id, name: nil, adding: [], removingIndexes: indexes)
    if let index = playlists.firstIndex(where: { $0.identity.remoteID == id }) {
      playlists[index].trackCount = max(0, playlists[index].trackCount - Set(indexes).count)
      syncPlaylistSection()
      await persistSnapshot()
    }
  }
  func deletePlaylist(id: String) async throws {
    try await provider.deletePlaylist(id: id)
    playlists.removeAll { $0.identity.remoteID == id }
    syncPlaylistSection()
    await persistSnapshot()
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    let savedAt = await restoreCache()
    if hasLoaded, let savedAt,
      Date().timeIntervalSince(savedAt) < automaticRefreshInterval
    {
      return
    }
    await refresh()
  }
  func dismissError() { errorMessage = nil }
  func refresh() async {
    refreshRequestVersion &+= 1
    if isLoading {
      await withCheckedContinuation { continuation in
        refreshWaiters.append(continuation)
      }
      return
    }
    isLoading = true
    repeat {
      let version = refreshRequestVersion
      await refreshOnce()
      if version == refreshRequestVersion { break }
    } while !Task.isCancelled
    isLoading = false
    let waiters = refreshWaiters
    refreshWaiters.removeAll(keepingCapacity: true)
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func refreshOnce() async {
    _ = await restoreCache()
    await provider.invalidateLibraryCache()
    async let homeRequest = provider.fetchHomeSections()
    async let artistsRequest = provider.fetchArtists()
    async let albumsRequest = provider.fetchAlbums()
    async let playlistsRequest = provider.fetchPlaylists()
    async let tracksRequest = provider.fetchSongs()
    var failures: [MusicSourceError] = []
    var refreshedArtists = false
    var refreshedAlbums = false
    var refreshedTracks = false
    var refreshedPlaylists = false
    do { homeSections = try await homeRequest.map(withArtworkFallback) } catch is CancellationError
    { return } catch {
      failures.append(.map(error))
    }
    do {
      artists = ArtistPresentationPolicy.deduplicated(
        try await artistsRequest.map(withArtworkFallback))
      refreshedArtists = true
    } catch is CancellationError { return } catch {
      failures.append(.map(error))
    }
    do {
      albums = try await albumsRequest.map(withArtworkFallback)
      refreshedAlbums = true
    } catch is CancellationError { return } catch {
      failures.append(.map(error))
    }
    do {
      playlists = try await playlistsRequest
      refreshedPlaylists = true
    } catch is CancellationError { return } catch {
      failures.append(.map(error))
    }
    do {
      tracks = try await tracksRequest.map(withArtworkFallback)
      refreshedTracks = true
    } catch is CancellationError { return } catch {
      failures.append(.map(error))
    }
    let snapshot = LibrarySnapshot(
      home: homeSections, artists: artists, albums: albums, tracks: tracks, playlists: playlists,
      savedAt: refreshedAlbums && refreshedTracks ? Date() : .distantPast)
    try? await cache.store(snapshot, serverID: provider.id, namespace: .metadata, key: "library")
    try? await cache.trimIfNeeded()
    if refreshedArtists && refreshedAlbums && refreshedTracks && refreshedPlaylists {
      try? await cache.reconcilePersistentResources(
        serverID: provider.id, retainingOwners: persistentResourceOwners())
    }
    hasLoaded =
      !homeSections.isEmpty || !artists.isEmpty || !albums.isEmpty || !tracks.isEmpty
      || !playlists.isEmpty
    connectionReporter(failures.first)
    errorMessage =
      failures.first?.localizedDescription
      ?? (hasLoaded ? nil : MusicSourceError.emptyLibrary.localizedDescription)
  }

  func search(_ query: String) async {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      searchResult = .empty
      return
    }
    isSearching = true
    defer { isSearching = false }
    do {
      let value = try await provider.search(query: normalized)
      searchResult = MusicSearchResult(
        artists: ArtistPresentationPolicy.deduplicated(
          value.artists.map(withArtworkFallback)),
        albums: value.albums.map(withArtworkFallback),
        tracks: value.tracks.map(withArtworkFallback),
        playlists: value.playlists)
      var history =
        (try? await cache.load(
          [String].self, serverID: provider.id, namespace: .searchHistory, key: "queries")) ?? []
      history.removeAll { $0.localizedCaseInsensitiveCompare(normalized) == .orderedSame }
      history.insert(normalized, at: 0)
      searchHistory = Array(history.prefix(20))
      try? await cache.store(
        searchHistory, serverID: provider.id, namespace: .searchHistory, key: "queries")
      errorMessage = nil
      connectionReporter(nil)
    } catch is CancellationError {} catch {
      let mapped = MusicSourceError.map(error)
      errorMessage = mapped.localizedDescription
      connectionReporter(mapped)
    }
  }

  @discardableResult func setFavorite(_ item: MusicLibraryItem, isFavorite: Bool) async -> Bool {
    let previousState = favoriteState(for: item)
    applyFavoriteState(
      isFavorite ? .favorite : .notFavorite, to: item)
    do {
      try await provider.setFavorite(item: item, isFavorite: isFavorite)
      await persistSnapshot()
      errorMessage = nil
      return true
    } catch {
      applyFavoriteState(previousState, to: item)
      errorMessage = MusicSourceError.map(error).localizedDescription
      return false
    }
  }

  func clearSearchHistory() async {
    searchHistory = []
    try? await cache.store(
      searchHistory, serverID: provider.id, namespace: .searchHistory, key: "queries")
  }

  private func restoreCache() async -> Date? {
    if searchHistory.isEmpty {
      searchHistory =
        (try? await cache.load(
          [String].self, serverID: provider.id, namespace: .searchHistory, key: "queries")) ?? []
    }
    guard !hasLoaded,
      let snapshot = try? await cache.load(
        LibrarySnapshot.self, serverID: provider.id, namespace: .metadata, key: "library")
    else { return nil }
    apply(snapshot)
    return snapshot.savedAt
  }
  private func recordRecent(_ value: String) async {
    var items =
      (try? await cache.load(
        [String].self, serverID: provider.id, namespace: .recentBrowsing, key: "items")) ?? []
    items.removeAll { $0 == value }
    items.insert(value, at: 0)
    try? await cache.store(
      Array(items.prefix(100)), serverID: provider.id, namespace: .recentBrowsing, key: "items")
  }
  private func resolvedLyricsCacheKey(for track: MusicTrack) -> String {
    [
      "resolved-lyrics-v1", track.identity.remoteID, track.title, track.artistName,
      track.albumTitle ?? "", String(Int(track.duration.rounded())),
    ].joined(separator: "|")
  }
  private func persistentResourceOwners() -> Set<String> {
    var owners = Set(tracks.map { MusicResourceOwner.track($0.identity.remoteID) })
    owners.formUnion(albums.map { MusicResourceOwner.album($0.identity.remoteID) })
    owners.formUnion(artists.map { MusicResourceOwner.artist($0.identity.remoteID) })
    owners.formUnion(playlists.map { MusicResourceOwner.playlist($0.identity.remoteID) })
    owners.formUnion(tracks.compactMap(\.albumRemoteID).map(MusicResourceOwner.album))
    owners.formUnion(tracks.compactMap(\.artistRemoteID).map(MusicResourceOwner.artist))
    return owners
  }
  private func sortAlbumTracks(_ values: [MusicTrack]) -> [MusicTrack] {
    values.sorted {
      if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
      if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
      return $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }
  private func sortArtistTracks(_ values: [MusicTrack]) -> [MusicTrack] {
    values.sorted {
      if $0.favoriteState != $1.favoriteState {
        return $0.favoriteState == .favorite
      }
      let albumOrder = ($0.albumTitle ?? "").localizedStandardCompare($1.albumTitle ?? "")
      if albumOrder != .orderedSame { return albumOrder == .orderedAscending }
      if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
      if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
      return $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }
  private func apply(_ snapshot: LibrarySnapshot) {
    homeSections = snapshot.home.map(withArtworkFallback)
    artists = ArtistPresentationPolicy.deduplicated(
      snapshot.artists.map(withArtworkFallback))
    albums = snapshot.albums.map(withArtworkFallback)
    tracks = snapshot.tracks.map(withArtworkFallback)
    playlists = snapshot.playlists
    hasLoaded =
      !homeSections.isEmpty || !artists.isEmpty || !albums.isEmpty || !tracks.isEmpty
      || !playlists.isEmpty
  }
  private func upsertPlaylist(_ playlist: MusicPlaylist) {
    if let index = playlists.firstIndex(where: {
      $0.identity.remoteID == playlist.identity.remoteID
    }) {
      playlists[index] = playlist
    } else {
      playlists.insert(playlist, at: 0)
    }
    syncPlaylistSection()
  }
  private func syncPlaylistSection() {
    guard let index = homeSections.firstIndex(where: { $0.kind == .playlists }) else { return }
    let section = homeSections[index]
    homeSections[index] = MusicSection(
      id: section.id, title: section.title, kind: section.kind,
      items: playlists.map(MusicSectionItem.playlist))
  }
  private func favoriteState(for item: MusicLibraryItem) -> FavoriteState {
    switch item {
    case .track(let track):
      tracks.first(where: { $0.id == track.id })?.favoriteState ?? track.favoriteState
    case .album(let album):
      albums.first(where: { $0.id == album.id })?.favoriteState ?? album.favoriteState
    case .artist(let artist):
      artists.first(where: { $0.id == artist.id })?.favoriteState ?? artist.favoriteState
    }
  }
  private func applyFavoriteState(_ state: FavoriteState, to item: MusicLibraryItem) {
    switch item {
    case .track(let track):
      if state == .favorite, !tracks.contains(where: { $0.id == track.id }) {
        var indexedTrack = track
        indexedTrack.favoriteState = .favorite
        tracks.append(indexedTrack)
      }
      updateFavoriteState(in: &tracks, matching: track.id, state: state)
      updateFavoriteState(in: &searchResult.tracks, matching: track.id, state: state)
      updateTrackSections(matching: track.id, state: state)
      syncFavoriteTrackSection()
    case .album(let album):
      updateFavoriteState(in: &albums, matching: album.id, state: state)
      updateFavoriteState(in: &searchResult.albums, matching: album.id, state: state)
      updateAlbumSections(matching: album.id, state: state)
    case .artist(let artist):
      updateFavoriteState(in: &artists, matching: artist.id, state: state)
      updateFavoriteState(in: &searchResult.artists, matching: artist.id, state: state)
      updateArtistSections(matching: artist.id, state: state)
    }
  }
  private func updateFavoriteState(
    in values: inout [MusicTrack], matching id: UUID, state: FavoriteState
  ) {
    for index in values.indices where values[index].id == id {
      values[index].favoriteState = state
    }
  }
  private func updateFavoriteState(
    in values: inout [MusicAlbum], matching id: UUID, state: FavoriteState
  ) {
    for index in values.indices where values[index].id == id {
      values[index].favoriteState = state
    }
  }
  private func updateFavoriteState(
    in values: inout [MusicArtist], matching id: UUID, state: FavoriteState
  ) {
    for index in values.indices where values[index].id == id {
      values[index].favoriteState = state
    }
  }
  private func updateTrackSections(matching id: UUID, state: FavoriteState) {
    for index in homeSections.indices {
      let section = homeSections[index]
      let items = section.items.map { item in
        guard case .track(var track) = item, track.id == id else { return item }
        track.favoriteState = state
        return MusicSectionItem.track(track)
      }
      homeSections[index] = MusicSection(
        id: section.id, title: section.title, kind: section.kind, items: items)
    }
  }
  private func updateAlbumSections(matching id: UUID, state: FavoriteState) {
    for index in homeSections.indices {
      let section = homeSections[index]
      let items = section.items.map { item in
        guard case .album(var album) = item, album.id == id else { return item }
        album.favoriteState = state
        return MusicSectionItem.album(album)
      }
      homeSections[index] = MusicSection(
        id: section.id, title: section.title, kind: section.kind, items: items)
    }
  }
  private func updateArtistSections(matching id: UUID, state: FavoriteState) {
    for index in homeSections.indices {
      let section = homeSections[index]
      let items = section.items.map { item in
        guard case .artist(var artist) = item, artist.id == id else { return item }
        artist.favoriteState = state
        return MusicSectionItem.artist(artist)
      }
      homeSections[index] = MusicSection(
        id: section.id, title: section.title, kind: section.kind, items: items)
    }
  }
  private func syncFavoriteTrackSection() {
    let items = favoriteTracks.map(MusicSectionItem.track)
    if let index = homeSections.firstIndex(where: { $0.kind == .favoriteTracks }) {
      if items.isEmpty {
        homeSections.remove(at: index)
      } else {
        let section = homeSections[index]
        homeSections[index] = MusicSection(
          id: section.id, title: section.title, kind: section.kind, items: items)
      }
    } else if !items.isEmpty {
      homeSections.append(
        MusicSection(
          id: "system-favorite-tracks", title: String(localized: "喜欢的歌曲"), kind: .favoriteTracks,
          items: items))
    }
  }
  private func persistSnapshot() async {
    let snapshot = LibrarySnapshot(
      home: homeSections, artists: artists, albums: albums, tracks: tracks,
      playlists: playlists, savedAt: Date())
    try? await cache.store(snapshot, serverID: provider.id, namespace: .metadata, key: "library")
  }

  private func withArtworkFallback(_ track: MusicTrack) -> MusicTrack {
    guard let fallback = ExternalArtworkFallback.url(for: .track(track)) else { return track }
    var value = track
    value.artworkURL =
      track.artworkURL.map { ArtworkURLFallback.attaching(fallback, to: $0) }
      ?? fallback
    return value
  }
  private func withArtworkFallback(_ album: MusicAlbum) -> MusicAlbum {
    guard let fallback = ExternalArtworkFallback.url(for: .album(album)) else { return album }
    var value = album
    value.artworkURL =
      album.artworkURL.map { ArtworkURLFallback.attaching(fallback, to: $0) }
      ?? fallback
    return value
  }
  private func withArtworkFallback(_ artist: MusicArtist) -> MusicArtist {
    guard let primary = artist.artworkURL else { return artist }
    var value = artist
    if let fallback = ExternalArtworkFallback.url(for: .artist(artist)) {
      value.artworkURL = ArtworkURLFallback.attaching(fallback, to: primary)
    }
    return value
  }
  private func withArtworkFallback(_ section: MusicSection) -> MusicSection {
    MusicSection(
      id: section.id, title: section.title, kind: section.kind,
      items: section.items.map { item in
        switch item {
        case .track(let value): .track(withArtworkFallback(value))
        case .album(let value): .album(withArtworkFallback(value))
        case .artist(let value): .artist(withArtworkFallback(value))
        case .playlist: item
        }
      })
  }
}

enum ArtistPresentationPolicy {
  nonisolated static func normalizedName(_ name: String) -> String {
    name
      .replacingOccurrences(of: "\u{200B}", with: "")
      .replacingOccurrences(of: "\u{FEFF}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "zh_Hans_CN"))
  }

  nonisolated static func deduplicated(_ artists: [MusicArtist]) -> [MusicArtist] {
    var canonicalByName: [String: MusicArtist] = [:]
    for artist in artists {
      let key = normalizedName(artist.name)
      guard !key.isEmpty else { continue }
      if let current = canonicalByName[key] {
        canonicalByName[key] = merged(current, artist)
      } else {
        canonicalByName[key] = artist
      }
    }
    return canonicalByName.values.sorted(by: presentationOrder)
  }

  nonisolated static func preferred(
    _ lhs: MusicArtist, _ rhs: MusicArtist
  ) -> MusicArtist {
    presentationScore(lhs) >= presentationScore(rhs) ? lhs : rhs
  }

  private nonisolated static func merged(
    _ lhs: MusicArtist, _ rhs: MusicArtist
  ) -> MusicArtist {
    var value = preferred(lhs, rhs)
    let other = value.id == lhs.id ? rhs : lhs
    if value.artworkURL == nil { value.artworkURL = other.artworkURL }
    if value.biography?.isEmpty != false { value.biography = other.biography }
    value.albumCount = max(value.albumCount ?? 0, other.albumCount ?? 0)
    if lhs.favoriteState == .favorite || rhs.favoriteState == .favorite {
      value.favoriteState = .favorite
    }
    value.metadata.merge(other.metadata) { current, _ in current }
    return value
  }

  private nonisolated static func presentationOrder(
    _ lhs: MusicArtist, _ rhs: MusicArtist
  ) -> Bool {
    if (lhs.artworkURL != nil) != (rhs.artworkURL != nil) {
      return lhs.artworkURL != nil
    }
    if lhs.favoriteState != rhs.favoriteState {
      return lhs.favoriteState == .favorite
    }
    let comparison = lhs.name.localizedStandardCompare(rhs.name)
    if comparison != .orderedSame { return comparison == .orderedAscending }
    return lhs.identity.remoteID < rhs.identity.remoteID
  }

  private nonisolated static func presentationScore(_ artist: MusicArtist) -> Int {
    (artist.artworkURL == nil ? 0 : 1_000)
      + (artist.biography?.isEmpty == false ? 100 : 0)
      + (artist.favoriteState == .favorite ? 50 : 0)
      + min(max(artist.albumCount ?? 0, 0), 40)
  }
}

private struct LibrarySnapshot: Codable, Sendable {
  let home: [MusicSection]
  let artists: [MusicArtist]
  let albums: [MusicAlbum]
  let tracks: [MusicTrack]
  let playlists: [MusicPlaylist]
  let savedAt: Date
}
