import Foundation
import OSLog
import SwiftUI
#if DEBUG
  import UIKit
#endif

/// Owns the app-wide runtime — the source store plus the library and player for the active
/// server — so it belongs to the app rather than to any one scene. CarPlay is frequently the
/// only connected scene (the car launches the app while the phone stays locked), in which case
/// SwiftUI never builds a window and nothing else would create a player.
@MainActor
final class MusicRuntimeCoordinator {
  static let shared = MusicRuntimeCoordinator()

  let sourceStore: MusicSourceStore

  private var restoreTask: Task<Void, Never>?
  private var activeProvider: (any MusicSourceProvider)?
  private var activeContext: CarPlayRuntimeContext?

  init(sourceStore: MusicSourceStore = MusicSourceStore()) {
    self.sourceStore = sourceStore
  }

  /// Restores the persisted sources once, however many scenes ask for it.
  func restoreIfNeeded() async {
    if let restoreTask {
      await restoreTask.value
      return
    }
    let task = Task { [sourceStore] in await sourceStore.restore() }
    restoreTask = task
    await task.value
  }

  /// The library and player for a server, created once and shared by every scene so the phone
  /// UI and CarPlay always drive the same playback controller.
  @discardableResult
  func runtime(
    for server: MusicServer, provider: any MusicSourceProvider
  ) -> CarPlayRuntimeContext {
    if let activeContext, activeContext.serverID == server.id,
      let activeProvider, activeProvider as AnyObject === provider as AnyObject
    {
      return activeContext
    }
    let serverID = server.id
    let artworkFetcher = MusicArtworkFetcher { url in
      try await provider.loadMediaResource(at: url, range: nil).data
    }
    let library = UnifiedLibraryStore(provider: provider) { [weak sourceStore] error in
      sourceStore?.recordConnectionResult(serverID: serverID, error: error)
    }
    let context = CarPlayRuntimeContext(
      library: library,
      playback: UnifiedPlaybackController(provider: provider, wifiQuality: server.wifiQuality),
      serverID: serverID,
      artworkFetcher: artworkFetcher)
    activeProvider = provider
    activeContext = context
    // Published before the library loads: CarPlay waits only a few seconds for a runtime, and a
    // cold full-library refresh takes far longer than that.
    CarPlayRuntimeRegistry.shared.register(context)
    return context
  }

  /// Builds the runtime from what CarPlay can reach on its own, then warms the library so the
  /// templates have something to show.
  func prepareRuntimeIfPossible() async {
    if CarPlayRuntimeRegistry.shared.context == nil {
      await restoreIfNeeded()
      guard sourceStore.hasReliableActiveSource, let provider = sourceStore.provider,
        let server = sourceStore.activeServer
      else { return }
      runtime(for: server, provider: provider)
    }
    guard let context = CarPlayRuntimeRegistry.shared.context else { return }
    await context.library.loadIfNeeded()
    CarPlayRuntimeRegistry.shared.notifyRuntimeDidChange()
  }
}

@main
struct MusicPlayerApp: App {
  @State private var sourceStore = MusicRuntimeCoordinator.shared.sourceStore

  init() {
    StartupTrace.mark("app.init")
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-visual-audit-home")
          || ProcessInfo.processInfo.arguments.contains("-visual-audit-settings")
        {
          VisualAuditHomeRoot()
        } else if ProcessInfo.processInfo.arguments.contains("-visual-audit-player") {
          VisualAuditPlayerRoot()
        } else if ProcessInfo.processInfo.arguments.contains("-visual-audit-library")
          || ProcessInfo.processInfo.arguments.contains("-visual-audit-favorites")
        {
          VisualAuditLibraryRoot()
        } else {
          RootView().environment(sourceStore)
        }
      #else
        RootView().environment(sourceStore)
      #endif
    }
  }
}

