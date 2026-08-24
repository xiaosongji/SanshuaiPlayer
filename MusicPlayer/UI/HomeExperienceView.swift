import Combine
import SwiftUI
import UIKit

enum HomeContentMode: String, CaseIterable {
  case albums
  case artists

  var title: String {
    self == .albums ? String(localized: "专辑") : String(localized: "歌手")
  }
}

enum HomeGalleryItem: Identifiable, Hashable {
  case album(MusicAlbum)
  case artist(MusicArtist)

  var id: String {
    switch self {
    case .album(let value): "album:\(value.identity.remoteID)"
    case .artist(let value): "artist:\(value.identity.remoteID)"
    }
  }
  var title: String {
    switch self {
    case .album(let value): value.title
    case .artist(let value): value.name
    }
  }
  var subtitle: String {
    switch self {
    case .album(let value): value.artistName
    case .artist(let value):
      value.albumCount.map { String(localized: "\($0) 张专辑") } ?? String(localized: "歌手")
    }
  }
  var artworkURL: URL? {
    switch self {
    case .album(let value): value.artworkURL
    case .artist(let value): value.artworkURL
    }
  }
  var cacheIdentity: String { id }
}

struct HomeExperienceView: View {
  @Environment(UnifiedLibraryStore.self) private var library
  @Environment(UnifiedPlaybackController.self) private var playback
  @Environment(\.musicServerID) private var serverID
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Binding var isLandscapePresentation: Bool
  @State private var mode: HomeContentMode = .albums
  @State private var selectedID: String?
  @State private var startingID: String?

  var body: some View {
    GeometryReader { proxy in
      let isLandscape = proxy.size.width > proxy.size.height
      ZStack {
        galleryBackground
        if items.isEmpty {
          emptyState
        } else if isLandscape {
          LandscapeArtworkFlow(
            items: items, selection: $selectedID, startingID: startingID,
            currentTrack: playback.currentTrack, reduceMotion: reduceMotion,
            onPlay: play)
        } else {
          PortraitArtworkConstellation(
            items: items, startingID: startingID, currentTrack: playback.currentTrack,
            reduceMotion: reduceMotion, onPlay: play)
        }
        VStack(spacing: 0) {
          LinearGradient(
            colors: [
              (colorScheme == .dark ? HimhuuVisualTheme.cocoa : HimhuuVisualTheme.cream)
                .opacity(0.52),
              HimhuuVisualTheme.softPeach.opacity(colorScheme == .dark ? 0.10 : 0.16),
              .clear,
            ],
            startPoint: .top, endPoint: .bottom)
            .frame(height: 72)
          Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
      }
      .onAppear { isLandscapePresentation = isLandscape }
      .onChange(of: isLandscape) { _, newValue in
        isLandscapePresentation = newValue
      }
    }
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .refreshable { await library.refresh() }
    .onAppear {
      restoreMode()
    }
    .onChange(of: mode) { _, _ in selectedID = items.first?.id }
    .onDisappear { isLandscapePresentation = false }
  }

  private var items: [HomeGalleryItem] {
    switch mode {
    case .albums:
      return HomeFeedBuilder.albums(
        sections: library.homeSections, albums: library.albums
      ).prefix(120).map(HomeGalleryItem.album)
    case .artists:
      return HomeFeedBuilder.artists(
        sections: library.homeSections, artists: library.artists,
        albums: library.albums
      ).prefix(96).map(HomeGalleryItem.artist)
    }
  }

  private var galleryBackground: some View {
    Group {
      if colorScheme == .dark {
        LinearGradient(
          colors: [
            HimhuuVisualTheme.cocoa,
            Color(red: 0.28, green: 0.15, blue: 0.13),
            Color(red: 0.22, green: 0.12, blue: 0.14),
          ], startPoint: .topLeading, endPoint: .bottomTrailing)
      } else {
        LinearGradient(
          colors: [
            HimhuuVisualTheme.cream,
            Color(red: 1.00, green: 0.89, blue: 0.80),
            Color(red: 0.94, green: 0.88, blue: 0.96),
          ], startPoint: .topLeading, endPoint: .bottomTrailing)
      }
    }
    .ignoresSafeArea()
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(
        library.isLoading ? String(localized: "正在整理音乐库…") : String(localized: "这里还没有内容"),
        systemImage: "square.grid.3x3.fill")
    } description: {
      Text("连接音乐源后，专辑和歌手会在这里组成你的收藏星图。")
    }
  }

