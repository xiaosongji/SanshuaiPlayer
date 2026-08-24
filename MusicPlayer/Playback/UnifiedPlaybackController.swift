import AVFoundation
import Foundation
import MediaPlayer
import Network
import Observation
import OSLog
import UIKit
import UniformTypeIdentifiers

enum PlaybackOrder: String, Codable, CaseIterable, Sendable {
  case sequential
  case shuffle

  var title: String {
    self == .sequential ? String(localized: "列表循环") : String(localized: "随机循环")
  }
  var icon: String { self == .sequential ? "repeat" : "shuffle" }
}

enum PlaybackControlPresentationPolicy {
  nonisolated static func shouldShowPause(
    hasCurrentTrack: Bool, wantsPlayback: Bool
  ) -> Bool {
    hasCurrentTrack && wantsPlayback
  }
}

private final class NowPlayingArtworkImageBox: @unchecked Sendable {
  nonisolated let image: UIImage

  nonisolated init(_ image: UIImage) {
    self.image = image
  }
}

enum NowPlayingArtworkFactory {
  nonisolated static func make(image: UIImage, boundsSize: CGSize) -> MPMediaItemArtwork {
    let imageBox = NowPlayingArtworkImageBox(image)
    return MPMediaItemArtwork(boundsSize: boundsSize) { @Sendable _ in
      imageBox.image
    }
  }
}

@MainActor
@Observable
final class UnifiedPlaybackController {
  private nonisolated static let logger = Logger(
    subsystem: "com.himhuu.music", category: "Playback")
  nonisolated static let prefetchStartFraction = 0.75
  nonisolated static let prefetchedTrackLimit = 3
  nonisolated static let cellularStreamingQuality: StreamingQuality = .standard
  private static weak var activeController: UnifiedPlaybackController?
  private(set) var currentTrack: MusicTrack?
  private(set) var queue: [MusicTrack] = []
  private(set) var currentIndex: Int?
  private(set) var isPlaying = false
  private(set) var isBuffering = false
  private(set) var currentTime: TimeInterval = 0
  private(set) var duration: TimeInterval = 0
  private(set) var errorMessage: String?
  private(set) var completedPlaybackCount = 0
  private(set) var playbackOrder: PlaybackOrder
  var isPlaybackRequested: Bool {
    PlaybackControlPresentationPolicy.shouldShowPause(
      hasCurrentTrack: currentTrack != nil, wantsPlayback: wantsPlayback)
  }
  let audioReactiveAnalyzer = AudioReactiveAnalyzer()

  private let provider: any MusicSourceProvider
  private var wifiQuality: StreamingQuality
  private let prefetchDelay: Duration
  private let network = NetworkQualityMonitor()
  private let cache: MusicCache
  private let player = AVPlayer()
  private var timeObserver: Any?
  private var timeControlObserver: NSKeyValueObservation?
  private var itemStatusObserver: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var failureObserver: NSObjectProtocol?
  private var stalledObserver: NSObjectProtocol?
  private var timeJumpObserver: NSObjectProtocol?
  private var accessLogObserver: NSObjectProtocol?
  private var errorLogObserver: NSObjectProtocol?
  private var audioSessionInterruptionObserver: NSObjectProtocol?
  private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
  private var playbackTask: Task<Void, Never>?
  private var prefetchTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var healthMonitorTask: Task<Void, Never>?
  private var artworkNetworkReleaseTask: Task<Void, Never>?
  private var nowPlayingArtworkTask: Task<Void, Never>?
  private var deferredAudioAnalysisTask: Task<Void, Never>?
  private var progressReportTask: Task<Void, Never>?
  private var audioReactiveAnalysisRequested = false
  private var mediaResourceLoader: ProviderAssetResourceLoader?
  private var lastReportedSecond = -1
  private var lastBroadcastTrackID: UUID?
  private var lastBroadcastPlaybackRequested = false
  private var nowPlayingArtwork: MPMediaItemArtwork?
  private var playbackRequestID: UInt = 0
  private var playbackRequestedAt: Date?
  private var needsReloadOnResume = false
  private var shouldResumeAfterAudioInterruption = false
  private var wantsPlayback = false
  private var lastProgressAt = Date()
  private var lastProgressTime: TimeInterval = 0
  private var recoveryAttempts = 0
  private var lastRecoveryPosition: TimeInterval?
  private var durationAnomalyCount = 0
  private var currentMediaCacheKey: String?
  private var currentUsesCachedMedia = false
  private var cellularOriginalFallbackTrackIDs = Set<UUID>()
  #if DEBUG
    private var usesVisualAuditPlaybackState = false
  #endif

  init(
    provider: any MusicSourceProvider, wifiQuality: StreamingQuality, cache: MusicCache = .shared,
    prefetchDelay: Duration = .seconds(3)
  ) {
    self.provider = provider
    self.wifiQuality = wifiQuality
    self.cache = cache
    self.prefetchDelay = prefetchDelay
    player.automaticallyWaitsToMinimizeStalling = true
    playbackOrder =
      UserDefaults.standard.string(forKey: "playback.order.\(provider.id.uuidString.lowercased())")
      .flatMap(PlaybackOrder.init(rawValue:)) ?? .sequential
    configureAudioSession()
    observeAudioSessionInterruptions()
    configureRemoteCommands()
    observePlayer()
    Task { await restoreQueue() }
  }

  isolated deinit {
    playbackTask?.cancel()
    prefetchTask?.cancel()
    recoveryTask?.cancel()
    healthMonitorTask?.cancel()
    artworkNetworkReleaseTask?.cancel()
    nowPlayingArtworkTask?.cancel()
    deferredAudioAnalysisTask?.cancel()
    progressReportTask?.cancel()
    player.pause()
    mediaResourceLoader?.invalidate()
    mediaResourceLoader = nil
    audioReactiveAnalyzer.reset()
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeControlObserver?.invalidate()
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    if let stalledObserver { NotificationCenter.default.removeObserver(stalledObserver) }
    if let timeJumpObserver { NotificationCenter.default.removeObserver(timeJumpObserver) }
    if let accessLogObserver { NotificationCenter.default.removeObserver(accessLogObserver) }
    if let errorLogObserver { NotificationCenter.default.removeObserver(errorLogObserver) }
    if let audioSessionInterruptionObserver {
      NotificationCenter.default.removeObserver(audioSessionInterruptionObserver)
    }
    for value in remoteCommandTargets { value.command.removeTarget(value.target) }
  }

