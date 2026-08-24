import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import UniformTypeIdentifiers

actor LocalMusicProvider: MusicSourceProvider {
  nonisolated let id: UUID
  nonisolated let sourceType: MusicSourceType = .local
  nonisolated let capabilities: Set<MusicProviderCapability> = [
    .home, .artists, .albums, .tracks, .playlists, .search, .lyrics, .favorites,
    .playlistEditing, .recentlyAdded,
  ]

  private let rootURL: URL
  private let mediaURL: URL
  private let artworkDirectoryURL: URL
  private let indexURL: URL
  private var state = LocalLibraryState.empty
  private var hasLoaded = false

  init(server: MusicServer, rootURL: URL? = nil) {
    id = server.id
    let applicationSupport =
      rootURL
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appending(path: "UniversalPersonalMusic/LocalLibraries")
        .appending(path: server.id.uuidString.lowercased())
    self.rootURL = applicationSupport
    mediaURL = applicationSupport.appending(path: "Media")
    artworkDirectoryURL = applicationSupport.appending(path: "Artwork")
    indexURL = applicationSupport.appending(path: "library.json")
  }

  func authenticate() async throws {
    try prepareStorage()
    try loadIfNeeded()
  }

  func fetchServerInfo() async throws -> MusicServerInfo {
    try loadIfNeeded()
    return .init(
name: String(localized: "本机音乐"), version: "1", type: .local, capabilities: capabilities)
  }

  func fetchLibraries() async throws -> [MusicLibrary] {
    try loadIfNeeded()
return [.init(id: "local", name: String(localized: "本机音乐"))]
  }

  func fetchHomeSections() async throws -> [MusicSection] {
    try loadIfNeeded()
    let tracks = state.records.sorted { $0.importedAt > $1.importedAt }.prefix(24).map(\.track)
    let playlists = try await fetchPlaylists()
    var sections: [MusicSection] = []
    if !tracks.isEmpty {
      sections.append(
        .init(
id: "local-recently-added", title: String(localized: "最近导入"), kind: .recentlyAdded,
          items: tracks.map(MusicSectionItem.track)))
    }
    if !playlists.isEmpty {
      sections.append(
        .init(
id: "local-playlists", title: String(localized: "我的歌单"), kind: .playlists,
          items: playlists.map(MusicSectionItem.playlist)))
    }
    return sections
  }

  func fetchArtists() async throws -> [MusicArtist] {
    try loadIfNeeded()
    let grouped = Dictionary(grouping: state.records.map(\.track), by: \.artistName)
    return grouped.keys.sorted().map { name in
      MusicArtist(
        identity: .init(providerID: id, remoteID: "artist:\(name)", sourceType: .local),
        name: name, biography: nil, artworkURL: grouped[name]?.compactMap(\.artworkURL).first,
        albumCount: Set(grouped[name]?.compactMap(\.albumTitle) ?? []).count,
        favoriteState: .unknown, metadata: [:])
    }
  }

  func fetchAlbums() async throws -> [MusicAlbum] {
    try loadIfNeeded()
    let grouped = Dictionary(
      grouping: state.records.map(\.track),
by: { "\($0.artistName)\u{1f}\($0.albumTitle ?? String(localized: "未知专辑"))" })
    return grouped.values.compactMap { tracks in
      guard let first = tracks.first else { return nil }
let title = first.albumTitle ?? String(localized: "未知专辑")
      return MusicAlbum(
        identity: .init(
          providerID: id, remoteID: albumRemoteID(artist: first.artistName, title: title),
          sourceType: .local),
        artistID: "artist:\(first.artistName)", title: title, artistName: first.artistName,
        releaseDate: nil, year: nil, artworkURL: tracks.compactMap(\.artworkURL).first,
        genreNames: [], trackCount: tracks.count, duration: tracks.reduce(0) { $0 + $1.duration },
        favoriteState: .unknown, metadata: [:])
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  func fetchSongs() async throws -> [MusicTrack] {
    try loadIfNeeded()
    return state.records.map(\.track).sorted {
      let artist = $0.artistName.localizedStandardCompare($1.artistName)
      if artist != .orderedSame { return artist == .orderedAscending }
      let album = ($0.albumTitle ?? "").localizedStandardCompare($1.albumTitle ?? "")
      if album != .orderedSame { return album == .orderedAscending }
      if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
      if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
      return $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }

  func fetchPlaylists() async throws -> [MusicPlaylist] {
    try loadIfNeeded()
    return state.playlists.map(mapPlaylist)
  }

  func search(query: String) async throws -> MusicSearchResult {
    try loadIfNeeded()
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return .empty }
    let tracks = state.records.map(\.track).filter {
      $0.title.localizedCaseInsensitiveContains(needle)
        || $0.artistName.localizedCaseInsensitiveContains(needle)
        || ($0.albumTitle?.localizedCaseInsensitiveContains(needle) == true)
    }
    return .init(
      artists: try await fetchArtists().filter { $0.name.localizedCaseInsensitiveContains(needle) },
      albums: try await fetchAlbums().filter {
        $0.title.localizedCaseInsensitiveContains(needle)
          || $0.artistName.localizedCaseInsensitiveContains(needle)
      }, tracks: tracks,
      playlists: try await fetchPlaylists().filter {
        $0.name.localizedCaseInsensitiveContains(needle)
      })
  }

  func fetchArtist(id remoteID: String) async throws -> MusicArtistDetail {
    let artists = try await fetchArtists()
    guard let artist = artists.first(where: { $0.identity.remoteID == remoteID }) else {
      throw MusicSourceError.fileNotFound
    }
    let tracks = try await fetchSongs().filter { $0.artistName == artist.name }
    let albums = try await fetchAlbums().filter { $0.artistName == artist.name }
    return .init(artist: artist, albums: albums, topTracks: tracks)
  }

  func fetchAlbum(id remoteID: String) async throws -> MusicAlbumDetail {
    let albums = try await fetchAlbums()
    guard let album = albums.first(where: { $0.identity.remoteID == remoteID }) else {
      throw MusicSourceError.fileNotFound
    }
    let tracks = try await fetchSongs().filter {
albumRemoteID(artist: $0.artistName, title: $0.albumTitle ?? String(localized: "未知专辑")) == remoteID
    }
    return .init(album: album, tracks: tracks)
  }

  func fetchPlaylist(id remoteID: String) async throws -> MusicPlaylistDetail {
    try loadIfNeeded()
    guard let record = state.playlists.first(where: { $0.id == remoteID }) else {
      throw MusicSourceError.fileNotFound
    }
    let byID = Dictionary(uniqueKeysWithValues: state.records.map { ($0.track.identity.remoteID, $0.track) })
    let tracks = record.trackIDs.compactMap { byID[$0] }
    return .init(playlist: mapPlaylist(record), tracks: tracks)
  }

  func fetchLyrics(for track: MusicTrack) async throws -> MusicLyrics? {
    guard let text = track.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else { return nil }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let parsed = lines.compactMap(parseTimedLyric)
    if !parsed.isEmpty {
      return .init(
        displayArtist: track.artistName, displayTitle: track.title, language: nil,
        lines: parsed, isSynced: true)
    }
    return .init(
      displayArtist: track.artistName, displayTitle: track.title, language: nil,
      lines: lines.map { .init(time: nil, text: $0) }, isSynced: false)
  }

  func streamURL(for track: MusicTrack, quality: StreamingQuality) async throws -> URL {
    try loadIfNeeded()
    guard let record = state.records.first(where: { $0.track.identity.remoteID == track.identity.remoteID })
    else { throw MusicSourceError.fileNotFound }
    let url = mediaURL.appending(path: record.fileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw MusicSourceError.fileNotFound
    }
    return url
  }

  func loadMediaResource(at url: URL, range: String?) async throws -> MusicMediaResponse {
    guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
      throw MusicSourceError.fileNotFound
    }
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
    let size = values.fileSize ?? 0
    guard let range, let bounds = byteRange(range, size: size) else {
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      return .init(
        data: data, statusCode: 200, mimeType: values.contentType?.preferredMIMEType,
        expectedContentLength: Int64(size),
        headers: ["content-length": String(size), "accept-ranges": "bytes"])
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(bounds.lowerBound))
    let data = try handle.read(upToCount: bounds.count) ?? Data()
    return .init(
      data: data, statusCode: 206, mimeType: values.contentType?.preferredMIMEType,
      expectedContentLength: Int64(data.count),
      headers: [
        "content-length": String(data.count),
        "content-range": "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(size)",
        "accept-ranges": "bytes",
      ])
  }

  nonisolated func artworkURL(for item: MusicArtworkItem, size: CGSize?) -> URL? {
    switch item {
    case .track(let value): value.artworkURL
    case .album(let value): value.artworkURL
    case .artist(let value): value.artworkURL
    case .playlist(let value): value.artworkURL
    }
  }

  func setFavorite(item: MusicLibraryItem, isFavorite: Bool) async throws {
    guard case .track(let track) = item,
      let index = state.records.firstIndex(where: {
        $0.track.identity.remoteID == track.identity.remoteID
      })
    else { throw MusicSourceError.unsupportedFeature }
    state.records[index].track.favoriteState = isFavorite ? .favorite : .notFavorite
    try save()
  }

  func createPlaylist(name: String, trackIDs: [String]) async throws -> MusicPlaylist {
    try loadIfNeeded()
    let record = LocalPlaylistRecord(
      id: UUID().uuidString.lowercased(), name: name, trackIDs: unique(trackIDs))
    state.playlists.append(record)
    try save()
    return mapPlaylist(record)
  }

  func updatePlaylist(id: String, name: String?, adding: [String], removingIndexes: [Int])
    async throws
  {
    try loadIfNeeded()
    guard let index = state.playlists.firstIndex(where: { $0.id == id }) else {
      throw MusicSourceError.fileNotFound
    }
    if let name { state.playlists[index].name = name }
    for offset in removingIndexes.sorted(by: >) {
      if state.playlists[index].trackIDs.indices.contains(offset) {
        state.playlists[index].trackIDs.remove(at: offset)
      }
    }
    state.playlists[index].trackIDs = unique(state.playlists[index].trackIDs + adding)
    try save()
  }

  func deletePlaylist(id: String) async throws {
    try loadIfNeeded()
    guard state.playlists.contains(where: { $0.id == id }) else {
      throw MusicSourceError.fileNotFound
    }
    state.playlists.removeAll { $0.id == id }
    try save()
  }

  func reportPlayback(_ event: PlaybackEvent) async throws {}

  @discardableResult
  func importFiles(_ urls: [URL]) async throws -> Int {
    try await importFilesDetailed(urls).importedCount
  }

  func importFolder(_ folderURL: URL) async throws -> LocalMusicImportReport {
    let values = try folderURL.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else { throw MusicSourceError.fileNotFound }
    let audioURLs = try Self.collectAudioURLs(in: folderURL)
    guard !audioURLs.isEmpty else { throw MusicSourceError.emptyLibrary }
    return try await importFilesDetailed(audioURLs)
  }

  private nonisolated static func collectAudioURLs(in folderURL: URL) throws -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: folderURL,
        includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey, .isReadableKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { _, _ in true })
    else { throw MusicSourceError.fileNotFound }

    var audioURLs: [URL] = []
    while let url = enumerator.nextObject() as? URL {
      guard
        let values = try? url.resourceValues(forKeys: [
          .isRegularFileKey, .contentTypeKey, .isReadableKey,
        ]), values.isRegularFile == true, values.isReadable != false
      else { continue }
      if values.contentType?.conforms(to: .audio) == true
        || Self.audioFileExtensions.contains(url.pathExtension.lowercased())
      {
        audioURLs.append(url)
      }
    }
    audioURLs.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    return audioURLs
  }

  func importFilesDetailed(_ urls: [URL]) async throws -> LocalMusicImportReport {
    try prepareStorage()
    try loadIfNeeded()
    var report = LocalMusicImportReport()
    var firstFailure: Error?
    for sourceURL in urls {
      try Task.checkCancellation()
      let remoteID = UUID().uuidString.lowercased()
      let suffix = sourceURL.pathExtension.lowercased()
      let fileName = suffix.isEmpty ? remoteID : "\(remoteID).\(suffix)"
      let destination = mediaURL.appending(path: fileName)
      let temporary = mediaURL.appending(path: ".importing-\(UUID().uuidString.lowercased())")
      do {
        // File-provider and SMB URLs can be expensive or transient. Copy once into the app
        // sandbox, then hash and inspect the local staging file rather than reading the NAS twice.
        try FileManager.default.copyItem(at: sourceURL, to: temporary)
        let contentHash = try hash(of: temporary)
        if let existing = state.records.first(where: { $0.contentHash == contentHash }) {
          try? FileManager.default.removeItem(at: temporary)
          report.duplicateCount += 1
          report.availableTracks.append(existing.track)
          continue
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        let track = try await inspect(
          url: destination, remoteID: remoteID,
          fallbackTitle: sourceURL.deletingPathExtension().lastPathComponent)
        state.records.append(
          .init(
            track: track, fileName: fileName, contentHash: contentHash, importedAt: Date()))
        report.importedCount += 1
        report.availableTracks.append(track)
      } catch {
        try? FileManager.default.removeItem(at: temporary)
        try? FileManager.default.removeItem(at: destination)
        if MusicSourceError.map(error) == .unsupportedFormat {
          report.unsupportedCount += 1
        } else {
          report.failedCount += 1
          firstFailure = firstFailure ?? error
        }
      }
    }
    if report.importedCount > 0 { try save() }
    if report.availableTracks.isEmpty, let firstFailure { throw firstFailure }
    return report
  }

  private func inspect(url: URL, remoteID: String, fallbackTitle: String) async throws -> MusicTrack {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard try await asset.load(.isPlayable) else { throw MusicSourceError.unsupportedFormat }
    let durationValue = try await asset.load(.duration).seconds
    let metadata = try await asset.load(.commonMetadata)
    let title = await metadataString(.commonIdentifierTitle, in: metadata) ?? fallbackTitle
let artist = await metadataString(.commonIdentifierArtist, in: metadata) ?? String(localized: "未知艺人")
    let album = await metadataString(.commonIdentifierAlbumName, in: metadata)
    let trackNumber = await metadataString(matching: "track", in: metadata)
      .flatMap { Int($0.split(separator: "/").first ?? "") } ?? 0
    let artworkURL = try await saveArtwork(from: metadata, remoteID: remoteID)
    let lyrics = try? await asset.load(.lyrics)
    return MusicTrack(
      identity: .init(providerID: id, remoteID: remoteID, sourceType: .local),
      albumRemoteID: album.map { albumRemoteID(artist: artist, title: $0) },
      artistRemoteID: "artist:\(artist)", title: title, artistName: artist, albumTitle: album,
      discNumber: 1, trackNumber: trackNumber,
      duration: durationValue.isFinite ? max(durationValue, 0) : 0, artworkURL: artworkURL,
      lyrics: lyrics, isExplicit: false, favoriteState: .notFavorite,
      contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
      suffix: url.pathExtension.lowercased(), bitRate: nil, metadata: [:])
  }

  private func metadataString(
    _ identifier: AVMetadataIdentifier, in metadata: [AVMetadataItem]
  ) async -> String? {
    guard let item = metadata.first(where: { $0.identifier == identifier }) else { return nil }
    return try? await item.load(.stringValue)
  }

  private func metadataString(matching value: String, in metadata: [AVMetadataItem]) async -> String? {
    guard let item = metadata.first(where: {
      $0.identifier?.rawValue.localizedCaseInsensitiveContains(value) == true
    }) else { return nil }
    return try? await item.load(.stringValue)
  }

  private func saveArtwork(from metadata: [AVMetadataItem], remoteID: String) async throws -> URL? {
    guard
      let item = metadata.first(where: { $0.identifier == .commonIdentifierArtwork }),
      let data = try? await item.load(.dataValue), !data.isEmpty
    else { return nil }
    let url = artworkDirectoryURL.appending(path: "\(remoteID).artwork")
    try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    return url
  }

  private func hash(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func prepareStorage() throws {
    try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: artworkDirectoryURL, withIntermediateDirectories: true)
  }

  private func loadIfNeeded() throws {
    guard !hasLoaded else { return }
    try prepareStorage()
    if FileManager.default.fileExists(atPath: indexURL.path) {
      state = try JSONDecoder.musicStorage.decode(
        LocalLibraryState.self, from: Data(contentsOf: indexURL))
    }
    hasLoaded = true
  }

  private func save() throws {
    try JSONEncoder.musicStorage.encode(state).write(
      to: indexURL, options: [.atomic, .completeFileProtectionUnlessOpen])
  }

  private func mapPlaylist(_ value: LocalPlaylistRecord) -> MusicPlaylist {
    .init(
      identity: .init(providerID: id, remoteID: value.id, sourceType: .local), name: value.name,
      artworkURL: value.trackIDs.compactMap { remoteID in
        state.records.first { $0.track.identity.remoteID == remoteID }?.track.artworkURL
      }.first, trackCount: value.trackIDs.count,
      duration: value.trackIDs.compactMap { remoteID in
        state.records.first { $0.track.identity.remoteID == remoteID }?.track.duration
      }.reduce(0, +), isPublic: false, isEditable: true, metadata: [:])
  }

  private func albumRemoteID(artist: String, title: String) -> String {
    "album:\(artist)\u{1f}\(title)"
  }

  private func byteRange(_ header: String, size: Int) -> Range<Int>? {
    guard size > 0, header.lowercased().hasPrefix("bytes=") else { return nil }
    let values = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard values.count == 2 else { return nil }
    if values[0].isEmpty, let suffix = Int(values[1]), suffix > 0 {
      return max(0, size - suffix)..<size
    }
    guard let start = Int(values[0]), start >= 0, start < size else { return nil }
    let end = min(Int(values[1]) ?? (size - 1), size - 1)
    guard end >= start else { return nil }
    return start..<(end + 1)
  }

  private func parseTimedLyric(_ value: String) -> MusicLyrics.Line? {
    guard value.first == "[", let end = value.firstIndex(of: "]") else { return nil }
    let stamp = value[value.index(after: value.startIndex)..<end]
    let parts = stamp.split(separator: ":")
    guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else {
      return nil
    }
    let text = String(value[value.index(after: end)...]).trimmingCharacters(in: .whitespaces)
    return .init(time: minutes * 60 + seconds, text: text)
  }

  private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  private static let audioFileExtensions: Set<String> = [
    "aac", "aif", "aiff", "alac", "ape", "caf", "flac", "m4a", "m4b", "mp3", "mp4",
    "ogg", "opus", "wav", "wave", "wma", "wv",
  ]
}

