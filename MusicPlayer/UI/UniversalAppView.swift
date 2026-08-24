import StoreKit
import SwiftUI
import UniformTypeIdentifiers

enum HimhuuVisualTheme {
  static let cream = Color(red: 1.00, green: 0.96, blue: 0.86)
  static let peach = Color(red: 1.00, green: 0.52, blue: 0.34)
  static let softPeach = Color(red: 1.00, green: 0.76, blue: 0.62)
  static let lavender = Color(red: 0.64, green: 0.49, blue: 0.88)
  static let avocado = Color(red: 0.61, green: 0.68, blue: 0.31)
  static let warmInk = Color(red: 0.24, green: 0.13, blue: 0.12)
  static let cocoa = Color(red: 0.20, green: 0.11, blue: 0.10)

  static func foreground(for scheme: ColorScheme) -> Color {
    scheme == .dark ? cream : warmInk
  }
}

struct UniversalAppView: View {
  @Environment(UnifiedLibraryStore.self) private var library
  @Environment(UnifiedPlaybackController.self) private var playback
  @Environment(MusicSourceStore.self) private var sources
  @State private var showsPlayer: Bool
  @State private var selectedTab: AppTab = .home
  @State private var homeIsLandscape = false
  @AppStorage("rating.didRequestAfterPlayback") private var didRequestRating = false
  @Environment(\.requestReview) private var requestReview

  init() {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      _showsPlayer = State(
        initialValue: arguments.contains("-visual-audit-player"))
      _selectedTab = State(
        initialValue:
          arguments.contains("-visual-audit-settings")
          ? .settings
          : arguments.contains("-visual-audit-library")
            || arguments.contains("-visual-audit-favorites")
            ? .library : .home)
    #else
      _showsPlayer = State(initialValue: false)
    #endif
  }

  var body: some View {
    GeometryReader { _ in
      let hidesPlaybackNavigation = selectedTab == .home && homeIsLandscape
      let scrollFooterHeight: CGFloat =
        hidesPlaybackNavigation
        ? 0 : playback.currentTrack != nil ? 138 : 64
      tabs
        .environment(\.playerDockScrollFooterHeight, scrollFooterHeight)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if !hidesPlaybackNavigation {
            FloatingPlaybackNavigation(
              selection: $selectedTab,
              showPlayer: { showsPlayer = true })
              .padding(.horizontal, 14)
              .padding(.top, 38)
              .padding(.bottom, 8)
              .background(Color.clear)
          }
        }
        .fullScreenCover(isPresented: $showsPlayer) { UnifiedPlayerView() }
        .onChange(of: playback.completedPlaybackCount) { _, count in
          guard count >= 5, !didRequestRating else { return }
          didRequestRating = true
          requestReview()
        }
        .task { await library.loadIfNeeded() }
        .alert(
          "资料库提示",
          isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.dismissError() } })
        ) {
          Button("好") { library.dismissError() }
        } message: {
          Text(library.errorMessage ?? "")
        }
        .alert(
          "播放提示",
          isPresented: Binding(
            get: { playback.errorMessage != nil },
            set: { if !$0 { playback.dismissError() } })
        ) {
          Button("好") { playback.dismissError() }
        } message: {
          Text(playback.errorMessage ?? "")
        }
    }
  }

  private var tabs: some View {
    TabView(selection: $selectedTab) {
      NavigationStack {
        UniversalHomeView(isLandscapePresentation: $homeIsLandscape)
          .toolbar(.hidden, for: .navigationBar)
      }
        .toolbar(.hidden, for: .tabBar)
        .tag(AppTab.home).tabItem {
          Label(
            AppTab.home.title,
            systemImage: selectedTab == .home ? AppTab.home.selectedIcon : AppTab.home.icon)
        }
      NavigationStack { UniversalBrowseView().sourceToolbar() }
        .toolbar(.hidden, for: .tabBar)
        .tag(AppTab.library).tabItem {
          Label(
            AppTab.library.title,
            systemImage: selectedTab == .library ? AppTab.library.selectedIcon : AppTab.library.icon
          )
        }
      NavigationStack { UniversalSearchView().sourceToolbar() }
        .toolbar(.hidden, for: .tabBar)
        .tag(AppTab.search).tabItem {
          Label(
            AppTab.search.title,
            systemImage: selectedTab == .search ? AppTab.search.selectedIcon : AppTab.search.icon)
        }
      NavigationStack { UniversalSettingsView().sourceToolbar() }
        .toolbar(.hidden, for: .tabBar)
        .tag(AppTab.settings).tabItem {
          Label(
            AppTab.settings.title,
            systemImage: selectedTab == .settings
              ? AppTab.settings.selectedIcon : AppTab.settings.icon)
        }
    }
  }
}

private struct PlayerDockScrollFooterHeightKey: EnvironmentKey {
  static let defaultValue: CGFloat = 64
}

enum InAppMiniPlayerPresentationPolicy {
  nonisolated static func shouldShow(hasCurrentTrack: Bool) -> Bool {
    hasCurrentTrack
  }
}

extension EnvironmentValues {
  var playerDockScrollFooterHeight: CGFloat {
    get { self[PlayerDockScrollFooterHeightKey.self] }
    set { self[PlayerDockScrollFooterHeightKey.self] = newValue }
  }
}

struct PlayerDockScrollFooter: View {
  @Environment(\.playerDockScrollFooterHeight) private var height

  var body: some View {
    Color.clear
      .frame(height: height)
      .listRowInsets(EdgeInsets())
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct FloatingPlaybackNavigation: View {
  @Environment(UnifiedPlaybackController.self) private var playback
  @Binding var selection: AppTab
  let showPlayer: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      if InAppMiniPlayerPresentationPolicy.shouldShow(
        hasCurrentTrack: playback.currentTrack != nil)
      {
        FloatingMiniPlayer(showPlayer: showPlayer)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      FloatingTabDock(selection: $selection)
    }
    .animation(.snappy(duration: 0.32), value: playback.currentTrack?.id)
  }
}

private struct FloatingTabDock: View {
  @Environment(\.colorScheme) private var colorScheme
  @Binding var selection: AppTab
  @Namespace private var selectionGlassNamespace

