import CarPlay
import Foundation
import OSLog
import UIKit

extension Notification.Name {
  static let musicPlaybackStateDidChange = Notification.Name(
    "com.himhuu.music.playback-state-did-change")
  static let carPlayRuntimeDidChange = Notification.Name(
    "com.himhuu.music.carplay-runtime-did-change")
}

struct CarPlayRuntimeContext {
  let library: UnifiedLibraryStore
  let playback: UnifiedPlaybackController
  let serverID: UUID
  let artworkFetcher: MusicArtworkFetcher
}

@MainActor
final class CarPlayRuntimeRegistry {
  static let shared = CarPlayRuntimeRegistry()

  private(set) var context: CarPlayRuntimeContext?

  func register(
    library: UnifiedLibraryStore,
    playback: UnifiedPlaybackController,
    serverID: UUID,
    artworkFetcher: MusicArtworkFetcher
  ) {
    register(
      CarPlayRuntimeContext(
        library: library,
        playback: playback,
        serverID: serverID,
        artworkFetcher: artworkFetcher))
  }

  func register(_ context: CarPlayRuntimeContext) {
    self.context = context
    notifyRuntimeDidChange()
  }

  /// Re-announces the current runtime, e.g. once a cold library load has produced content that
  /// CarPlay should now show.
  func notifyRuntimeDidChange() {
    NotificationCenter.default.post(name: .carPlayRuntimeDidChange, object: nil)
  }

  func unregister(playback: UnifiedPlaybackController) {
    guard context?.playback === playback else { return }
    context = nil
    NotificationCenter.default.post(name: .carPlayRuntimeDidChange, object: nil)
  }
}

enum CarPlayContentPolicy {
  static let homeSectionLimit = 3
  static let homeItemLimit = 4
  static let pageSize = 20