  func play(_ track: MusicTrack, queue newQueue: [MusicTrack]) async {
    queue = newQueue.isEmpty ? [track] : unique(newQueue)
    if !queue.contains(where: { $0.id == track.id }) { queue.insert(track, at: 0) }
    currentIndex = queue.firstIndex { $0.id == track.id }
    await prepare(track)
    await persistQueue()
  }
  func play(
    _ track: MusicTrack, queue primaryQueue: [MusicTrack],
    continuingWith continuationQueue: [MusicTrack]
  ) async {
    await play(track, queue: primaryQueue + continuationQueue)
  }
  func togglePlayback() { isPlaybackRequested ? pause() : resume() }
  func togglePlaybackOrder() {
    playbackOrder = playbackOrder == .sequential ? .shuffle : .sequential
    UserDefaults.standard.set(
      playbackOrder.rawValue, forKey: "playback.order.\(provider.id.uuidString.lowercased())")
  }
  func updateWiFiStreamingQuality(_ wifi: StreamingQuality) {
    guard wifiQuality != wifi else { return }
    wifiQuality = wifi
    prefetchUpcomingTracks()
  }
  func setAudioReactiveAnalysisEnabled(_ enabled: Bool) {
    audioReactiveAnalysisRequested = enabled
    audioReactiveAnalyzer.setAnalysisEnabled(enabled)
    guard enabled else {
      deferredAudioAnalysisTask?.cancel()
      deferredAudioAnalysisTask = nil
      player.currentItem?.audioMix = nil
      Self.logger.info("已退出横屏动效，音频频谱分析已卸载")
      return
    }
    guard let item = player.currentItem, let currentTrack else { return }
    scheduleOnDemandAudioAnalysis(
      asset: item.asset, item: item, track: currentTrack, requestID: playbackRequestID)
  }
  func dismissError() { errorMessage = nil }
  func pause() {
    shouldResumeAfterAudioInterruption = false
    wantsPlayback = false
    recoveryTask?.cancel()
    recoveryTask = nil
    healthMonitorTask?.cancel()
    healthMonitorTask = nil
    artworkNetworkReleaseTask?.cancel()
    artworkNetworkReleaseTask = nil
    prefetchTask?.cancel()
    prefetchTask = nil
    player.pause()
    isPlaying = false
    isBuffering = false
    updateNowPlaying()
    if let currentTrack {
      let stoppedAt = currentTime
      Task {
        try? await provider.reportPlayback(.stopped(track: currentTrack, position: stoppedAt))
        await recordHistory(track: currentTrack, position: stoppedAt, completed: false)
      }
    }
  }
  func resume() {
    guard let currentTrack else { return }
    claimExclusivePlayback()
    wantsPlayback = true
    if player.currentItem == nil || needsReloadOnResume {
      Task { await prepare(currentTrack) }
      return
    }
    playbackRequestedAt = Date()
    player.play()
    syncPlaybackState()
    startPlaybackHealthMonitor(
      item: player.currentItem, track: currentTrack, requestID: playbackRequestID)
    prefetchUpcomingTracks()
    Task {
      try? await provider.reportPlayback(.started(track: currentTrack))
      if currentTime > 0 {
        try? await provider.reportPlayback(
          .progress(track: currentTrack, position: currentTime, duration: duration))
      }
    }
  }
  func seek(to time: TimeInterval) {
    let target = max(0, min(time.isFinite ? time : 0, duration))
    Self.logger.info(
      "用户定位播放位置：from=\(self.currentTime, privacy: .public), to=\(target, privacy: .public), session=\(self.playbackRequestID, privacy: .public)")
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    currentTime = target
    updateNowPlaying()
    prefetchUpcomingTracks()
  }
  func playNext() async {
    guard !queue.isEmpty else { return }
    if queue.count == 1 {
      currentIndex = 0
      seek(to: 0)
      resume()
      await persistQueue()
      return
    }
    let next: Int
    if playbackOrder == .shuffle, queue.count > 1 {
      let current = currentIndex ?? 0
      next = (0..<queue.count).filter { $0 != current }.randomElement() ?? current
    } else {
      next = ((currentIndex ?? -1) + 1) % queue.count
    }
    currentIndex = next
    await prepare(queue[next], resumeAt: 0)
    await persistQueue()
  }
  func playPrevious() async {
    if currentTime > 4 {
      seek(to: 0)
      return
    }
    guard !queue.isEmpty else { return }
    let index = currentIndex ?? 0
    let previous = (index - 1 + queue.count) % queue.count
    currentIndex = previous
    await prepare(queue[previous], resumeAt: 0)
    await persistQueue()
  }
  func remove(at offsets: IndexSet) {
    guard let currentTrack else { return }
    queue.remove(atOffsets: offsets)
    currentIndex = queue.firstIndex { $0.id == currentTrack.id }
    Task { await persistQueue() }
    prefetchUpcomingTracks()
  }
  func move(from offsets: IndexSet, to destination: Int) {
    queue.move(fromOffsets: offsets, toOffset: destination)
    currentIndex = currentTrack.flatMap { value in queue.firstIndex { $0.id == value.id } }
    Task { await persistQueue() }
    prefetchUpcomingTracks()
  }