  var body: some View {
    Group {
      if #available(iOS 26.0, *) {
        GlassEffectContainer(spacing: 8) {
          tabButtons
        }
      } else {
        tabButtons
      }
    }
    .padding(.horizontal, 5)
    .frame(height: 64)
    // Keep persistent navigation usable at accessibility sizes; page content still follows
    // the user's full Dynamic Type setting and every tab retains its VoiceOver label.
    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    .floatingGlassSurface(cornerRadius: 29)
  }

  private var tabButtons: some View {
    HStack(spacing: 4) {
      ForEach(AppTab.allCases, id: \.rawValue) { tab in
        Button {
          withAnimation(.snappy(duration: 0.38, extraBounce: 0.04)) {
            selection = tab
          }
        } label: {
          VStack(spacing: 3) {
            Image(systemName: selection == tab ? tab.selectedIcon : tab.icon)
              .font(.system(size: 20, weight: .semibold))
              .symbolRenderingMode(.hierarchical)
            Text(tab.title)
              .font(.caption2.weight(.medium))
          }
          .frame(maxWidth: .infinity, minHeight: 54)
          .contentShape(Capsule())
          .modifier(
            SelectedTabGlassModifier(
              isSelected: selection == tab,
              tint: colorScheme == .dark
                ? HimhuuVisualTheme.lavender.opacity(0.22)
                : HimhuuVisualTheme.softPeach.opacity(0.28),
              namespace: selectionGlassNamespace))
        }
        .buttonStyle(.plain)
        .foregroundStyle(
          selection == tab
            ? AnyShapeStyle(
              colorScheme == .dark
                ? HimhuuVisualTheme.cream : HimhuuVisualTheme.warmInk)
            : AnyShapeStyle(
              colorScheme == .dark
                ? HimhuuVisualTheme.cream.opacity(0.68)
                : HimhuuVisualTheme.warmInk.opacity(0.66)))
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
      }
    }
  }
}

private struct SelectedTabGlassModifier: ViewModifier {
  let isSelected: Bool
  let tint: Color
  let namespace: Namespace.ID

  @ViewBuilder
  func body(content: Content) -> some View {
    let shape = Capsule()
    if isSelected, #available(iOS 26.0, *) {
      content
        .glassEffect(
          .regular.tint(tint).interactive(),
          in: shape)
        .glassEffectID("active-tab", in: namespace)
        .glassEffectTransition(.matchedGeometry)
        .padding(3)
    } else if isSelected {
      content
        .background(
          .ultraThinMaterial,
          in: shape)
        .matchedGeometryEffect(id: "active-tab", in: namespace)
        .padding(3)
    } else {
      content.padding(3)
    }
  }
}

private struct FloatingMiniPlayer: View {
  @Environment(UnifiedPlaybackController.self) private var playback
  @Environment(\.colorScheme) private var colorScheme
  let showPlayer: () -> Void

  var body: some View {
    if let track = playback.currentTrack {
      HStack(spacing: 10) {
        Button(action: showPlayer) {
          HStack(spacing: 10) {
            CoverArtworkView(
              url: track.artworkURL, cornerRadius: 11,
              cacheIdentity: track.albumRemoteID.map { "album:\($0)" }
                ?? "track:\(track.identity.remoteID)",
              maximumPixelSize: 192)
              .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
              Text(track.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
              Text(track.artistName)
                .font(.caption)
                .foregroundStyle(
                  colorScheme == .dark
                    ? HimhuuVisualTheme.cream.opacity(0.62)
                    : HimhuuVisualTheme.warmInk.opacity(0.64))
                .lineLimit(1)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开正在播放，\(track.title)，\(track.artistName)")
        Spacer(minLength: 4)
        miniControl(
          playback.isPlaybackRequested ? "pause.fill" : "play.fill",
          label: playback.isPlaybackRequested ? "暂停" : "播放"
        ) {
          playback.togglePlayback()
        }
        miniControl("forward.fill", label: "下一首") {
          Task { await playback.playNext() }
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 64)
      .foregroundStyle(
        colorScheme == .dark
          ? HimhuuVisualTheme.cream : HimhuuVisualTheme.warmInk)
      .floatingGlassSurface(cornerRadius: 29)
      .overlay(alignment: .bottomLeading) {
        GeometryReader { proxy in
          Capsule()
            .fill(
              colorScheme == .dark
                ? HimhuuVisualTheme.lavender.opacity(0.92)
                : HimhuuVisualTheme.peach.opacity(0.92))
            .frame(
              width: proxy.size.width
                * min(max(playback.currentTime / max(playback.duration, 1), 0), 1),
              height: 2)
        }
        .frame(height: 2)
        .padding(.horizontal, 18)
        .allowsHitTesting(false)
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 20).onEnded { value in handleSwipe(value.translation) })
    }
  }

  private func miniControl(
    _ icon: String, label: LocalizedStringKey, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .semibold))
        .frame(width: 44, height: 44)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(label))
  }

  private func handleSwipe(_ translation: CGSize) {
    if abs(translation.width) > abs(translation.height), abs(translation.width) > 44 {
      Task {
        if translation.width < 0 {
          await playback.playNext()
        } else {
          await playback.playPrevious()
        }
      }
    } else if translation.height < -32 {
      showPlayer()
    }
  }
}

