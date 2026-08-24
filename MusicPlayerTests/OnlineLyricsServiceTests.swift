import Foundation
import XCTest

@testable import MusicPlayer

final class OnlineLyricsServiceTests: XCTestCase {
  func testLRCLIBSyncedLyricsAreParsedAndPreferred() async throws {
    LyricsStubURLProtocol.reset()
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = OnlineLyricsService(
      session: makeSession(), cache: MusicCache(rootURL: root),
      lrclibBaseURL: URL(string: "https://lyrics.test/lrclib")!,
      chineseLyricsBaseURL: URL(string: "https://lyrics.test/chinese")!)

    let value = try await service.fetchLyrics(for: makeTrack())

    XCTAssertEqual(value?.isSynced, true)
    XCTAssertEqual(value?.lines.map(\.text), ["第一句", "第二句"])
    XCTAssertEqual(value?.lines.map(\.time), [1.5, 12])
    XCTAssertEqual(LyricsStubURLProtocol.paths(), ["/lrclib"])
  }

  func testChineseSourceIsUsedWhenLRCLIBHasNoMatch() async throws {
    LyricsStubURLProtocol.reset()
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = OnlineLyricsService(
      session: makeSession(), cache: MusicCache(rootURL: root),
      lrclibBaseURL: URL(string: "https://lyrics.test/missing")!,
      chineseLyricsBaseURL: URL(string: "https://lyrics.test/chinese")!)

    let value = try await service.fetchLyrics(for: makeTrack())

    XCTAssertEqual(value?.isSynced, true)
    XCTAssertEqual(value?.lines.first?.text, "中文回退")
    XCTAssertEqual(LyricsStubURLProtocol.paths(), ["/missing", "/chinese"])
  }

  func testLRCParserHandlesOffsetAndMultipleTimestamps() {
    let lines = OnlineLyricsService.parseLRC(
      """
      [offset:500]
      [00:01.00][00:02.25]重复
      [ar:Artist]
      """)

    XCTAssertEqual(lines.map(\.text), ["重复", "重复"])
    XCTAssertEqual(lines.map(\.time), [1.5, 2.75])
  }

  func testAdvertisementOnlyLyricsAreRejected() {
    let value = MusicLyrics(
      displayArtist: nil, displayTitle: nil, language: nil,
      lines: [
        .init(time: nil, text: "更多无损音乐请访问 www.example.com"),
        .init(time: nil, text: "关注微信公众号获取下载地址"),
      ], isSynced: false)

    XCTAssertNil(LyricsQuality.sanitized(value))
  }

  @MainActor
  func testDownloadedLyricsWinOverUnsyncedEmbeddedText() async throws {
    var track = makeTrack()
    track.lyrics = "这是普通歌词\n没有时间轴\n但不是广告\n继续一行\n再继续一行"
    let provider = MockMusicSourceProvider(
      id: track.identity.providerID, tracks: [track], lyricsAreSynced: false)
    let downloaded = MusicLyrics(
      displayArtist: track.artistName, displayTitle: track.title, language: "zh",
      lines: [.init(time: 3, text: "在线同步歌词")], isSynced: true)
    let online = LyricsFetcherStub(result: downloaded)
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let library = UnifiedLibraryStore(
      provider: provider, cache: MusicCache(rootURL: temporary), onlineLyrics: online)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let value = try await library.lyrics(for: track)

    XCTAssertEqual(value?.lines.first?.text, "在线同步歌词")
    let requests = await online.requestCount
    XCTAssertEqual(requests, 1)
  }

  @MainActor
  func testSyncedServerLyricsRemainHighestPriority() async throws {
    var track = makeTrack()
    track.lyrics = "服务端同步歌词"
    let provider = MockMusicSourceProvider(id: track.identity.providerID, tracks: [track])
    let online = LyricsFetcherStub(
      result: MusicLyrics(
        displayArtist: nil, displayTitle: nil, language: nil,
        lines: [.init(time: 1, text: "不应使用")], isSynced: true))
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let library = UnifiedLibraryStore(
      provider: provider, cache: MusicCache(rootURL: temporary), onlineLyrics: online)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let value = try await library.lyrics(for: track)

    XCTAssertEqual(value?.lines.first?.text, "服务端同步歌词")
    let requests = await online.requestCount
    XCTAssertEqual(requests, 0)
  }