  private func prepare(
    _ track: MusicTrack, resumeAt requestedResumePosition: TimeInterval? = nil,
    isRecovery: Bool = false
  ) async {
    claimExclusivePlayback()
    if isRecovery {
      recoveryTask = nil
    } else {
      recoveryTask?.cancel()
      recoveryTask = nil
      recoveryAttempts = 0
      lastRecoveryPosition = nil
    }
    playbackTask?.cancel()
    progressReportTask?.cancel()
    progressReportTask = nil
    healthMonitorTask?.cancel()
    healthMonitorTask = nil
    prefetchTask?.cancel()
    prefetchTask = nil
    artworkNetworkReleaseTask?.cancel()
    artworkNetworkReleaseTask = nil
    nowPlayingArtworkTask?.cancel()
    nowPlayingArtworkTask = nil
    nowPlayingArtwork = nil
    deferredAudioAnalysisTask?.cancel()
    deferredAudioAnalysisTask = nil
    ArtworkRepository.shared.beginPlaybackArtworkDeferral()
    playbackRequestID &+= 1
    let requestID = playbackRequestID
    let previousTrack = currentTrack
    let previousTime = currentTime

    player.pause()
    player.replaceCurrentItem(with: nil)
    removeItemObservers()
    mediaResourceLoader?.invalidate()
    mediaResourceLoader = nil
    audioReactiveAnalyzer.reset()
    wantsPlayback = true
    currentTrack = track
    duration = track.duration
    currentTime = 0
    isPlaying = false
    isBuffering = true
    errorMessage = nil
    needsReloadOnResume = false
    shouldResumeAfterAudioInterruption = false
    lastReportedSecond = -1
    durationAnomalyCount = 0
    lastProgressAt = Date()
    lastProgressTime = 0
    currentMediaCacheKey = nil
    currentUsesCachedMedia = false
    playbackRequestedAt = Date()
    updateNowPlaying()
    loadNowPlayingArtwork(for: track, requestID: requestID)

    // The stop report is what releases the server-side play/transcode session, so it has to be
    // sent on every track change — including the instant skips that never reached 1 second.
    // Only the listening history is gated on actual progress.
    if let previousTrack, previousTrack.id != track.id {
      let shouldRecordHistory = previousTime > 0
      Task { [weak self, provider] in
        try? await provider.reportPlayback(
          .stopped(track: previousTrack, position: max(previousTime, 0)))
        guard shouldRecordHistory else { return }
        await self?.recordHistory(
          track: previousTrack, position: previousTime, completed: false)
      }
    }

    let task = Task { [weak self] in
      guard let self else { return }
      let usesExpensiveNetwork = self.network.isConstrainedOrExpensive
      let usesCellularNetwork =
        self.provider.sourceType != .local && self.network.isCellular
      let usesCellularMP3 =
        usesCellularNetwork && !self.cellularOriginalFallbackTrackIDs.contains(track.id)
      let selectedQuality: StreamingQuality =
        if usesCellularNetwork {
          usesCellularMP3 ? Self.cellularStreamingQuality : .original
        } else {
          self.wifiQuality
        }
      do {
        if usesCellularMP3 {
          Self.logger.notice("蜂窝网络固定使用 MP3 转码流")
        } else if usesCellularNetwork {
          Self.logger.notice("该歌曲的蜂窝 MP3 转码不可用，使用原始格式")
        }
        let cacheKey = Self.mediaCacheKey(for: track, quality: selectedQuality)
        var resolvedCacheKey = cacheKey
        let cachedURL = await self.cache.mediaURL(serverID: self.provider.id, key: cacheKey)
        try Task.checkCancellation()
        var asset: AVURLAsset
        var inspection: PlaybackAssetInspection?
        var resourceLoader: ProviderAssetResourceLoader?
        var usesCachedMedia = false
        if let cachedURL {
          let cachedAsset = AVURLAsset(url: cachedURL)
          if let cachedInspection = try? await self.inspectForPlayback(cachedAsset),
            MediaDurationPolicy.isPlausible(
              catalogDuration: track.duration, mediaDuration: cachedInspection.duration)
          {
            asset = cachedAsset
            inspection = cachedInspection
            usesCachedMedia = true
          } else {
            Self.logger.error("缓存音频不完整或时长异常，删除后改用网络流")
            try Task.checkCancellation()
            await self.cache.removeMedia(serverID: self.provider.id, key: cacheKey)
            let remoteAsset = try await self.remoteAsset(for: track, quality: selectedQuality)
            asset = remoteAsset.asset
            resourceLoader = remoteAsset.resourceLoader
          }
        } else {
          let remoteAsset = try await self.remoteAsset(for: track, quality: selectedQuality)
          asset = remoteAsset.asset
          resourceLoader = remoteAsset.resourceLoader
        }
        try Task.checkCancellation()
        let usesFastRemoteStart = Self.shouldUseFastRemoteStart(
          isRecovery: isRecovery, usesCachedMedia: usesCachedMedia,
          hasResourceLoader: resourceLoader != nil, quality: selectedQuality,
          isNativelyPlayable: track.isNativelyPlayableOnIOS)
        if usesFastRemoteStart {
          Self.logger.notice("远程音频启用快速起播，跳过可能阻塞 20 秒的音轨预检")
        } else {
          do {
            if inspection == nil {
              inspection = try await self.inspectForPlayback(
                asset, loadDuration: usesCachedMedia)
            }
            guard
              MediaDurationPolicy.isPlausible(
                catalogDuration: track.duration, mediaDuration: inspection?.duration)
            else { throw MusicSourceError.invalidResponse }
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            let originalError = error
            if (selectedQuality == .original || selectedQuality == .lossless),
              self.provider.capabilities.contains(.transcoding),
              !(usesCellularNetwork
                && self.cellularOriginalFallbackTrackIDs.contains(track.id))
            {
              Self.logger.notice("原始音频不可用，切换到兼容 MP3 转码流")
              let fallbackQuality = StreamingQuality.high
              resolvedCacheKey = Self.mediaCacheKey(for: track, quality: fallbackQuality)
              do {
                let fallbackAsset = try await self.remoteAsset(
                  for: track, quality: fallbackQuality)
                resourceLoader = fallbackAsset.resourceLoader
                asset = fallbackAsset.asset
                inspection = try await self.inspectForPlayback(asset, loadDuration: false)
                guard
                  MediaDurationPolicy.isPlausible(
                    catalogDuration: track.duration, mediaDuration: inspection?.duration)
                else { throw MusicSourceError.invalidResponse }
              } catch is CancellationError {
                throw CancellationError()
              } catch {
                guard isRecovery, self.recoveryAttempts >= 2 else {
                  Self.logger.notice("兼容 MP3 流仍在冷启动，稍后自动重新请求")
                  throw MusicSourceError.transcodingFailed
                }
                Self.logger.notice("兼容流连续预检失败，下载完整转码文件作为最终兜底")
                do {
                  let downloaded = try await self.downloadPlayableAsset(
                    for: track, quality: fallbackQuality, cacheKey: resolvedCacheKey)
                  asset = downloaded.asset
                  inspection = downloaded.inspection
                  resourceLoader = nil
                  usesCachedMedia = true
                } catch is CancellationError {
                  throw CancellationError()
                } catch {
                  throw MusicSourceError.transcodingFailed
                }
              }
            } else {
              guard selectedQuality == .original || selectedQuality == .lossless
                || (isRecovery && self.recoveryAttempts >= 2)
              else {
                Self.logger.notice("MP3 转码流仍在冷启动，稍后自动重新请求")
                throw MusicSourceError.transcodingFailed
              }
              Self.logger.notice("串流连续预检失败，下载完整文件作为最终兜底")
              do {
                let downloaded = try await self.downloadPlayableAsset(
                  for: track, quality: selectedQuality, cacheKey: resolvedCacheKey)
                asset = downloaded.asset
                inspection = downloaded.inspection
                resourceLoader = nil
                usesCachedMedia = true
              } catch is CancellationError {
                throw CancellationError()
              } catch {
                throw originalError
              }
            }
          }
        }
        try Task.checkCancellation()
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = Self.startupBufferDuration(
          usesExpensiveNetwork: usesExpensiveNetwork)
        try Task.checkCancellation()
        guard self.isCurrentRequest(requestID, track: track) else { return }
        self.currentMediaCacheKey = resolvedCacheKey
        self.currentUsesCachedMedia = usesCachedMedia
        if self.mediaResourceLoader !== resourceLoader { self.mediaResourceLoader?.invalidate() }
        self.mediaResourceLoader = resourceLoader
        self.player.replaceCurrentItem(with: item)
        if self.audioReactiveAnalysisRequested {
          self.scheduleOnDemandAudioAnalysis(
            asset: asset, item: item, track: track, requestID: requestID)
        }
        self.observeEnd(of: item, track: track, requestID: requestID)
        let resumePosition =
          requestedResumePosition
          ?? track.resumePosition.flatMap { $0 < max(track.duration - 5, 0) ? $0 : nil } ?? 0
        self.currentTime = resumePosition
        if resumePosition > 0 {
          await self.player.seek(to: CMTime(seconds: resumePosition, preferredTimescale: 600))
        }
        try Task.checkCancellation()
        guard self.isCurrentRequest(requestID, track: track) else { return }
        self.syncPlaybackState()
        self.needsReloadOnResume = false
        if self.wantsPlayback {
          self.player.play()
          self.syncPlaybackState()
          self.startPlaybackHealthMonitor(
            item: item, track: track, requestID: requestID)
          try? await self.provider.reportPlayback(.started(track: track))
          try Task.checkCancellation()
          guard self.isCurrentRequest(requestID, track: track) else { return }
          self.prefetchUpcomingTracks()
          if resumePosition > 0 {
            try? await self.provider.reportPlayback(
              .progress(track: track, position: resumePosition, duration: track.duration))
          }
        }
      } catch is CancellationError {} catch {
        guard self.isCurrentRequest(requestID, track: track) else { return }
        guard self.wantsPlayback else {
          self.isPlaying = false
          self.isBuffering = false
          self.needsReloadOnResume = true
          return
        }
        let mapped = MusicSourceError.map(error)
        if usesCellularNetwork, selectedQuality == Self.cellularStreamingQuality,
          Self.shouldFallbackToOriginalFromCellularMP3(after: mapped)
        {
          self.cellularOriginalFallbackTrackIDs.insert(track.id)
          Self.logger.notice("蜂窝 MP3 转码失败，立即回退原始格式")
          let resumePosition =
            requestedResumePosition
            ?? track.resumePosition.flatMap { $0 < max(track.duration - 5, 0) ? $0 : nil }
            ?? self.currentTime
          Task { [weak self] in
            await self?.prepare(track, resumeAt: max(resumePosition, 0), isRecovery: true)
          }
          return
        }
        Self.logger.error(
          "播放流准备失败：\(mapped.localizedDescription, privacy: .public)")
        let resumePosition =
          requestedResumePosition
          ?? track.resumePosition.flatMap { $0 < max(track.duration - 5, 0) ? $0 : nil }
          ?? self.currentTime
        if self.schedulePreparationRecovery(
          track: track, requestID: requestID, resumePosition: resumePosition, error: mapped)
        {
          self.isPlaying = false
          self.isBuffering = true
          self.needsReloadOnResume = false
        } else {
          self.errorMessage = mapped.localizedDescription
          self.wantsPlayback = false
          self.isPlaying = false
          self.isBuffering = false
          self.needsReloadOnResume = true
        }
      }
    }
    playbackTask = task
    await task.value
    if playbackRequestID == requestID { playbackTask = nil }
  }