#if DEBUG
  private struct VisualAuditHomeRoot: View {
    @State private var sourceStore = MusicSourceStore(
      repository: InMemoryServerRepository(), vault: InMemoryCredentialVault())
    @State private var library: UnifiedLibraryStore
    @State private var playback: UnifiedPlaybackController
    private let providerID: UUID
    private let artworkFetcher: MusicArtworkFetcher
    private let previewTrack: MusicTrack

    init() {
      let providerID = UUID(uuidString: "D62C18AF-7EA7-482F-98B7-E34428401C38")!
      let usesEnglish = Locale.preferredLanguages.first?.hasPrefix("en") == true
      let artistNames = usesEnglish
        ? ["Forest Radio", "Midnight Route", "North Shore", "Softlight", "Mist Theater", "Field Notes"]
        : ["林间电台", "午夜航线", "北岸来信", "微光旅人", "雾中剧场", "拾音计划"]
      let artistURLs = artistNames.indices.map {
        URL(string: "https://mock.invalid/artwork/artist-cover-\($0)")!
      }
      let artists = artistNames.indices.map { index in
        MusicArtist(
          identity: .init(
            providerID: providerID, remoteID: "artist-\(index)", sourceType: .local),
          name: artistNames[index], biography: nil, artworkURL: artistURLs[index], albumCount: 3,
          favoriteState: index < 2 ? .favorite : .notFavorite, metadata: [:])
      }
      let albumTitles = usesEnglish
        ? [
          "North of Clouds", "Backlit Echo", "Weightless Walk", "Tidal Letters", "Night Screening", "Glass Coast",
          "Long Dusk", "Field Radio", "Old Starlight", "City Drift", "Quiet Highway", "Daylight Signal",
          "Four A.M.", "Distant Hills", "Neon After Rain", "Summer Tape", "The Mist Stage", "Morning Index",
        ]
        : [
          "云层以北", "逆光留声", "失重散步", "潮汐来信", "夜色放映厅", "玻璃海岸",
          "漫长黄昏", "野外收音机", "星河旧梦", "城市漂流", "静默公路", "白日信号",
          "凌晨四点", "远山回声", "雨后霓虹", "夏夜磁带", "迷雾剧场", "晨光目录",
        ]
      let albumURLs = albumTitles.indices.map {
        URL(string: "https://mock.invalid/artwork/album-cover-\($0)")!
      }
      let albums = albumTitles.indices.map { index in
        MusicAlbum(
          identity: .init(
            providerID: providerID, remoteID: "album-\(index)", sourceType: .local),
          artistID: "artist-\(index % artistNames.count)", title: albumTitles[index],
          artistName: artistNames[index % artistNames.count],
          releaseDate: Calendar.current.date(byAdding: .day, value: -index * 13, to: .now),
          year: 2026 - index % 5, artworkURL: albumURLs[index], genreNames: ["独立流行"],
          trackCount: 1, duration: 218, favoriteState: index < 4 ? .favorite : .notFavorite,
          metadata: [:])
      }
      let tracks = albumTitles.indices.map { index in
        MusicTrack(
          identity: .init(
            providerID: providerID, remoteID: "track-\(index)", sourceType: .local),
          albumRemoteID: "album-\(index)", artistRemoteID: "artist-\(index % artistNames.count)",
          title: usesEnglish ? "\(albumTitles[index]) · Prelude" : "\(albumTitles[index]) · 序曲",
          artistName: artistNames[index % artistNames.count],
          albumTitle: albumTitles[index], discNumber: 1, trackNumber: 1, duration: 218,
          artworkURL: albumURLs[index], lyrics: nil, isExplicit: false,
          favoriteState: index < 4 ? .favorite : .notFavorite, contentType: "audio/wav",
          suffix: "wav", bitRate: 705, metadata: [:])
      }
      let home = MusicSection(
        id: "visual-home", title: usesEnglish ? "Floating for You" : "为你漂浮", kind: .recentlyPlayed,
        items: albums.map(MusicSectionItem.album))
      var artworkData: [String: Data] = [:]
      for index in albumTitles.indices {
        artworkData["album-cover-\(index)"] = makeHomeAuditCover(
          index: index, title: albumTitles[index], isArtist: false)
      }
      for index in artistNames.indices {
        artworkData["artist-cover-\(index)"] = makeHomeAuditCover(
          index: index + albumTitles.count, title: artistNames[index], isArtist: true)
      }
      let provider = MockMusicSourceProvider(
        id: providerID, sourceType: .local, home: [home], artists: artists, albums: albums,
        tracks: tracks, mediaDataByRemoteID: artworkData, mediaMimeType: "image/jpeg")
      self.providerID = providerID
      previewTrack = tracks[0]
      artworkFetcher = MusicArtworkFetcher { url in
        try await provider.loadMediaResource(at: url, range: nil).data
      }
      _library = State(
        initialValue: UnifiedLibraryStore(provider: provider, automaticRefreshInterval: 0))
      _playback = State(
        initialValue: UnifiedPlaybackController(
          provider: provider, wifiQuality: .original))
    }

    var body: some View {
      UniversalAppView()
        .environment(sourceStore)
        .environment(library)
        .environment(playback)
        .environment(\.musicServerID, providerID)
        .environment(\.musicArtworkFetcher, artworkFetcher)
        .task {
          await library.loadIfNeeded()
          playback.loadVisualAuditTrack(previewTrack, at: 42)
          CarPlayRuntimeRegistry.shared.register(
            library: library, playback: playback, serverID: providerID,
            artworkFetcher: artworkFetcher)
        }
        .onDisappear { CarPlayRuntimeRegistry.shared.unregister(playback: playback) }
    }
  }

  private func makeHomeAuditCover(index: Int, title: String, isArtist: Bool) -> Data {
    let palettes: [(UIColor, UIColor, UIColor)] = [
      (.systemIndigo, .systemPink, .systemOrange),
      (.systemTeal, .systemBlue, .systemPurple),
      (.systemRed, .systemOrange, .systemYellow),
      (.systemPurple, .systemIndigo, .systemCyan),
      (.systemGreen, .systemTeal, .systemBlue),
      (.systemPink, .systemPurple, .systemIndigo),
    ]
    let palette = palettes[index % palettes.count]
    let size = CGSize(width: 560, height: 560)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { renderContext in
      let context = renderContext.cgContext
      let colors = [palette.0.cgColor, palette.1.cgColor, palette.2.cgColor] as CFArray
      let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
        locations: [0, 0.56, 1])!
      context.drawLinearGradient(
        gradient, start: CGPoint(x: 30, y: 0), end: CGPoint(x: 530, y: 560), options: [])
      context.setBlendMode(.screen)
      context.setStrokeColor(UIColor.white.withAlphaComponent(0.36).cgColor)
      context.setLineWidth(isArtist ? 28 : 12)
      let inset = CGFloat(42 + (index % 4) * 19)
      context.strokeEllipse(in: CGRect(x: inset, y: inset, width: 560 - inset * 2, height: 560 - inset * 2))
      context.setFillColor(UIColor.black.withAlphaComponent(0.18).cgColor)
      context.fill(
        CGRect(
          x: CGFloat((index * 43) % 210) - 30, y: CGFloat((index * 67) % 190) + 120,
          width: 390, height: isArtist ? 250 : 170))
      context.setBlendMode(.normal)

      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .left
      let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: title.count > 5 ? 56 : 68, weight: .black),
        .foregroundColor: UIColor.white, .paragraphStyle: paragraph,
      ]
      (title as NSString).draw(
        in: CGRect(x: 42, y: 382, width: 476, height: 116), withAttributes: titleAttributes)
      let label = isArtist ? "PORTRAIT / \(index + 1)" : "ARCHIVE / \(index + 1)"
      (label as NSString).draw(
        at: CGPoint(x: 44, y: 48),
        withAttributes: [
          .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .semibold),
          .foregroundColor: UIColor.white.withAlphaComponent(0.84),
        ])
    }
    return image.jpegData(compressionQuality: 0.91) ?? Data()
  }

  private struct VisualAuditPlayerRoot: View {
    @State private var sourceStore = MusicSourceStore(
      repository: InMemoryServerRepository(), vault: InMemoryCredentialVault())
    @State private var library: UnifiedLibraryStore
    @State private var playback: UnifiedPlaybackController
    private let tracks: [MusicTrack]

    init() {
      let providerID = UUID(uuidString: "48CBA9F1-27ED-4B81-8171-93C1C19463B1")!
      let usesEnglish = Locale.preferredLanguages.first?.hasPrefix("en") == true
      let beatTrack = MusicTrack(
        identity: .init(providerID: providerID, remoteID: "visual-beat", sourceType: .local),
        albumRemoteID: "album", artistRemoteID: "artist", title: usesEnglish ? "Starlight Pulse" : "星潮脉冲测试",
        artistName: usesEnglish ? "Original Demo Audio" : "本地受控音轨",
        albumTitle: usesEnglish ? "Visual Sessions" : "视觉验收", discNumber: 1, trackNumber: 1,
        duration: 18, artworkURL: nil,
        lyrics: usesEnglish
          ? "Low frequencies move closer\nA transient lights the tide\nMidrange turns the room"
          : "低频从远处靠近\n瞬态点亮整片星潮\n中频推动空间旋转",
        isExplicit: false, favoriteState: .favorite, contentType: "audio/wav", suffix: "wav",
        bitRate: 705, metadata: [:])
      let ambientTrack = MusicTrack(
        identity: .init(providerID: providerID, remoteID: "visual-ambient", sourceType: .local),
        albumRemoteID: "album", artistRemoteID: "artist", title: usesEnglish ? "Aurora Breathing" : "极光呼吸测试",
        artistName: usesEnglish ? "Original Demo Audio" : "本地受控音轨",
        albumTitle: usesEnglish ? "Visual Sessions" : "视觉验收", discNumber: 1, trackNumber: 2,
        duration: 18, artworkURL: nil,
        lyrics: usesEnglish
          ? "Aurora opens in the quiet\nVoices rise and settle\nSoft light follows the edge"
          : "极光在安静处展开\n人声频段慢慢起伏\n微光沿着边缘经过",
        isExplicit: false, favoriteState: .notFavorite, contentType: "audio/wav", suffix: "wav",
        bitRate: 705, metadata: [:])
      let tracks = [beatTrack, ambientTrack]
      let home = MusicSection(
        id: "visual-audit", title: usesEnglish ? "Original Demo Tracks" : "视觉验收音轨", kind: .recentlyPlayed,
        items: tracks.map(MusicSectionItem.track))
      let playlists = [
        MusicPlaylist(
          identity: .init(
            providerID: providerID, remoteID: "visual-night-list", sourceType: .local),
          name: usesEnglish ? "Night Walk" : "夜间散步", artworkURL: nil, trackCount: 8, duration: nil, isPublic: false,
          isEditable: true, metadata: [:]),
        MusicPlaylist(
          identity: .init(
            providerID: providerID, remoteID: "visual-favorites-list", sourceType: .local),
          name: usesEnglish ? "On Repeat" : "最近常听", artworkURL: nil, trackCount: 16, duration: nil, isPublic: false,
          isEditable: true, metadata: [:]),
      ]
      let provider = MockMusicSourceProvider(
        id: providerID, sourceType: .local, home: [home], tracks: tracks, playlists: playlists,
        mediaDataByRemoteID: [
          "visual-beat": makeVisualAuditWAV(style: .beat),
          "visual-ambient": makeVisualAuditWAV(style: .ambient),
        ], mediaMimeType: "audio/wav")
      self.tracks = tracks
      _library = State(initialValue: UnifiedLibraryStore(provider: provider))
      _playback = State(
        initialValue: UnifiedPlaybackController(
          provider: provider, wifiQuality: .original))
    }

    var body: some View {
      UniversalAppView()
        .environment(sourceStore)
        .environment(library)
        .environment(playback)
        .task {
          await library.loadIfNeeded()
          if playback.currentTrack == nil {
            await playback.play(tracks[0], queue: tracks)
          }
        }
    }
  }

  private enum VisualAuditAudioStyle { case beat, ambient }

  private func makeVisualAuditWAV(style: VisualAuditAudioStyle) -> Data {
    let sampleRate = 44_100
    let duration = 18
    let sampleCount = sampleRate * duration
    var pcm = Data()
    pcm.reserveCapacity(sampleCount * 2)
    for index in 0..<sampleCount {
      let time = Double(index) / Double(sampleRate)
      let interval = style == .beat ? 0.47 : 0.72
      let phase = time.truncatingRemainder(dividingBy: interval)
      let transient = exp(-phase * (style == .beat ? 19 : 12))
      let lowFrequency = style == .beat ? 68.0 : 92.0
      let midFrequency = style == .beat ? 420.0 : 610.0
      let low = sin(2 * Double.pi * lowFrequency * time) * (0.22 + transient * 0.48)
      let mid =
        sin(2 * Double.pi * midFrequency * time + sin(time * 0.9))
        * (style == .beat ? 0.13 : 0.23)
      let high =
        sin(2 * Double.pi * (style == .beat ? 5_800 : 3_900) * time)
        * transient * (style == .beat ? 0.16 : 0.08)
      let slow = sin(2 * Double.pi * 0.17 * time) * 0.06
      let value = max(-0.92, min(0.92, low + mid + high + slow))
      let integer = Int16(value * Double(Int16.max))
      pcm.append(UInt8(truncatingIfNeeded: integer))
      pcm.append(UInt8(truncatingIfNeeded: integer >> 8))
    }

    var wav = Data()
    func ascii(_ value: String) { wav.append(contentsOf: value.utf8) }
    func little16(_ value: UInt16) {
      wav.append(UInt8(truncatingIfNeeded: value))
      wav.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    func little32(_ value: UInt32) {
      wav.append(UInt8(truncatingIfNeeded: value))
      wav.append(UInt8(truncatingIfNeeded: value >> 8))
      wav.append(UInt8(truncatingIfNeeded: value >> 16))
      wav.append(UInt8(truncatingIfNeeded: value >> 24))
    }
    ascii("RIFF")
    little32(UInt32(36 + pcm.count))
    ascii("WAVEfmt ")
    little32(16)
    little16(1)
    little16(1)
    little32(UInt32(sampleRate))
    little32(UInt32(sampleRate * 2))
    little16(2)
    little16(16)
    ascii("data")
    little32(UInt32(pcm.count))
    wav.append(pcm)
    return wav
  }

  private struct VisualAuditLibraryRoot: View {
    @State private var sourceStore = MusicSourceStore(
      repository: InMemoryServerRepository(), vault: InMemoryCredentialVault())
    @State private var library: UnifiedLibraryStore
    @State private var playback: UnifiedPlaybackController
    private let track: MusicTrack

    init() {
      let providerID = UUID(uuidString: "48CBA9F1-27ED-4B81-8171-93C1C19463B1")!
      let usesEnglish = Locale.preferredLanguages.first?.hasPrefix("en") == true
      let track = MusicTrack(
        identity: .init(providerID: providerID, remoteID: "visual-audit", sourceType: .local),
        albumRemoteID: "album", artistRemoteID: "artist",
        title: usesEnglish ? "Moonlight on the Record Shelf" : "月光落在私人唱片架",
        artistName: usesEnglish ? "Sanshuai Player" : "散帅播放器",
        albumTitle: usesEnglish ? "Archive Pulse" : "收藏脉冲",
        discNumber: 1, trackNumber: 1,
        duration: 218, artworkURL: nil, lyrics: nil, isExplicit: false,
        favoriteState: .favorite, contentType: "audio/m4a", suffix: "m4a", bitRate: 320,
        metadata: [:])
      let home = MusicSection(
        id: "recent", title: usesEnglish ? "Recently Played" : "最近播放",
        kind: .recentlyPlayed, items: [.track(track)])
      let provider = MockMusicSourceProvider(
        id: providerID, sourceType: .local, home: [home], tracks: [track])
      self.track = track
      _library = State(initialValue: UnifiedLibraryStore(provider: provider))
      _playback = State(
        initialValue: UnifiedPlaybackController(
          provider: provider, wifiQuality: .original))
    }

    var body: some View {
      UniversalAppView()
        .environment(sourceStore)
        .environment(library)
        .environment(playback)
        .task {
          playback.loadVisualAuditTrack(track, at: 48)
          await library.loadIfNeeded()
        }
    }
  }
#endif

private struct RootView: View {
  @Environment(MusicSourceStore.self) private var sourceStore
  @State private var isShowingRestoreStatus = false

  var body: some View {
    Group {
      if sourceStore.isRestoring {
        StartupView(showRestoreStatus: isShowingRestoreStatus)
      } else if sourceStore.hasReliableActiveSource,
        let provider = sourceStore.provider, let server = sourceStore.activeServer
      {
        UniversalConnectedView(provider: provider, server: server)
          .id(server.id)
      } else {
        NavigationStack { MusicSourcesView() }
      }
    }
    .task {
      let statusTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(300))
        if !Task.isCancelled, sourceStore.isRestoring {
          isShowingRestoreStatus = true
        }
      }
      await MusicRuntimeCoordinator.shared.restoreIfNeeded()
      statusTask.cancel()
      StartupTrace.mark("startup-page.finished")
    }
  }
}