  static func curatedHomeSections(
    _ sections: [MusicSection],
    maximumSectionCount: Int = .max,
    maximumItemCount: Int = .max
  ) -> [MusicSection] {
    let sectionLimit = max(1, min(homeSectionLimit, maximumSectionCount))
    var remainingItems = max(1, maximumItemCount)
    var result: [MusicSection] = []

    for section in sections where !section.items.isEmpty {
      guard result.count < sectionLimit, remainingItems > 0 else { break }
      let count = min(homeItemLimit, remainingItems, section.items.count)
      result.append(
        MusicSection(
          id: section.id, title: section.title, kind: section.kind,
          items: Array(section.items.prefix(count))))
      remainingItems -= count
    }
    return result
  }
}

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
  @preconcurrency CPNowPlayingTemplateObserver
{
  private static let logger = Logger(subsystem: "com.himhuu.music", category: "CarPlay")

  private weak var interfaceController: CPInterfaceController?
  private var context: CarPlayRuntimeContext?
  private var connectionID = UUID()
  private var runtimeObserver: NSObjectProtocol?
  private var playbackObserver: NSObjectProtocol?
  private var artworkTasks: [Task<Void, Never>] = []
  private var trackItems: [UUID: [CPListItem]] = [:]
  private var shuffleButton: CPNowPlayingShuffleButton?
  private var hasPresentedLibraryContent = false
  private let placeholderArtwork = UIImage(named: "ArtworkPlaceholder")

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController
    connectionID = UUID()
    observeRuntime()
    configureNowPlayingTemplate()
    presentLoadingRoot()
    loadRuntimeAndPresent(connectionID: connectionID)
    Self.logger.info("CarPlay 场景已连接")
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    connectionID = UUID()
    hasPresentedLibraryContent = false
    removeObservers()
    cancelArtworkTasks()
    CPNowPlayingTemplate.shared.remove(self)
    self.interfaceController = nil
    context = nil
    trackItems = [:]
    shuffleButton = nil
    Self.logger.info("CarPlay 场景已断开")
  }

  func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    guard let context, !context.playback.queue.isEmpty else { return }
    let template = makeTrackPage(
      title: String(localized: "接下来播放"), tracks: context.playback.queue, startIndex: 0)
    push(template)
  }

  func nowPlayingTemplateAlbumArtistButtonTapped(
    _ nowPlayingTemplate: CPNowPlayingTemplate
  ) {
    guard let track = context?.playback.currentTrack, let albumID = track.albumRemoteID else {
      return
    }
    showAlbum(id: albumID, fallbackTitle: track.albumTitle ?? String(localized: "专辑"))
  }

  private func observeRuntime() {
    removeObservers()
    runtimeObserver = NotificationCenter.default.addObserver(
      forName: .carPlayRuntimeDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.loadRuntimeAndPresent(connectionID: self.connectionID)
      }
    }
    playbackObserver = NotificationCenter.default.addObserver(
      forName: .musicPlaybackStateDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.synchronizePlaybackPresentation() }
    }
  }

  private func removeObservers() {
    if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
    if let playbackObserver { NotificationCenter.default.removeObserver(playbackObserver) }
    runtimeObserver = nil
    playbackObserver = nil
  }

  private func loadRuntimeAndPresent(connectionID: UUID) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if self.adoptRuntimeIfAvailable(connectionID: connectionID) { return }
      // CarPlay can be the only connected scene — the car launches the app while the phone
      // stays locked and SwiftUI never creates a window — so build the runtime here instead of
      // waiting for a phone UI that may never appear.
      await MusicRuntimeCoordinator.shared.prepareRuntimeIfPossible()
      guard self.connectionID == connectionID, self.interfaceController != nil else { return }
      if self.adoptRuntimeIfAvailable(connectionID: connectionID) { return }
      self.presentUnavailableRoot()
    }
  }

  /// Returns true when a runtime was adopted and presented. Presenting again after the library
  /// has content upgrades the placeholder root, but an already populated root is left alone so
  /// a spurious notification cannot throw away the driver's navigation.
  private func adoptRuntimeIfAvailable(connectionID: UUID) -> Bool {
    guard self.connectionID == connectionID, interfaceController != nil,
      let context = CarPlayRuntimeRegistry.shared.context
    else { return false }
    let isSameRuntime = self.context?.playback === context.playback
    guard !isSameRuntime || !hasPresentedLibraryContent else { return true }
    self.context = context
    presentLibraryRoot()
    return true
  }

  private func presentLoadingRoot() {
    let template = CPListTemplate(title: String(localized: "散帅播放器"), sections: [])
    template.emptyViewTitleVariants = [String(localized: "正在整理音乐库…")]
    template.emptyViewSubtitleVariants = [String(localized: "请稍候")]
    if #available(iOS 18.4, *) {
      template.showsSpinnerWhileEmpty = true
    }
    setRoot(template, animated: false)
  }

  private func presentUnavailableRoot() {
    let item = CPListItem(
      text: String(localized: "尚未配置音乐源"),
      detailText: String(localized: "请在停车后打开 iPhone 完成设置"),
      image: UIImage(systemName: "iphone.badge.exclamationmark"))
    item.isEnabled = false
    let template = CPListTemplate(
      title: String(localized: "散帅播放器"), sections: [CPListSection(items: [item])])
    setRoot(template, animated: true)
  }

  private func presentLibraryRoot() {
    guard let context else {
      presentUnavailableRoot()
      return
    }
    cancelArtworkTasks()
    trackItems = [:]

    let maximumTabs = max(1, CPTabBarTemplate.maximumTabCount)
    let listen = makeListenTemplate(context: context)
    let library = makeLibraryTemplate(context: context, includesPlaylists: maximumTabs < 3)
    var templates: [CPTemplate] = [listen]
    if maximumTabs >= 2 { templates.append(library) }
    if maximumTabs >= 3 { templates.append(makePlaylistsTemplate(context: context)) }

    if templates.count == 1 {
      setRoot(listen, animated: true)
    } else {
      setRoot(CPTabBarTemplate(templates: templates), animated: true)
    }
    hasPresentedLibraryContent = !context.library.tracks.isEmpty
      || !context.library.albums.isEmpty || !context.library.playlists.isEmpty
    synchronizePlaybackPresentation()
  }

  private func makeListenTemplate(context: CarPlayRuntimeContext) -> CPListTemplate {
    var curated = CarPlayContentPolicy.curatedHomeSections(
      context.library.homeSections,
      maximumSectionCount: Int(CPListTemplate.maximumSectionCount),
      maximumItemCount: Int(CPListTemplate.maximumItemCount))
    if curated.isEmpty, !context.library.tracks.isEmpty {
      curated = [
        MusicSection(
          id: "carplay-songs", title: String(localized: "歌曲"), kind: .recentlyAdded,
          items: Array(context.library.tracks.prefix(CarPlayContentPolicy.homeItemLimit)).map(
            MusicSectionItem.track))
      ]
    }

    let sections = curated.map { section in
      let sectionTracks = section.items.compactMap { item -> MusicTrack? in
        guard case .track(let track) = item else { return nil }
        return track
      }
      let items = section.items.compactMap {
        makeHomeItem(
          $0, trackQueue: sectionTracks.isEmpty ? context.library.tracks : sectionTracks)
      }
      return CPListSection(items: items, header: section.title, sectionIndexTitle: nil)
    }
    let template = CPListTemplate(title: String(localized: "现在就听"), sections: sections)
    template.tabTitle = String(localized: "现在就听")
    template.tabImage = UIImage(systemName: "play.circle.fill")
    if sections.isEmpty {
      template.emptyViewTitleVariants = [String(localized: "音乐库暂时为空")]
      template.emptyViewSubtitleVariants = [
        context.library.errorMessage ?? String(localized: "连接恢复后可重试")
      ]
    }
    return template
  }

  private func makeLibraryTemplate(
    context: CarPlayRuntimeContext, includesPlaylists: Bool
  ) -> CPListTemplate {
    var items: [CPListItem] = [
      collectionItem(
        title: String(localized: "喜欢的歌曲"),
        detail: String(localized: "\(context.library.favoriteTracks.count) 首"),
        symbol: "heart.fill"
      ) { [weak self] in
        guard let self, let context = self.context else { return }
        self.push(
          self.makeTrackPage(
            title: String(localized: "喜欢的歌曲"), tracks: context.library.favoriteTracks,
            startIndex: 0))
      },
      collectionItem(
        title: String(localized: "专辑"),
        detail: String(localized: "\(context.library.albums.count) 张"),
        symbol: "square.stack.fill"
      ) { [weak self] in
        guard let self, let context = self.context else { return }
        self.push(self.makeAlbumPage(context.library.albums, startIndex: 0))
      },
      collectionItem(
        title: String(localized: "艺人"),
        detail: String(localized: "\(context.library.artists.count) 位"),
        symbol: "music.mic"
      ) { [weak self] in
        guard let self, let context = self.context else { return }
        self.push(self.makeArtistPage(context.library.artists, startIndex: 0))
      },
      collectionItem(
        title: String(localized: "全部歌曲"),
        detail: String(localized: "\(context.library.tracks.count) 首"),
        symbol: "music.note.list"
      ) { [weak self] in
        guard let self, let context = self.context else { return }
        self.push(
          self.makeTrackPage(
            title: String(localized: "全部歌曲"), tracks: context.library.tracks, startIndex: 0))
      },
    ]
    if includesPlaylists {
      items.append(
        collectionItem(
          title: String(localized: "歌单"),
          detail: String(localized: "\(context.library.playlists.count) 个"),
          symbol: "music.note.list"
        ) { [weak self] in
          guard let self, let context = self.context else { return }
          self.push(self.makePlaylistPage(context.library.playlists, startIndex: 0))
        })
    }

    let template = CPListTemplate(
      title: String(localized: "资料库"), sections: [CPListSection(items: items)])
    template.tabTitle = String(localized: "资料库")
    template.tabImage = UIImage(systemName: "rectangle.stack.fill")
    return template
  }

  private func makePlaylistsTemplate(context: CarPlayRuntimeContext) -> CPListTemplate {
    let template = makePlaylistPage(context.library.playlists, startIndex: 0)
    template.tabTitle = String(localized: "歌单")
    template.tabImage = UIImage(systemName: "music.note.list")
    return template
  }

  private func makeHomeItem(
    _ value: MusicSectionItem, trackQueue: [MusicTrack]
  ) -> CPListItem? {
    switch value {
    case .track(let track):
      return trackItem(track, queue: trackQueue)
    case .album(let album):
      let item = CPListItem(
        text: album.title, detailText: album.artistName, image: placeholderArtwork,
        accessoryImage: nil, accessoryType: .disclosureIndicator)
      item.handler = { [weak self] _, completion in
        self?.showAlbum(id: album.identity.remoteID, fallbackTitle: album.title)
        completion()
      }
      loadArtwork(
        url: album.artworkURL, cacheIdentity: "album:\(album.identity.remoteID)", into: item)
      return item
    case .artist(let artist):
      let item = CPListItem(
        text: artist.name, detailText: nil, image: placeholderArtwork, accessoryImage: nil,
        accessoryType: .disclosureIndicator)
      item.handler = { [weak self] _, completion in
        self?.showArtist(id: artist.identity.remoteID, fallbackTitle: artist.name)
        completion()
      }
      loadArtwork(
        url: artist.artworkURL, cacheIdentity: "artist:\(artist.identity.remoteID)", into: item)
      return item
    case .playlist(let playlist):
      return playlistItem(playlist)
    }
  }

  private func collectionItem(
    title: String, detail: String?, symbol: String, action: @escaping @MainActor () -> Void
  ) -> CPListItem {
    let item = CPListItem(
      text: title, detailText: detail, image: UIImage(systemName: symbol),
      accessoryImage: nil, accessoryType: .disclosureIndicator)
    item.handler = { _, completion in
      action()
      completion()
    }
    return item
  }

  private func trackItem(_ track: MusicTrack, queue: [MusicTrack]) -> CPListItem {
    let item = CPListItem(
      text: track.title, detailText: trackDetail(track), image: placeholderArtwork,
      accessoryImage: nil, accessoryType: .none)
    item.isExplicitContent = track.isExplicit
    item.isPlaying = context?.playback.currentTrack?.id == track.id
    item.playingIndicatorLocation = .trailing
    item.handler = { [weak self] _, completion in
      guard let self, let context = self.context else {
        completion()
        return
      }
      // `play` does not return until the asset is fully prepared, which on a cold transcode can
      // take far longer than CarPlay will keep a row spinning. Show Now Playing right away and
      // let it render the buffering state.
      Task { @MainActor in
        await context.playback.play(track, queue: queue)
        self.synchronizePlaybackPresentation()
      }
      self.push(CPNowPlayingTemplate.shared, completion: completion)
    }
    trackItems[track.id, default: []].append(item)
    loadArtwork(
      url: track.artworkURL,
      cacheIdentity: track.albumRemoteID.map { "album:\($0)" }
        ?? "track:\(track.identity.remoteID)",
      into: item)
    return item
  }

  private func playlistItem(_ playlist: MusicPlaylist) -> CPListItem {
    let item = CPListItem(
      text: playlist.name, detailText: String(localized: "\(playlist.trackCount) 首"),
      image: placeholderArtwork, accessoryImage: nil, accessoryType: .disclosureIndicator)
    item.handler = { [weak self] _, completion in
      self?.showPlaylist(id: playlist.identity.remoteID, fallbackTitle: playlist.name)
      completion()
    }
    loadArtwork(
      url: playlist.artworkURL, cacheIdentity: "playlist:\(playlist.identity.remoteID)", into: item)
    return item
  }

  private func makeTrackPage(
    title: String, tracks: [MusicTrack], startIndex: Int
  ) -> CPListTemplate {
    let end = min(tracks.count, startIndex + CarPlayContentPolicy.pageSize)
    var items =
      startIndex < end
      ? tracks[startIndex..<end].map { trackItem($0, queue: tracks) } : []
    if end < tracks.count {
      items.append(
        collectionItem(
          title: String(localized: "更多歌曲"),
          detail: String(localized: "继续浏览 \(tracks.count - end) 首"),
          symbol: "ellipsis.circle"
        ) { [weak self] in
          guard let self else { return }
          self.push(self.makeTrackPage(title: title, tracks: tracks, startIndex: end))
        })
    }
    let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
    if items.isEmpty {
      template.emptyViewTitleVariants = [String(localized: "这里还没有歌曲")]
      template.emptyViewSubtitleVariants = [String(localized: "连接恢复后可重试")]
    }
    return template
  }

  private func makeAlbumPage(_ albums: [MusicAlbum], startIndex: Int) -> CPListTemplate {
    let end = min(albums.count, startIndex + CarPlayContentPolicy.pageSize)
    var items: [CPListItem] = []
    if startIndex < end {
      for album in albums[startIndex..<end] {
        let item = CPListItem(
          text: album.title, detailText: album.artistName, image: placeholderArtwork,
          accessoryImage: nil, accessoryType: .disclosureIndicator)
        item.handler = { [weak self] _, completion in
          self?.showAlbum(id: album.identity.remoteID, fallbackTitle: album.title)
          completion()
        }
        loadArtwork(
          url: album.artworkURL, cacheIdentity: "album:\(album.identity.remoteID)", into: item)
        items.append(item)
      }
    }
    if end < albums.count {
      items.append(
        collectionItem(
          title: String(localized: "更多专辑"),
          detail: String(localized: "继续浏览 \(albums.count - end) 张"),
          symbol: "ellipsis.circle"
        ) { [weak self] in
          guard let self else { return }
          self.push(self.makeAlbumPage(albums, startIndex: end))
        })
    }
    let template = CPListTemplate(
      title: String(localized: "专辑"), sections: [CPListSection(items: items)])
    if items.isEmpty { template.emptyViewTitleVariants = [String(localized: "这里还没有专辑")] }
    return template
  }

  private func makeArtistPage(_ artists: [MusicArtist], startIndex: Int) -> CPListTemplate {
    let end = min(artists.count, startIndex + CarPlayContentPolicy.pageSize)
    var items: [CPListItem] = []
    if startIndex < end {
      for artist in artists[startIndex..<end] {
        let item = CPListItem(
          text: artist.name,
          detailText: artist.albumCount.map { String(localized: "\($0) 张专辑") },
          image: placeholderArtwork, accessoryImage: nil, accessoryType: .disclosureIndicator)
        item.handler = { [weak self] _, completion in
          self?.showArtist(id: artist.identity.remoteID, fallbackTitle: artist.name)
          completion()
        }
        loadArtwork(
          url: artist.artworkURL, cacheIdentity: "artist:\(artist.identity.remoteID)", into: item)
        items.append(item)
      }
    }
    if end < artists.count {
      items.append(
        collectionItem(
          title: String(localized: "更多艺人"),
          detail: String(localized: "继续浏览 \(artists.count - end) 位"),
          symbol: "ellipsis.circle"
        ) { [weak self] in
          guard let self else { return }
          self.push(self.makeArtistPage(artists, startIndex: end))
        })
    }
    let template = CPListTemplate(
      title: String(localized: "艺人"), sections: [CPListSection(items: items)])
    if items.isEmpty { template.emptyViewTitleVariants = [String(localized: "这里还没有艺人")] }
    return template
  }

  private func makePlaylistPage(
    _ playlists: [MusicPlaylist], startIndex: Int
  ) -> CPListTemplate {
    let end = min(playlists.count, startIndex + CarPlayContentPolicy.pageSize)
    var items =
      startIndex < end ? playlists[startIndex..<end].map(playlistItem) : []
    if end < playlists.count {
      items.append(
        collectionItem(
          title: String(localized: "更多歌单"),
          detail: String(localized: "继续浏览 \(playlists.count - end) 个"),
          symbol: "ellipsis.circle"
        ) { [weak self] in
          guard let self else { return }
          self.push(self.makePlaylistPage(playlists, startIndex: end))
        })
    }
    let template = CPListTemplate(
      title: String(localized: "歌单"), sections: [CPListSection(items: items)])
    if items.isEmpty {
      template.emptyViewTitleVariants = [String(localized: "这里还没有歌单")]
      template.emptyViewSubtitleVariants = [String(localized: "可在 iPhone 上管理歌单")]
    }
    return template
  }

  private func showAlbum(id: String, fallbackTitle: String) {
    guard let context else { return }
    let template = loadingDetailTemplate(title: fallbackTitle)
    push(template)
    Task { @MainActor [weak self, weak template] in
      guard let self, let template else { return }
      do {
        let detail = try await context.library.albumDetail(id: id)
        let page = self.makeTrackPage(
          title: detail.album.title, tracks: detail.tracks, startIndex: 0)
        template.emptyViewTitleVariants = page.emptyViewTitleVariants
        template.emptyViewSubtitleVariants = page.emptyViewSubtitleVariants
        template.updateSections(page.sections)
        if #available(iOS 18.4, *) { template.showsSpinnerWhileEmpty = false }
      } catch {
        self.showLoadFailure(on: template)
      }
    }
  }

  private func showPlaylist(id: String, fallbackTitle: String) {
    guard let context else { return }
    let template = loadingDetailTemplate(title: fallbackTitle)
    push(template)
    Task { @MainActor [weak self, weak template] in
      guard let self, let template else { return }
      do {
        let detail = try await context.library.playlistDetail(id: id)
        let page = self.makeTrackPage(
          title: detail.playlist.name, tracks: detail.tracks, startIndex: 0)
        template.emptyViewTitleVariants = page.emptyViewTitleVariants
        template.emptyViewSubtitleVariants = page.emptyViewSubtitleVariants
        template.updateSections(page.sections)
        if #available(iOS 18.4, *) { template.showsSpinnerWhileEmpty = false }
      } catch {
        self.showLoadFailure(on: template)
      }
    }
  }

  private func showArtist(id: String, fallbackTitle: String) {
    guard let context else { return }
    let template = loadingDetailTemplate(title: fallbackTitle)
    push(template)
    Task { @MainActor [weak self, weak template] in
      guard let self, let template else { return }
      do {
        let detail = try await context.library.artistDetail(id: id)
        var sections: [CPListSection] = []
        if !detail.topTracks.isEmpty {
          sections.append(
            CPListSection(
              items: Array(detail.topTracks.prefix(8)).map {
                self.trackItem($0, queue: detail.topTracks)
              },
              header: String(localized: "热门歌曲"), sectionIndexTitle: nil))
        }
        if !detail.albums.isEmpty {
          var albumItems: [CPListItem] = []
          for album in detail.albums.prefix(12) {
            let item = CPListItem(
              text: album.title, detailText: album.artistName, image: self.placeholderArtwork,
              accessoryImage: nil, accessoryType: .disclosureIndicator)
            item.handler = { [weak self] _, completion in
              self?.showAlbum(id: album.identity.remoteID, fallbackTitle: album.title)
              completion()
            }
            self.loadArtwork(
              url: album.artworkURL, cacheIdentity: "album:\(album.identity.remoteID)",
              into: item)
            albumItems.append(item)
          }
          sections.append(
            CPListSection(
              items: albumItems, header: String(localized: "专辑"), sectionIndexTitle: nil))
        }
        template.updateSections(sections)
        if sections.isEmpty { self.showLoadFailure(on: template, emptyLibrary: true) }
        if #available(iOS 18.4, *) { template.showsSpinnerWhileEmpty = false }
      } catch {
        self.showLoadFailure(on: template)
      }
    }
  }

  private func loadingDetailTemplate(title: String) -> CPListTemplate {
    let template = CPListTemplate(title: title, sections: [])
    template.emptyViewTitleVariants = [String(localized: "正在载入…")]
    if #available(iOS 18.4, *) { template.showsSpinnerWhileEmpty = true }
    return template
  }

  private func showLoadFailure(
    on template: CPListTemplate, emptyLibrary: Bool = false
  ) {
    if #available(iOS 18.4, *) { template.showsSpinnerWhileEmpty = false }
    template.emptyViewTitleVariants = [
      emptyLibrary ? String(localized: "这里还没有内容") : String(localized: "暂时无法连接音乐源")
    ]
    template.emptyViewSubtitleVariants = [String(localized: "连接恢复后可重试")]
    template.updateSections([])
  }

  private func configureNowPlayingTemplate() {
    let template = CPNowPlayingTemplate.shared
    template.add(self)
    template.isUpNextButtonEnabled = true
    template.upNextTitle = String(localized: "接下来播放")

    let button = CPNowPlayingShuffleButton { [weak self] button in
      guard let self, let context = self.context else { return }
      context.playback.togglePlaybackOrder()
      button.isSelected = context.playback.playbackOrder == .shuffle
    }
    shuffleButton = button
    template.updateNowPlayingButtons([button])
  }

  private func synchronizePlaybackPresentation() {
    guard let context else { return }
    let currentID = context.playback.currentTrack?.id
    for (trackID, items) in trackItems {
      for item in items {
        item.isPlaying = trackID == currentID && context.playback.isPlaybackRequested
      }
    }
    shuffleButton?.isSelected = context.playback.playbackOrder == .shuffle
    CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled =
      context.playback.currentTrack?.albumRemoteID != nil
  }

  private func trackDetail(_ track: MusicTrack) -> String {
    [track.artistName, track.albumTitle]
      .compactMap { value in
        guard let value, !value.isEmpty else { return nil }
        return value
      }
      .joined(separator: " · ")
  }

  private func loadArtwork(url: URL?, cacheIdentity: String, into item: CPListItem) {
    guard let url, let context else { return }
    let scale = interfaceController?.carTraitCollection.displayScale ?? 2
    let size = CPListItem.maximumImageSize
    let maximumPixelSize = max(size.width, size.height) * scale
    let task = Task { @MainActor [weak item] in
      let image = await ArtworkRepository.shared.image(
        for: url, serverID: context.serverID, fetcher: context.artworkFetcher,
        cacheIdentity: cacheIdentity, maximumPixelSize: maximumPixelSize)
      guard !Task.isCancelled, let image else { return }
      item?.setImage(image)
    }
    artworkTasks.append(task)
  }

  private func cancelArtworkTasks() {
    for task in artworkTasks { task.cancel() }
    artworkTasks.removeAll(keepingCapacity: true)
  }

  private func setRoot(_ template: CPTemplate, animated: Bool) {
    interfaceController?.setRootTemplate(template, animated: animated) { success, error in
      if !success, let error {
        Self.logger.error(
          "设置 CarPlay 根模板失败：\(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func push(_ template: CPTemplate, completion: (() -> Void)? = nil) {
    guard let interfaceController else {
      completion?()
      return
    }
    interfaceController.pushTemplate(template, animated: true) { success, error in
      if !success, let error {
        Self.logger.error(
          "展示 CarPlay 模板失败：\(error.localizedDescription, privacy: .public)")
      }
      completion?()
    }
  }
}