  private func play(_ item: HomeGalleryItem) {
    guard startingID == nil else { return }
    startingID = item.id
    selectedID = item.id
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    Task {
      let queue: [MusicTrack]
      switch item {
      case .album(let album):
        queue = await library.playbackQueue(for: album)
      case .artist(let artist):
        queue = await library.playbackQueue(for: artist)
      }
      guard let first = queue.first else {
        startingID = nil
        return
      }
      await playback.play(first, queue: queue)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      startingID = nil
    }
  }

  private var modeStorageKey: String {
    "home.gallery.mode.\(serverID?.uuidString.lowercased() ?? "default")"
  }

  private func restoreMode() {
    guard let raw = UserDefaults.standard.string(forKey: modeStorageKey),
      let stored = HomeContentMode(rawValue: raw)
    else { return }
    mode = stored
  }
}

private enum HomeFeedBuilder {
  static func albums(sections: [MusicSection], albums: [MusicAlbum]) -> [MusicAlbum] {
    var byRemoteID: [String: MusicAlbum] = [:]
    for album in albums { byRemoteID[album.identity.remoteID] = album }
    var result: [MusicAlbum] = []
    var seen = Set<UUID>()
    func append(_ album: MusicAlbum) {
      guard seen.insert(album.id).inserted else { return }
      result.append(album)
    }
    for section in sections {
      for item in section.items {
        switch item {
        case .album(let album):
          append(album)
        case .track(let track):
          if let id = track.albumRemoteID, let album = byRemoteID[id] { append(album) }
        case .artist, .playlist:
          break
        }
      }
    }
    for album in albums.sorted(by: stableAlbumOrder) { append(album) }
    return result
  }

  static func artists(
    sections: [MusicSection], artists: [MusicArtist], albums: [MusicAlbum]
  ) -> [MusicArtist] {
    var candidates = artists
    let byRemoteID = Dictionary(
      artists.map { ($0.identity.remoteID, $0) },
      uniquingKeysWith: { current, candidate in
        ArtistPresentationPolicy.preferred(current, candidate)
      })
    for section in sections {
      for item in section.items {
        switch item {
        case .artist(let artist):
          candidates.append(artist)
        case .album(let album):
          if let id = album.artistID, let artist = byRemoteID[id] {
            candidates.append(artist)
          }
        case .track, .playlist:
          break
        }
      }
    }
    return ArtistPresentationPolicy.deduplicated(candidates)
  }

  private static func stableAlbumOrder(_ lhs: MusicAlbum, _ rhs: MusicAlbum) -> Bool {
    if lhs.favoriteState != rhs.favoriteState { return lhs.favoriteState == .favorite }
    if lhs.releaseDate != rhs.releaseDate {
      return (lhs.releaseDate ?? .distantPast) > (rhs.releaseDate ?? .distantPast)
    }
    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
  }

}

private struct PortraitArtworkConstellation: View {
  let items: [HomeGalleryItem]
  let startingID: String?
  let currentTrack: MusicTrack?
  let reduceMotion: Bool
  let onPlay: (HomeGalleryItem) -> Void
  @Environment(\.scenePhase) private var scenePhase

  private let columnSpacing: CGFloat = 7
  private let horizontalPadding: CGFloat = 8

  var body: some View {
    GeometryReader { proxy in
      let cellWidth = max(
        1,
        (proxy.size.width - horizontalPadding * 2 - columnSpacing * 2) / 3)
      let columns = Array(
        repeating: GridItem(.flexible(), spacing: columnSpacing), count: 3)

      ScrollView {
        LazyVGrid(columns: columns, alignment: .center, spacing: columnSpacing) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            let size = tileSize(index, cellWidth: cellWidth)
            GalleryArtworkButton(
              item: item, size: size, isStarting: startingID == item.id,
              isPlaying: item.matches(currentTrack), maximumPixelSize: 384, action: {
                onPlay(item)
              })
              .rotationEffect(reduceMotion ? .zero : .degrees(rotation(index)))
              .offset(y: reduceMotion ? 0 : verticalOffset(index))
              .ambientFloating(
                index: index, identity: item.id,
                isEnabled: allowsAmbientMotion)
              .zIndex(Double(size))
              .frame(maxWidth: .infinity, minHeight: cellWidth)
              .padding(.vertical, 4)
          }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 8)
        PlayerDockScrollFooter()
      }
      .scrollIndicators(.hidden)
    }
  }

  private var allowsAmbientMotion: Bool {
    !reduceMotion && scenePhase == .active
  }

  private func tileSize(_ index: Int, cellWidth: CGFloat) -> CGFloat {
    let scale: CGFloat =
      switch index % 9 {
      case 0, 5: 0.89
      case 2, 7: 0.76
      default: 0.84
      }
    return max(72, floor(cellWidth * scale))
  }

  private func rotation(_ index: Int) -> Double {
    [-2.2, 0.8, 1.7, -0.7, 2.4, -1.4][index % 6]
  }

  private func verticalOffset(_ index: Int) -> CGFloat {
    [-7, 8, -1, 5, -5, 3][index % 6]
  }
}

