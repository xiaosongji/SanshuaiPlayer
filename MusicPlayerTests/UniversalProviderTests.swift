import CryptoKit
import Foundation
import SwiftUI
import UIKit
import XCTest

import class AVFoundation.AVAssetReader
import class AVFoundation.AVAssetReaderTrackOutput
import struct AVFoundation.AVError
import let AVFoundation.AVFormatIDKey
import let AVFoundation.AVFoundationErrorDomain
import let AVFoundation.AVLinearPCMBitDepthKey
import let AVFoundation.AVLinearPCMIsFloatKey
import let AVFoundation.AVLinearPCMIsNonInterleaved
import class AVFoundation.AVURLAsset
import let AudioToolbox.kAudioFormatLinearPCM
import func CoreMedia.CMBlockBufferGetDataPointer
import func CoreMedia.CMSampleBufferGetDataBuffer
import struct CoreMedia.CMTime
import struct CoreMedia.CMTimeRange

@testable import MusicPlayer

final class UniversalProviderTests: XCTestCase {
  func testLiveNavidromeColdTranscodeDeliversLeadingBytesPromptly() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let baseURLValue = environment["MUSICPLAYER_NAVIDROME_URL"],
      let baseURL = URL(string: baseURLValue),
      let username = environment["MUSICPLAYER_NAVIDROME_USERNAME"],
      let password = environment["MUSICPLAYER_NAVIDROME_PASSWORD"]
    else {
      throw XCTSkip("Set MUSICPLAYER_NAVIDROME_* to run the live startup-latency test")
    }
    let server = MusicServer(
      name: "Navidrome Startup Latency", baseURL: baseURL, sourceType: .openSubsonic,
      username: username, usesHTTPS: baseURL.scheme?.lowercased() == "https",
      allowsSelfSignedCertificate: true,
      certificateFingerprint: environment["MUSICPLAYER_NAVIDROME_FINGERPRINT"])
    let provider = OpenSubsonicProvider(
      server: server, credentials: .init(password: password))
    try await provider.authenticate()
    let candidates = try await provider.fetchSongs().filter { $0.duration > 120 }
    let track = try XCTUnwrap(candidates.randomElement())
    let url = try await provider.streamURL(for: track, quality: .standard)
    let probe = LiveMediaStreamProbe()
    let clock = ContinuousClock()
    let start = clock.now

    try await provider.streamMediaResource(
      at: url, range: "bytes=0-65535",
      onResponse: { metadata in
        await probe.record(metadata: metadata)
        return true
      },
      onData: { data in
        await probe.record(data: data)
        return false
      })