  @MainActor
  func testResolvedServerLyricsAreReadFromDiskBeforeAnotherNASRequest() async throws {
    var track = makeTrack()
    track.lyrics = "服务端歌词"
    let provider = MockMusicSourceProvider(id: track.identity.providerID, tracks: [track])
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = MusicCache(
      rootURL: temporary.appending(path: "Caches"),
      persistentRootURL: temporary.appending(path: "ApplicationSupport"))
    let library = UnifiedLibraryStore(provider: provider, cache: cache)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let first = try await library.lyrics(for: track)
    let second = try await library.lyrics(for: track)
    let requestCount = await provider.requestedLyricsCount()

    XCTAssertEqual(first, second)
    XCTAssertEqual(requestCount, 1)
  }

  @MainActor
  func testMissingArtworkGetsExternalFallbackURL() async {
    let track = makeTrack()
    let provider = MockMusicSourceProvider(id: track.identity.providerID, tracks: [track])
    let library = UnifiedLibraryStore(provider: provider)

    await library.refresh()

    let url = library.tracks.first?.artworkURL
    XCTAssertEqual(url?.host, "api.lrc.cx")
    XCTAssertEqual(url?.path, "/cover")
    let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertTrue(items.contains(URLQueryItem(name: "title", value: "歌曲")))
    XCTAssertTrue(items.contains(URLQueryItem(name: "artist", value: "歌手")))
  }

  func testArtworkFallbackCleansDownloadSiteMetadata() {
    var track = makeTrack()
    track.artistName = "刘若英更多打包下载--熊猫无损音乐 www.xmwav.com"
    track.albumTitle = "【熊猫无损音乐www.xmwav.net】更多打包资源下载"

    let url = ExternalArtworkFallback.url(for: .track(track))
    let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []

    XCTAssertTrue(items.contains(URLQueryItem(name: "title", value: "歌曲")))
    XCTAssertTrue(items.contains(URLQueryItem(name: "artist", value: "刘若英")))
    XCTAssertFalse(items.contains { $0.name == "album" })
    XCTAssertFalse(url!.absoluteString.localizedCaseInsensitiveContains("xmwav"))
  }

  func testPrimaryArtworkCarriesRecoverableExternalFallback() {
    let primary = URL(string: "https://music.example/rest/getCoverArt?id=album")!
    let fallback = URL(string: "https://api.lrc.cx/cover?title=歌曲&artist=歌手")!

    let combined = ArtworkURLFallback.attaching(fallback, to: primary)
    let sources = ArtworkURLFallback.sources(from: combined)

    XCTAssertEqual(sources.primary, primary)
    XCTAssertEqual(sources.fallback, fallback)
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LyricsStubURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func makeTrack() -> MusicTrack {
    let providerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    return MusicTrack(
      identity: .init(
        providerID: providerID, remoteID: "lyrics-track", sourceType: .openSubsonic),
      albumRemoteID: "album", artistRemoteID: "artist", title: "歌曲", artistName: "歌手",
      albumTitle: "专辑", discNumber: 1, trackNumber: 1, duration: 180, artworkURL: nil,
      lyrics: nil, isExplicit: false, favoriteState: .notFavorite, contentType: "audio/flac",
      suffix: "flac", bitRate: 900, metadata: [:])
  }
}

private actor LyricsFetcherStub: OnlineLyricsFetching {
  private(set) var requestCount = 0
  let result: MusicLyrics?

  init(result: MusicLyrics?) {
    self.result = result
  }

  func fetchLyrics(for track: MusicTrack) async throws -> MusicLyrics? {
    requestCount += 1
    return result
  }
}

private final class LyricsStubURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requestedPaths: [String] = []

  static func reset() { lock.withLock { requestedPaths.removeAll() } }
  static func paths() -> [String] { lock.withLock { requestedPaths } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let path = request.url?.path ?? ""
    Self.lock.withLock { Self.requestedPaths.append(path) }
    let statusCode: Int
    let contentType: String
    let body: String
    switch path {
    case "/lrclib":
      statusCode = 200
      contentType = "application/json"
      body =
        #"{"trackName":"歌曲","artistName":"歌手","instrumental":false,"plainLyrics":"第一句\n第二句","syncedLyrics":"[00:01.50]第一句\n[00:12.00]第二句"}"#
    case "/chinese":
      statusCode = 200
      contentType = "text/plain"
      body = "[00:03.00]中文回退"
    default:
      statusCode = 404
      contentType = "application/json"
      body = #"{"code":404}"#
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": contentType])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