private struct AmbientFloatingModifier: ViewModifier {
  let index: Int
  let identity: String
  let isEnabled: Bool
  @State private var isAtFarPoint = false
  @State private var hasStarted = false

  func body(content: Content) -> some View {
    let rawHorizontal = CGFloat([4.8, -6.8, 8.4, -5.2, 7.2][index % 5])
    let horizontal =
      index % 3 == 0 || index % 3 == 2
      ? min(max(rawHorizontal, -4.8), 4.8) : rawHorizontal
    let vertical = CGFloat([-7.2, 5.2, -8.8, 6.8, -5.6, 8.0][index % 6])
    let rotation = Double([1.12, -1.36, 1.68, -1.0][index % 4])
    content
      .offset(
        x: isAtFarPoint ? horizontal : -horizontal * 0.45,
        y: isAtFarPoint ? vertical : -vertical * 0.45)
      .rotationEffect(.degrees(isAtFarPoint ? rotation : -rotation * 0.45))
      .task(id: AnimationTaskID(identity: identity, isEnabled: isEnabled)) {
        guard isEnabled else {
          withAnimation(.easeOut(duration: 0.24)) { isAtFarPoint = false }
          return
        }

        if !hasStarted {
          do {
            try await Task.sleep(for: .seconds(stablePhaseDelay))
          } catch {
            return
          }
          hasStarted = true
        }

        let duration = 8.6 + Double(index % 5) * 0.72
        while !Task.isCancelled {
          withAnimation(.easeInOut(duration: duration)) {
            isAtFarPoint.toggle()
          }
          do {
            try await Task.sleep(for: .seconds(duration))
          } catch {
            return
          }
        }
      }
  }

  private struct AnimationTaskID: Hashable {
    let identity: String
    let isEnabled: Bool
  }

  private var stablePhaseDelay: TimeInterval {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in identity.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return Double(hash % 2_401) / 1_000
  }
}

private extension View {
  func ambientFloating(index: Int, identity: String, isEnabled: Bool) -> some View {
    modifier(
      AmbientFloatingModifier(index: index, identity: identity, isEnabled: isEnabled))
  }
}

private struct LandscapeArtworkFlow: View {
  let items: [HomeGalleryItem]
  @Binding var selection: String?
  let startingID: String?
  let currentTrack: MusicTrack?
  let reduceMotion: Bool
  let onPlay: (HomeGalleryItem) -> Void

  var body: some View {
    GeometryReader { proxy in
      let cardSize = min(max(150, proxy.size.height * 0.62), 258)
      let reflectionHeight = cardSize * 0.27
      VStack(spacing: 8) {
        ScrollView(.horizontal) {
          LazyHStack(spacing: reduceMotion ? 18 : -cardSize * 0.20) {
            ForEach(items) { item in
              GeometryReader { cardProxy in
                let midX = cardProxy.frame(in: .global).midX
                let centerX = proxy.frame(in: .global).midX
                let progress = min(max((midX - centerX) / cardSize, -2), 2)
                VStack(spacing: 7) {
                  GalleryArtworkButton(
                    item: item, size: cardSize, isStarting: startingID == item.id,
                    isPlaying: item.matches(currentTrack), maximumPixelSize: 768,
                    action: {
                      withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        selection = item.id
                      }
                      onPlay(item)
                    })
                  LandscapeArtworkReflection(
                    item: item, size: cardSize, height: reflectionHeight)
                }
                  .scaleEffect(reduceMotion ? 1 : max(0.72, 1 - abs(progress) * 0.18))
                  .rotation3DEffect(
                    reduceMotion ? .zero : .degrees(Double(progress) * -52),
                    axis: (x: 0, y: 1, z: 0), perspective: 0.64)
                  .opacity(
                    reduceMotion ? 1 : abs(progress) > 1.55
                      ? 0 : max(0.44, 1 - abs(progress) * 0.26))
                  .zIndex(10 - abs(Double(progress)))
              }
              .frame(width: cardSize, height: cardSize + reflectionHeight + 7)
              .id(item.id)
            }
          }
          .scrollTargetLayout()
        }
        .contentMargins(.horizontal, max(16, (proxy.size.width - cardSize) / 2), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: $selection, anchor: .center)
        .scrollIndicators(.hidden)
        .frame(height: cardSize + reflectionHeight + 7)
        .fixedSize(horizontal: false, vertical: true)

      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .onAppear {
        if selection == nil {
          let startingIndex = min(2, max(0, items.count - 1))
          selection =
            items.first(where: { $0.matches(currentTrack) })?.id
            ?? items.dropFirst(startingIndex).first?.id
        }
      }
    }
  }
}

