import Foundation

protocol OnlineLyricsFetching: Sendable {
  func fetchLyrics(for track: MusicTrack) async throws -> MusicLyrics?
}

actor OnlineLyricsService: OnlineLyricsFetching {
  static let shared = OnlineLyricsService()

  private let session: URLSession
  private let cache: MusicCache
  private let lrclibBaseURL: URL
  private let chineseLyricsBaseURL: URL
  private var lrclibBlockedUntil: Date?

  init(
    session: URLSession = OnlineLyricsService.makeSession(),
    cache: MusicCache = .shared,
    lrclibBaseURL: URL = URL(string: "https://lrclib.net/api/get")!,
    chineseLyricsBaseURL: URL = URL(string: "https://api.lrc.cx/lyrics")!
  ) {
    self.session = session
    self.cache = cache
    self.lrclibBaseURL = lrclibBaseURL
    self.chineseLyricsBaseURL = chineseLyricsBaseURL
  }

  func fetchLyrics(for track: MusicTrack) async throws -> MusicLyrics? {
    let cacheKey = [
      "online-lyrics-v2", track.identity.remoteID, track.title, track.artistName,
      track.albumTitle ?? "", String(Int(track.duration.rounded())),
    ].joined(separator: "|")
    if let cached = try? await cache.load(
      MusicLyrics.self, serverID: track.identity.providerID, namespace: .lyrics, key: cacheKey),
      let sanitized = LyricsQuality.sanitized(cached)
    {
      return sanitized
    }

    var lyrics: MusicLyrics?
    do {
      lyrics = try await fetchFromLRCLIB(for: track)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      lyrics = nil
    }
    if lyrics == nil {
      do {
        lyrics = try await fetchFromChineseSource(for: track)
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as URLError where error.code == .cancelled {
        throw CancellationError()
      } catch {
        lyrics = nil
      }
    }

    lyrics = lyrics.flatMap(LyricsQuality.sanitized)
    if let lyrics {
      try? await cache.storeLyrics(
        lyrics, serverID: track.identity.providerID, key: cacheKey,
        owner: MusicResourceOwner.track(track.identity.remoteID))
    }
    return lyrics
  }

  private func fetchFromLRCLIB(for track: MusicTrack) async throws -> MusicLyrics? {
    if let lrclibBlockedUntil, lrclibBlockedUntil > Date() { return nil }
    guard
      var components = URLComponents(
        url: lrclibBaseURL, resolvingAgainstBaseURL: false)
    else { return nil }
    components.queryItems = [
      URLQueryItem(name: "track_name", value: track.title),
      URLQueryItem(name: "artist_name", value: track.artistName),
      URLQueryItem(name: "album_name", value: track.albumTitle ?? ""),
      URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
    ]
    guard let url = components.url else { return nil }
    let (data, response) = try await session.data(for: request(url))
    guard let http = response as? HTTPURLResponse else { return nil }
    if http.statusCode == 429 {
      let delay = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
      lrclibBlockedUntil = Date().addingTimeInterval(max(1, delay))
      return nil
    }
    guard http.statusCode == 200, data.count <= 1_048_576 else { return nil }
    let value = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
    guard value.instrumental != true else { return nil }
    return makeLyrics(
      synced: value.syncedLyrics, plain: value.plainLyrics,
      artist: value.artistName ?? track.artistName, title: value.trackName ?? track.title)
  }

  private func fetchFromChineseSource(for track: MusicTrack) async throws -> MusicLyrics? {
    guard
      var components = URLComponents(
        url: chineseLyricsBaseURL, resolvingAgainstBaseURL: false)
    else { return nil }
    components.queryItems = [
      URLQueryItem(name: "title", value: track.title),
      URLQueryItem(name: "artist", value: track.artistName),
      URLQueryItem(name: "album", value: track.albumTitle ?? ""),
    ]
    guard let url = components.url else { return nil }
    let (data, response) = try await session.data(for: request(url))
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      data.count <= 1_048_576, let raw = String(data: data, encoding: .utf8)
    else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("{") else { return nil }
    return makeLyrics(
      synced: trimmed, plain: nil, artist: track.artistName, title: track.title)
  }

  private func request(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.setValue(
      "SanshuaiPlayer/4.3.1 (iOS; https://github.com/xiaosongji/SanshuaiPlayer)",
      forHTTPHeaderField: "User-Agent")
    request.setValue("text/plain, application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private func makeLyrics(
    synced: String?, plain: String?, artist: String?, title: String?
  ) -> MusicLyrics? {
    if let synced {
      let lines = Self.parseLRC(synced)
      if lines.contains(where: { $0.time != nil }) {
        return MusicLyrics(
          displayArtist: artist, displayTitle: title, language: nil, lines: lines,
          isSynced: true)
      }
    }
    let text = plain ?? synced
    guard let text else { return nil }
    let lines = Self.plainLines(text)
    guard !lines.isEmpty else { return nil }
    return MusicLyrics(
      displayArtist: artist, displayTitle: title, language: nil, lines: lines,
      isSynced: false)
  }

  nonisolated static func parseLRC(_ source: String) -> [MusicLyrics.Line] {
    let expression = try! NSRegularExpression(
      pattern: #"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]"#)
    var offset: TimeInterval = 0
    var result: [(order: Int, line: MusicLyrics.Line)] = []
    var order = 0
    for rawLine in source.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.lowercased().hasPrefix("[offset:"),
        let end = line.firstIndex(of: "]"),
        let milliseconds = Double(line[line.index(line.startIndex, offsetBy: 8)..<end])
      {
        offset = milliseconds / 1_000
        continue
      }
      let range = NSRange(line.startIndex..<line.endIndex, in: line)
      let matches = expression.matches(in: line, range: range)
      guard !matches.isEmpty else { continue }
      let finalMatch = matches[matches.count - 1]
      let textStart = Range(finalMatch.range, in: line)!.upperBound
      let text = String(line[textStart...]).trimmingCharacters(in: .whitespaces)
      for match in matches {
        guard
          let minuteRange = Range(match.range(at: 1), in: line),
          let secondRange = Range(match.range(at: 2), in: line),
          let minutes = Double(line[minuteRange]), let seconds = Double(line[secondRange])
        else { continue }
        result.append(
          (
            order: order,
            line: MusicLyrics.Line(
              time: max(0, minutes * 60 + seconds + offset), text: text)
          ))
        order += 1
      }
    }
    return result.sorted {
      if $0.line.time == $1.line.time { return $0.order < $1.order }
      return ($0.line.time ?? 0) < ($1.line.time ?? 0)
    }.map(\.line)
  }

  nonisolated static func plainLines(_ source: String) -> [MusicLyrics.Line] {
    source.components(separatedBy: .newlines).compactMap { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { return nil }
      let lower = line.lowercased()
      let isMetadata = ["[ar:", "[ti:", "[al:", "[by:", "[offset:"].contains {
        lower.hasPrefix($0)
      }
      guard !isMetadata else { return nil }
      return MusicLyrics.Line(time: nil, text: line)
    }
  }

  private nonisolated static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 12
    return URLSession(configuration: configuration)
  }
}

enum LyricsQuality {
  static func isSynchronized(_ lyrics: MusicLyrics) -> Bool {
    lyrics.isSynced && lyrics.lines.contains { $0.time != nil }
  }

  static func sanitized(_ lyrics: MusicLyrics) -> MusicLyrics? {
    let original = lyrics.lines.filter {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !original.isEmpty else { return nil }
    let retained = original.filter { !isAdvertisementLine($0.text) }
    let adCount = original.count - retained.count
    let likelyAdvertisement =
      adCount >= 2 || (original.count <= 6 && adCount >= 1)
      || original.contains { containsWebAddress($0.text) }
    guard !retained.isEmpty, !(likelyAdvertisement && retained.count < 4) else { return nil }
    return MusicLyrics(
      displayArtist: lyrics.displayArtist, displayTitle: lyrics.displayTitle,
      language: lyrics.language, lines: retained,
      isSynced: lyrics.isSynced && retained.contains { $0.time != nil })
  }

  private static func isAdvertisementLine(_ value: String) -> Bool {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if containsWebAddress(text) { return true }
    let phrases = [
      "音乐下载", "歌曲下载", "无损音乐", "高品质音乐", "下载站", "本站", "资源分享",
      "关注公众号", "微信公众号", "搜索公众号", "qq群", "加群", "上传者", "由本站提供",
      "本歌词来自", "本歌曲来自", "更多好歌", "尽在",
    ]
    return phrases.contains { text.contains($0) }
  }

  private static func containsWebAddress(_ value: String) -> Bool {
    let text = value.lowercased()
    if text.contains("http://") || text.contains("https://") || text.contains("www.") {
      return true
    }
    return text.range(
      of: #"\b[a-z0-9][a-z0-9.-]*\.(com|cn|net|org|cc|tv|top)\b"#,
      options: .regularExpression) != nil
  }
}

enum ExternalArtworkFallback {
  private static let endpoint = URL(string: "https://api.lrc.cx/cover")!

  static func url(for item: MusicArtworkItem) -> URL? {
    let title: String?
    let album: String?
    let artist: String?
    switch item {
    case .track(let value):
      title = cleanedMetadata(value.title)
      album = value.albumTitle.flatMap(cleanedMetadata)
      artist = cleanedMetadata(value.artistName)
    case .album(let value):
      title = nil
      album = cleanedMetadata(value.title)
      artist = cleanedMetadata(value.artistName)
    case .artist(let value):
      title = nil
      album = nil
      artist = cleanedMetadata(value.name)
    case .playlist:
      return nil
    }
    guard title != nil || album != nil || artist != nil else { return nil }
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    else { return nil }
    components.queryItems = [
      title.map { URLQueryItem(name: "title", value: $0) },
      album.map { URLQueryItem(name: "album", value: $0) },
      artist.map { URLQueryItem(name: "artist", value: $0) },
    ].compactMap { $0 }
    return components.url
  }

  private static func cleanedMetadata(_ value: String) -> String? {
    var result = value.replacingOccurrences(
      of: #"【[^】]*(?:www\.|https?://|下载|无损音乐|打包资源)[^】]*】"#,
      with: "", options: [.regularExpression, .caseInsensitive])
    result = result.replacingOccurrences(
      of: #"\[[^\]]*(?:www\.|https?://|下载|无损音乐|打包资源)[^\]]*\]"#,
      with: "", options: [.regularExpression, .caseInsensitive])
    let markers = [
      "更多打包", "打包下载", "打包资源", "音乐下载", "歌曲下载", "下载站", "无损音乐",
      "www.", "http://", "https://",
    ]
    if let boundary = markers.compactMap({
      result.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound
    }).min() {
      result = String(result[..<boundary])
    }
    result = result.trimmingCharacters(
      in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—_|/·:：")))
    return result.isEmpty ? nil : result
  }
}

enum ArtworkURLFallback {
  private static let fragmentPrefix = "external-artwork-v1:"

  static func attaching(_ fallback: URL, to primary: URL) -> URL {
    let cleanPrimary = sources(from: primary).primary
    guard var components = URLComponents(url: cleanPrimary, resolvingAgainstBaseURL: false)
    else { return cleanPrimary }
    let token = Data(fallback.absoluteString.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    components.fragment = fragmentPrefix + token
    return components.url ?? cleanPrimary
  }

  static func sources(from value: URL) -> (primary: URL, fallback: URL?) {
    guard var components = URLComponents(url: value, resolvingAgainstBaseURL: false) else {
      return (value, nil)
    }
    let fragment = components.fragment
    components.fragment = nil
    let primary = components.url ?? value
    guard let fragment, fragment.hasPrefix(fragmentPrefix) else {
      return (primary, nil)
    }
    var token = String(fragment.dropFirst(fragmentPrefix.count))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - token.count % 4) % 4
    token += String(repeating: "=", count: padding)
    guard let data = Data(base64Encoded: token),
      let text = String(data: data, encoding: .utf8),
      let fallback = URL(string: text)
    else { return (primary, nil) }
    return (primary, fallback)
  }
}

private struct LRCLIBResponse: Decodable {
  let trackName: String?
  let artistName: String?
  let instrumental: Bool?
  let plainLyrics: String?
  let syncedLyrics: String?
}