private struct FloatingGlassSurfaceModifier: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  @ViewBuilder
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    if reduceTransparency {
      content
        .background(
          colorScheme == .dark
            ? HimhuuVisualTheme.cocoa : HimhuuVisualTheme.cream,
          in: shape)
        .overlay {
          shape.stroke(
            colorScheme == .dark
              ? HimhuuVisualTheme.cream.opacity(0.18)
              : HimhuuVisualTheme.peach.opacity(0.20),
            lineWidth: 0.8)
        }
        .shadow(
          color: HimhuuVisualTheme.warmInk.opacity(colorScheme == .dark ? 0.30 : 0.14),
          radius: 18, y: 10)
    } else if #available(iOS 26.0, *) {
      content
        .background(
          colorScheme == .dark
            ? HimhuuVisualTheme.cocoa.opacity(0.42)
            : HimhuuVisualTheme.cream.opacity(0.48),
          in: shape)
        .glassEffect(.clear, in: shape)
        .overlay {
          shape
            .stroke(
              colorScheme == .dark
                ? HimhuuVisualTheme.cream.opacity(0.22)
                : Color.white.opacity(0.78),
              lineWidth: 0.9)
            .mask(
              LinearGradient(
                colors: [.white, .white.opacity(0.18), .clear],
                startPoint: .top, endPoint: .bottom))
        }
        .shadow(
          color: HimhuuVisualTheme.warmInk.opacity(colorScheme == .dark ? 0.32 : 0.16),
          radius: 20, y: 12)
    } else {
      content
        .background(.ultraThinMaterial, in: shape)
        .background(
          colorScheme == .dark
            ? HimhuuVisualTheme.cocoa.opacity(0.42)
            : HimhuuVisualTheme.cream.opacity(0.42),
          in: shape)
        .overlay {
          shape
            .stroke(
              colorScheme == .dark
                ? HimhuuVisualTheme.cream.opacity(0.22)
                : Color.white.opacity(0.74),
              lineWidth: 0.9)
            .mask(
              LinearGradient(
                colors: [.white, .white.opacity(0.18), .clear],
                startPoint: .top, endPoint: .bottom))
        }
        .shadow(
          color: HimhuuVisualTheme.warmInk.opacity(colorScheme == .dark ? 0.32 : 0.16),
          radius: 20, y: 12)
    }
  }

  let cornerRadius: CGFloat
}

private extension View {
  func floatingGlassSurface(cornerRadius: CGFloat) -> some View {
    modifier(FloatingGlassSurfaceModifier(cornerRadius: cornerRadius))
  }
}

private enum AppTab: Int, CaseIterable {
  case home, library, search, settings
  var title: String {
    switch self {
    case .home: String(localized: "首页")
    case .library: String(localized: "资料库")
    case .search: String(localized: "搜索")
    case .settings: String(localized: "设置")
    }
  }
  var icon: String {
    switch self {
    case .home: "house"
    case .library: "rectangle.stack"
    case .search: "magnifyingglass"
    case .settings: "gearshape"
    }
  }
  var selectedIcon: String {
    switch self {
    case .home: "house.fill"
    case .library: "rectangle.stack.fill"
    case .search: "magnifyingglass"
    case .settings: "gearshape.fill"
    }
  }
}

struct UniversalHomeView: View {
  @Binding var isLandscapePresentation: Bool

  var body: some View {
    HomeExperienceView(isLandscapePresentation: $isLandscapePresentation)
  }
}

struct UniversalBrowseView: View {
  @Environment(UnifiedLibraryStore.self) private var library
  @Environment(UnifiedPlaybackController.self) private var playback
  @Environment(MusicSourceStore.self) private var sources
  @State private var segment = 0
  @State private var showsCreatePlaylist = false
  @State private var showsFileImporter = false
  @State private var showsFolderImporter = false
  @State private var isImporting = false
  @State private var importMessage: String?
  var body: some View {
    VStack(spacing: 0) {
      Picker("内容", selection: $segment) {
        Text("歌曲").tag(0)
        Text("歌单").tag(1)
      }.pickerStyle(.segmented).padding()
      switch segment {
      case 0:
        if library.isLoading && library.tracks.isEmpty {
          ProgressView("正在载入歌曲…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          TrackCollectionView(tracks: library.tracks)
        }
      case 1:
        List {
          if library.capabilities.contains(.favorites) {
            NavigationLink {
              FavoriteTracksView()
            } label: {
              FavoriteCollectionRow(count: library.favoriteTracks.count)
            }
          }
          ForEach(library.playlists) { playlist in
            NavigationLink {
              PlaylistDetailView(playlist: playlist)
            } label: {
              MediaRow(
                artwork: playlist.artworkURL
                  ?? library.artworkURL(
                    for: .playlist(playlist), size: .init(width: 96, height: 96)),
                title: playlist.name, subtitle: "\(playlist.trackCount) 首歌曲",
                cacheIdentity: MusicResourceOwner.playlist(playlist.identity.remoteID))
            }
          }
          if library.playlists.isEmpty && !library.isLoading {
            ContentUnavailableView {
              Label("还没有自建歌单", systemImage: "music.note.list")
            } description: {
              Text("“喜欢的歌曲”会自动收纳收藏内容；你也可以创建自己的歌单。")
            } actions: {
              if library.capabilities.contains(.playlistEditing) {
                Button("新建歌单") { showsCreatePlaylist = true }.buttonStyle(.borderedProminent)
              }
            }
          }
          PlayerDockScrollFooter()
        }
      default:
        EmptyView()
      }
    }.navigationTitle("资料库").refreshable { await library.refresh() }.toolbar {
      if sources.activeServer?.sourceType == .local {
        ToolbarItem(placement: .topBarLeading) {
          Menu {
            Button {
              showsFileImporter = true
            } label: {
              Label("选择歌曲文件", systemImage: "music.note")
            }
            Button {
              showsFolderImporter = true
            } label: {
              Label("选择 NAS 或本地文件夹", systemImage: "folder.badge.plus")
            }
          } label: {
            if isImporting {
              ProgressView().accessibilityLabel("正在导入音乐")
            } else {
              Label("导入音乐", systemImage: "square.and.arrow.down")
            }
          }
          .disabled(isImporting)
        }
      }
      if segment == 1 && library.capabilities.contains(.playlistEditing) {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showsCreatePlaylist = true
          } label: {
            Image(systemName: "plus")
          }
        }
      }
    }
    .onAppear { restoreSegment() }
    .onChange(of: segment) { _, value in persistSegment(value) }
    .onChange(of: sources.activeServerID) { _, _ in restoreSegment() }
    .fileImporter(
      isPresented: $showsFileImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true
    ) { result in
      importFiles(result)
    }
    .fileImporter(
      isPresented: $showsFolderImporter, allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      importFolder(result)
    }
    .sheet(isPresented: $showsCreatePlaylist) { NewPlaylistSheet() }
    .alert(
      "本机音乐",
      isPresented: Binding(
        get: { importMessage != nil }, set: { if !$0 { importMessage = nil } }
      )
    ) {
      Button("好") { importMessage = nil }
    } message: {
      Text(importMessage ?? "")
    }
  }

  private var segmentStorageKey: String {
    "library.segment.\(sources.activeServerID?.uuidString.lowercased() ?? "none")"
  }

  private func restoreSegment() {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-visual-audit-favorites") {
        segment = 1
        return
      }
      if ProcessInfo.processInfo.arguments.contains("-visual-audit-library") {
        segment = 0
        return
      }
    #endif
    segment = UserDefaults.standard.object(forKey: segmentStorageKey) as? Int ?? 0
  }

  private func persistSegment(_ value: Int) {
    UserDefaults.standard.set(value, forKey: segmentStorageKey)
  }

  private func importFiles(_ result: Result<[URL], any Error>) {
    switch result {
    case .failure(let error):
      importMessage = MusicSourceError.map(error).localizedDescription
    case .success(let urls):
      Task {
        isImporting = true
        defer { isImporting = false }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer {
          for url in scoped {
            url.stopAccessingSecurityScopedResource()
          }
        }
        do {
          let report = try await sources.importLocalFilesDetailed(urls)
          await library.refresh()
          importMessage = report.summary
        } catch { importMessage = MusicSourceError.map(error).localizedDescription }
      }
    }
  }

  private func importFolder(_ result: Result<[URL], any Error>) {
    switch result {
    case .failure(let error):
      importMessage = MusicSourceError.map(error).localizedDescription
    case .success(let urls):
      guard let url = urls.first else {
        importMessage = "没有选择文件夹。"
        return
      }
      Task {
        isImporting = true
        defer { isImporting = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
          let report = try await sources.importLocalFolder(url)
          await library.refresh()
          importMessage = report.summary
          if let first = report.availableTracks.first {
            await playback.play(first, queue: report.availableTracks)
          }
        } catch { importMessage = MusicSourceError.map(error).localizedDescription }
      }
    }
  }
}