private struct UniversalConnectedView: View {
  private let context: CarPlayRuntimeContext

  init(provider: any MusicSourceProvider, server: MusicServer) {
    // The coordinator owns these, so the window scene coming and going never tears down a
    // player CarPlay is still driving.
    context = MusicRuntimeCoordinator.shared.runtime(for: server, provider: provider)
  }

  var body: some View {
    UniversalAppView()
      .environment(context.library)
      .environment(context.playback)
      .environment(\.musicServerID, context.serverID)
      .environment(\.musicArtworkFetcher, context.artworkFetcher)
      .task {
        await context.library.loadIfNeeded()
        // A CarPlay screen that adopted this runtime before the library had content needs to
        // know it can show the real library now.
        CarPlayRuntimeRegistry.shared.notifyRuntimeDidChange()
      }
  }
}

private struct StartupView: View {
  let showRestoreStatus: Bool

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 32)

      VStack(spacing: 16) {
        Image("BrandIcon")
          .resizable().scaledToFit()
          .frame(width: 144, height: 144)
          .clipShape(.rect(cornerRadius: 34, style: .continuous))
          .shadow(color: Color.black.opacity(0.10), radius: 18, y: 10)
          .accessibilityHidden(true)

        if showRestoreStatus {
          VStack(spacing: 6) {
            Text(AppInfo.name)
              .font(.headline)
            Text("正在准备资料库")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }

          ProgressView()
            .controlSize(.small)
        }
      }
      .padding(.horizontal, 28)

      Spacer(minLength: 32)

      Text("v\(AppInfo.shortVersion) @2026himhuu")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color("LaunchBackground"))
  }

}