  @discardableResult
  private func configureAudioSession() -> Bool {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
      try AVAudioSession.sharedInstance().setActive(true)
      return true
    } catch {
      errorMessage = String(localized: "无法启用后台音频。")
      return false
    }
  }
  private func observeAudioSessionInterruptions() {
    audioSessionInterruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      let box = NotificationBox(notification)
      Task { @MainActor in self?.handleAudioSessionInterruption(box.notification) }
    }
  }
  private func handleAudioSessionInterruption(_ notification: Notification) {
    guard
      let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }

    switch type {
    case .began:
      shouldResumeAfterAudioInterruption =
        isPlaybackRequested || player.timeControlStatus == .playing
      wantsPlayback = false
      recoveryTask?.cancel()
      recoveryTask = nil
      healthMonitorTask?.cancel()
      healthMonitorTask = nil
      guard shouldResumeAfterAudioInterruption else { return }
      prefetchTask?.cancel()
      prefetchTask = nil
      isPlaying = false
      isBuffering = false
      updateNowPlaying()
    case .ended:
      let optionsValue =
        notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
      let shouldResume = AudioSessionInterruptionPolicy.shouldResumePlayback(
        wasPlayingBeforeInterruption: shouldResumeAfterAudioInterruption,
        systemAllowsResume: options.contains(.shouldResume))
      shouldResumeAfterAudioInterruption = false
      guard shouldResume, configureAudioSession() else { return }
      resume()
    @unknown default:
      shouldResumeAfterAudioInterruption = false
    }
  }
  private func configureRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    remoteCommandTargets.append(
      (
        center.playCommand,
        center.playCommand.addTarget { [weak self] _ in
          Task { @MainActor in
            guard let self, Self.activeController === self else { return }
            self.resume()
          }
          return .success
        }
      ))
    remoteCommandTargets.append(
      (
        center.pauseCommand,
        center.pauseCommand.addTarget { [weak self] _ in
          Task { @MainActor in
            guard let self, Self.activeController === self else { return }
            self.pause()
          }
          return .success
        }
      ))
    remoteCommandTargets.append(
      (
        center.nextTrackCommand,
        center.nextTrackCommand.addTarget { [weak self] _ in
          Task { @MainActor in
            guard let self, Self.activeController === self else { return }
            await self.playNext()
          }
          return .success
        }
      ))
    remoteCommandTargets.append(
      (
        center.previousTrackCommand,
        center.previousTrackCommand.addTarget { [weak self] _ in
          Task { @MainActor in
            guard let self, Self.activeController === self else { return }
            await self.playPrevious()
          }
          return .success
        }
      ))
    remoteCommandTargets.append(
      (
        center.changePlaybackPositionCommand,
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
          guard let event = event as? MPChangePlaybackPositionCommandEvent else {
            return .commandFailed
          }
          Task { @MainActor in
            guard let self, Self.activeController === self else { return }
            self.seek(to: event.positionTime)
          }
          return .success
        }
      ))
  }
  private func observePlayer() {
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main
    ) { [weak self] time in Task { @MainActor in self?.tick(time.seconds) } }
    timeControlObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) {
      [weak self] _, _ in
      Task { @MainActor in self?.syncPlaybackState() }
    }
  }
  private func observeEnd(of item: AVPlayerItem, track: MusicTrack, requestID: UInt) {
    removeItemObservers()
    itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
      Task { @MainActor in
        guard let self, let item, item.status == .failed,
          self.isCurrentRequest(requestID, track: track), self.player.currentItem === item
        else { return }
        let mapped = MusicSourceError.map(item.error ?? MusicSourceError.unsupportedFormat)
        Self.logger.error(
          "播放项首次装载失败，将自动重建：\(mapped.localizedDescription, privacy: .public)")
        self.logPlaybackDiagnostics(for: item, reason: "initial-item-failed")
        self.schedulePlaybackRecovery(
          item: item, track: track, requestID: requestID, reason: "initial-item-failed")
      }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isCurrentRequest(requestID, track: track),
          self.player.currentItem === item
        else { return }
        let endedAt = self.player.currentTime().seconds
        let itemDuration = item.duration.seconds
        guard
          PlaybackCompletionPolicy.shouldAdvance(
            position: endedAt, catalogDuration: track.duration, itemDuration: itemDuration)
        else {
          Self.logger.error(
            "播放项提前结束，将自动恢复：position=\(endedAt, privacy: .public), expected=\(track.duration, privacy: .public)")
          self.logPlaybackDiagnostics(for: item, reason: "premature-end")
          self.schedulePlaybackRecovery(
            item: item, track: track, requestID: requestID, reason: "premature-end")
          return
        }
        try? await self.provider.reportPlayback(.completed(track: track))
        await self.recordHistory(track: track, position: endedAt, completed: true)
        self.completedPlaybackCount += 1
        await self.playNext()
      }
    }
    failureObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
    ) { [weak self] notification in
      let box = NotificationBox(notification)
      Task { @MainActor in
        guard let self, self.isCurrentRequest(requestID, track: track),
          self.player.currentItem === item
        else { return }
        let error = box.notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        let mapped = MusicSourceError.map(error ?? MusicSourceError.unsupportedFormat)
        Self.logger.error(
          "播放失败，将尝试恢复：\(mapped.localizedDescription, privacy: .public)")
        self.logPlaybackDiagnostics(for: item, reason: "failed-to-end")
        self.schedulePlaybackRecovery(
          item: item, track: track, requestID: requestID, reason: "failed-to-end")
      }
    }
    stalledObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isCurrentRequest(requestID, track: track),
          self.player.currentItem === item
        else { return }
        Self.logger.notice("检测到播放停滞，交由 AVPlayer 等待缓冲恢复，不重建播放项")
        self.isPlaying = false
        self.isBuffering = true
        self.logPlaybackDiagnostics(for: item, reason: "playback-stalled")
      }
    }
    timeJumpObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemTimeJumped, object: item, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isCurrentRequest(requestID, track: track),
          self.player.currentItem === item
        else { return }
        self.logPlaybackDiagnostics(for: item, reason: "time-jumped")
      }
    }
    accessLogObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isCurrentRequest(requestID, track: track),
          self.player.currentItem === item
        else { return }
        self.logPlaybackDiagnostics(for: item, reason: "access-log")
      }
    }
    errorLogObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isCurrentRequest(requestID, track: track),
          self.player.currentItem === item
        else { return }
        self.logPlaybackDiagnostics(for: item, reason: "error-log")
      }
    }
  }
  private func removeItemObservers() {
    itemStatusObserver?.invalidate()
    itemStatusObserver = nil
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
    if let failureObserver {
      NotificationCenter.default.removeObserver(failureObserver)
      self.failureObserver = nil
    }
    if let stalledObserver {
      NotificationCenter.default.removeObserver(stalledObserver)
      self.stalledObserver = nil
    }
    if let timeJumpObserver {
      NotificationCenter.default.removeObserver(timeJumpObserver)
      self.timeJumpObserver = nil
    }
    if let accessLogObserver {
      NotificationCenter.default.removeObserver(accessLogObserver)
      self.accessLogObserver = nil
    }
    if let errorLogObserver {
      NotificationCenter.default.removeObserver(errorLogObserver)
      self.errorLogObserver = nil
    }
  }
  private func isCurrentRequest(_ requestID: UInt, track: MusicTrack) -> Bool {
    playbackRequestID == requestID && currentTrack?.id == track.id
  }
  private func claimExclusivePlayback() {
    if let activeController = Self.activeController, activeController !== self {
      activeController.stopForPlaybackHandoff()
    }
    Self.activeController = self
  }
  private func stopForPlaybackHandoff() {
    shouldResumeAfterAudioInterruption = false
    wantsPlayback = false
    playbackRequestID &+= 1
    playbackTask?.cancel()
    playbackTask = nil
    prefetchTask?.cancel()
    prefetchTask = nil
    recoveryTask?.cancel()
    recoveryTask = nil
    healthMonitorTask?.cancel()
    healthMonitorTask = nil
    progressReportTask?.cancel()
    progressReportTask = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    removeItemObservers()
    mediaResourceLoader?.invalidate()
    mediaResourceLoader = nil
    audioReactiveAnalyzer.reset()
    isPlaying = false
    isBuffering = false
    needsReloadOnResume = currentTrack != nil
  }
  private func tick(_ value: TimeInterval) {
    guard value.isFinite, value >= 0 else { return }
    let catalogDuration = currentTrack?.duration ?? 0
    let itemDuration = player.currentItem?.duration.seconds
    let effectiveDuration =
      itemDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
      ?? (catalogDuration.isFinite && catalogDuration > 0 ? catalogDuration : nil)
    guard let effectiveDuration else { return }
    let boundedValue = min(value, effectiveDuration)
    currentTime = boundedValue
    if boundedValue > lastProgressTime + 0.15 {
      lastProgressTime = boundedValue
      lastProgressAt = Date()
      if let lastRecoveryPosition, boundedValue >= lastRecoveryPosition + 30 {
        recoveryAttempts = 0
        self.lastRecoveryPosition = nil
      }
    }
    if MediaDurationPolicy.isPlausible(
      catalogDuration: catalogDuration, mediaDuration: itemDuration)
    {
      duration =
        itemDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? catalogDuration
      durationAnomalyCount = 0
    } else {
      duration = catalogDuration
      durationAnomalyCount += 1
      if durationAnomalyCount == 3, let item = player.currentItem, let currentTrack {
        Self.logger.error(
          "播放流时长异常：catalog=\(catalogDuration, privacy: .public), item=\(itemDuration ?? -1, privacy: .public)")
        logPlaybackDiagnostics(for: item, reason: "duration-anomaly")
        schedulePlaybackRecovery(
          item: item, track: currentTrack, requestID: playbackRequestID,
          reason: "duration-anomaly")
      }
    }
    syncPlaybackState()
    let shouldWatchProgress =
      player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      || player.timeControlStatus == .playing
    if wantsPlayback, shouldWatchProgress,
      Date().timeIntervalSince(lastProgressAt) >= 9, let item = player.currentItem
    {
      Self.logger.notice("播放器等待数据超过 9 秒；保留当前播放项，继续等待系统恢复")
      logPlaybackDiagnostics(for: item, reason: "watchdog-no-progress")
      lastProgressAt = Date()
    }
    let second = Int(boundedValue)
    if second > 0, second % 15 == 0, second != lastReportedSecond, let currentTrack {
      lastReportedSecond = second
      guard progressReportTask == nil else { return }
      let reportDuration = duration
      progressReportTask = Task { [weak self, provider] in
        try? await provider.reportPlayback(
          .progress(track: currentTrack, position: boundedValue, duration: reportDuration))
        guard !Task.isCancelled else { return }
        self?.progressReportTask = nil
      }
    }
  }

  private func inspectForPlayback(
    _ asset: AVURLAsset, loadDuration: Bool = true
  ) async throws -> PlaybackAssetInspection {
    async let playable = asset.load(.isPlayable)
    async let audioTracks = asset.loadTracks(withMediaType: .audio)
    guard try await playable else { throw MusicSourceError.unsupportedFormat }
    let tracks = try await audioTracks
    guard let audioTrack = tracks.first else { throw MusicSourceError.unsupportedFormat }
    let mediaDuration: TimeInterval?
    if loadDuration {
      let loadedDuration = try? await asset.load(.duration)
      let seconds = loadedDuration?.seconds
      mediaDuration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    } else {
      mediaDuration = nil
    }
    return PlaybackAssetInspection(
      audioTrack: audioTrack,
      duration: mediaDuration)
  }

  private func remoteAsset(for track: MusicTrack, quality: StreamingQuality) async throws -> (
    asset: AVURLAsset, resourceLoader: ProviderAssetResourceLoader?
  ) {
    let remoteURL = try await provider.streamURL(for: track, quality: quality)
    guard !provider.mediaURLAllowsDirectPlayback else {
      return (AVURLAsset(url: remoteURL), nil)
    }
    let loader = try ProviderAssetResourceLoader(url: remoteURL, provider: provider)
    return (loader.makeAsset(), loader)
  }

  private func scheduleOnDemandAudioAnalysis(
    asset: AVAsset, item: AVPlayerItem, track: MusicTrack, requestID: UInt
  ) {
    guard audioReactiveAnalysisRequested, item.audioMix == nil else { return }
    deferredAudioAnalysisTask?.cancel()
    deferredAudioAnalysisTask = Task { [weak self] in
      guard let self, self.audioReactiveAnalysisRequested, self.player.currentItem === item,
        self.isCurrentRequest(requestID, track: track)
      else { return }
      do {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !Task.isCancelled, self.audioReactiveAnalysisRequested,
          let audioTrack = tracks.first,
          self.player.currentItem === item,
          let audioMix = self.audioReactiveAnalyzer.makeAudioMix(for: audioTrack)
        else { return }
        item.audioMix = audioMix
        Self.logger.info("横屏动效已按需加载实时音频频谱分析")
      } catch is CancellationError {
      } catch {
        Self.logger.debug(
          "横屏动效音轨分析未能启用：\(error.localizedDescription, privacy: .public)")
      }
      self.deferredAudioAnalysisTask = nil
    }
  }

  nonisolated static func shouldUseFastRemoteStart(
    isRecovery: Bool, usesCachedMedia: Bool, hasResourceLoader: Bool,
    quality: StreamingQuality, isNativelyPlayable: Bool
  ) -> Bool {
    _ = hasResourceLoader
    return !isRecovery && !usesCachedMedia
      && quality != .lossless
      && (quality != .original || isNativelyPlayable)
  }

  private func downloadPlayableAsset(
    for track: MusicTrack, quality: StreamingQuality, cacheKey: String
  ) async throws -> (asset: AVURLAsset, inspection: PlaybackAssetInspection) {
    if let cachedURL = await cache.mediaURL(serverID: provider.id, key: cacheKey),
      let inspection = try? await inspectForPlayback(AVURLAsset(url: cachedURL)),
      MediaDurationPolicy.isPlausible(
        catalogDuration: track.duration, mediaDuration: inspection.duration)
    {
      return (AVURLAsset(url: cachedURL), inspection)
    }
    try await Self.downloadAndCachePrefetchedTrack(
      track, quality: quality, cacheKey: cacheKey, provider: provider, cache: cache)
    guard let storedURL = await cache.mediaURL(serverID: provider.id, key: cacheKey) else {
      throw MusicSourceError.invalidResponse
    }
    let asset = AVURLAsset(url: storedURL)
    let inspection = try await inspectForPlayback(asset)
    guard
      MediaDurationPolicy.isPlausible(
        catalogDuration: track.duration, mediaDuration: inspection.duration)
    else { throw MusicSourceError.invalidResponse }
    return (asset, inspection)
  }

  private func schedulePlaybackRecovery(
    item: AVPlayerItem, track: MusicTrack, requestID: UInt, reason: String
  ) {
    guard recoveryTask == nil, wantsPlayback, isCurrentRequest(requestID, track: track),
      player.currentItem === item
    else { return }
    isPlaying = false
    isBuffering = true
    updateNowPlaying()
    let startingProgress = currentTime
    recoveryTask = Task { [weak self] in
      var loggedOfflineWait = false
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        guard let self, self.wantsPlayback,
          self.isCurrentRequest(requestID, track: track), self.player.currentItem === item
        else { return }
        if self.currentTime > startingProgress + 0.25 {
          self.recoveryTask = nil
          return
        }
        if !self.currentUsesCachedMedia, !self.network.isAvailable {
          if !loggedOfflineWait {
            loggedOfflineWait = true
            Self.logger.notice("网络不可用，保留当前播放项并每 3 秒等待网络恢复")
          }
          continue
        }
        self.player.play()
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        guard self.wantsPlayback, self.isCurrentRequest(requestID, track: track),
          self.player.currentItem === item
        else { return }
        if self.currentTime > startingProgress + 0.25 {
          self.recoveryTask = nil
          return
        }
        await self.performPlaybackRecovery(track: track, reason: reason)
        return
      }
    }
  }

  private func startPlaybackHealthMonitor(
    item: AVPlayerItem?, track: MusicTrack, requestID: UInt
  ) {
    healthMonitorTask?.cancel()
    guard let item else {
      healthMonitorTask = nil
      return
    }
    healthMonitorTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        guard let self, self.wantsPlayback,
          self.isCurrentRequest(requestID, track: track), self.player.currentItem === item
        else { return }
        guard Date().timeIntervalSince(self.lastProgressAt) >= 9 else { continue }
        guard self.recoveryTask == nil else { continue }
        Self.logger.notice("播放健康监测连续 9 秒未见进度；保留播放项等待缓冲")
        self.logPlaybackDiagnostics(for: item, reason: "health-monitor-no-progress")
        self.lastProgressAt = Date()
      }
    }
  }

  private func performPlaybackRecovery(track: MusicTrack, reason: String) async {
    guard wantsPlayback, currentTrack?.id == track.id else { return }
    guard recoveryAttempts < 3 else {
      Self.logger.error("播放自动恢复已达到上限")
      recoveryTask = nil
      errorMessage = String(localized: "播放连接未能自动恢复，请稍后重新点击播放。")
      wantsPlayback = false
      isPlaying = false
      isBuffering = false
      needsReloadOnResume = true
      return
    }
    recoveryAttempts += 1
    let playerPosition = player.currentTime().seconds
    let resumePosition = max(
      0, min(playerPosition.isFinite ? playerPosition : currentTime, duration))
    lastRecoveryPosition = resumePosition
    Self.logger.notice(
      "重建播放流：reason=\(reason, privacy: .public), attempt=\(self.recoveryAttempts, privacy: .public), position=\(resumePosition, privacy: .public)")
    if currentUsesCachedMedia, let currentMediaCacheKey {
      await cache.removeMedia(serverID: provider.id, key: currentMediaCacheKey)
    }
    currentUsesCachedMedia = false
    await prepare(track, resumeAt: resumePosition, isRecovery: true)
  }

  @discardableResult
  private func schedulePreparationRecovery(
    track: MusicTrack, requestID: UInt, resumePosition: TimeInterval, error: MusicSourceError
  ) -> Bool {
    guard recoveryTask == nil, wantsPlayback, recoveryAttempts < 3,
      Self.shouldRetryPreparation(after: error)
    else { return false }
    recoveryTask = Task { [weak self] in
      while !Task.isCancelled {
        let delay = Self.preparationRetryDelay(after: error)
        do { try await Task.sleep(for: delay) } catch { return }
        guard let self, self.wantsPlayback, self.isCurrentRequest(requestID, track: track)
        else { return }
        guard self.network.isAvailable else { continue }
        self.recoveryAttempts += 1
        self.lastRecoveryPosition = max(resumePosition, 0)
        Self.logger.notice(
          "重新准备播放流：attempt=\(self.recoveryAttempts, privacy: .public), position=\(resumePosition, privacy: .public)")
        await self.prepare(
          track, resumeAt: max(resumePosition, 0), isRecovery: true)
        return
      }
    }
    return true
  }

  private nonisolated static func shouldRetryPreparation(after error: MusicSourceError) -> Bool {
    switch error {
    case .dnsFailure, .networkUnavailable, .timeout, .transcodingFailed, .invalidResponse,
      .unsupportedFormat:
      true
    case .httpStatus(let status):
      [408, 425, 429, 500, 502, 503, 504].contains(status)
    default:
      false
    }
  }

  private nonisolated static func preparationRetryDelay(
    after error: MusicSourceError
  ) -> Duration {
    switch error {
    case .transcodingFailed, .unsupportedFormat, .invalidResponse:
      .seconds(1)
    default:
      .seconds(3)
    }
  }

  private func logPlaybackDiagnostics(for item: AVPlayerItem, reason: String) {
    let position = player.currentTime().seconds
    let itemDuration = item.duration.seconds
    let waitingReason = player.reasonForWaitingToPlay?.rawValue ?? "none"
    let ranges = item.loadedTimeRanges.map(\.timeRangeValue).map {
      "\($0.start.seconds)-\($0.start.seconds + $0.duration.seconds)"
    }.joined(separator: ",")
    Self.logger.notice(
      "播放状态：reason=\(reason, privacy: .public), session=\(self.playbackRequestID, privacy: .public), position=\(position, privacy: .public), duration=\(itemDuration, privacy: .public), rate=\(self.player.rate, privacy: .public), timeControl=\(self.player.timeControlStatus.rawValue, privacy: .public), waiting=\(waitingReason, privacy: .public), itemStatus=\(item.status.rawValue, privacy: .public), likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp, privacy: .public), bufferEmpty=\(item.isPlaybackBufferEmpty, privacy: .public), bufferFull=\(item.isPlaybackBufferFull, privacy: .public), ranges=\(ranges, privacy: .public)")
    if let event = item.accessLog()?.events.last {
      Self.logger.notice(
        "播放诊断：reason=\(reason, privacy: .public), uri=\(event.uri ?? "", privacy: .private), server=\(event.serverAddress ?? "", privacy: .private), stalls=\(event.numberOfStalls, privacy: .public), requests=\(event.numberOfMediaRequests, privacy: .public), bytes=\(event.numberOfBytesTransferred, privacy: .public), observedBitrate=\(event.observedBitrate, privacy: .public), indicatedBitrate=\(event.indicatedBitrate, privacy: .public), transfer=\(event.transferDuration, privacy: .public)")
    } else {
      Self.logger.notice("播放诊断：reason=\(reason, privacy: .public), accessLog=empty")
    }
    if let event = item.errorLog()?.events.last {
      Self.logger.error(
        "播放错误日志：domain=\(event.errorDomain, privacy: .public), status=\(event.errorStatusCode, privacy: .public)")
    }
  }

  nonisolated static func effectiveStreamingQuality(
    wifiQuality: StreamingQuality, usesCellularNetwork: Bool
  ) -> StreamingQuality {
    usesCellularNetwork ? cellularStreamingQuality : wifiQuality
  }

  nonisolated static func prefetchStartTime(
    trackDuration: TimeInterval, usesExpensiveNetwork: Bool
  ) -> TimeInterval {
    usesExpensiveNetwork ? 3 : max(trackDuration, 0) * prefetchStartFraction
  }

  nonisolated static func startupBufferDuration(
    usesExpensiveNetwork: Bool
  ) -> TimeInterval {
    usesExpensiveNetwork ? 2 : 8
  }

  private func syncPlaybackState() {
    #if DEBUG
      guard !usesVisualAuditPlaybackState else { return }
    #endif
    let status = player.timeControlStatus
    let wasBuffering = isBuffering
    isPlaying = status == .playing
    isBuffering = status == .waitingToPlayAtSpecifiedRate
    if isBuffering {
      prefetchTask?.cancel()
      prefetchTask = nil
    } else if wasBuffering, isPlaying {
      prefetchUpcomingTracks()
    }
    if status == .playing, let requestedAt = playbackRequestedAt {
      let elapsed = Date().timeIntervalSince(requestedAt)
      Self.logger.info("音频开始播放，启动耗时 \(elapsed, format: .fixed(precision: 3)) 秒")
      playbackRequestedAt = nil
    } else if status == .waitingToPlayAtSpecifiedRate {
      let reason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
      Self.logger.debug("播放器等待起播：\(reason, privacy: .public)")
    }
    if status == .playing, artworkNetworkReleaseTask == nil {
      let requestID = playbackRequestID
      let trackID = currentTrack?.id
      artworkNetworkReleaseTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(7)) } catch { return }
        guard let self, self.wantsPlayback, self.player.timeControlStatus == .playing,
          self.playbackRequestID == requestID, self.currentTrack?.id == trackID
        else { return }
        ArtworkRepository.shared.allowCellularArtworkNetworking()
        self.artworkNetworkReleaseTask = nil
      }
    } else if status != .playing {
      artworkNetworkReleaseTask?.cancel()
      artworkNetworkReleaseTask = nil
    }
    updateNowPlaying()
  }

  #if DEBUG
    var automaticallyWaitsToMinimizeStallingForTesting: Bool {
      player.automaticallyWaitsToMinimizeStalling
    }
    var preferredForwardBufferDurationForTesting: TimeInterval? {
      player.currentItem?.preferredForwardBufferDuration
    }
    var hasAudioReactiveMixForTesting: Bool {
      player.currentItem?.audioMix != nil
    }

    func loadVisualAuditTrack(_ track: MusicTrack, at time: TimeInterval = 48) {
      audioReactiveAnalyzer.enablePreviewMode()
      usesVisualAuditPlaybackState = true
      queue = [track]
      currentIndex = 0
      currentTrack = track
      currentTime = time
      duration = track.duration
      wantsPlayback = true
      isPlaying = true
      isBuffering = false
      updateNowPlaying()
    }
  #endif
  private func updateNowPlaying() {
    let center = MPNowPlayingInfoCenter.default()
    guard let track = currentTrack else {
      center.nowPlayingInfo = nil
      center.playbackState = .stopped
      broadcastPlaybackStateIfNeeded()
      return
    }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artistName,
      MPMediaItemPropertyAlbumTitle: track.albumTitle ?? "",
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaybackRequested ? 1 : 0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
      MPNowPlayingInfoPropertyPlaybackQueueIndex: currentIndex ?? 0,
    ]
    if let nowPlayingArtwork {
      info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
    }
    center.nowPlayingInfo = info
    center.playbackState = isPlaybackRequested ? .playing : .paused
    broadcastPlaybackStateIfNeeded()
  }
  private func loadNowPlayingArtwork(for track: MusicTrack, requestID: UInt) {
    nowPlayingArtworkTask?.cancel()
    guard let artworkURL = track.artworkURL else { return }
    let provider = self.provider
    let providerID = provider.id
    let cacheIdentity = track.albumRemoteID.map { "album:\($0)" }
      ?? "track:\(track.identity.remoteID)"
    nowPlayingArtworkTask = Task { [weak self] in
      let fetcher = MusicArtworkFetcher { url in
        try await provider.loadMediaResource(at: url, range: nil).data
      }
      guard
        let image = await ArtworkRepository.shared.image(
          for: artworkURL, serverID: providerID, fetcher: fetcher,
          cacheIdentity: cacheIdentity, maximumPixelSize: 512),
        !Task.isCancelled,
        let self,
        self.playbackRequestID == requestID,
        self.currentTrack?.id == track.id
      else { return }
      self.nowPlayingArtwork = NowPlayingArtworkFactory.make(
        image: image, boundsSize: image.size)
      self.updateNowPlaying()
      self.nowPlayingArtworkTask = nil
    }
  }
  private func broadcastPlaybackStateIfNeeded() {
    let trackID = currentTrack?.id
    let requested = isPlaybackRequested
    guard trackID != lastBroadcastTrackID || requested != lastBroadcastPlaybackRequested else {
      return
    }
    lastBroadcastTrackID = trackID
    lastBroadcastPlaybackRequested = requested
    NotificationCenter.default.post(name: .musicPlaybackStateDidChange, object: nil)
  }
  private func persistQueue() async {
    try? await cache.store(
      PlaybackQueue(tracks: queue, currentIndex: currentIndex, updatedAt: Date()),
      serverID: provider.id, namespace: .queue, key: "current")
  }
  private func prefetchUpcomingTracks() {
    prefetchTask?.cancel()
    guard provider.sourceType != .local, let currentIndex, let currentTrack else { return }
    let requestID = playbackRequestID
    let upcoming = Self.upcomingTracks(
      in: queue, currentIndex: currentIndex, order: playbackOrder, limit: Self.prefetchedTrackLimit)
    guard !upcoming.isEmpty else { return }
    prefetchTask = Task(priority: .utility) {
      [weak self, provider, cache, wifiQuality, network, prefetchDelay] in
      do { try await Task.sleep(for: prefetchDelay) } catch { return }
      guard let self,
        await self.waitForCurrentTrackToTakePriority(track: currentTrack, requestID: requestID)
      else { return }
      for track in upcoming {
        while !Task.isCancelled {
          guard self.isCurrentRequest(requestID, track: currentTrack) else { return }
          let usesCellularNetwork = network.isCellular
          let quality: StreamingQuality =
            if usesCellularNetwork {
              self.cellularOriginalFallbackTrackIDs.contains(track.id)
                ? .original : Self.cellularStreamingQuality
            } else {
              wifiQuality
            }
          let cacheKey = UnifiedPlaybackController.mediaCacheKey(for: track, quality: quality)
          if let cachedURL = await cache.mediaURL(serverID: provider.id, key: cacheKey) {
            if await Self.cachedMediaIsComplete(cachedURL, for: track) {
              break
            }
            Self.logger.error("下一首已有缓存不完整，删除后重新预取")
            await cache.removeMedia(serverID: provider.id, key: cacheKey)
          }
          guard network.isAvailable else {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            continue
          }
          do {
            try Task.checkCancellation()
            try await Self.downloadAndCachePrefetchedTrack(
              track, quality: quality, cacheKey: cacheKey, provider: provider, cache: cache)
            break
          } catch is CancellationError {
            return
          } catch {
            let mapped = MusicSourceError.map(error)
            if usesCellularNetwork, quality == Self.cellularStreamingQuality,
              Self.shouldFallbackToOriginalFromCellularMP3(after: mapped)
            {
              self.cellularOriginalFallbackTrackIDs.insert(track.id)
              Self.logger.notice("下一首的蜂窝 MP3 转码失败，改为预取原始格式")
              let fallbackCacheKey = Self.mediaCacheKey(for: track, quality: .original)
              do {
                try await Self.downloadAndCachePrefetchedTrack(
                  track, quality: .original, cacheKey: fallbackCacheKey,
                  provider: provider, cache: cache)
              } catch is CancellationError {
                return
              } catch {
                let fallbackError = MusicSourceError.map(error)
                Self.logger.error(
                  "下一首原始格式预取失败：\(fallbackError.localizedDescription, privacy: .public)")
              }
              break
            }
            Self.logger.error(
              "下一首预取失败：\(mapped.localizedDescription, privacy: .public)")
            guard Self.shouldRetryPrefetch(after: mapped) else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
          }
        }
      }
    }
  }

  nonisolated static func upcomingTracks(
    in queue: [MusicTrack], currentIndex: Int, order: PlaybackOrder, limit: Int
  ) -> [MusicTrack] {
    guard queue.indices.contains(currentIndex), queue.count > 1, limit > 0 else { return [] }
    let count = min(limit, queue.count - 1)
    switch order {
    case .sequential:
      return (1...count).map { queue[(currentIndex + $0) % queue.count] }
    case .shuffle:
      return queue.enumerated()
        .filter { $0.offset != currentIndex }
        .map(\.element)
        .prefix(count)
        .map { $0 }
    }
  }

  private func waitForCurrentTrackToTakePriority(track: MusicTrack, requestID: UInt) async -> Bool {
    while !Task.isCancelled {
      guard isCurrentRequest(requestID, track: track) else { return false }
      guard player.timeControlStatus == .playing, !isBuffering else {
        do { try await Task.sleep(for: .seconds(3)) } catch { return false }
        continue
      }
      let threshold =
        Self.prefetchStartTime(
          trackDuration: track.duration,
          usesExpensiveNetwork: network.isConstrainedOrExpensive)
      if currentTime >= threshold { return true }
      do { try await Task.sleep(for: .seconds(3)) } catch { return false }
    }
    return false
  }

  private nonisolated static func downloadAndCachePrefetchedTrack(
    _ track: MusicTrack, quality: StreamingQuality, cacheKey: String,
    provider: any MusicSourceProvider, cache: MusicCache
  ) async throws {
    let remoteURL = try await provider.streamURL(for: track, quality: quality)
    let download = try await provider.downloadMediaResource(at: remoteURL)
    defer { try? FileManager.default.removeItem(at: download.temporaryURL) }
    try Task.checkCancellation()
    guard (200...299).contains(download.statusCode) else {
      throw MusicSourceError.httpStatus(download.statusCode)
    }
    let values = try download.temporaryURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw MusicSourceError.invalidResponse }
    let actualByteCount = Int64(values.fileSize ?? 0)
    let declaredByteCount =
      download.headers["content-length"].flatMap(Int64.init)
      ?? (download.expectedContentLength > 0 ? download.expectedContentLength : nil)
    guard actualByteCount > 0,
      declaredByteCount == nil || declaredByteCount == actualByteCount
    else {
      logger.error(
        "预取文件长度不完整：actual=\(actualByteCount, privacy: .public), declared=\(declaredByteCount ?? -1, privacy: .public)")
      throw MusicSourceError.invalidResponse
    }

    let asset = AVURLAsset(url: download.temporaryURL)
    async let playable = asset.load(.isPlayable)
    async let audioTracks = asset.loadTracks(withMediaType: .audio)
    async let loadedDuration = try? asset.load(.duration)
    let tracks = try await audioTracks
    guard try await playable, !tracks.isEmpty else {
      throw MusicSourceError.unsupportedFormat
    }
    let loadedTime = await loadedDuration
    let loadedSeconds = loadedTime?.seconds
    let mediaDuration: TimeInterval? =
      if let loadedSeconds, loadedSeconds.isFinite, loadedSeconds > 0 {
        loadedSeconds
      } else {
        nil
      }
    guard mediaDuration != nil || track.duration <= 0,
      MediaDurationPolicy.isPlausible(
        catalogDuration: track.duration, mediaDuration: mediaDuration)
    else {
      logger.error(
        "预取文件时长异常：catalog=\(track.duration, privacy: .public), media=\(mediaDuration ?? -1, privacy: .public)")
      throw MusicSourceError.invalidResponse
    }
    let stored = try await cache.storeMediaFile(
      at: download.temporaryURL, serverID: provider.id, key: cacheKey,
      fileExtension: cacheFileExtension(
        mimeType: download.mimeType, fallback: track.suffix))
    guard stored else { throw MusicSourceError.invalidResponse }
    logger.info(
      "下一首已流式预取并校验：bytes=\(actualByteCount, privacy: .public), duration=\(mediaDuration ?? -1, privacy: .public)")
  }

  private nonisolated static func cachedMediaIsComplete(
    _ url: URL, for track: MusicTrack
  ) async -> Bool {
    let asset = AVURLAsset(url: url)
    do {
      async let playable = asset.load(.isPlayable)
      async let audioTracks = asset.loadTracks(withMediaType: .audio)
      async let loadedDuration = asset.load(.duration)
      let tracks = try await audioTracks
      let duration = try await loadedDuration
      let isPlayable = try await playable
      return isPlayable && !tracks.isEmpty
        && duration.seconds.isFinite && duration.seconds > 0
        && MediaDurationPolicy.isPlausible(
          catalogDuration: track.duration, mediaDuration: duration.seconds)
    } catch {
      return false
    }
  }

  private nonisolated static func shouldRetryPrefetch(after error: MusicSourceError) -> Bool {
    switch error {
    case .dnsFailure, .networkUnavailable, .timeout, .transcodingFailed:
      true
    case .httpStatus(let status):
      [408, 425, 429, 500, 502, 503, 504].contains(status)
    default:
      false
    }
  }

  nonisolated static func shouldFallbackToOriginalFromCellularMP3(
    after error: MusicSourceError
  ) -> Bool {
    switch error {
    case .transcodingFailed, .unsupportedFormat:
      true
    case .httpStatus(let status):
      [400, 404, 406, 415, 422, 500, 501].contains(status)
    default:
      false
    }
  }
  private nonisolated static func cacheFileExtension(
    mimeType: String?, fallback: String?
  ) -> String? {
    guard let mimeType = mimeType?.lowercased() else { return fallback }
    switch mimeType {
    case "audio/mpeg", "audio/mp3": return "mp3"
    case "audio/mp4", "audio/x-m4a": return "m4a"
    case "audio/aac": return "aac"
    case "audio/flac", "audio/x-flac": return "flac"
    case "audio/wav", "audio/x-wav", "audio/vnd.wave": return "wav"
    case "audio/aiff", "audio/x-aiff": return "aiff"
    case "audio/ogg": return "ogg"
    default: return UTType(mimeType: mimeType)?.preferredFilenameExtension ?? fallback
    }
  }
  private nonisolated static func mediaCacheKey(
    for track: MusicTrack, quality: StreamingQuality
  ) -> String {
    "\(track.identity.remoteID)|quality:\(quality.rawValue)"
  }
  private func restoreQueue() async {
    guard
      let value = try? await cache.load(
        PlaybackQueue.self, serverID: provider.id, namespace: .queue, key: "current")
    else { return }
    queue = value.tracks
    currentIndex = value.currentIndex
    if let index = value.currentIndex, value.tracks.indices.contains(index) {
      currentTrack = value.tracks[index]
      duration = value.tracks[index].duration
      updateNowPlaying()
    }
  }
  private func recordHistory(track: MusicTrack, position: TimeInterval, completed: Bool) async {
    var items =
      (try? await cache.load(
        [PlaybackHistory].self, serverID: provider.id, namespace: .playbackHistory, key: "items"))
      ?? []
    items.insert(
      .init(
        id: UUID(), serverID: provider.id, track: track, playedAt: Date(), position: position,
        completed: completed), at: 0)
    try? await cache.store(
      Array(items.prefix(500)), serverID: provider.id, namespace: .playbackHistory, key: "items")
  }
  private func unique(_ values: [MusicTrack]) -> [MusicTrack] {
    var seen = Set<UUID>()
    return values.filter { seen.insert($0.id).inserted }
  }
}