    let elapsed = start.duration(to: clock.now)
    let result = await probe.result()
    XCTAssertTrue((200...206).contains(result.statusCode))
    XCTAssertGreaterThan(result.byteCount, 0)
    XCTAssertLessThan(
      elapsed, .seconds(5),
      "The app did not receive the transcoder's leading bytes within the startup budget")
  }

  func testLiveNavidromeProviderLoaderDoesNotRestartAcrossProgressiveRanges() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let baseURLValue = environment["MUSICPLAYER_NAVIDROME_URL"],
      let baseURL = URL(string: baseURLValue),
      let username = environment["MUSICPLAYER_NAVIDROME_USERNAME"],
      let password = environment["MUSICPLAYER_NAVIDROME_PASSWORD"]
    else {
      throw XCTSkip("Set MUSICPLAYER_NAVIDROME_* to run the live media-boundary test")
    }
    let server = MusicServer(
      name: "Navidrome Media Boundary", baseURL: baseURL, sourceType: .openSubsonic,
      username: username, usesHTTPS: baseURL.scheme?.lowercased() == "https",
      allowsSelfSignedCertificate: true,
      certificateFingerprint: environment["MUSICPLAYER_NAVIDROME_FINGERPRINT"])
    let provider = OpenSubsonicProvider(
      server: server, credentials: .init(password: password))
    try await provider.authenticate()
    let songs = try await provider.fetchSongs()
    let track = try XCTUnwrap(songs.first { $0.duration > 120 })
    let url = try await provider.streamURL(for: track, quality: .standard)
    let loader = try ProviderAssetResourceLoader(url: url, provider: provider)
    let asset = loader.makeAsset()

    let opening = try await decodedAudioFingerprint(asset: asset, start: 0, duration: 3)
    for checkpoint in [30.0, 60.0, 90.0] {
      let laterAudio = try await decodedAudioFingerprint(
        asset: asset, start: checkpoint, duration: 3)
      XCTAssertNotEqual(
        opening, laterAudio,
        "The decoded audio at \(checkpoint) seconds restarted from the opening")
    }
  }

  func testNowPlayingArtworkCallbackIsSafeOnMediaPlayerQueue() async {
    let image = await MainActor.run {
      UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
        UIColor.systemOrange.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
      }
    }
    let artwork = NowPlayingArtworkFactory.make(
      image: image, boundsSize: CGSize(width: 8, height: 8))
    let artworkBox = SendableBox(artwork)

    let requestedImage = await withCheckedContinuation { continuation in
      DispatchQueue(label: "com.himhuu.music.tests.now-playing-artwork").async {
        continuation.resume(
          returning: artworkBox.value.image(at: CGSize(width: 4, height: 4)))
      }
    }

    XCTAssertNotNil(requestedImage)
  }

  func testProductionAppStoreReviewURLUsesVerifiedNumericID() {
    XCTAssertEqual(AppInfo.appStoreID, "6784067140")
    XCTAssertEqual(
      AppInfo.writeReviewURL.absoluteString,
      "https://apps.apple.com/app/id6784067140?action=write-review")
  }

  private func decodedAudioFingerprint(
    asset: AVURLAsset, start: TimeInterval, duration: TimeInterval
  ) async throws -> SHA256.Digest {
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    let track = try XCTUnwrap(audioTracks.first)
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 600),
      duration: CMTime(seconds: duration, preferredTimescale: 600))
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    XCTAssertTrue(reader.canAdd(output))
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? MusicSourceError.invalidResponse
    }
    var hasher = SHA256()
    var byteCount = 0
    while let sample = output.copyNextSampleBuffer(), byteCount < 1_048_576 {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      var length = 0
      var pointer: UnsafeMutablePointer<Int8>?
      let status = CMBlockBufferGetDataPointer(
        block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
        dataPointerOut: &pointer)
      guard status == noErr, let pointer, length > 0 else { continue }
      let count = min(length, 1_048_576 - byteCount)
      hasher.update(data: Data(bytes: pointer, count: count))
      byteCount += count
    }
    XCTAssertGreaterThan(byteCount, 0)
    if reader.status == .failed { throw reader.error ?? MusicSourceError.invalidResponse }
    return hasher.finalize()
  }

  func testCanonicalProductSupportAndPolicyURLsAreAppSpecific() {
    XCTAssertEqual(AppInfo.productURL.absoluteString, "https://himhuu.com/apps/sanshuai-player")
    XCTAssertEqual(
      AppInfo.privacyURL.absoluteString, "https://himhuu.com/apps/sanshuai-player/privacy")
    XCTAssertEqual(AppInfo.termsURL.absoluteString, "https://himhuu.com/apps/sanshuai-player/terms")
    XCTAssertEqual(
      AppInfo.supportURL.absoluteString, "https://himhuu.com/apps/sanshuai-player/support")
  }

  @MainActor
  func testSourceRestoreLoadsRepositoryOffMainThreadAndKeepsLoadingStateUntilReady() async {
    let repository = ThreadRecordingServerRepository(delay: 0.08)
    let store = MusicSourceStore(
      repository: repository, vault: InMemoryCredentialVault(),
      cache: MusicCache(
        rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))

    let restoreTask = Task { await store.restore() }
    await Task.yield()
    XCTAssertTrue(store.isRestoring)
    XCTAssertFalse(store.hasReliableActiveSource)
    await restoreTask.value

    XCTAssertEqual(repository.loadedOnMainThread, false)
    XCTAssertFalse(store.isRestoring)
  }

  @MainActor
  func testSourceRestoreFailureAlwaysEndsLoadingState() async {
    let store = MusicSourceStore(
      repository: FailingServerRepository(), vault: InMemoryCredentialVault(),
      cache: MusicCache(
        rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))

    await store.restore()

    XCTAssertFalse(store.isRestoring)
    XCTAssertNotNil(store.lastMigrationReport)
  }

  func testInAppMiniPlayerDependsOnPlaybackInsteadOfDeviceShape() {
    XCTAssertTrue(InAppMiniPlayerPresentationPolicy.shouldShow(hasCurrentTrack: true))
    XCTAssertFalse(InAppMiniPlayerPresentationPolicy.shouldShow(hasCurrentTrack: false))
  }

  func testArtistPresentationDeduplicatesNormalizedNamesAndDefersMissingArtwork() throws {
    let providerID = UUID()
    let artworkURL = try XCTUnwrap(URL(string: "https://music.example/artist.jpg"))
    let duplicateWithoutArtwork = MusicArtist(
      identity: .init(
        providerID: providerID, remoteID: "lin-1", sourceType: .openSubsonic),
      name: " 林俊杰 ", biography: nil, artworkURL: nil, albumCount: 4,
      favoriteState: .notFavorite, metadata: [:])
    let duplicateWithArtwork = MusicArtist(
      identity: .init(
        providerID: providerID, remoteID: "lin-2", sourceType: .openSubsonic),
      name: "林俊杰", biography: "JJ Lin", artworkURL: artworkURL, albumCount: 12,
      favoriteState: .favorite, metadata: [:])
    let missingArtwork = MusicArtist(
      identity: .init(
        providerID: providerID, remoteID: "missing", sourceType: .openSubsonic),
      name: "无封面歌手", biography: nil, artworkURL: nil, albumCount: 1,
      favoriteState: .notFavorite, metadata: [:])

    let result = ArtistPresentationPolicy.deduplicated([
      missingArtwork, duplicateWithoutArtwork, duplicateWithArtwork,
    ])

    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result.first?.name, "林俊杰")
    XCTAssertEqual(result.first?.artworkURL, artworkURL)
    XCTAssertEqual(result.first?.albumCount, 12)
    XCTAssertEqual(result.first?.favoriteState, .favorite)
    XCTAssertNil(result.last?.artworkURL)
  }

  func testMediaContentTypeDetectorNormalizesParameterizedMIMEAndOggSignature() {
    XCTAssertEqual(
      MediaContentTypeDetector.contentType(
        declaredMIMEType: "audio/mpeg; charset=binary", data: Data()),
      "public.mp3")
    XCTAssertEqual(
      MediaContentTypeDetector.signatureType(for: Data("OggS\u{0}\u{2}".utf8)),
      "org.xiph.ogg-audio")
  }

  @MainActor
  func testEveryQueueLoopsIncludingSingleTrack() async throws {
    let providerID = UUID()
    let tracks = (0..<2).map { index in
      MusicTrack(
        identity: .init(
          providerID: providerID, remoteID: "loop-\(index)", sourceType: .openSubsonic),
        albumRemoteID: "loop-album", artistRemoteID: "loop-artist",
        title: "Loop \(index)", artistName: "Artist", albumTitle: "Loop Album",
        discNumber: 1, trackNumber: index + 1, duration: 1, artworkURL: nil,
        lyrics: nil, isExplicit: false, favoriteState: .notFavorite,
        contentType: "audio/wav", suffix: "wav", bitRate: 128, metadata: [:])
    }
    let provider = MockMusicSourceProvider(
      id: providerID, sourceType: .openSubsonic, tracks: tracks,
      mediaData: makeSilentWAV(), mediaMimeType: "audio/wav")
    let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }
    let playback = UnifiedPlaybackController(
      provider: provider, wifiQuality: .original,
      cache: MusicCache(rootURL: cacheRoot))

    await playback.play(tracks[1], queue: tracks)
    await playback.playNext()
    XCTAssertEqual(playback.currentTrack?.id, tracks[0].id)
    await playback.playPrevious()
    XCTAssertEqual(playback.currentTrack?.id, tracks[1].id)

    await playback.play(tracks[0], queue: [tracks[0]])
    await playback.playNext()
    XCTAssertEqual(playback.currentTrack?.id, tracks[0].id)
    XCTAssertEqual(playback.currentIndex, 0)
  }

  func testArtworkCacheStoresBinaryDataAndRemovesIt() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(rootURL: root)
    let serverID = UUID()
    let artwork = Data((0..<4_096).map { UInt8($0 % 251) })
    defer { try? FileManager.default.removeItem(at: root) }

    try await cache.storeArtwork(artwork, serverID: serverID, key: "album:binary-cover")
    let stored = try await cache.artworkData(serverID: serverID, key: "album:binary-cover")
    XCTAssertEqual(stored, artwork)

    await cache.removeArtwork(serverID: serverID, key: "album:binary-cover")
    let removed = try await cache.artworkData(serverID: serverID, key: "album:binary-cover")
    XCTAssertNil(removed)
  }

  func testArtworkCacheReadsLegacyJSONData() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(rootURL: root)
    let serverID = UUID()
    let artwork = Data("legacy-base64-artwork".utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    try await cache.store(
      artwork, serverID: serverID, namespace: .artwork, key: "legacy-cover")

    let restored = try await cache.artworkData(serverID: serverID, key: "legacy-cover")
    XCTAssertEqual(restored, artwork)
  }

  func testArtworkNetworkFetchIsDeferredOnCellular() {
    XCTAssertTrue(
      ArtworkFetchPolicy.shouldWaitForPlayback(
        usesExpensiveNetwork: true, cellularPlaybackGateOpen: false))
    XCTAssertFalse(
      ArtworkFetchPolicy.shouldWaitForPlayback(
        usesExpensiveNetwork: false, cellularPlaybackGateOpen: false))
    XCTAssertFalse(
      ArtworkFetchPolicy.shouldWaitForPlayback(
        usesExpensiveNetwork: true, cellularPlaybackGateOpen: true))
  }

  @MainActor
  func testFavoriteSmartCollectionUpdatesImmediately() async throws {
    let providerID = UUID()
    let track = MusicTrack(
      identity: .init(
        providerID: providerID, remoteID: "favorite-smart-collection", sourceType: .openSubsonic),
      albumRemoteID: nil, artistRemoteID: nil, title: "Favorite", artistName: "Artist",
      albumTitle: nil, discNumber: 1, trackNumber: 1, duration: 180, artworkURL: nil,
      lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/mpeg",
      suffix: "mp3", bitRate: 320, metadata: [:])
    let provider = MockMusicSourceProvider(id: providerID, tracks: [track])
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(rootURL: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = UnifiedLibraryStore(provider: provider, cache: cache)

    await library.refresh()
    XCTAssertTrue(library.favoriteTracks.isEmpty)

    let didAddFavorite = await library.setFavorite(.track(track), isFavorite: true)
    XCTAssertTrue(didAddFavorite)
    XCTAssertEqual(library.favoriteTracks.map(\.id), [track.id])
    XCTAssertTrue(library.isFavorite(track))
    XCTAssertEqual(
      library.homeSections.first(where: { $0.kind == .favoriteTracks })?.items.count, 1)

    let didRemoveFavorite = await library.setFavorite(.track(track), isFavorite: false)
    XCTAssertTrue(didRemoveFavorite)
    XCTAssertTrue(library.favoriteTracks.isEmpty)
    XCTAssertFalse(library.isFavorite(track))
    XCTAssertFalse(library.homeSections.contains { $0.kind == .favoriteTracks })
  }

  @MainActor
  func testFavoritingNewNASSearchResultIndexesItBeforeLibraryRefresh() async throws {
    let providerID = UUID()
    let track = MusicTrack(
      identity: .init(
        providerID: providerID, remoteID: "new-nas-search-track", sourceType: .openSubsonic),
      albumRemoteID: nil, artistRemoteID: nil, title: "空心", artistName: "冯提莫",
      albumTitle: nil, discNumber: 1, trackNumber: 1, duration: 240, artworkURL: nil,
      lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/mpeg",
      suffix: "mp3", bitRate: 320, metadata: [:])
    let provider = MockMusicSourceProvider(id: providerID, tracks: [track])
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(rootURL: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = UnifiedLibraryStore(provider: provider, cache: cache)

    await library.search("空心")
    XCTAssertTrue(library.tracks.isEmpty)
    XCTAssertEqual(library.searchResult.tracks.map(\.id), [track.id])

    let didFavorite = await library.setFavorite(.track(track), isFavorite: true)
    XCTAssertTrue(didFavorite)
    XCTAssertEqual(library.favoriteTracks.map(\.id), [track.id])
    XCTAssertTrue(library.isFavorite(track))
  }

  func testMediaCacheAutomaticallyEvictsLeastRecentlyUsedFile() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(rootURL: root, byteLimit: 20, minimumByteLimit: 1)
    let serverID = UUID()
    let payload = Data(repeating: 7, count: 8)
    defer { try? FileManager.default.removeItem(at: root) }

    try await cache.storeMedia(payload, serverID: serverID, key: "old-a", fileExtension: "mp3")
    try await Task.sleep(for: .milliseconds(20))
    try await cache.storeMedia(payload, serverID: serverID, key: "old-b", fileExtension: "mp3")
    try await Task.sleep(for: .milliseconds(20))
    let touchedA = await cache.mediaURL(serverID: serverID, key: "old-a")
    XCTAssertNotNil(touchedA)
    try await Task.sleep(for: .milliseconds(20))
    try await cache.storeMedia(payload, serverID: serverID, key: "new-c", fileExtension: "mp3")

    let retainedA = await cache.mediaURL(serverID: serverID, key: "old-a")
    let evictedB = await cache.mediaURL(serverID: serverID, key: "old-b")
    let retainedC = await cache.mediaURL(serverID: serverID, key: "new-c")
    let cacheSize = await cache.size()
    XCTAssertNotNil(retainedA)
    XCTAssertNil(evictedB)
    XCTAssertNotNil(retainedC)
    XCTAssertLessThanOrEqual(cacheSize, 20)
  }

  func testPersistentResourcesAreNotRejectedByLegacyCacheLimit() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(
      rootURL: root, byteLimit: 30, minimumByteLimit: 1, mediaByteLimit: 10)
    let serverID = UUID()
    defer { try? FileManager.default.removeItem(at: root) }

    let retainedArtwork = Data(repeating: 1, count: 12)
    try await cache.storeArtwork(retainedArtwork, serverID: serverID, key: "retained")
    try await cache.storeArtwork(
      Data(repeating: 2, count: 12), serverID: serverID, key: "over-limit")

    let retained = try await cache.artworkData(serverID: serverID, key: "retained")
    let second = try await cache.artworkData(serverID: serverID, key: "over-limit")
    XCTAssertEqual(retained, retainedArtwork)
    XCTAssertEqual(second, Data(repeating: 2, count: 12))
    let usage = await cache.usage()
    XCTAssertEqual(usage.resourceBytes, 24)
    XCTAssertEqual(usage.mediaBytes, 0)
  }

  func testLegacyResourcesMigrateFromCachesToPersistentStorage() async throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let legacyRoot = temporary.appending(path: "Caches")
    let persistentRoot = temporary.appending(path: "ApplicationSupport")
    let serverID = UUID()
    let artwork = Data("legacy-artwork".utf8)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let legacyCache = MusicCache(rootURL: legacyRoot)
    try await legacyCache.storeArtwork(artwork, serverID: serverID, key: "cover")

    let upgradedCache = MusicCache(
      rootURL: legacyRoot, persistentRootURL: persistentRoot)
    let restored = try await upgradedCache.artworkData(serverID: serverID, key: "cover")

    XCTAssertEqual(restored, artwork)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: legacyRoot.appending(path: serverID.uuidString.lowercased())
          .appending(path: "artwork").path))
    XCTAssertTrue(
      try persistentRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup == true)
  }

  func testPersistentResourcesRequireTwoAuthoritativeMissesBeforeDeletion() async throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cacheRoot = temporary.appending(path: "Caches")
    let persistentRoot = temporary.appending(path: "ApplicationSupport")
    let cache = MusicCache(rootURL: cacheRoot, persistentRootURL: persistentRoot)
    let serverID = UUID()
    let removedOwner = MusicResourceOwner.track("removed-track")
    let retainedOwner = MusicResourceOwner.album("retained-album")
    defer { try? FileManager.default.removeItem(at: temporary) }

    try await cache.storeArtwork(
      Data("removed".utf8), serverID: serverID, key: "removed-cover", owner: removedOwner)
    try await cache.storeArtwork(
      Data("retained".utf8), serverID: serverID, key: "retained-cover",
      owner: retainedOwner)

    try await cache.reconcilePersistentResources(
      serverID: serverID, retainingOwners: [retainedOwner])
    let retainedAfterOneMiss = try await cache.artworkData(
      serverID: serverID, key: "removed-cover")
    XCTAssertNotNil(retainedAfterOneMiss)

    try await cache.reconcilePersistentResources(
      serverID: serverID, retainingOwners: [retainedOwner])
    let removedAfterTwoMisses = try await cache.artworkData(
      serverID: serverID, key: "removed-cover")
    let retainedArtwork = try await cache.artworkData(
      serverID: serverID, key: "retained-cover")
    XCTAssertNil(removedAfterTwoMisses)
    XCTAssertEqual(retainedArtwork, Data("retained".utf8))
  }

  func testExistingNASLibraryInvalidationFetchesAuthoritativeDeletionState() async throws {
    let albumID = UUID()
    let firstCatalog = MusicCatalog(
      artist: Artist(id: UUID(), name: "Artist", biography: nil, artworkURL: nil),
      albums: [],
      tracks: [
        Track(
          id: UUID(), albumID: albumID, title: "Song", artistName: "Artist", discNumber: 1,
          trackNumber: 1, durationSeconds: 180, artworkURL: nil, lyrics: nil,
          isExplicit: false)
      ], featuredAlbumIDs: [])
    let catalog = SequencedCatalogService(values: [firstCatalog, .empty])
    let server = MusicServer(
      name: "NAS", baseURL: URL(string: "https://nas.example")!, sourceType: .existingNAS,
      username: "user")
    let provider = ExistingNASProvider(
      server: server, credentials: .init(), client: catalog)

    let initialCount = try await provider.fetchSongs().count
    let cachedCount = try await provider.fetchSongs().count
    await provider.invalidateLibraryCache()
    let refreshedSongs = try await provider.fetchSongs()
    let requestCount = await catalog.requestCount()
    XCTAssertEqual(initialCount, 1)
    XCTAssertEqual(cachedCount, 1)
    XCTAssertTrue(refreshedSongs.isEmpty)
    XCTAssertEqual(requestCount, 2)
  }

  func testCacheUsageSeparatesCircularMediaFromOtherResources() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(
      rootURL: root, byteLimit: 100, minimumByteLimit: 1, mediaByteLimit: 40)
    let serverID = UUID()
    defer { try? FileManager.default.removeItem(at: root) }

    try await cache.storeMedia(
      Data(repeating: 3, count: 16), serverID: serverID, key: "song",
      fileExtension: "mp3")
    try await cache.storeArtwork(
      Data(repeating: 4, count: 20), serverID: serverID, key: "cover")

    let usage = await cache.usage()
    XCTAssertEqual(usage.mediaBytes, 16)
    XCTAssertEqual(usage.resourceBytes, 20)
    XCTAssertEqual(usage.totalBytes, 36)
  }

  func testMediaCacheCommitsDownloadedFileWithoutLoadingItAsData() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(rootURL: root, byteLimit: 1_024, minimumByteLimit: 1)
    let serverID = UUID()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: source)
    }
    try Data(repeating: 9, count: 256).write(to: source)

    let stored = try await cache.storeMediaFile(
      at: source, serverID: serverID, key: "streamed", fileExtension: "mp3")
    let cachedURL = await cache.mediaURL(
      serverID: serverID, key: "streamed", fileExtension: "mp3")

    XCTAssertTrue(stored)
    XCTAssertEqual(try cachedURL?.resourceValues(forKeys: [.fileSizeKey]).fileSize, 256)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  @MainActor
  func testPlaybackDefersPrefetchWhileCurrentTrackHasPriority() async throws {
    let providerID = UUID()
    let tracks = (0..<3).map { index in
      MusicTrack(
        identity: .init(
          providerID: providerID, remoteID: "prefetch-\(index)", sourceType: .openSubsonic),
        albumRemoteID: nil, artistRemoteID: nil, title: "Track \(index)", artistName: "Artist",
        albumTitle: nil, discNumber: 1, trackNumber: index + 1, duration: 600, artworkURL: nil,
        lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/wav",
        suffix: "wav", bitRate: 128, metadata: [:])
    }
    let provider = MockMusicSourceProvider(
      id: providerID, sourceType: .openSubsonic, tracks: tracks,
      mediaData: makeSilentWAV(), mediaMimeType: "audio/wav")
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(rootURL: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = UnifiedPlaybackController(
      provider: provider, wifiQuality: .original, cache: cache,
      prefetchDelay: .zero)

    await playback.play(tracks[0], queue: tracks)
    try await Task.sleep(for: .milliseconds(250))
    let nextTrack = await cache.mediaURL(
      serverID: providerID, key: "prefetch-1|quality:original", fileExtension: "wav")
    let secondNextTrack = await cache.mediaURL(
      serverID: providerID, key: "prefetch-2|quality:original", fileExtension: "wav")
    XCTAssertNil(nextTrack)
    XCTAssertNil(secondNextTrack)
    playback.pause()
  }

  @MainActor
  func testInstantSkipStillReportsStopForThePreviousTrack() async throws {
    let providerID = UUID()
    let tracks = (0..<2).map { index in
      MusicTrack(
        identity: .init(
          providerID: providerID, remoteID: "skip-\(index)", sourceType: .openSubsonic),
        albumRemoteID: nil, artistRemoteID: nil, title: "Track \(index)", artistName: "Artist",
        albumTitle: nil, discNumber: 1, trackNumber: index + 1, duration: 180, artworkURL: nil,
        lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/wav",
        suffix: "wav", bitRate: 128, metadata: [:])
    }
    let provider = MockMusicSourceProvider(
      id: providerID, sourceType: .openSubsonic, tracks: tracks,
      mediaData: makeSilentWAV(), mediaMimeType: "audio/wav")
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(rootURL: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = UnifiedPlaybackController(
      provider: provider, wifiQuality: .original, cache: cache, prefetchDelay: .seconds(60))

    await playback.play(tracks[0], queue: tracks)
    // Skipped before a single second elapsed, which is exactly what rapid switching looks like.
    await playback.play(tracks[1], queue: tracks)
    try await Task.sleep(for: .milliseconds(300))
    playback.pause()

    let events = await provider.reportedPlaybackEvents()
    let stoppedFirstTrack = events.contains { event in
      guard case .stopped(let track, _) = event else { return false }
      return track.identity.remoteID == tracks[0].identity.remoteID
    }
    XCTAssertTrue(
      stoppedFirstTrack,
      "The stop report is what releases the server-side play session, so it has to be sent even "
        + "when the track was skipped instantly")
  }

  @MainActor
  func testPrefetchStartsAfterMostOfCurrentTrackHasPlayed() {
    XCTAssertEqual(UnifiedPlaybackController.prefetchStartFraction, 0.75)
    XCTAssertEqual(
      UnifiedPlaybackController.prefetchStartTime(
        trackDuration: 200, usesExpensiveNetwork: false), 150)
  }

  func testCellularPrefetchStartsAfterThreeSeconds() {
    XCTAssertEqual(
      UnifiedPlaybackController.prefetchStartTime(
        trackDuration: 200, usesExpensiveNetwork: true), 3)
  }

  func testPrefetchSelectsNextThreeTracksAndWrapsQueue() {
    let providerID = UUID()
    let tracks = (0..<5).map { index in
      MusicTrack(
        identity: .init(
          providerID: providerID, remoteID: "ahead-\(index)", sourceType: .openSubsonic),
        albumRemoteID: nil, artistRemoteID: nil, title: "Track \(index)", artistName: "Artist",
        albumTitle: nil, discNumber: 1, trackNumber: index + 1, duration: 180,
        artworkURL: nil, lyrics: nil, isExplicit: false, favoriteState: .notFavorite,
        contentType: "audio/mpeg", suffix: "mp3", bitRate: 192, metadata: [:])
    }

    let upcoming = UnifiedPlaybackController.upcomingTracks(
      in: tracks, currentIndex: 3, order: .sequential,
      limit: UnifiedPlaybackController.prefetchedTrackLimit)

    XCTAssertEqual(upcoming.map(\.identity.remoteID), ["ahead-4", "ahead-0", "ahead-1"])
  }

  func testPlaybackControlKeepsPauseVisibleWhilePlaybackIsRequested() {
    XCTAssertTrue(
      PlaybackControlPresentationPolicy.shouldShowPause(
        hasCurrentTrack: true, wantsPlayback: true))
  }

  func testPlaybackControlShowsPlayOnlyAfterUserPausesOrQueueIsEmpty() {
    XCTAssertFalse(
      PlaybackControlPresentationPolicy.shouldShowPause(
        hasCurrentTrack: true, wantsPlayback: false))
    XCTAssertFalse(
      PlaybackControlPresentationPolicy.shouldShowPause(
        hasCurrentTrack: false, wantsPlayback: true))
  }

  @MainActor
  func testPausingDuringPreparationDoesNotStartPlaybackWhenPreparationFinishes() async throws {
    let providerID = UUID()
    let track = MusicTrack(
      identity: .init(providerID: providerID, remoteID: "slow-start", sourceType: .openSubsonic),
      albumRemoteID: nil, artistRemoteID: nil, title: "Slow Start", artistName: "Artist",
      albumTitle: nil, discNumber: 1, trackNumber: 1, duration: 1, artworkURL: nil,
      lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/wav",
      suffix: "wav", bitRate: 128, metadata: [:])
    let provider = MockMusicSourceProvider(
      id: providerID, sourceType: .openSubsonic, tracks: [track],
      mediaData: makeSilentWAV(), mediaMimeType: "audio/wav",
      streamDelayByRemoteID: [track.identity.remoteID: .milliseconds(200)])
    let playback = UnifiedPlaybackController(
      provider: provider, wifiQuality: .original)

    let preparation = Task { await playback.play(track, queue: [track]) }
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertTrue(playback.isPlaybackRequested)
    playback.togglePlayback()
    XCTAssertFalse(playback.isPlaybackRequested)
    await preparation.value

    XCTAssertFalse(playback.isPlaybackRequested)
    XCTAssertFalse(playback.isPlaying)
  }

  func testCellularPlaybackAlwaysUsesFixedMP3Quality() {
    for wifiQuality in StreamingQuality.allCases {
      XCTAssertEqual(
        UnifiedPlaybackController.effectiveStreamingQuality(
          wifiQuality: wifiQuality, usesCellularNetwork: true),
        .standard)
    }
  }

  func testCellularMP3FailureFallsBackOnlyForTranscodingErrors() {
    XCTAssertTrue(
      UnifiedPlaybackController.shouldFallbackToOriginalFromCellularMP3(
        after: .transcodingFailed))
    XCTAssertTrue(
      UnifiedPlaybackController.shouldFallbackToOriginalFromCellularMP3(
        after: .httpStatus(415)))
    XCTAssertFalse(
      UnifiedPlaybackController.shouldFallbackToOriginalFromCellularMP3(
        after: .networkUnavailable))
    XCTAssertFalse(
      UnifiedPlaybackController.shouldFallbackToOriginalFromCellularMP3(
        after: .authenticationFailed))
  }

  func testPlaybackErrorMappingPreservesUnderlyingNetworkTimeout() {
    let error = NSError(
      domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue,
      userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])

    XCTAssertEqual(MusicSourceError.map(error), .timeout)
  }

  func testPlaybackErrorMappingOnlyReportsExplicitFormatFailureAsUnsupported() {
    XCTAssertEqual(
      MusicSourceError.map(
        NSError(domain: AVFoundationErrorDomain, code: AVError.fileFormatNotRecognized.rawValue)),
      .unsupportedFormat)
    XCTAssertEqual(
      MusicSourceError.map(
        NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue)),
      .invalidResponse)
  }

  func testWiFiPlaybackPreservesRequestedOriginalQuality() {
    XCTAssertEqual(
      UnifiedPlaybackController.effectiveStreamingQuality(
        wifiQuality: .original, usesCellularNetwork: false),
      .original)
  }

  @MainActor
  func testPlaybackAppliesChangedStreamingQualityToSubsequentTracks() async throws {
    let providerID = UUID()
    let tracks = (0..<2).map { index in
      MusicTrack(
        identity: .init(providerID: providerID, remoteID: "quality-\(index)", sourceType: .local),
        albumRemoteID: nil, artistRemoteID: nil, title: "Quality \(index)", artistName: "Artist",
        albumTitle: nil, discNumber: 1, trackNumber: index + 1, duration: 1, artworkURL: nil,
        lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/wav",
        suffix: "wav", bitRate: 128, metadata: [:])
    }
    let provider = MockMusicSourceProvider(
      id: providerID, sourceType: .local, tracks: tracks,
      mediaData: makeSilentWAV(), mediaMimeType: "audio/wav")
    let playback = UnifiedPlaybackController(
      provider: provider, wifiQuality: .original)

    await playback.play(tracks[0], queue: tracks)
    playback.updateWiFiStreamingQuality(.dataSaver)
    await playback.play(tracks[1], queue: tracks)

    let qualityRequests = await provider.requestedStreamingQualities()
    XCTAssertEqual(qualityRequests, [.original, .dataSaver])
    playback.pause()
  }

  @MainActor
  func testPlaybackUsesStallResistantStartupPolicy() async throws {
    let providerID = UUID()
    let track = MusicTrack(
      identity: .init(
        providerID: providerID, remoteID: "low-latency-start", sourceType: .openSubsonic),
      albumRemoteID: nil, artistRemoteID: nil, title: "Low Latency", artistName: "Artist",
      albumTitle: nil, discNumber: 1, trackNumber: 1, duration: 1, artworkURL: nil,
      lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/wav",
      suffix: "wav", bitRate: 2_304, metadata: [:])
    let provider = MockMusicSourceProvider(
      id: providerID, sourceType: .openSubsonic, tracks: [track],
      mediaData: makeSilentWAV(), mediaMimeType: "audio/wav")
    let playback = UnifiedPlaybackController(
      provider: provider, wifiQuality: .original)

    await playback.play(track, queue: [track])

    XCTAssertTrue(playback.automaticallyWaitsToMinimizeStallingForTesting)
    XCTAssertEqual(
      playback.preferredForwardBufferDurationForTesting,
      UnifiedPlaybackController.startupBufferDuration(usesExpensiveNetwork: false))
    playback.pause()
  }

  func testCellularPlaybackUsesShortStartupBuffer() {
    XCTAssertEqual(
      UnifiedPlaybackController.startupBufferDuration(usesExpensiveNetwork: true), 2)
    XCTAssertEqual(
      UnifiedPlaybackController.startupBufferDuration(usesExpensiveNetwork: false), 8)
  }

  func testCellularFastStartSkipsInspectionForNativeAndTranscodedDirectStreams() {
    XCTAssertTrue(
      UnifiedPlaybackController.shouldUseFastRemoteStart(
        isRecovery: false, usesCachedMedia: false, hasResourceLoader: false,
        quality: .original, isNativelyPlayable: true))
    XCTAssertFalse(
      UnifiedPlaybackController.shouldUseFastRemoteStart(
        isRecovery: true, usesCachedMedia: false, hasResourceLoader: false,
        quality: .original, isNativelyPlayable: true))
    XCTAssertTrue(
      UnifiedPlaybackController.shouldUseFastRemoteStart(
        isRecovery: false, usesCachedMedia: false, hasResourceLoader: true,
        quality: .original, isNativelyPlayable: true))
    XCTAssertTrue(
      UnifiedPlaybackController.shouldUseFastRemoteStart(
        isRecovery: false, usesCachedMedia: false, hasResourceLoader: false,
        quality: .standard, isNativelyPlayable: true))
    XCTAssertTrue(
      UnifiedPlaybackController.shouldUseFastRemoteStart(
        isRecovery: false, usesCachedMedia: false, hasResourceLoader: false,
        quality: .standard, isNativelyPlayable: false))
  }

  func testPlaybackCompletionPolicyRejectsPrematureStreamEnd() {
    XCTAssertFalse(
      PlaybackCompletionPolicy.shouldAdvance(
        position: 4, catalogDuration: 180, itemDuration: 4))
  }

  func testPlaybackCompletionPolicyAllowsNaturalEndWithinTolerance() {
    XCTAssertTrue(
      PlaybackCompletionPolicy.shouldAdvance(
        position: 177, catalogDuration: 180, itemDuration: 179.5))
  }

  func testPlaybackCompletionPolicyUsesLongerKnownDuration() {
    XCTAssertFalse(
      PlaybackCompletionPolicy.shouldAdvance(
        position: 120, catalogDuration: 120, itemDuration: 180))
  }

  func testPlaybackCompletionPolicyAllowsUnknownDurationEndNotification() {
    XCTAssertTrue(
      PlaybackCompletionPolicy.shouldAdvance(
        position: 0, catalogDuration: 0, itemDuration: .nan))
  }

  func testMediaDurationPolicyRejectsTruncatedAndRepeatedTimelines() {
    XCTAssertFalse(
      MediaDurationPolicy.isPlausible(catalogDuration: 199, mediaDuration: 93))
    XCTAssertFalse(
      MediaDurationPolicy.isPlausible(catalogDuration: 180, mediaDuration: 420))
  }

  func testMediaDurationPolicyAllowsNormalContainerVariance() {
    XCTAssertTrue(
      MediaDurationPolicy.isPlausible(catalogDuration: 199, mediaDuration: 199.128))
    XCTAssertTrue(
      MediaDurationPolicy.isPlausible(catalogDuration: 180, mediaDuration: nil))
  }

  func testAudioInterruptionResumesOnlyWhenPlaybackWasActiveAndSystemAllowsIt() {
    XCTAssertTrue(
      AudioSessionInterruptionPolicy.shouldResumePlayback(
        wasPlayingBeforeInterruption: true, systemAllowsResume: true))
  }

  func testAudioInterruptionDoesNotResumeWhenSystemDeclinesRecovery() {
    XCTAssertFalse(
      AudioSessionInterruptionPolicy.shouldResumePlayback(
        wasPlayingBeforeInterruption: true, systemAllowsResume: false))
  }

  func testAudioInterruptionDoesNotResumeUserPausedPlayback() {
    XCTAssertFalse(
      AudioSessionInterruptionPolicy.shouldResumePlayback(
        wasPlayingBeforeInterruption: false, systemAllowsResume: true))
  }

  @MainActor
  func testRapidTrackSelectionKeepsOnlyLatestPlaybackRequest() async throws {
    let providerID = UUID()
    func track(_ remoteID: String) -> MusicTrack {
      MusicTrack(
        identity: .init(providerID: providerID, remoteID: remoteID, sourceType: .local),
        albumRemoteID: nil, artistRemoteID: nil, title: remoteID, artistName: "Artist",
        albumTitle: nil, discNumber: 1, trackNumber: 1, duration: 1, artworkURL: nil,
        lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/wav",
        suffix: "wav", bitRate: 128, metadata: [:])
    }
    let slowTrack = track("slow-track")
    let latestTrack = track("latest-track")
    let provider = MockMusicSourceProvider(
      id: providerID, sourceType: .local, tracks: [slowTrack, latestTrack],
      mediaData: makeSilentWAV(), mediaMimeType: "audio/wav",
      streamDelayByRemoteID: [slowTrack.identity.remoteID: .milliseconds(250)])
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(rootURL: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = UnifiedPlaybackController(
      provider: provider, wifiQuality: .original, cache: cache)

    let slowRequest = Task { await playback.play(slowTrack, queue: [slowTrack, latestTrack]) }
    try await Task.sleep(for: .milliseconds(30))
    await playback.play(latestTrack, queue: [slowTrack, latestTrack])
    await slowRequest.value

    XCTAssertEqual(playback.currentTrack?.id, latestTrack.id)
    for _ in 0..<20 where !playback.isPlaying {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(playback.isPlaying)
    playback.pause()
  }

  @MainActor
  func testStartingAnotherControllerStopsPreviousAudioOwner() async throws {
    let audio = makeSilentWAV()
    let firstID = UUID()
    let secondID = UUID()
    let firstTrack = MusicTrack(
      identity: .init(providerID: firstID, remoteID: "first", sourceType: .local),
      albumRemoteID: nil, artistRemoteID: nil, title: "First", artistName: "Artist",
      albumTitle: nil, discNumber: 1, trackNumber: 1, duration: 1, artworkURL: nil,
      lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/wav",
      suffix: "wav", bitRate: 128, metadata: [:])
    let secondTrack = MusicTrack(
      identity: .init(providerID: secondID, remoteID: "second", sourceType: .local),
      albumRemoteID: nil, artistRemoteID: nil, title: "Second", artistName: "Artist",
      albumTitle: nil, discNumber: 1, trackNumber: 1, duration: 1, artworkURL: nil,
      lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/wav",
      suffix: "wav", bitRate: 128, metadata: [:])
    let firstPlayback = UnifiedPlaybackController(
      provider: MockMusicSourceProvider(
        id: firstID, sourceType: .local, tracks: [firstTrack], mediaData: audio,
        mediaMimeType: "audio/wav"),
      wifiQuality: .original)
    let secondPlayback = UnifiedPlaybackController(
      provider: MockMusicSourceProvider(
        id: secondID, sourceType: .local, tracks: [secondTrack], mediaData: audio,
        mediaMimeType: "audio/wav"),
      wifiQuality: .original)

    await firstPlayback.play(firstTrack, queue: [firstTrack])
    for _ in 0..<20 where !firstPlayback.isPlaying {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(firstPlayback.isPlaying)
    await secondPlayback.play(secondTrack, queue: [secondTrack])

    XCTAssertFalse(firstPlayback.isPlaying)
    for _ in 0..<20 where !secondPlayback.isPlaying {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(secondPlayback.isPlaying)
    secondPlayback.pause()
  }

  @MainActor
  func testSearchQueueContinuesIntoDefaultQueueWithoutDuplicates() async throws {
    let providerID = UUID()
    func track(_ remoteID: String) -> MusicTrack {
      MusicTrack(
        identity: .init(providerID: providerID, remoteID: remoteID, sourceType: .local),
        albumRemoteID: nil, artistRemoteID: nil, title: remoteID, artistName: "Artist",
        albumTitle: nil, discNumber: 1, trackNumber: 1, duration: 1, artworkURL: nil,
        lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/wav",
        suffix: "wav", bitRate: 128, metadata: [:])
    }
    let searchA = track("search-a")
    let shared = track("shared")
    let libraryOnly = track("library-only")
    let provider = MockMusicSourceProvider(
      id: providerID, sourceType: .local, tracks: [searchA, shared, libraryOnly],
      mediaData: makeSilentWAV(), mediaMimeType: "audio/wav")
    let playback = UnifiedPlaybackController(
      provider: provider, wifiQuality: .original)

    await playback.play(
      searchA, queue: [searchA, shared], continuingWith: [shared, libraryOnly])

    XCTAssertEqual(
      playback.queue.map(\.identity.remoteID), ["search-a", "shared", "library-only"])
    playback.pause()
  }

  func testLocalMusicProviderImportsDeduplicatesAndEditsPlaylists() async throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let source = temporary.appending(path: "A Local Song.wav")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    try makeSilentWAV().write(to: source)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let server = MusicServer(
      id: UUID(uuidString: "00000000-0000-5000-8000-000000000001")!, name: "Local",
      baseURL: URL(string: "localmusic://library")!,
      sourceType: .local, username: "", usesHTTPS: false, transcodingEnabled: false)
    let provider = LocalMusicProvider(server: server, rootURL: temporary.appending(path: "Library"))
    try await provider.authenticate()
    let firstImportCount = try await provider.importFiles([source])
    let duplicateImportCount = try await provider.importFiles([source])
    XCTAssertEqual(firstImportCount, 1)
    XCTAssertEqual(duplicateImportCount, 0)
    let songs = try await provider.fetchSongs()
    let track = try XCTUnwrap(songs.first)
    XCTAssertEqual(track.title, "A Local Song")
    XCTAssertGreaterThan(track.duration, 0.9)
    let mediaURL = try await provider.streamURL(for: track, quality: .original)
    let response = try await provider.loadMediaResource(at: mediaURL, range: "bytes=0-43")
    XCTAssertEqual(response.statusCode, 206)
    XCTAssertEqual(response.data.count, 44)

    let playlist = try await provider.createPlaylist(
      name: "Local Mix", trackIDs: [track.identity.remoteID])
    XCTAssertEqual(playlist.trackCount, 1)
    let createdDetail = try await provider.fetchPlaylist(id: playlist.identity.remoteID)
    XCTAssertEqual(createdDetail.tracks, [track])
    try await provider.updatePlaylist(
      id: playlist.identity.remoteID, name: "Renamed", adding: [], removingIndexes: [0])
    let updatedDetail = try await provider.fetchPlaylist(id: playlist.identity.remoteID)
    XCTAssertEqual(updatedDetail.tracks.count, 0)
    try await provider.deletePlaylist(id: playlist.identity.remoteID)
    let remainingPlaylists = try await provider.fetchPlaylists()
    XCTAssertTrue(remainingPlaylists.isEmpty)
  }

  func testLocalMusicProviderRecursivelyImportsFolderAndReturnsExistingTracks() async throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceFolder = temporary.appending(path: "NAS Music")
    let nestedFolder = sourceFolder.appending(path: "Artist/Album")
    try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
    let first = sourceFolder.appending(path: "First.wav")
    let second = nestedFolder.appending(path: "Second.wav")
    try makeSilentWAV().write(to: first)
    var distinctAudio = makeSilentWAV()
    distinctAudio.append(0)
    try distinctAudio.write(to: second)
    try Data("not audio".utf8).write(to: sourceFolder.appending(path: "notes.txt"))
    defer { try? FileManager.default.removeItem(at: temporary) }

    let server = MusicServer(
      id: UUID(uuidString: "00000000-0000-5000-8000-000000000001")!, name: "Local",
      baseURL: URL(string: "localmusic://library")!, sourceType: .local, username: "",
      usesHTTPS: false, transcodingEnabled: false)
    let provider = LocalMusicProvider(server: server, rootURL: temporary.appending(path: "Library"))
    try await provider.authenticate()

    let firstReport = try await provider.importFolder(sourceFolder)
    XCTAssertEqual(firstReport.importedCount, 2)
    XCTAssertEqual(firstReport.availableTracks.count, 2)
    let songsAfterFirstImport = try await provider.fetchSongs()
    XCTAssertEqual(songsAfterFirstImport.count, 2)

    let duplicateReport = try await provider.importFolder(sourceFolder)
    XCTAssertEqual(duplicateReport.importedCount, 0)
    XCTAssertEqual(duplicateReport.duplicateCount, 2)
    XCTAssertEqual(duplicateReport.availableTracks.count, 2)
    let songsAfterDuplicateImport = try await provider.fetchSongs()
    XCTAssertEqual(songsAfterDuplicateImport.count, 2)
  }

  func testMediaCacheFindsActualTranscodedExtensionWithoutTrustingSourceSuffix() async throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(rootURL: temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let serverID = UUID()
    try await cache.storeMedia(
      Data("compatible-audio".utf8), serverID: serverID, key: "source-ape",
      fileExtension: "m4a")

    let discovered = await cache.mediaURL(serverID: serverID, key: "source-ape")
    let incorrectlyNamed = await cache.mediaURL(
      serverID: serverID, key: "source-ape", fileExtension: "ape")

    XCTAssertEqual(discovered?.pathExtension, "m4a")
    XCTAssertNil(incorrectlyNamed)
  }

  func testStableIdentityIsDeterministicAndProviderScoped() {
    let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    XCTAssertEqual(
      StableMusicID.make(providerID: first, remoteID: "song-1"),
      StableMusicID.make(providerID: first, remoteID: "song-1"))
    XCTAssertNotEqual(
      StableMusicID.make(providerID: first, remoteID: "song-1"),
      StableMusicID.make(providerID: second, remoteID: "song-1"))
    XCTAssertEqual(
      MusicServerURLNormalizer.normalize(
        URL(string: "https://music.example.test/navidrome/rest/")!, for: .openSubsonic
      ).path, "/navidrome")
    XCTAssertEqual(
      MusicServerURLNormalizer.normalize(
        URL(string: "https://music.example.test/jellyfin/web/index.html#!/home.html")!,
        for: .jellyfin
      ).path, "/jellyfin")
  }

  func testNativePlaybackDetectionFallsBackToContentTypeAndTranscodesUnknownFormats() {
    let providerID = UUID()
    var track = makeTrack(providerID: providerID, sourceType: .openSubsonic)
    track.suffix = nil
    track.contentType = "audio/flac"
    XCTAssertTrue(track.isNativelyPlayableOnIOS)
    track.contentType = "audio/ogg"
    XCTAssertFalse(track.isNativelyPlayableOnIOS)
    track.contentType = nil
    XCTAssertFalse(track.isNativelyPlayableOnIOS)
    track.suffix = ".M4A"
    XCTAssertTrue(track.isNativelyPlayableOnIOS)
    track.suffix = "wv"
    XCTAssertFalse(track.isNativelyPlayableOnIOS)
  }

  func testProviderHTTPClientRetriesTransientReadWhenExplicitlyEnabled() async throws {
    FlakyReadURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FlakyReadURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let server = MusicServer(
      name: "NAS", baseURL: URL(string: "https://nas.example.test")!,
      sourceType: .existingNAS, username: "listener")
    let client = ProviderHTTPClient(server: server, session: session)
    let data = try await client.data(
      for: URLRequest(url: server.baseURL.appending(path: "v1/catalog")),
      retryPolicy: .transient(maxAttempts: 3))

    XCTAssertEqual(String(decoding: data, as: UTF8.self), "stable")
    XCTAssertEqual(FlakyReadURLProtocol.attempts(), 2)
  }

  func testProviderHTTPClientRetriesTransientTLSFailureBeforeStreamingData() async throws {
    FlakyReadURLProtocol.reset(failure: .secureConnectionFailed)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FlakyReadURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let server = MusicServer(
      name: "NAS", baseURL: URL(string: "https://nas.example.test")!,
      sourceType: .existingNAS, username: "listener")
    let client = ProviderHTTPClient(server: server, session: session)
    let probe = LiveMediaStreamProbe()

    try await client.streamMediaResponse(
      for: URLRequest(url: server.baseURL.appending(path: "v1/media")),
      retryPolicy: .transient(maxAttempts: 3),
      onResponse: { metadata in
        await probe.record(metadata: metadata)
        return true
      },
      onData: { data in
        await probe.record(data: data)
        return false
      })

    let result = await probe.result()
    XCTAssertEqual(result.statusCode, 200)
    XCTAssertEqual(result.byteCount, Data("stable".utf8).count)
    XCTAssertEqual(FlakyReadURLProtocol.attempts(), 2)
  }

  func testProviderHTTPClientStreamsDownloadToTemporaryFile() async throws {
    FlakyReadURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FlakyReadURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let server = MusicServer(
      name: "NAS", baseURL: URL(string: "https://nas.example.test")!,
      sourceType: .existingNAS, username: "listener")
    let client = ProviderHTTPClient(server: server, session: session)
    let download = try await client.downloadResponse(
      for: URLRequest(url: server.baseURL.appending(path: "v1/media")),
      retryPolicy: .transient(maxAttempts: 3))
    defer { try? FileManager.default.removeItem(at: download.temporaryURL) }

    XCTAssertEqual(try Data(contentsOf: download.temporaryURL), Data("stable".utf8))
    XCTAssertEqual(download.statusCode, 200)
    XCTAssertEqual(FlakyReadURLProtocol.attempts(), 2)
  }

  func testOpenSubsonicUsesValidatedMediaResourceLoader() {
    let openSubsonicServer = MusicServer(
      name: "OpenSubsonic", baseURL: URL(string: "https://music.example.test")!,
      sourceType: .openSubsonic, username: "listener")
    let openSubsonic = OpenSubsonicProvider(
      server: openSubsonicServer, credentials: .init(password: "password"))
    let jellyfinServer = MusicServer(
      name: "Jellyfin", baseURL: URL(string: "https://jellyfin.example.test")!,
      sourceType: .jellyfin, username: "listener")
    let jellyfin = JellyfinProvider(
      server: jellyfinServer, credentials: .init(password: "password"))

    XCTAssertFalse(openSubsonic.mediaURLAllowsDirectPlayback)
    XCTAssertFalse(jellyfin.mediaURLAllowsDirectPlayback)
  }

  func testOpenSubsonicAuthenticationAndQualityURL() async throws {
    ProviderStubURLProtocol.reset()
    let session = makeSession()
    let server = MusicServer(
      name: "Navidrome", baseURL: URL(string: "https://music.example.test")!,
      sourceType: .openSubsonic, username: "listener")
    let provider = OpenSubsonicProvider(
      server: server, credentials: .init(password: "secret"), session: session)
    try await provider.authenticate()
    async let albumsRequest = provider.fetchAlbums()
    async let songsRequest = provider.fetchSongs()
    let albums = try await albumsRequest
    let songs = try await songsRequest
    XCTAssertEqual(albums.first?.title, "Parsed Album")
    let openSubsonicLibraries = try await provider.fetchLibraries()
    XCTAssertEqual(openSubsonicLibraries.first?.name, "Main Music")
    let search = try await provider.search(query: "song")
    XCTAssertEqual(search.tracks.first?.title, "Parsed Song")
    XCTAssertEqual(songs.first?.title, "Parsed Song")
    let lyrics = try await provider.fetchLyrics(for: try XCTUnwrap(songs.first))
    XCTAssertEqual(lyrics?.lines.first?.text, "Timed line")
    XCTAssertEqual(lyrics?.lines.first?.time, 1.5)
    XCTAssertEqual(lyrics?.isSynced, true)
    XCTAssertEqual(
      ProviderStubURLProtocol.requests().filter { $0.url?.path.contains("getAlbumList2") == true }
        .count, 1)
    XCTAssertFalse(
      ProviderStubURLProtocol.requests().contains { request in
        request.url?.path.contains("getAlbum") == true
          && request.url?.path.contains("getAlbumList2") == false
      })
    let librarySearch = ProviderStubURLProtocol.requests().first { request in
      guard request.url?.path.contains("search3") == true,
        let items = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?
          .queryItems
      else { return false }
      return items.first(where: { $0.name == "query" })?.value == ""
    }
    XCTAssertNotNil(librarySearch)
    _ = try await provider.createPlaylist(name: "Mix", trackIDs: ["song-a", "song-b"])
    let createItems = try XCTUnwrap(
      ProviderStubURLProtocol.requests().last(where: {
        $0.url?.path.contains("createPlaylist") == true
      })?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
    XCTAssertEqual(createItems.filter { $0.name == "songId" }.map(\.value), ["song-a", "song-b"])
    XCTAssertFalse(createItems.contains { $0.name.contains("[") })
    try await provider.updatePlaylist(
      id: "playlist-1", name: "Renamed", adding: ["song-c", "song-d"], removingIndexes: [1, 3])
    let updateItems = try XCTUnwrap(
      ProviderStubURLProtocol.requests().last(where: {
        $0.url?.path.contains("updatePlaylist") == true
      })?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
    XCTAssertEqual(updateItems.filter { $0.name == "songIdToAdd" }.count, 2)
    XCTAssertEqual(updateItems.filter { $0.name == "songIndexToRemove" }.count, 2)
    let home = try await provider.fetchHomeSections()
    XCTAssertTrue(home.contains { $0.kind == .favoriteTracks })
    let track = makeTrack(providerID: server.id, sourceType: .openSubsonic)
    let url = try await provider.streamURL(for: track, quality: .high)
    let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(query.first(where: { $0.name == "maxBitRate" })?.value, "320")
    XCTAssertEqual(query.first(where: { $0.name == "format" })?.value, "mp3")
    XCTAssertEqual(query.first(where: { $0.name == "u" })?.value, "listener")
    XCTAssertEqual(query.first(where: { $0.name == "t" })?.value?.count, 32)
    XCTAssertNil(query.first(where: { $0.name == "p" }))
    var unsupported = track
    unsupported.suffix = "ape"
    let compatibilityURL = try await provider.streamURL(for: unsupported, quality: .original)
    XCTAssertNil(
      URLComponents(url: compatibilityURL, resolvingAgainstBaseURL: false)?.queryItems?.first(
        where: { $0.name == "format" }))
  }

  func testJellyfinLoginAndTranscodingURL() async throws {
    ProviderStubURLProtocol.reset()
    let server = MusicServer(
      name: "Jellyfin", baseURL: URL(string: "https://jellyfin.example.test")!,
      sourceType: .jellyfin, username: "listener")
    let provider = JellyfinProvider(
      server: server, credentials: .init(password: "secret"), session: makeSession())
    try await provider.authenticate()
    let jellyfinLibraries = try await provider.fetchLibraries()
    XCTAssertEqual(jellyfinLibraries.first?.name, "Music")
    let search = try await provider.search(query: "song")
    XCTAssertEqual(search.tracks.first?.title, "Jellyfin Song")
    let credentials = await provider.refreshedCredentials()
    XCTAssertEqual(credentials?.token, "access-token")
    XCTAssertEqual(credentials?.remoteUserID, "user-1")
    let url = try await provider.streamURL(
      for: makeTrack(providerID: server.id, sourceType: .jellyfin), quality: .standard)
    let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(items.first(where: { $0.name == "api_key" })?.value, "access-token")
    XCTAssertEqual(items.first(where: { $0.name == "MaxStreamingBitrate" })?.value, "192000")
    XCTAssertEqual(items.first(where: { $0.name == "TranscodingProtocol" })?.value, "http")
    let directURL = try await provider.streamURL(
      for: makeTrack(providerID: server.id, sourceType: .jellyfin), quality: .original)
    XCTAssertTrue(directURL.path.hasSuffix("/stream"))
    var unsupported = makeTrack(providerID: server.id, sourceType: .jellyfin)
    unsupported.suffix = "ape"
    unsupported.contentType = "audio/x-ape"
    let originalFallbackURL = try await provider.streamURL(for: unsupported, quality: .original)
    XCTAssertTrue(originalFallbackURL.path.hasSuffix("/stream"))
    XCTAssertNil(
      URLComponents(url: originalFallbackURL, resolvingAgainstBaseURL: false)?.queryItems?.first(
        where: { $0.name == "AudioCodec" }))
  }

  func testJellyfinReusesOnePlaySessionPerTrackAcrossStreamURLRequests() async throws {
    ProviderStubURLProtocol.reset()
    let server = MusicServer(
      name: "Jellyfin", baseURL: URL(string: "https://jellyfin.example.test")!,
      sourceType: .jellyfin, username: "listener")
    let provider = JellyfinProvider(
      server: server, credentials: .init(password: "secret"), session: makeSession())
    try await provider.authenticate()
    let track = makeTrack(providerID: server.id, sourceType: .jellyfin)
    let template = makeTrack(providerID: server.id, sourceType: .jellyfin)
    let other = MusicTrack(
      identity: .init(providerID: server.id, remoteID: "track-2", sourceType: .jellyfin),
      albumRemoteID: template.albumRemoteID, artistRemoteID: template.artistRemoteID,
      title: "Next Song", artistName: template.artistName, albumTitle: template.albumTitle,
      discNumber: 1, trackNumber: 2, duration: template.duration, artworkURL: nil, lyrics: nil,
      isExplicit: false, favoriteState: .notFavorite, contentType: template.contentType,
      suffix: template.suffix, bitRate: template.bitRate, metadata: [:])

    func playSessionID(_ url: URL) throws -> String {
      let items = try XCTUnwrap(
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
      return try XCTUnwrap(items.first(where: { $0.name == "PlaySessionId" })?.value)
    }

    let first = try playSessionID(await provider.streamURL(for: track, quality: .standard))
    // A prefetch of the next track must not take the current track's session with it.
    _ = try await provider.streamURL(for: other, quality: .standard)
    let retried = try playSessionID(await provider.streamURL(for: track, quality: .original))
    let nextTrackSession = try playSessionID(
      await provider.streamURL(for: other, quality: .standard))

    XCTAssertEqual(
      first, retried,
      "Minting a new play session per request leaks a server-side transcode session for every "
        + "skipped track")
    XCTAssertNotEqual(first, nextTrackSession)
  }

  func testJellyfinRestoresTokenWithoutPasswordLogin() async throws {
    ProviderStubURLProtocol.reset()
    let server = MusicServer(
      name: "Jellyfin", baseURL: URL(string: "https://jellyfin.example.test")!,
      sourceType: .jellyfin, username: "listener")
    let provider = JellyfinProvider(
      server: server,
      credentials: .init(token: "access-token", remoteUserID: "user-1"),
      session: makeSession())
    try await provider.authenticate()
    XCTAssertFalse(
      ProviderStubURLProtocol.requests().contains {
        $0.url?.path.contains("AuthenticateByName") == true
      })
  }

  func testLiveNavidromeProviderContractWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let baseURLValue = environment["MUSICPLAYER_NAVIDROME_URL"],
      let baseURL = URL(string: baseURLValue),
      let username = environment["MUSICPLAYER_NAVIDROME_USERNAME"],
      let password = environment["MUSICPLAYER_NAVIDROME_PASSWORD"]
    else {
      throw XCTSkip("Set MUSICPLAYER_NAVIDROME_* to run the live provider contract test")
    }

    let server = MusicServer(
      name: "Navidrome Integration", baseURL: baseURL, sourceType: .openSubsonic,
      username: username, allowsSelfSignedCertificate: true,
      certificateFingerprint: environment["MUSICPLAYER_NAVIDROME_FINGERPRINT"])
    let provider = OpenSubsonicProvider(
      server: server, credentials: .init(password: password))

    try await provider.authenticate()
    let info = try await provider.fetchServerInfo()
    XCTAssertEqual(info.type, .openSubsonic)
    let libraries = try await provider.fetchLibraries()
    let artists = try await provider.fetchArtists()
    let albums = try await provider.fetchAlbums()
    XCTAssertFalse(libraries.isEmpty)
    XCTAssertFalse(artists.isEmpty)
    XCTAssertFalse(albums.isEmpty)
    let tracks = try await provider.fetchSongs()
    let track = try XCTUnwrap(tracks.first)
    let search = try await provider.search(query: track.title)
    let home = try await provider.fetchHomeSections()
    XCTAssertFalse(search.tracks.isEmpty)
    XCTAssertFalse(home.isEmpty)

    let streamURL = try await provider.streamURL(for: track, quality: .original)
    let media = try await provider.loadMediaResource(at: streamURL, range: "bytes=0-1023")
    XCTAssertFalse(media.data.isEmpty)
    XCTAssertTrue((200...206).contains(media.statusCode))

    try await provider.setFavorite(item: .track(track), isFavorite: true)
    try await provider.setFavorite(item: .track(track), isFavorite: false)
    try await provider.reportPlayback(.started(track: track))
    try await provider.reportPlayback(
      .progress(track: track, position: 0.5, duration: track.duration))
    try await provider.reportPlayback(.completed(track: track))

    let playlist = try await provider.createPlaylist(
      name: "MusicPlayer Integration", trackIDs: [track.identity.remoteID])
    do {
      let detail = try await provider.fetchPlaylist(id: playlist.identity.remoteID)
      XCTAssertEqual(detail.tracks.first?.identity.remoteID, track.identity.remoteID)
      try await provider.updatePlaylist(
        id: playlist.identity.remoteID, name: "MusicPlayer Integration Updated", adding: [],
        removingIndexes: [])
      try await provider.deletePlaylist(id: playlist.identity.remoteID)
    } catch {
      try? await provider.deletePlaylist(id: playlist.identity.remoteID)
      throw error
    }
  }

  func testLiveJellyfinProviderContractWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let baseURLValue = environment["MUSICPLAYER_JELLYFIN_URL"],
      let baseURL = URL(string: baseURLValue),
      let username = environment["MUSICPLAYER_JELLYFIN_USERNAME"],
      let password = environment["MUSICPLAYER_JELLYFIN_PASSWORD"]
    else {
      throw XCTSkip("Set MUSICPLAYER_JELLYFIN_* to run the live provider contract test")
    }

    let server = MusicServer(
      name: "Jellyfin Integration", baseURL: baseURL, sourceType: .jellyfin,
      username: username, usesHTTPS: baseURL.scheme?.lowercased() == "https")
    let provider = JellyfinProvider(server: server, credentials: .init(password: password))

    try await provider.authenticate()
    let credentials = await provider.refreshedCredentials()
    let refreshedCredentials = try XCTUnwrap(credentials)
    XCTAssertNotNil(refreshedCredentials.token)
    XCTAssertNotNil(refreshedCredentials.remoteUserID)
    let info = try await provider.fetchServerInfo()
    XCTAssertEqual(info.type, .jellyfin)
    let libraries = try await provider.fetchLibraries()
    let artists = try await provider.fetchArtists()
    let albums = try await provider.fetchAlbums()
    let tracks = try await provider.fetchSongs()
    XCTAssertFalse(libraries.isEmpty)
    XCTAssertFalse(artists.isEmpty)
    XCTAssertFalse(albums.isEmpty)
    let track = try XCTUnwrap(tracks.first)
    let search = try await provider.search(query: track.title)
    let home = try await provider.fetchHomeSections()
    XCTAssertFalse(search.tracks.isEmpty)
    XCTAssertFalse(home.isEmpty)

    let streamURL = try await provider.streamURL(for: track, quality: .original)
    let media = try await provider.loadMediaResource(at: streamURL, range: "bytes=0-1023")
    XCTAssertFalse(media.data.isEmpty)
    XCTAssertTrue((200...206).contains(media.statusCode))

    try await provider.setFavorite(item: .track(track), isFavorite: true)
    try await provider.setFavorite(item: .track(track), isFavorite: false)
    try await provider.reportPlayback(.started(track: track))
    try await provider.reportPlayback(
      .progress(track: track, position: 0.5, duration: track.duration))
    try await provider.reportPlayback(.stopped(track: track, position: 0.5))

    let playlist = try await provider.createPlaylist(
      name: "MusicPlayer Integration", trackIDs: [track.identity.remoteID])
    do {
      let detail = try await provider.fetchPlaylist(id: playlist.identity.remoteID)
      XCTAssertEqual(detail.tracks.first?.identity.remoteID, track.identity.remoteID)
      try await provider.updatePlaylist(
        id: playlist.identity.remoteID, name: "MusicPlayer Integration Updated", adding: [],
        removingIndexes: [])
      try await provider.deletePlaylist(id: playlist.identity.remoteID)
    } catch {
      try? await provider.deletePlaylist(id: playlist.identity.remoteID)
      throw error
    }
  }

  func testLiveSecondarySubsonicCompatibilityWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let baseURLValue = environment["MUSICPLAYER_SECONDARY_SUBSONIC_URL"],
      let baseURL = URL(string: baseURLValue),
      let username = environment["MUSICPLAYER_SECONDARY_SUBSONIC_USERNAME"],
      let password = environment["MUSICPLAYER_SECONDARY_SUBSONIC_PASSWORD"]
    else {
      throw XCTSkip(
        "Set MUSICPLAYER_SECONDARY_SUBSONIC_* to run the compatibility test")
    }

    let server = MusicServer(
      name: "Secondary Subsonic Integration", baseURL: baseURL, sourceType: .openSubsonic,
      username: username, usesHTTPS: baseURL.scheme?.lowercased() == "https",
      allowsSelfSignedCertificate: true,
      certificateFingerprint: environment["MUSICPLAYER_SECONDARY_SUBSONIC_FINGERPRINT"])
    let provider = OpenSubsonicProvider(
      server: server, credentials: .init(password: password))

    try await provider.authenticate()
    let info = try await provider.fetchServerInfo()
    XCTAssertEqual(info.type, .openSubsonic)
    _ = try await provider.fetchLibraries()
    _ = try await provider.fetchArtists()
    _ = try await provider.fetchAlbums()
    _ = try await provider.fetchSongs()
    _ = try await provider.fetchPlaylists()
    _ = try await provider.search(query: "compatibility")
    _ = try await provider.fetchHomeSections()
    let playlist = try await provider.createPlaylist(
      name: "MusicPlayer Compatibility", trackIDs: [])
    try await provider.deletePlaylist(id: playlist.identity.remoteID)
  }

  @MainActor
  func testSourceStoreSupportsMultipleServersAndSwitching() async throws {
    let repository = InMemoryServerRepository()
    let vault = InMemoryCredentialVault()
    let suiteName = "MusicPlayerTests.SourceStore.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let factory = ProviderFactory { server, _ in
      MockMusicSourceProvider(id: server.id, sourceType: server.sourceType)
    }
    let store = MusicSourceStore(
      repository: repository, vault: vault, factory: factory,
      cache: MusicCache(
        rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
      defaults: defaults)
    await store.restore()
    XCTAssertFalse(store.hasReliableActiveSource)
    let first = MusicServer(
      name: "Navidrome", baseURL: URL(string: "https://one.example")!, sourceType: .openSubsonic,
      username: "a")
    let second = MusicServer(
      name: "Jellyfin", baseURL: URL(string: "https://two.example")!, sourceType: .jellyfin,
      username: "b")
    try await store.add(first, credentials: .init(password: "one"))
    XCTAssertTrue(store.hasReliableActiveSource)
    store.recordConnectionResult(serverID: first.id, error: .networkUnavailable)
    XCTAssertTrue(
      store.hasReliableActiveSource,
      "A temporary outage must not eject a previously verified source back to setup")
    try await store.add(second, credentials: .init(password: "two"))
    XCTAssertEqual(store.servers.count, 2)
    XCTAssertEqual(store.activeServerID, second.id)
    try store.select(first.id)
    XCTAssertEqual(store.activeServerID, first.id)
    XCTAssertEqual(try vault.read(serverID: first.id)?.password, "one")
    let persisted = try repository.load().servers.first { $0.id == first.id }
    XCTAssertEqual(persisted?.wifiQuality, .original)
  }

  func testKeychainCredentialVaultRoundTripAndDeletion() throws {
    let serverID = UUID()
    let vault = KeychainCredentialVault(service: "MusicPlayerTests.\(UUID().uuidString)")
    let expected = ProviderCredentials(password: "secret", token: "token", remoteUserID: "user-1")
    do {
      try vault.save(expected, serverID: serverID)
      XCTAssertEqual(try vault.read(serverID: serverID), expected)
      try vault.delete(serverID: serverID)
      XCTAssertNil(try vault.read(serverID: serverID))
    } catch MusicSourceError.keychainFailure(-34018) {
      throw XCTSkip("未签名的模拟器测试包没有 Keychain entitlement")
    }
  }

  func testSimulatorVaultFallsBackOnlyAfterMissingEntitlement() throws {
    let primary = MissingEntitlementCredentialVault()
    let vault = SimulatorFallbackCredentialVault(primary: primary, allowsFallback: true)
    let serverID = UUID()
    let credentials = ProviderCredentials(password: "session-secret")

    XCTAssertEqual(vault.mode, .keychain)
    try vault.save(credentials, serverID: serverID)
    XCTAssertEqual(vault.mode, .ephemeralSimulator)
    XCTAssertEqual(try vault.read(serverID: serverID), credentials)
    try vault.delete(serverID: serverID)
    XCTAssertNil(try vault.read(serverID: serverID))
  }

  func testSimulatorVaultDoesNotFallbackWhenDisabled() {
    let vault = SimulatorFallbackCredentialVault(
      primary: MissingEntitlementCredentialVault(), allowsFallback: false)
    XCTAssertThrowsError(try vault.read(serverID: UUID())) { error in
      XCTAssertEqual(error as? MusicSourceError, .keychainFailure(-34_018))
    }
    XCTAssertEqual(vault.mode, .keychain)
  }

  func testCarPlayContentPolicyRespectsDrivingGlanceLimits() {
    let providerID = UUID()
    let track = MusicTrack(
      identity: .init(providerID: providerID, remoteID: "carplay-track", sourceType: .local),
      albumRemoteID: "album", artistRemoteID: "artist", title: "CarPlay Test",
      artistName: "Artist", albumTitle: "Album", discNumber: 1, trackNumber: 1,
      duration: 180, artworkURL: nil, lyrics: nil, isExplicit: false,
      favoriteState: .notFavorite, contentType: "audio/mpeg", suffix: "mp3", bitRate: 320,
      metadata: [:])
    let sections = (0..<5).map { index in
      MusicSection(
        id: "section-\(index)", title: "Section \(index)", kind: .recentlyPlayed,
        items: Array(repeating: MusicSectionItem.track(track), count: 6))
    }

    let curated = CarPlayContentPolicy.curatedHomeSections(
      sections, maximumSectionCount: 2, maximumItemCount: 7)

    XCTAssertEqual(curated.count, 2)
    XCTAssertEqual(curated.map(\.items.count), [4, 3])
    XCTAssertEqual(curated.flatMap(\.items).count, 7)
  }

  private func makeTrack(providerID: UUID, sourceType: MusicSourceType) -> MusicTrack {
    .init(
      identity: .init(providerID: providerID, remoteID: "track-1", sourceType: sourceType),
      albumRemoteID: "album-1", artistRemoteID: "artist-1", title: "Song", artistName: "Artist",
      albumTitle: "Album", discNumber: 1, trackNumber: 1, duration: 180, artworkURL: nil,
      lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/flac",
      suffix: "flac", bitRate: 900, metadata: [:])
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderStubURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func makeSilentWAV() -> Data {
    let sampleRate: UInt32 = 8_000
    let payloadSize = sampleRate * 2
    var data = Data()
    func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
    func little16(_ value: UInt16) {
      var value = value.littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    func little32(_ value: UInt32) {
      var value = value.littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    ascii("RIFF")
    little32(36 + payloadSize)
    ascii("WAVEfmt ")
    little32(16)
    little16(1)
    little16(1)
    little32(sampleRate)
    little32(sampleRate * 2)
    little16(2)
    little16(16)
    ascii("data")
    little32(payloadSize)
    data.append(Data(repeating: 0, count: Int(payloadSize)))
    return data
  }

}

private actor LiveMediaStreamProbe {
  private var statusCode = 0
  private var byteCount = 0

  func record(metadata: MusicMediaResponseMetadata) { statusCode = metadata.statusCode }
  func record(data: Data) { byteCount += data.count }
  func result() -> (statusCode: Int, byteCount: Int) { (statusCode, byteCount) }
}

private final class SendableBox<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}

private final class ThreadRecordingServerRepository: ServerRepository, @unchecked Sendable {
  private let lock = NSLock()
  private let delay: TimeInterval
  private var _loadedOnMainThread: Bool?

  init(delay: TimeInterval) { self.delay = delay }

  var loadedOnMainThread: Bool? { lock.withLock { _loadedOnMainThread } }

  func load() throws -> StoredServerState {
    lock.withLock { _loadedOnMainThread = Thread.isMainThread }
    Thread.sleep(forTimeInterval: delay)
    return .empty
  }

  func save(_: StoredServerState) throws {}
}

private struct FailingServerRepository: ServerRepository {
  struct ExpectedFailure: Error {}
  func load() throws -> StoredServerState { throw ExpectedFailure() }
  func save(_: StoredServerState) throws {}
}

private struct MissingEntitlementCredentialVault: CredentialVault {
  func save(_ credentials: ProviderCredentials, serverID: UUID) throws {
    throw MusicSourceError.keychainFailure(-34_018)
  }
  func read(serverID: UUID) throws -> ProviderCredentials? {
    throw MusicSourceError.keychainFailure(-34_018)
  }
  func delete(serverID: UUID) throws { throw MusicSourceError.keychainFailure(-34_018) }
}

private actor SequencedCatalogService: MusicCatalogServing {
  private var values: [MusicCatalog]
  private var requests = 0

  init(values: [MusicCatalog]) { self.values = values }

  func fetchCatalog() async throws -> MusicCatalog {
    let index = min(requests, max(0, values.count - 1))
    requests += 1
    return values[index]
  }

  func fetchPlaybackURL(
    for trackID: UUID, encoding: MusicPlaybackEncoding?
  ) async throws -> URL {
    URL(string: "https://nas.example/audio/\(trackID.uuidString)")!
  }

  func requestCount() -> Int { requests }
}

private final class ProviderStubURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []
  static func reset() { lock.withLock { recordedRequests.removeAll() } }
  static func requests() -> [URLRequest] { lock.withLock { recordedRequests } }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.withLock { Self.recordedRequests.append(request) }
    let path = request.url?.path ?? ""
    let body: String
    if path.contains("AuthenticateByName") {
      body = #"{"User":{"Id":"user-1"},"AccessToken":"access-token"}"#
    } else if path.contains("System/Info") {
      body = #"{"ServerName":"Jellyfin Test","Version":"10.10.0"}"#
    } else if path.contains("getAlbumList2") {
      body =
        #"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[{"id":"album-1","name":"Parsed Album","artist":"Artist","songCount":1}]}}}"#
    } else if path.contains("getMusicFolders") {
      body =
        #"{"subsonic-response":{"status":"ok","version":"1.16.1","musicFolders":{"musicFolder":[{"id":1,"name":"Main Music"}]}}}"#
    } else if path.contains("getAlbum.view") {
      body =
        #"{"subsonic-response":{"status":"ok","version":"1.16.1","album":{"id":"album-1","name":"Parsed Album","artist":"Artist","songCount":1,"song":[{"id":"track-album","title":"Album Song","artist":"Artist","album":"Parsed Album","albumId":"album-1","duration":200}]}}}"#
    } else if path.contains("search3") {
      body =
        #"{"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{"song":[{"id":"track-1","title":"Parsed Song","artist":"Artist","album":"Parsed Album","duration":180}]}}}"#
    } else if path.contains("getLyricsBySongId") {
      body =
        #"{"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[{"displayArtist":"Artist","displayTitle":"Album Song","lang":"en","synced":true,"line":[{"start":1500,"value":"Timed line"}]}]}}}"#
    } else if path.contains("getStarred2") {
      body =
        #"{"subsonic-response":{"status":"ok","version":"1.16.1","starred2":{"song":[{"id":"favorite-1","title":"Favorite Song","artist":"Artist","duration":180,"starred":"2026-01-01T00:00:00Z"}]}}}"#
    } else if path.contains("createPlaylist") {
      body =
        #"{"subsonic-response":{"status":"ok","version":"1.16.1","playlist":{"id":"playlist-1","name":"Mix","songCount":2}}}"#
    } else if path.contains("/Users/user-1/Views") {
      body =
        #"{"Items":[{"Id":"library-1","Name":"Music","Type":"CollectionFolder","CollectionType":"music"}]}"#
    } else if path.contains("/Artists/AlbumArtists") {
      body =
        #"{"Items":[{"Id":"artist-1","Name":"Artist","Type":"MusicArtist","ChildCount":1}]}"#
    } else if path.contains("/Users/user-1/Items") {
      body =
        #"{"Items":[{"Id":"track-1","Name":"Jellyfin Song","Type":"Audio","Artists":["Artist"],"Album":"Album","RunTimeTicks":1800000000}]}"#
    } else {
      body = #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private final class FlakyReadURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var attemptCount = 0
  nonisolated(unsafe) private static var failureCode = URLError.Code.networkConnectionLost
  static func reset(failure: URLError.Code = .networkConnectionLost) {
    lock.withLock {
      attemptCount = 0
      failureCode = failure
    }
  }
  static func attempts() -> Int { lock.withLock { attemptCount } }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let (attempt, failure) = Self.lock.withLock {
      Self.attemptCount += 1
      return (Self.attemptCount, Self.failureCode)
    }
    if attempt == 1 {
      client?.urlProtocol(self, didFailWithError: URLError(failure))
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "text/plain"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("stable".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