enum AppInfo {
  private static let productionAppStoreID = "6784067140"
  private static let canonicalBaseURL = URL(string: "https://himhuu.com/apps/sanshuai-player")!

  static var name: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? "散帅播放器"
  }

  static var shortVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
  }

  static var version: String {
    "\(shortVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))"
  }

  static var appStoreID: String {
    let configured = Bundle.main.object(forInfoDictionaryKey: "AppStoreID") as? String
    if let configured, !configured.isEmpty, configured.allSatisfy(\.isNumber) {
      return configured
    }
    return productionAppStoreID
  }

  static var appStoreURL: URL {
    URL(string: "https://apps.apple.com/app/id\(appStoreID)")!
  }

  static var writeReviewURL: URL {
    URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")!
  }

  static var productURL: URL { canonicalBaseURL }
  static var privacyURL: URL { canonicalBaseURL.appending(path: "privacy") }
  static var termsURL: URL { canonicalBaseURL.appending(path: "terms") }
  static var supportURL: URL { canonicalBaseURL.appending(path: "support") }

  static var feedbackURL: URL {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = "support@himhuu.com"
    components.queryItems = [
      URLQueryItem(name: "subject", value: "\(name) 技术支持与故障反馈"),
      URLQueryItem(
        name: "body",
        value: "请提供 App 版本（\(version)）、设备、系统版本、复现步骤和脱敏截图。请勿发送密码、令牌或未脱敏的私密内容。")
    ]
    return components.url!
  }
}

enum StartupTrace {
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MusicPlayer",
    category: "Startup"
  )
  private static let launchTime = ProcessInfo.processInfo.systemUptime

  static func mark(_ event: String) {
    let elapsed = ProcessInfo.processInfo.systemUptime - launchTime
    logger.notice(
      "\(event, privacy: .public) +\(elapsed, format: .fixed(precision: 3), privacy: .public)s")
  }
}