enum PlaybackCompletionPolicy {
  static func shouldAdvance(
    position: TimeInterval, catalogDuration: TimeInterval, itemDuration: TimeInterval
  ) -> Bool {
    let expectedDurations = [catalogDuration, itemDuration].filter { $0.isFinite && $0 > 0 }
    guard let expectedDuration = expectedDurations.max() else { return true }
    guard position.isFinite, position >= 0 else { return false }
    let tolerance = min(5, max(1.5, expectedDuration * 0.02))
    return position + tolerance >= expectedDuration
  }
}

struct PlaybackAssetInspection {
  let audioTrack: AVAssetTrack
  let duration: TimeInterval?
}

enum MediaDurationPolicy {
  static func isPlausible(
    catalogDuration: TimeInterval, mediaDuration: TimeInterval?
  ) -> Bool {
    guard catalogDuration.isFinite, catalogDuration > 0, let mediaDuration,
      mediaDuration.isFinite, mediaDuration > 0
    else { return true }
    let tolerance = max(15, catalogDuration * 0.20)
    return abs(mediaDuration - catalogDuration) <= tolerance
  }
}

enum AudioSessionInterruptionPolicy {
  static func shouldResumePlayback(
    wasPlayingBeforeInterruption: Bool, systemAllowsResume: Bool
  ) -> Bool {
    wasPlayingBeforeInterruption && systemAllowsResume
  }
}

private final class NotificationBox: @unchecked Sendable {
  let notification: Notification
  init(_ notification: Notification) { self.notification = notification }
}

private final class NetworkQualityMonitor: @unchecked Sendable {
  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var expensive = true
  private var available = true
  private var cellular = false
  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      self?.lock.withLock {
        self?.available = path.status == .satisfied
        self?.cellular =
          path.status == .satisfied && path.usesInterfaceType(.cellular)
        self?.expensive =
          path.status != .satisfied || path.isExpensive || path.isConstrained
      }
    }
    monitor.start(queue: DispatchQueue(label: "music.network-quality"))
  }
  deinit { monitor.cancel() }
  var isConstrainedOrExpensive: Bool { lock.withLock { expensive } }
  var isAvailable: Bool { lock.withLock { available } }
  var isCellular: Bool { lock.withLock { cellular } }
}