struct LocalMusicImportReport: Sendable, Equatable {
  var importedCount = 0
  var duplicateCount = 0
  var unsupportedCount = 0
  var failedCount = 0
  var availableTracks: [MusicTrack] = []

  var summary: String {
    var parts: [String] = []
    if importedCount > 0 { parts.append(String(localized: "已导入 \(importedCount) 首")) }
    if duplicateCount > 0 { parts.append(String(localized: "\(duplicateCount) 首已存在")) }
    if unsupportedCount > 0 { parts.append(String(localized: "\(unsupportedCount) 首格式暂不支持")) }
    if failedCount > 0 { parts.append(String(localized: "\(failedCount) 首读取失败")) }
    return parts.isEmpty
      ? String(localized: "没有找到可导入的歌曲。")
      : parts.joined(separator: String(localized: "，")) + String(localized: "。")
  }
}

private struct LocalTrackRecord: Codable, Sendable {
  var track: MusicTrack
  let fileName: String
  let contentHash: String
  let importedAt: Date
}

private struct LocalPlaylistRecord: Codable, Sendable {
  let id: String
  var name: String
  var trackIDs: [String]
}

private struct LocalLibraryState: Codable, Sendable {
  var schemaVersion: Int
  var records: [LocalTrackRecord]
  var playlists: [LocalPlaylistRecord]
  static let empty = Self(schemaVersion: 1, records: [], playlists: [])
}