private struct NewPlaylistSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(UnifiedLibraryStore.self) private var library
  @State private var name = ""
  @State private var errorMessage: String?
  @State private var isCreating = false

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("歌单名称", text: $name)
            .textInputAutocapitalization(.sentences)
            .submitLabel(.done)
        } footer: {
          Text("创建后可以从歌曲的长按菜单添加内容。")
        }
        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("新建歌单")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }.disabled(isCreating)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isCreating ? "正在创建…" : "创建") { create() }
            .disabled(trimmedName.isEmpty || isCreating)
        }
      }
    }
    .presentationDetents([.height(300)])
    .interactiveDismissDisabled(isCreating)
  }

  private func create() {
    isCreating = true
    errorMessage = nil
    Task {
      do {
        _ = try await library.createPlaylist(name: trimmedName)
        dismiss()
      } catch {
        errorMessage = MusicSourceError.map(error).localizedDescription
        isCreating = false
      }
    }
  }
}

struct UniversalSearchView: View {
  @Environment(UnifiedLibraryStore.self) private var library
  @State private var query = ""
  @State private var submittedQuery = ""
  private var normalizedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private var showsSubmittedResults: Bool {
    !submittedQuery.isEmpty
      && submittedQuery.localizedCaseInsensitiveCompare(normalizedQuery) == .orderedSame
  }
  var body: some View {
    List {
      if query.isEmpty && !library.searchHistory.isEmpty {
        Section {
          ForEach(library.searchHistory, id: \.self) { value in
            Button(value) {
              query = value
              submitSearch(value)
            }
          }
        } header: {
          HStack {
            Text("最近搜索")
            Spacer()
            Button("清除") { Task { await library.clearSearchHistory() } }.font(.caption)
          }
        }
      }
      if showsSubmittedResults && library.isSearching {
        ProgressView().frame(maxWidth: .infinity)
      }
      if showsSubmittedResults && !library.searchResult.artists.isEmpty {
        Section("艺人") {
          ForEach(library.searchResult.artists) { x in
            NavigationLink(x.name) { ArtistDetailView(artist: x) }
          }
        }
      }
      if showsSubmittedResults && !library.searchResult.albums.isEmpty {
        Section("专辑") {
          ForEach(library.searchResult.albums) { x in
            NavigationLink {
              AlbumDetailView(album: x)
            } label: {
              MediaRow(
                artwork: x.artworkURL, title: x.title, subtitle: x.artistName,
                cacheIdentity: MusicResourceOwner.album(x.identity.remoteID))
            }
          }
        }
      }
      if showsSubmittedResults && !library.searchResult.tracks.isEmpty {
        Section("歌曲") {
          TrackRows(tracks: library.searchResult.tracks, continuationQueue: library.tracks)
        }
      }
      if showsSubmittedResults && !library.searchResult.playlists.isEmpty {
        Section("歌单") {
          ForEach(library.searchResult.playlists) { x in
            NavigationLink {
              PlaylistDetailView(playlist: x)
            } label: {
              MediaRow(
                artwork: x.artworkURL, title: x.name, subtitle: "\(x.trackCount) 首歌曲",
                cacheIdentity: MusicResourceOwner.playlist(x.identity.remoteID))
            }
          }
        }
      }
      if showsSubmittedResults && !library.isSearching && library.searchResult == .empty {
        ContentUnavailableView.search(text: submittedQuery)
      }
      PlayerDockScrollFooter()
    }
    .navigationTitle("搜索")
    .searchable(text: $query, prompt: "歌曲、专辑、艺人或歌单")
    .submitLabel(.search)
    .onSubmit(of: .search) { submitSearch(query) }
  }

  private func submitSearch(_ value: String) {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    query = normalized
    submittedQuery = normalized
    Task { await library.search(normalized) }
  }
}