private struct LandscapeArtworkReflection: View {
  let item: HomeGalleryItem
  let size: CGFloat
  let height: CGFloat

  var body: some View {
    CoverArtworkView(
      url: item.artworkURL, cornerRadius: max(8, size * 0.07),
      cacheIdentity: item.cacheIdentity, maximumPixelSize: 512)
      .frame(width: size, height: height)
      .scaleEffect(x: 1, y: -1)
      .blur(radius: 2)
      .opacity(0.17)
      .mask {
        LinearGradient(
          colors: [.white.opacity(0.78), .white.opacity(0.20), .clear],
          startPoint: .top, endPoint: .bottom)
      }
      .overlay {
        LinearGradient(
          colors: [.white.opacity(0.08), .clear],
          startPoint: .top, endPoint: .bottom)
          .blendMode(.screen)
      }
      .clipped()
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct GalleryArtworkButton: View {
  let item: HomeGalleryItem
  let size: CGFloat
  let isStarting: Bool
  let isPlaying: Bool
  let maximumPixelSize: CGFloat
  let action: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: action) {
      ZStack {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                colorScheme == .dark
                  ? Color(red: 0.36, green: 0.22, blue: 0.18)
                  : HimhuuVisualTheme.cream,
                colorScheme == .dark
                  ? HimhuuVisualTheme.cocoa
                  : HimhuuVisualTheme.softPeach.opacity(0.82),
              ],
              startPoint: .topLeading, endPoint: .bottomTrailing))
        CoverArtworkView(
          url: item.artworkURL, cornerRadius: cornerRadius,
          cacheIdentity: item.cacheIdentity,
          maximumPixelSize: maximumPixelSize)
          .frame(width: size, height: size)
        if item.artworkURL == nil {
          Text(String(item.title.prefix(1)).uppercased())
            .font(.system(size: max(24, size * 0.28), weight: .black, design: .rounded))
            .foregroundStyle(.white.opacity(0.86))
        }
        if isStarting {
          ProgressView()
            .tint(.white)
            .padding(12)
            .background(.black.opacity(0.60), in: Circle())
        }
      }
      .frame(width: size, height: size)
      .overlay(alignment: .bottomTrailing) {
        if isPlaying {
          Label("正在播放", systemImage: "waveform")
            .labelStyle(.iconOnly)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(HimhuuVisualTheme.peach, in: Circle())
            .overlay(Circle().stroke(HimhuuVisualTheme.cream.opacity(0.92), lineWidth: 1.5))
            .padding(7)
        }
      }
      .shadow(
        color: HimhuuVisualTheme.warmInk.opacity(
          isPlaying ? 0.34 : colorScheme == .dark ? 0.25 : 0.16),
        radius: isPlaying ? 22 : 13, y: isPlaying ? 12 : 8)
      .shadow(
        color: Color.white.opacity(colorScheme == .dark ? 0.04 : 0.42),
        radius: 3, x: -2, y: -2)
      .scaleEffect(isStarting || isPlaying ? 1.035 : 1)
      .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isStarting)
      .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isPlaying)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(item.title)，\(item.subtitle)")
    .accessibilityHint("播放")
    .accessibilityAddTraits(isPlaying ? [.isSelected] : [])
  }

  private var cornerRadius: CGFloat {
    switch item {
    case .album: max(10, size * 0.09)
    case .artist: max(16, size * 0.15)
    }
  }
}

private extension HomeGalleryItem {
  func matches(_ track: MusicTrack?) -> Bool {
    guard let track else { return false }
    switch self {
    case .album(let album):
      return track.albumRemoteID == album.identity.remoteID
        || (track.albumTitle?.localizedCaseInsensitiveCompare(album.title) == .orderedSame
          && track.artistName.localizedCaseInsensitiveCompare(album.artistName) == .orderedSame)
    case .artist(let artist):
      return track.artistRemoteID == artist.identity.remoteID
        || track.artistName.localizedCaseInsensitiveCompare(artist.name) == .orderedSame
    }
  }
}
