import CoreGraphics
import Foundation

#if DEBUG
  actor MockMusicSourceProvider: MusicSourceProvider {
    nonisolated let id: UUID
    nonisolated let sourceType: MusicSourceType
    nonisolated let capabilities: Set<MusicProviderCapability>
    nonisolated let mediaURLAllowsDirectPlayback: Bool
    var serverInfo: MusicServerInfo
    var home: [MusicSection]
    var artists: [MusicArtist]
    var albums: [MusicAlbum]
    var tracks: [MusicTrack]
    var playlists: [MusicPlaylist]
    var error: MusicSourceError?
    private let mediaData: Data
    private let mediaDataByRemoteID: [String: Data]
    private let mediaMimeType: String
    private let streamDelayByRemoteID: [String: Duration]
    private let mediaIgnoresRange: Bool
    private let mediaStreamChunkSize: Int?
    private let mediaStreamChunkDelay: Duration?
    private let lyricsAreSynced: Bool
    private var streamingQualityRequests: [StreamingQuality] = []
    private var mediaRangeRequests: [String?] = []
    private var completedMediaStreams = 0
    private var deliveredMediaStreamChunks = 0
    private var lyricsRequests = 0
    private var playbackEvents: [PlaybackEvent] = []

    init(
      id: UUID = UUID(), sourceType: MusicSourceType = .openSubsonic,
      capabilities: Set<MusicProviderCapability> = Set(MusicProviderCapability.allMockCases),
      serverInfo: MusicServerInfo? = nil, home: [MusicSection] = [], artists: [MusicArtist] = [],
      albums: [MusicAlbum] = [], tracks: [MusicTrack] = [], playlists: [MusicPlaylist] = [],
      error: MusicSourceError? = nil, mediaData: Data = Data(),
      mediaDataByRemoteID: [String: Data] = [:], mediaMimeType: String = "audio/mpeg",
      streamDelayByRemoteID: [String: Duration] = [:], mediaURLAllowsDirectPlayback: Bool = false,
      lyricsAreSynced: Bool = true, mediaIgnoresRange: Bool = false,
      mediaStreamChunkSize: Int? = nil, mediaStreamChunkDelay: Duration? = nil
    ) {
      self.id = id
      self.sourceType = sourceType
      self.capabilities = capabilities
      self.mediaURLAllowsDirectPlayback = mediaURLAllowsDirectPlayback
      self.serverInfo =
        serverInfo
        ?? .init(
          name: "Mock Music Server", version: "1.0", type: sourceType, capabilities: capabilities)
      self.home = home
      self.artists = artists
      self.albums = albums
      self.tracks = tracks
      self.playlists = playlists
      self.error = error
      self.mediaData = mediaData
      self.mediaDataByRemoteID = mediaDataByRemoteID
      self.mediaMimeType = mediaMimeType
      self.streamDelayByRemoteID = streamDelayByRemoteID
      self.mediaIgnoresRange = mediaIgnoresRange
      self.mediaStreamChunkSize = mediaStreamChunkSize
      self.mediaStreamChunkDelay = mediaStreamChunkDelay
      self.lyricsAreSynced = lyricsAreSynced
    }
    func authenticate() async throws { try checkError() }
    func fetchServerInfo() async throws -> MusicServerInfo {
      try checkError()
      return serverInfo
    }
    func fetchLibraries() async throws -> [MusicLibrary] {
      try checkError()
      return [.init(id: "mock-library", name: "Mock Library")]
    }
    func fetchHomeSections() async throws -> [MusicSection] {
      try checkError()
      return home
    }
    func fetchArtists() async throws -> [MusicArtist] {
      try checkError()
      return artists
    }
    func fetchAlbums() async throws -> [MusicAlbum] {
      try checkError()
      return albums
    }
    func fetchSongs() async throws -> [MusicTrack] {
      try checkError()
      return tracks
    }
    func fetchPlaylists() async throws -> [MusicPlaylist] {
      try checkError()
      return playlists
    }
    func search(query: String) async throws -> MusicSearchResult {
      try checkError()
      let needle = query.lowercased()
      return .init(
        artists: artists.filter { $0.name.lowercased().contains(needle) },
        albums: albums.filter { $0.title.lowercased().contains(needle) },
        tracks: tracks.filter { $0.title.lowercased().contains(needle) },
        playlists: playlists.filter { $0.name.lowercased().contains(needle) })
    }
    func fetchArtist(id: String) async throws -> MusicArtistDetail {
      try checkError()
      guard let artist = artists.first(where: { $0.identity.remoteID == id }) else {
        throw MusicSourceError.fileNotFound
      }
      return .init(
        artist: artist, albums: albums.filter { $0.artistID == id },
        topTracks: tracks.filter { $0.artistRemoteID == id })
    }
    func fetchAlbum(id: String) async throws -> MusicAlbumDetail {
      try checkError()
      guard let album = albums.first(where: { $0.identity.remoteID == id }) else {
        throw MusicSourceError.fileNotFound
      }
      return .init(album: album, tracks: tracks.filter { $0.albumRemoteID == id })
    }
    func fetchPlaylist(id: String) async throws -> MusicPlaylistDetail {
      try checkError()
      guard let playlist = playlists.first(where: { $0.identity.remoteID == id }) else {
        throw MusicSourceError.fileNotFound
      }
      return .init(playlist: playlist, tracks: tracks)
    }
    func fetchLyrics(for track: MusicTrack) async throws -> MusicLyrics? {
      lyricsRequests += 1
      guard let raw = track.lyrics else { return nil }
      let lines = raw.split(separator: "\n").enumerated().map { index, value in
        MusicLyrics.Line(
          time: lyricsAreSynced ? TimeInterval(index * 8) : nil, text: String(value))
      }
      return .init(
        displayArtist: track.artistName, displayTitle: track.title, language: nil, lines: lines,
        isSynced: lyricsAreSynced)
    }
    func streamURL(for track: MusicTrack, quality: StreamingQuality) async throws -> URL {
      try checkError()
      streamingQualityRequests.append(quality)
      if let delay = streamDelayByRemoteID[track.identity.remoteID] {
        try await Task.sleep(for: delay)
      }
      guard let url = URL(string: "https://mock.invalid/audio/\(track.identity.remoteID)") else {
        throw MusicSourceError.playbackURLUnavailable
      }
      return url
    }
    func requestedStreamingQualities() -> [StreamingQuality] { streamingQualityRequests }
    func requestedMediaRanges() -> [String?] { mediaRangeRequests }
    func completedMediaStreamCount() -> Int { completedMediaStreams }
    func deliveredMediaStreamChunkCount() -> Int { deliveredMediaStreamChunks }
    func requestedLyricsCount() -> Int { lyricsRequests }
    func reportedPlaybackEvents() -> [PlaybackEvent] { playbackEvents }
    func loadMediaResource(at url: URL, range: String?) async throws -> MusicMediaResponse {
      try checkError()
      mediaRangeRequests.append(range)
      let selectedData = mediaDataByRemoteID[url.lastPathComponent] ?? mediaData
      return mediaResponse(data: selectedData, range: range)
    }
    func streamMediaResource(
      at url: URL, range: String?,
      onResponse: @escaping @Sendable (MusicMediaResponseMetadata) async throws -> Bool,
      onData: @escaping @Sendable (Data) async throws -> Bool
    ) async throws {
      try checkError()
      mediaRangeRequests.append(range)
      let selectedData = mediaDataByRemoteID[url.lastPathComponent] ?? mediaData
      let response = mediaResponse(
        data: selectedData, range: mediaIgnoresRange ? nil : range)
      guard try await onResponse(response.metadata) else { return }

      let chunkSize = max(mediaStreamChunkSize ?? response.data.count, 1)
      var offset = 0
      while offset < response.data.count {
        try Task.checkCancellation()
        if let mediaStreamChunkDelay { try await Task.sleep(for: mediaStreamChunkDelay) }
        let end = min(offset + chunkSize, response.data.count)
        let shouldContinue = try await onData(response.data.subdata(in: offset..<end))
        deliveredMediaStreamChunks += 1
        offset = end
        guard shouldContinue else { return }
      }
      completedMediaStreams += 1
    }

    private func mediaResponse(data selectedData: Data, range: String?) -> MusicMediaResponse {
      guard let range, range.hasPrefix("bytes="), !selectedData.isEmpty else {
        return .init(
          data: selectedData, statusCode: 200, mimeType: mediaMimeType,
          expectedContentLength: Int64(selectedData.count),
          headers: ["content-length": String(selectedData.count), "accept-ranges": "bytes"])
      }
      let bounds = range.dropFirst(6).split(separator: "-", maxSplits: 1).compactMap { Int($0) }
      let start = min(max(bounds.first ?? 0, 0), selectedData.count)
      let requestedEnd = bounds.count > 1 ? bounds[1] : selectedData.count - 1
      let end = min(max(requestedEnd, start - 1), selectedData.count - 1)
      let data =
        start <= end && start < selectedData.count
        ? selectedData.subdata(in: start..<(end + 1)) : Data()
      return .init(
        data: data, statusCode: 206, mimeType: mediaMimeType,
        expectedContentLength: Int64(data.count),
        headers: [
          "content-range": "bytes \(start)-\(max(end, start))/\(selectedData.count)",
          "content-length": String(data.count), "accept-ranges": "bytes",
        ])
    }
    nonisolated func artworkURL(for item: MusicArtworkItem, size: CGSize?) -> URL? { nil }
    func setFavorite(item: MusicLibraryItem, isFavorite: Bool) async throws { try checkError() }
    func reportPlayback(_ event: PlaybackEvent) async throws {
      playbackEvents.append(event)
      try checkError()
    }
    private func checkError() throws { if let error { throw error } }
  }

  extension MusicProviderCapability {
    fileprivate static var allMockCases: [MusicProviderCapability] {
      [
        .home, .artists, .albums, .tracks, .playlists, .search, .lyrics, .favorites,
        .playlistEditing,
        .scrobbling, .progress, .transcoding, .random, .recentlyPlayed, .recentlyAdded, .frequent,
        .resume,
      ]
    }
  }
#endif