private struct TrackCollectionView: View {
  let tracks: [MusicTrack]
  var body: some View {
    List {
      TrackRows(tracks: tracks)
      PlayerDockScrollFooter()
    }
  }
}
private struct TrackRows: View {
  @Environment(UnifiedLibraryStore.self) private var library
  @Environment(UnifiedPlaybackController.self) private var playback
  @State private var favoriteOperations: Set<UUID> = []
  @State private var favoriteFeedback = 0
  let tracks: [MusicTrack]
  let continuationQueue: [MusicTrack]
  init(tracks: [MusicTrack], continuationQueue: [MusicTrack] = []) {
    self.tracks = tracks
    self.continuationQueue = continuationQueue
  }
  var body: some View {
    ForEach(tracks) { track in
      let isFavorite = library.isFavorite(track)
      HStack(spacing: 0) {
        Button {
          Task {
            await playback.play(track, queue: tracks, continuingWith: continuationQueue)
          }
        } label: {
          MediaRow(
            artwork: track.artworkURL
              ?? library.artworkURL(for: .track(track), size: .init(width: 96, height: 96)),
            title: track.title, subtitle: track.artistName,
            cacheIdentity: track.albumRemoteID.map(MusicResourceOwner.album)
              ?? MusicResourceOwner.track(track.identity.remoteID))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)

        if library.capabilities.contains(.favorites) {
          Button {
            updateFavorite(track, isFavorite: isFavorite)
          } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
              .font(.body.weight(.semibold))
              .foregroundStyle(isFavorite ? Color.favoriteRed : .secondary)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(favoriteOperations.contains(track.id))
          .opacity(favoriteOperations.contains(track.id) ? 0.45 : 1)
          .accessibilityLabel(
            isFavorite ? String(localized: "取消喜欢歌曲") : String(localized: "喜欢歌曲"))
          .accessibilityValue(
            isFavorite ? String(localized: "已喜欢") : String(localized: "未喜欢"))
        } else if isFavorite {
          Image(systemName: "heart.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.favoriteRed)
            .frame(width: 44, height: 44)
            .accessibilityLabel("已喜欢")
        }
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        if library.capabilities.contains(.favorites) {
          Button {
            updateFavorite(track, isFavorite: isFavorite)
          } label: {
            Label(
              isFavorite ? "取消喜欢" : "喜欢",
              systemImage: isFavorite ? "heart.slash.fill" : "heart.fill")
          }
          .tint(isFavorite ? .gray : Color.favoriteRed)
          .disabled(favoriteOperations.contains(track.id))
        }
      }
      .contentShape(.contextMenuPreview, Rectangle())
      .contextMenu {
        Section("加入歌曲列表") {
          if !library.capabilities.contains(.playlistEditing) {
            Button("当前音乐源不支持编辑歌曲列表") {}
              .disabled(true)
          } else if editablePlaylists.isEmpty {
            Button("暂无可加入的歌曲列表") {}
              .disabled(true)
          } else {
            ForEach(editablePlaylists) { playlist in
              Button {
                Task { await library.add(track, to: playlist) }
              } label: {
                Label("加入“\(playlist.name)”", systemImage: "text.badge.plus")
              }
            }
          }
        }
      }
    }
    .sensoryFeedback(.success, trigger: favoriteFeedback)
  }

  private var editablePlaylists: [MusicPlaylist] {
    library.playlists.filter(\.isEditable)
  }

  private func updateFavorite(_ track: MusicTrack, isFavorite: Bool) {
    Task {
      guard !favoriteOperations.contains(track.id) else { return }
      favoriteOperations.insert(track.id)
      defer { favoriteOperations.remove(track.id) }
      let desired = !isFavorite
      if await library.setFavorite(.track(track), isFavorite: desired), desired {
        favoriteFeedback &+= 1
      }
    }
  }
}

private struct MediaRow: View {
  let artwork: URL?
  let title: String
  let subtitle: String
  var cacheIdentity: String? = nil
  var body: some View {
    HStack(spacing: 12) {
      CoverArtworkView(url: artwork, cornerRadius: 7, cacheIdentity: cacheIdentity)
        .frame(width: 48, height: 48)
      VStack(alignment: .leading) {
        Text(title).lineLimit(1)
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
    }
  }
}

private struct FavoriteCollectionRow: View {
  let count: Int

  var body: some View {
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(
            LinearGradient(
              colors: [Color.accentColor.opacity(0.95), Color.orange.opacity(0.72)],
              startPoint: .topLeading, endPoint: .bottomTrailing))
        Circle().fill(.thinMaterial).frame(width: 32, height: 32)
        Image(systemName: "heart.fill")
          .font(.body.weight(.semibold))
          .foregroundStyle(Color.favoriteRed)
      }
      .frame(width: 48, height: 48)
      VStack(alignment: .leading, spacing: 3) {
        Text("喜欢的歌曲").fontWeight(.semibold)
        Text(count == 0 ? "左滑歌曲即可收藏" : "\(count) 首歌曲")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("喜欢的歌曲，\(count) 首歌曲")
  }
}

private struct FavoriteTracksView: View {
  @Environment(UnifiedLibraryStore.self) private var library

  var body: some View {
    Group {
      if library.favoriteTracks.isEmpty {
        ContentUnavailableView {
          Label("还没有喜欢的歌曲", systemImage: "heart")
        } description: {
          Text("在歌曲列表点按红心，或向左滑动并选择“喜欢”。")
        }
      } else {
        List {
          TrackRows(tracks: library.favoriteTracks)
          PlayerDockScrollFooter()
        }
      }
    }
    .navigationTitle("喜欢的歌曲")
  }
}

extension Color {
  fileprivate static let favoriteRed = Color(
    UIColor { traits in
      if traits.userInterfaceStyle == .dark {
        return UIColor(red: 1, green: 0.4, blue: 0.52, alpha: 1)
      }
      return UIColor(red: 0.85, green: 0.18, blue: 0.33, alpha: 1)
    })
}

private struct AlbumDetailView: View {
  @Environment(UnifiedLibraryStore.self) private var library
  let album: MusicAlbum
  @State private var detail: MusicAlbumDetail?
  @State private var errorMessage: String?
  @State private var isFavorite: Bool

  init(album: MusicAlbum) {
    self.album = album
    _isFavorite = State(initialValue: album.favoriteState == .favorite)
  }

  var body: some View {
    Group {
      if let detail {
        List {
          Section {
            VStack {
              CoverArtworkView(
                url: album.artworkURL, cornerRadius: 18,
                cacheIdentity: MusicResourceOwner.album(album.identity.remoteID)
              ).frame(width: 220, height: 220)
              Text(album.artistName).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
          }
          TrackRows(tracks: detail.tracks)
          PlayerDockScrollFooter()
        }
      } else if let errorMessage {
        DetailFailureView(message: errorMessage) { Task { await load() } }
      } else {
        ProgressView("正在载入专辑…")
      }
    }
    .navigationTitle(album.title)
    .task { if detail == nil, errorMessage == nil { await load() } }
    .toolbar {
      if library.capabilities.contains(.favorites) {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            let desired = !isFavorite
            Task {
              if await library.setFavorite(.album(album), isFavorite: desired) {
                isFavorite = desired
              }
            }
          } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
          }.accessibilityLabel(
            isFavorite ? String(localized: "取消收藏专辑") : String(localized: "收藏专辑"))
        }
      }
    }
  }

  private func load() async {
    errorMessage = nil
    do { detail = try await library.albumDetail(id: album.identity.remoteID) } catch {
      errorMessage = MusicSourceError.map(error).localizedDescription
    }
  }
}
private struct ArtistDetailView: View {
  @Environment(UnifiedLibraryStore.self) private var library
  let artist: MusicArtist
  @State private var detail: MusicArtistDetail?
  @State private var errorMessage: String?
  @State private var isFavorite: Bool

  init(artist: MusicArtist) {
    self.artist = artist
    _isFavorite = State(initialValue: artist.favoriteState == .favorite)
  }

  var body: some View {
    Group {
      if let detail {
        List {
          if let bio = detail.artist.biography { Section { Text(bio) } }
          Section("专辑") {
            ForEach(detail.albums) { album in
              NavigationLink {
                AlbumDetailView(album: album)
              } label: {
                MediaRow(
                  artwork: album.artworkURL, title: album.title, subtitle: album.artistName,
                  cacheIdentity: MusicResourceOwner.album(album.identity.remoteID))
              }
            }
          }
          Section("热门歌曲") { TrackRows(tracks: detail.topTracks) }
          PlayerDockScrollFooter()
        }
      } else if let errorMessage {
        DetailFailureView(message: errorMessage) { Task { await load() } }
      } else {
        ProgressView("正在载入艺人…")
      }
    }
    .navigationTitle(artist.name)
    .task { if detail == nil, errorMessage == nil { await load() } }
    .toolbar {
      if library.capabilities.contains(.favorites) {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            let desired = !isFavorite
            Task {
              if await library.setFavorite(.artist(artist), isFavorite: desired) {
                isFavorite = desired
              }
            }
          } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
          }.accessibilityLabel(
            isFavorite ? String(localized: "取消收藏艺人") : String(localized: "收藏艺人"))
        }
      }
    }
  }

  private func load() async {
    errorMessage = nil
    do { detail = try await library.artistDetail(id: artist.identity.remoteID) } catch {
      errorMessage = MusicSourceError.map(error).localizedDescription
    }
  }
}
private struct PlaylistDetailView: View {
  @Environment(UnifiedLibraryStore.self) private var library
  @Environment(\.dismiss) private var dismiss
  let playlist: MusicPlaylist
  @State private var detail: MusicPlaylistDetail?
  @State private var showsRename = false
  @State private var newName = ""
  @State private var displayedName: String
  @State private var errorMessage: String?

  init(playlist: MusicPlaylist) {
    self.playlist = playlist
    _displayedName = State(initialValue: playlist.name)
  }

  var body: some View {
    Group {
      if let detail {
        List {
          ForEach(Array(detail.tracks.enumerated()), id: \.element.id) { _, track in
            TrackRows(tracks: [track])
          }.onDelete(perform: remove)
          PlayerDockScrollFooter()
        }
      } else if let errorMessage {
        DetailFailureView(message: errorMessage) { Task { await reload() } }
      } else {
        ProgressView("正在载入歌单…")
      }
    }
    .navigationTitle(displayedName)
    .task { if detail == nil, errorMessage == nil { await reload() } }
    .toolbar {
      if playlist.isEditable && library.capabilities.contains(.playlistEditing) {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button("重命名") {
              newName = displayedName
              showsRename = true
            }
            Button("删除歌单", role: .destructive) { deletePlaylist() }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
        }
      }
    }
    .alert("重命名歌单", isPresented: $showsRename) {
      TextField("歌单名称", text: $newName)
      Button("保存") { renamePlaylist() }
      Button("取消", role: .cancel) {}
    }
  }

  private func reload() async {
    errorMessage = nil
    do { detail = try await library.playlistDetail(id: playlist.identity.remoteID) } catch {
      errorMessage = MusicSourceError.map(error).localizedDescription
    }
  }

  private func remove(_ offsets: IndexSet) {
    Task {
      do {
        try await library.removeFromPlaylist(
          id: playlist.identity.remoteID, indexes: Array(offsets))
        await reload()
      } catch {
        detail = nil
        errorMessage = MusicSourceError.map(error).localizedDescription
      }
    }
  }

  private func renamePlaylist() {
    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    Task {
      do {
        try await library.renamePlaylist(id: playlist.identity.remoteID, name: name)
        displayedName = name
        await reload()
      } catch {
        detail = nil
        errorMessage = MusicSourceError.map(error).localizedDescription
      }
    }
  }

  private func deletePlaylist() {
    Task {
      do {
        try await library.deletePlaylist(id: playlist.identity.remoteID)
        dismiss()
      } catch {
        detail = nil
        errorMessage = MusicSourceError.map(error).localizedDescription
      }
    }
  }
}

private struct DetailFailureView: View {
  let message: String
  let retry: () -> Void
  var body: some View {
    ContentUnavailableView {
      Label("无法载入", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("重试", action: retry).buttonStyle(.borderedProminent)
    }
  }
}

struct UnifiedPlayerView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(UnifiedPlaybackController.self) private var playback
  @Environment(UnifiedLibraryStore.self) private var library
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var lyrics: MusicLyrics?
  @State private var showsLyrics = false
  @State private var explicitlyShowsStage = false

  var body: some View {
    GeometryReader { proxy in
      let isLandscape = proxy.size.width > proxy.size.height
      if isLandscape || explicitlyShowsStage {
        ImmersiveVisualStage(
          lyrics: lyrics, isLyricsOnly: $showsLyrics, onDismiss: { dismiss() },
          onExitStage: {
            if explicitlyShowsStage { explicitlyShowsStage = false } else { dismiss() }
          }
        )
        .ignoresSafeArea(.all)
        .transition(.opacity)
      } else {
        NavigationStack {
          PlayerPortraitContent(
            lyrics: lyrics, showsLyrics: $showsLyrics,
            showStage: {
              withAnimation(reduceMotion ? .linear(duration: 0.1) : .easeInOut(duration: 0.42)) {
                explicitlyShowsStage = true
              }
            }
          )
          .toolbarBackground(.hidden, for: .navigationBar)
          .toolbar {
            ToolbarItem(placement: .topBarLeading) {
              Button {
                dismiss()
              } label: {
                Image(systemName: "chevron.down").frame(width: 44, height: 44)
              }
              .accessibilityLabel("关闭正在播放")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
              Button {
                withAnimation(reduceMotion ? .linear(duration: 0.1) : .easeInOut(duration: 0.35)) {
                  showsLyrics.toggle()
                }
              } label: {
                Image(systemName: showsLyrics ? "square.stack.fill" : "quote.bubble")
                  .frame(width: 44, height: 44)
              }
              .accessibilityLabel(
                showsLyrics ? String(localized: "显示封面") : String(localized: "显示全屏歌词"))
              NavigationLink {
                UnifiedQueueView()
              } label: {
                Image(systemName: "list.bullet").frame(width: 44, height: 44)
              }
              .accessibilityLabel("播放队列")
            }
          }
          .navigationTitle("正在播放")
          .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .transition(.opacity)
      }
    }
    .background(Color(red: 0.055, green: 0.045, blue: 0.13).ignoresSafeArea())
    .task(id: playback.currentTrack?.id) {
      guard let track = playback.currentTrack else {
        lyrics = nil
        return
      }
      lyrics = try? await library.lyrics(for: track)
    }
  }
}

private struct PlayerPortraitContent: View {
  @Environment(UnifiedPlaybackController.self) private var playback
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let lyrics: MusicLyrics?
  @Binding var showsLyrics: Bool
  let showStage: () -> Void

  var body: some View {
    ZStack {
      if let track = playback.currentTrack {
        PlayerFullscreenArtworkView(track: track)
      } else {
        GeometryReader { proxy in
          CoverArtworkView(url: nil, cornerRadius: 0, maximumPixelSize: 1_536)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
      }

      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.40), location: 0),
          .init(color: .black.opacity(showsLyrics ? 0.24 : 0), location: 0.22),
          .init(color: .black.opacity(showsLyrics ? 0.16 : 0), location: 0.52),
          .init(color: .black.opacity(0.68), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
      .allowsHitTesting(false)

      VStack(spacing: 18) {
        if showsLyrics {
          SyncedLyricsView(lyrics: lyrics, onReturnToArtwork: { showsLyrics = false })
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
        } else {
          Spacer(minLength: 180)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text(playback.currentTrack?.title ?? "未在播放")
            .font(.title2.bold()).lineLimit(2)
          Text(playback.currentTrack?.artistName ?? "")
            .font(.body.weight(.medium)).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
        }
        .frame(maxWidth: 560, alignment: .leading)

        PlayerProgressSlider()
        HStack {
          Text(DurationFormatter.string(from: playback.currentTime))
          Spacer()
          Text(
            "-\(DurationFormatter.string(from: max(playback.duration - playback.currentTime, 0)))")
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.76))

        HStack(spacing: 36) {
          control("backward.fill", label: "上一首", size: 56) {
            Task { await playback.playPrevious() }
          }
          control(
            playback.isPlaybackRequested ? "pause.fill" : "play.fill",
            label: playback.isPlaybackRequested ? "暂停" : "播放",
            size: 72
          ) { playback.togglePlayback() }
          control("forward.fill", label: "下一首", size: 56) {
            Task { await playback.playNext() }
          }
        }

        HStack(spacing: 36) {
          Button {
            playback.togglePlaybackOrder()
          } label: {
            Image(systemName: playback.playbackOrder.icon)
              .font(.title3.weight(.semibold))
              .frame(width: 56, height: 48)
              .contentShape(.interaction, Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("当前\(playback.playbackOrder.title)，切换播放顺序")

          Button(action: showStage) {
            Image(systemName: "sparkles.rectangle.stack")
              .font(.title3.weight(.semibold))
              .frame(width: 56, height: 48)
              .contentShape(.interaction, Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("视觉舞台")
        }
        .foregroundStyle(Color(red: 0.72, green: 0.62, blue: 1))
      }
      .frame(maxWidth: 560)
      .padding(.horizontal, 24)
      .padding(.bottom, 18)
    }
    .foregroundStyle(.white)
  }

  private func control(
    _ icon: String, label: LocalizedStringKey, size: CGFloat, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: size == 72 ? 29 : 21, weight: .semibold))
        .frame(width: size, height: size)
        .background(size == 72 ? Color.white : Color.white.opacity(0.10), in: Circle())
        .foregroundStyle(size == 72 ? Color(red: 0.10, green: 0.08, blue: 0.22) : .white)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(label))
  }
}

private struct PlayerProgressSlider: View {
  @Environment(UnifiedPlaybackController.self) private var playback

  private var progress: CGFloat {
    CGFloat(min(max(playback.currentTime / max(playback.duration, 1), 0), 1))
  }

  var body: some View {
    GeometryReader { proxy in
      let trackWidth = max(proxy.size.width, 1)
      let thumbX = min(max(trackWidth * progress, 6), trackWidth - 6)
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.white.opacity(0.28))
          .frame(height: 4)
        Capsule()
          .fill(.white.opacity(0.90))
          .frame(width: max(trackWidth * progress, 2), height: 4)
        Circle()
          .fill(.white)
          .frame(width: 12, height: 12)
          .offset(x: thumbX - 6)
          .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in seek(at: value.location.x, width: trackWidth) }
      )
    }
    .frame(height: 44)
    .accessibilityElement()
    .accessibilityLabel("播放进度")
    .accessibilityValue(
      "\(DurationFormatter.string(from: playback.currentTime)) / \(DurationFormatter.string(from: playback.duration))"
    )
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        playback.seek(to: min(playback.currentTime + 15, playback.duration))
      case .decrement:
        playback.seek(to: max(playback.currentTime - 15, 0))
      @unknown default:
        break
      }
    }
  }

  private func seek(at x: CGFloat, width: CGFloat) {
    playback.seek(to: Double(min(max(x / max(width, 1), 0), 1)) * playback.duration)
  }
}

private struct PlayerFullscreenArtworkView: View {
  @Environment(UnifiedLibraryStore.self) private var library
  let track: MusicTrack

  private var editablePlaylists: [MusicPlaylist] {
    library.playlists.filter(\.isEditable)
  }

  var body: some View {
    GeometryReader { proxy in
      CoverArtworkView(
        url: track.artworkURL, cornerRadius: 0,
        cacheIdentity: track.albumRemoteID.map { "album:\($0)" }
          ?? "track:\(track.identity.remoteID)",
        maximumPixelSize: 1_536)
        .frame(width: proxy.size.width, height: proxy.size.height)
        .clipped()
    }
    .ignoresSafeArea()
      .contentShape(.contextMenuPreview, Rectangle())
      .contextMenu {
        Section("加入歌曲列表") {
          if !library.capabilities.contains(.playlistEditing) {
            Button("当前音乐源不支持编辑歌曲列表") {}
              .disabled(true)
          } else if editablePlaylists.isEmpty {
            Button("暂无可加入的歌曲列表") {}
              .disabled(true)
          } else {
            playlistActions
          }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("《\(track.title)》全屏封面")
      .accessibilityHint("长按全屏封面可加入歌曲列表")
      .accessibilityActions {
        playlistActions
      }
  }

  @ViewBuilder
  private var playlistActions: some View {
    ForEach(editablePlaylists) { playlist in
      Button {
        Task { await library.add(track, to: playlist) }
      } label: {
        Label("加入“\(playlist.name)”", systemImage: "text.badge.plus")
      }
    }
  }
}

struct SyncedLyricsView: View {
  @Environment(UnifiedPlaybackController.self) private var playback
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let lyrics: MusicLyrics?
  let onReturnToArtwork: (() -> Void)?
  @State private var followsCurrentLine = true
  @State private var resumeTask: Task<Void, Never>?

  init(lyrics: MusicLyrics?, onReturnToArtwork: (() -> Void)? = nil) {
    self.lyrics = lyrics
    self.onReturnToArtwork = onReturnToArtwork
  }

  private var activeIndex: Int? {
    guard let lyrics, lyrics.isSynced else { return nil }
    return lyrics.lines.lastIndex { ($0.time ?? .infinity) <= playback.currentTime }
  }
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(showsIndicators: false) {
        if let lyrics {
          LazyVStack(alignment: .leading, spacing: 18) {
            if !lyrics.isSynced {
              Label("此歌词未包含时间信息", systemImage: "clock.badge.questionmark")
                .font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.58))
                .padding(.bottom, 14)
            }
            ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
              LyricLineButton(line: line, isActive: index == activeIndex).id(index)
            }
          }.padding(.horizontal, 24).padding(.vertical, 110)
        } else {
          ContentUnavailableView {
            Label("这首歌还没有歌词", systemImage: "quote.bubble")
          } description: {
            Text("当前音乐源没有提供这首歌的歌词。")
          } actions: {
            if let onReturnToArtwork { Button("返回封面", action: onReturnToArtwork) }
          }
        }
      }
      .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in pauseFollowing() })
      .onChange(of: activeIndex) { _, index in
        guard followsCurrentLine, let index else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
          proxy.scrollTo(index, anchor: .center)
        }
      }
      .onAppear {
        if let activeIndex { proxy.scrollTo(activeIndex, anchor: .center) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityLabel(
      lyrics?.isSynced == true ? String(localized: "同步滚动歌词") : String(localized: "歌词"))
    .onDisappear { resumeTask?.cancel() }
  }

  private func pauseFollowing() {
    followsCurrentLine = false
    resumeTask?.cancel()
    resumeTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      followsCurrentLine = true
    }
  }
}

private struct LyricLineButton: View {
  @Environment(UnifiedPlaybackController.self) private var playback
  let line: MusicLyrics.Line
  let isActive: Bool
  var body: some View {
    Button {
      if let time = line.time { playback.seek(to: time) }
    } label: {
      Text(line.text.isEmpty ? "·" : line.text)
        .font(isActive ? .title2.bold() : .title2.weight(.semibold))
        .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.42)))
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    .buttonStyle(.plain).disabled(line.time == nil)
    .accessibilityAddTraits(isActive ? .isSelected : [])
  }
}

private struct UnifiedQueueView: View {
  @Environment(UnifiedPlaybackController.self) private var playback
  var body: some View {
    List {
      ForEach(playback.queue) { track in
        MediaRow(
          artwork: track.artworkURL, title: track.title, subtitle: track.artistName,
          cacheIdentity: track.albumRemoteID.map(MusicResourceOwner.album)
            ?? MusicResourceOwner.track(track.identity.remoteID))
      }.onDelete(perform: playback.remove).onMove(perform: playback.move)
    }.navigationTitle("播放队列").toolbar { EditButton() }
  }
}

private struct SourceToolbarModifier: ViewModifier {
  @Environment(MusicSourceStore.self) private var sources
  func body(content: Content) -> some View {
    content.toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink {
          MusicSourcesView()
        } label: {
          Image(systemName: "externaldrive.badge.wifi")
        }
      }
    }
  }
}
extension View {
  fileprivate func sourceToolbar() -> some View { modifier(SourceToolbarModifier()) }
}
