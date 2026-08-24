import SwiftUI

struct PlaybackVisualState: Equatable, Sendable {
  let trackID: UUID?
  let title: String
  let artist: String
  let artworkURL: URL?
  let artworkCacheIdentity: String?
  let isPlaying: Bool
  let isBuffering: Bool
  let currentTime: TimeInterval
  let duration: TimeInterval

  @MainActor
  init(playback: UnifiedPlaybackController) {
    trackID = playback.currentTrack?.id
    title = playback.currentTrack?.title ?? "未在播放"
    artist = playback.currentTrack?.artistName ?? ""
    artworkURL = playback.currentTrack?.artworkURL
    artworkCacheIdentity = playback.currentTrack.map {
      $0.albumRemoteID.map { "album:\($0)" } ?? "track:\($0.identity.remoteID)"
    }
    isPlaying = playback.isPlaying
    isBuffering = playback.isBuffering
    currentTime = playback.currentTime
    duration = playback.duration
  }
}

struct ImmersiveVisualStage: View {
  @Environment(UnifiedPlaybackController.self) private var playback
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.musicServerID) private var serverID
  @Environment(\.musicArtworkFetcher) private var artworkFetcher
  let lyrics: MusicLyrics?
  @Binding var isLyricsOnly: Bool
  let onDismiss: () -> Void
  let onExitStage: () -> Void

  @State private var interfaceVisible = true
  @State private var autoHideTask: Task<Void, Never>?
  @State private var scrubSafetyTask: Task<Void, Never>?
  @State private var isScrubbing = false
  @State private var stageIsLandscape = false
  @State private var stageHasEntered = false
  @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
  @State private var palette = StagePalette.fallback
  @AppStorage("immersive.visual.preset") private var preset = VisualEffectPreset.starTide

  private var visualState: PlaybackVisualState { .init(playback: playback) }
  private var motionIsAllowed: Bool {
    !reduceMotion && !lowPowerMode && scenePhase == .active
  }
  private var shouldAutoHideInterface: Bool {
    stageIsLandscape && scenePhase == .active && !voiceOverEnabled && !isScrubbing
  }

  var body: some View {
    GeometryReader { proxy in
      let landscape = proxy.size.width > proxy.size.height
      let stageContentVisible = !landscape || interfaceVisible || isLyricsOnly
      ZStack {
        AudioReactiveMetalStage(
          analyzer: playback.audioReactiveAnalyzer, preset: preset, palette: palette,
          trackID: visualState.trackID,
          isPlaying: visualState.isPlaying && !visualState.isBuffering,
          allowsMotion: motionIsAllowed)
          .scaleEffect(stageHasEntered || reduceMotion ? 1 : 1.10)
          .opacity(stageHasEntered || reduceMotion ? 1 : 0)
          .ignoresSafeArea()
          .accessibilityHidden(true)
        LinearGradient(
          colors: [
            .black.opacity(0.34), .black.opacity(0.02),
            .black.opacity(landscape ? 0.22 : isLyricsOnly ? 0.58 : 0.22),
          ],
          startPoint: .top, endPoint: .bottom)
          .ignoresSafeArea()

        Group {
          if landscape {
            DimensionalStageLyricsColumn(lyrics: lyrics)
              .frame(
                width: min(680, proxy.size.width * 0.46),
                alignment: .leading)
              .offset(
                x: stageHasEntered || reduceMotion ? 0 : 112)
              .opacity(stageHasEntered || reduceMotion ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(
              .trailing,
              max(proxy.size.width * 0.045, proxy.safeAreaInsets.trailing + 28))
            .padding(.top, 52)
            .padding(.bottom, 116)
          } else if isLyricsOnly {
            SyncedLyricsView(lyrics: lyrics)
              .frame(maxWidth: 680)
              .padding(.horizontal, 24)
              .padding(.vertical, 54)
          } else {
            VStack(spacing: 22) {
              record(maximum: min(proxy.size.width - 96, 350))
                .scaleEffect(interfaceVisible || reduceMotion ? 1 : 0.985)
                .offset(y: stageHasEntered || reduceMotion ? 0 : -72)
              StageLyricsColumn(lyrics: lyrics)
                .frame(maxWidth: 560)
                .offset(y: stageHasEntered || reduceMotion ? 0 : 88)
                .opacity(stageHasEntered || reduceMotion ? 1 : 0)
            }
            .padding(.horizontal, 28)
            .padding(.top, 72)
            .padding(.bottom, 228)
          }
        }
        .opacity(landscape ? 1 : stageContentVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(!landscape && !stageContentVisible)

        StageChrome(
          visualState: visualState, preset: $preset, isLyricsOnly: $isLyricsOnly, onDismiss: onDismiss,
          onExitStage: onExitStage, differentiateWithoutColor: differentiateWithoutColor,
          isLandscape: landscape, bottomSafeArea: proxy.safeAreaInsets.bottom,
          onInteraction: revealInterface,
          onScrubbingChanged: handleScrubbing)
          .offset(
            y: (stageHasEntered || reduceMotion ? 0 : 36)
              + (interfaceVisible || reduceMotion ? 0 : 64))
          .opacity(interfaceVisible ? 1 : 0)
          .allowsHitTesting(interfaceVisible)
          .accessibilityHidden(!interfaceVisible)
          .padding(.leading, landscape ? proxy.safeAreaInsets.leading : 0)
          .padding(.trailing, landscape ? proxy.safeAreaInsets.trailing : 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea(.all)
      .contentShape(Rectangle())
      .onTapGesture { revealInterface() }
      .onAppear {
        stageIsLandscape = landscape
        playback.setAudioReactiveAnalysisEnabled(landscape && motionIsAllowed)
      }
      .onChange(of: landscape) { _, newValue in
        stageIsLandscape = newValue
        playback.setAudioReactiveAnalysisEnabled(newValue && motionIsAllowed)
        revealInterface()
      }
    }
    .ignoresSafeArea(.all)
    .preferredColorScheme(.dark)
    .onAppear {
      playback.setAudioReactiveAnalysisEnabled(stageIsLandscape && motionIsAllowed)
      stageHasEntered = reduceMotion
      if !reduceMotion {
        withAnimation(.spring(duration: 0.72, bounce: 0.18)) { stageHasEntered = true }
      }
      scheduleInterfaceToHide()
    }
    .onDisappear {
      autoHideTask?.cancel()
      scrubSafetyTask?.cancel()
      playback.setAudioReactiveAnalysisEnabled(false)
    }
    .onChange(of: motionIsAllowed) { _, enabled in
      playback.setAudioReactiveAnalysisEnabled(stageIsLandscape && enabled)
    }
    .onChange(of: visualState.trackID) { _, _ in revealInterface() }
    .onChange(of: shouldAutoHideInterface) { _, shouldHide in
      autoHideTask?.cancel()
      if shouldHide {
        scheduleInterfaceToHide()
      } else {
        withAnimation(reduceMotion ? .linear(duration: 0.1) : .easeOut(duration: 0.16)) {
          interfaceVisible = true
        }
      }
    }
    .onChange(of: isLyricsOnly) { _, _ in revealInterface() }
    .onChange(of: reduceMotion) { _, reduced in
      if reduced { stageHasEntered = true }
    }
    .onChange(of: preset) { _, _ in revealInterface() }
    .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
      lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    .task(id: visualState.artworkURL) {
      palette = await ArtworkPaletteLoader.shared.palette(
        for: visualState.artworkURL, trackID: visualState.trackID,
        cacheIdentity: visualState.artworkCacheIdentity, serverID: serverID,
        fetcher: artworkFetcher)
    }
  }

  private func record(maximum: CGFloat) -> some View {
    RotatingRecordArtwork(
      visualState: visualState,
      analyzer: playback.audioReactiveAnalyzer,
      allowsMotion: motionIsAllowed)
      .frame(width: maximum, height: maximum)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(visualState.title)，\(visualState.artist)，\(visualState.isPlaying ? String(localized: "正在播放") : String(localized: "已暂停"))")
  }

  private func revealInterface() {
    withAnimation(reduceMotion ? .linear(duration: 0.1) : .easeOut(duration: 0.2)) {
      interfaceVisible = true
    }
    scheduleInterfaceToHide()
  }

  private func handleScrubbing(_ scrubbing: Bool) {
    isScrubbing = scrubbing
    autoHideTask?.cancel()
    scrubSafetyTask?.cancel()
    if scrubbing {
      withAnimation(reduceMotion ? .linear(duration: 0.1) : .easeOut(duration: 0.2)) {
        interfaceVisible = true
      }
      scrubSafetyTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(6))
        guard !Task.isCancelled else { return }
        isScrubbing = false
        scheduleInterfaceToHide()
      }
    } else {
      revealInterface()
    }
  }

  private func scheduleInterfaceToHide() {
    autoHideTask?.cancel()
    guard shouldAutoHideInterface else { return }
    autoHideTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      withAnimation(reduceMotion ? .linear(duration: 0.1) : .easeInOut(duration: 0.28)) {
        interfaceVisible = false
      }
    }
  }
}

private struct RotatingRecordArtwork: View {
  let visualState: PlaybackVisualState
  let analyzer: AudioReactiveAnalyzer
  let allowsMotion: Bool
  @State private var baseAngle = 0.0
  @State private var anchor = Date()
  @State private var isDecelerating = false
  @State private var decelerationDuration = 0.38
  @State private var motionTask: Task<Void, Never>?

  private let degreesPerSecond = 200.0
  private var shouldSpin: Bool {
    allowsMotion && visualState.isPlaying && !visualState.isBuffering
  }

  var body: some View {
    TimelineView(
      .animation(minimumInterval: 1 / 60, paused: !(shouldSpin || isDecelerating))
    ) { context in
      let response = motionResponse(at: context.date)
      recordFace
        .rotationEffect(.degrees(angle(at: context.date)))
        .scaleEffect(response.scale)
        .rotation3DEffect(
          .degrees(response.tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.42)
        .rotation3DEffect(
          .degrees(response.tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.42)
        .offset(x: response.offsetX, y: response.offsetY)
    }
    .overlay {
      Circle()
        .strokeBorder(statusColor, lineWidth: visualState.isBuffering ? 5 : 2)
        .opacity(visualState.isBuffering ? 0.78 : 0.58)
        .scaleEffect(0.97)
        .animation(.easeInOut(duration: 0.3), value: visualState.isBuffering)
    }
    .overlay {
      if visualState.isBuffering {
        ProgressView().tint(.white).controlSize(.large)
      }
    }
    .shadow(color: .black.opacity(0.46), radius: 34, y: 18)
    .onAppear {
      baseAngle = visualState.currentTime * degreesPerSecond
      anchor = Date()
    }
    .onChange(of: shouldSpin) { oldValue, newValue in
      transitionMotion(wasSpinning: oldValue, isSpinning: newValue)
    }
    .onChange(of: visualState.trackID) { _, _ in
      motionTask?.cancel()
      baseAngle = 0
      anchor = Date()
      isDecelerating = false
    }
    .onDisappear { motionTask?.cancel() }
  }

  private var recordFace: some View {
    ZStack {
      Circle()
        .fill(Color(red: 0.035, green: 0.032, blue: 0.055))
        .overlay {
          AngularGradient(
            colors: [
              .white.opacity(0.015), .white.opacity(0.095), .clear,
              .white.opacity(0.045), .clear, .white.opacity(0.015),
            ], center: .center)
            .clipShape(Circle())
            .blendMode(.screen)
        }
      ForEach(1..<8, id: \.self) { index in
        Circle()
          .stroke(.white.opacity(index.isMultiple(of: 2) ? 0.045 : 0.025), lineWidth: 1)
          .padding(CGFloat(index) * 11)
      }
      CoverArtworkView(
        url: visualState.artworkURL, cornerRadius: 999,
        cacheIdentity: visualState.artworkCacheIdentity, maximumPixelSize: 768)
        .clipShape(Circle())
        .padding(52)
      Circle().fill(Color(red: 0.97, green: 0.96, blue: 1)).frame(width: 18, height: 18)
      Circle().fill(Color(red: 0.61, green: 0.48, blue: 1)).frame(width: 7, height: 7)
    }
    .overlay {
      Circle()
        .stroke(
          AngularGradient(
            colors: [.white.opacity(0.20), .clear, .white.opacity(0.04), .clear],
            center: .center),
          lineWidth: 1)
        .padding(2)
    }
  }

  private func motionResponse(at date: Date) -> (
    scale: CGFloat, tiltX: Double, tiltY: Double, offsetX: CGFloat, offsetY: CGFloat
  ) {
    guard allowsMotion, visualState.isPlaying, !visualState.isBuffering else {
      return (1, 0, 0, 0, 0)
    }
    let audio = analyzer.snapshot(at: date.timeIntervalSinceReferenceDate)
    let time = date.timeIntervalSinceReferenceDate
    let beat = CGFloat(audio.beatPulse)
    let low = CGFloat(audio.low)
    let mid = CGFloat(audio.mid)
    let high = CGFloat(audio.high)
    let breathing = CGFloat(sin(time * 0.72))
    let drift = CGFloat(sin(time * 0.31))
    return (
      1 + low * 0.025 + beat * 0.065 + breathing * 0.008,
      Double(-4.5 + mid * 7.0 + sin(time * 0.43) * 2.8),
      Double(drift * (4.0 + Double(high) * 3.0)),
      drift * (5 + high * 5),
      -beat * 8 + breathing * 3
    )
  }

  private var statusColor: Color {
    if visualState.isBuffering { return .white.opacity(0.72) }
    return visualState.isPlaying
      ? Color(red: 0.65, green: 0.54, blue: 0.98) : .gray.opacity(0.72)
  }

  private func angle(at date: Date) -> Double {
    let elapsed = max(0, date.timeIntervalSince(anchor))
    if shouldSpin {
      let acceleration = 0.65
      if elapsed < acceleration {
        let t = elapsed / acceleration
        return baseAngle + degreesPerSecond * acceleration * (t * t - t * t * t / 3)
      }
      return baseAngle + degreesPerSecond * acceleration * (2 / 3)
        + degreesPerSecond * (elapsed - acceleration)
    }
    if isDecelerating {
      let t = min(elapsed / decelerationDuration, 1)
      return baseAngle + degreesPerSecond * decelerationDuration * (t - t * t / 2)
    }
    return baseAngle
  }

  private func transitionMotion(wasSpinning: Bool, isSpinning: Bool) {
    let now = Date()
    motionTask?.cancel()
    baseAngle = angle(at: now).truncatingRemainder(dividingBy: 360)
    anchor = now
    if isSpinning {
      isDecelerating = false
      return
    }
    guard wasSpinning, allowsMotion else {
      isDecelerating = false
      return
    }
    decelerationDuration = visualState.isBuffering ? 0.30 : 0.38
    isDecelerating = true
    let duration = decelerationDuration
    motionTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(duration))
      guard !Task.isCancelled else { return }
      baseAngle = angle(at: Date()).truncatingRemainder(dividingBy: 360)
      anchor = Date()
      isDecelerating = false
    }
  }
}

private struct DimensionalStageLyricsColumn: View {
  @Environment(UnifiedPlaybackController.self) private var playback
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let lyrics: MusicLyrics?

  private var activeIndex: Int? {
    guard let lyrics, lyrics.isSynced else { return nil }
    return lyrics.lines.lastIndex { ($0.time ?? .infinity) <= playback.currentTime }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let lyrics, !lyrics.lines.isEmpty {
        ForEach(neighboringLines(in: lyrics), id: \.index) { item in
          let distance = abs(item.index - (activeIndex ?? 0))
          Text(item.line.text.isEmpty ? "·" : item.line.text)
            .font(
              .system(
                size: distance == 0 ? 42 : distance == 1 ? 31 : 23,
                weight: distance == 0 ? .bold : distance == 1 ? .semibold : .medium,
                design: .rounded))
            .foregroundStyle(
              distance == 0 ? .white : .white.opacity(distance == 1 ? 0.54 : 0.31))
            .lineLimit(2)
            .minimumScaleFactor(0.74)
            .frame(maxWidth: .infinity, alignment: distance == 0 ? .trailing : .leading)
            .offset(x: reduceMotion ? 0 : CGFloat(distance == 0 ? 10 : -distance * 22))
            .rotation3DEffect(
              reduceMotion ? .zero : .degrees(Double(distance) * -5),
              axis: (x: 0, y: 1, z: 0),
              anchor: .trailing,
              perspective: 0.62)
            .shadow(
              color: distance == 0 ? .black.opacity(0.62) : .clear,
              radius: distance == 0 ? 18 : 0, y: 8)
            .accessibilityAddTraits(distance == 0 ? .isSelected : [])
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Image(systemName: "quote.bubble").font(.title2)
          Text("这首歌还没有歌词").font(.title2.bold())
        }
        .foregroundStyle(.white.opacity(0.74))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 24)
    .padding(.vertical, 28)
    .background {
      RadialGradient(
        colors: [.black.opacity(0.52), .black.opacity(0.16), .clear],
        center: .center, startRadius: 0, endRadius: 340)
        .blur(radius: 24)
        .allowsHitTesting(false)
    }
    .animation(
      reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.44, dampingFraction: 0.84),
      value: activeIndex)
  }

  private func neighboringLines(in lyrics: MusicLyrics) -> [(index: Int, line: MusicLyrics.Line)] {
    guard !lyrics.lines.isEmpty else { return [] }
    let center = activeIndex ?? 0
    let lower = max(0, center - 2)
    let upper = min(lyrics.lines.count - 1, center + 2)
    return (lower...upper).map { ($0, lyrics.lines[$0]) }
  }
}

private struct StageLyricsColumn: View {
  @Environment(UnifiedPlaybackController.self) private var playback
  let lyrics: MusicLyrics?

  private var activeIndex: Int? {
    guard let lyrics, lyrics.isSynced else { return nil }
    return lyrics.lines.lastIndex { ($0.time ?? .infinity) <= playback.currentTime }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let lyrics, !lyrics.lines.isEmpty {
        ForEach(neighboringLines(in: lyrics), id: \.index) { item in
          Text(item.line.text.isEmpty ? "·" : item.line.text)
            .font(.system(
              size: item.index == activeIndex ? 35 : 21,
              weight: item.index == activeIndex ? .semibold : .medium,
              design: .rounded))
            .foregroundStyle(foregroundColor(for: item.index))
            .shadow(
              color: item.index == activeIndex ? .white.opacity(0.18) : .clear,
              radius: item.index == activeIndex ? 14 : 0)
            .lineLimit(3)
            .minimumScaleFactor(0.82)
            .accessibilityAddTraits(item.index == activeIndex ? .isSelected : [])
        }
      } else {
        VStack(alignment: .leading, spacing: 10) {
          Image(systemName: "quote.bubble").font(.title2)
          Text("这首歌还没有歌词").font(.title2.bold())
          Text("可以继续欣赏封面与播放状态驱动视觉。")
            .font(.subheadline).foregroundStyle(.white.opacity(0.58))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 26)
    .padding(.vertical, 30)
    .background {
      RadialGradient(
        colors: [.black.opacity(0.50), .black.opacity(0.18), .clear],
        center: .center, startRadius: 0, endRadius: 330)
        .blur(radius: 22)
        .allowsHitTesting(false)
    }
  }

  private func neighboringLines(in lyrics: MusicLyrics) -> [(index: Int, line: MusicLyrics.Line)] {
    guard !lyrics.lines.isEmpty else { return [] }
    let center = activeIndex ?? 0
    let lower = max(0, center - 1)
    let upper = min(lyrics.lines.count - 1, center + 1)
    return (lower...upper).map { ($0, lyrics.lines[$0]) }
  }

  private func foregroundColor(for index: Int) -> Color {
    guard let activeIndex else { return index == 0 ? .white : .white.opacity(0.30) }
    if index == activeIndex { return .white }
    return .white.opacity(index < activeIndex ? 0.42 : 0.30)
  }
}

private struct StageChrome: View {
  @Environment(UnifiedPlaybackController.self) private var playback
  let visualState: PlaybackVisualState
  @Binding var preset: VisualEffectPreset
  @Binding var isLyricsOnly: Bool
  let onDismiss: () -> Void
  let onExitStage: () -> Void
  let differentiateWithoutColor: Bool
  let isLandscape: Bool
  let bottomSafeArea: CGFloat
  let onInteraction: () -> Void
  let onScrubbingChanged: (Bool) -> Void

  var body: some View {
    VStack {
      HStack {
        chromeButton("xmark", label: "关闭正在播放", action: onDismiss)
        VStack(alignment: .leading, spacing: 2) {
          Text(visualState.title).font(.headline).lineLimit(1)
          Text(visualState.artist).font(.caption).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        Spacer()
        if isLandscape {
          presetPicker
        } else if !isLyricsOnly {
          presetMenu
        }
        chromeButton("rectangle.portrait.and.arrow.forward", label: "退出视觉舞台", action: onExitStage)
        if !isLandscape {
          chromeButton(
            isLyricsOnly ? "square.stack.fill" : "quote.bubble.fill",
            label: isLyricsOnly ? "显示视觉舞台" : "显示纯歌词"
          ) {
            onInteraction()
            isLyricsOnly.toggle()
          }
        }
      }
      Spacer()
      if isLandscape {
        HStack(spacing: 22) {
          progress
            .frame(minWidth: 160, maxWidth: 300)
            .layoutPriority(1)
          playbackControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.black.opacity(0.24), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .trailing)
      } else {
        VStack(spacing: 12) {
          progress
          playbackControls
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      }
    }
    .padding(.horizontal, 18)
    .padding(.top, 18)
    // The visual stage ignores the outer safe area, and some landscape simulator/device
    // combinations consequently report a zero bottom inset. Keep a physical fallback so
    // the largest transport button never falls underneath the home-indicator edge.
    .padding(.bottom, isLandscape ? max(48, bottomSafeArea + 20) : 18)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
    .foregroundStyle(.white)
  }

  private var presetPicker: some View {
    HStack(spacing: 3) {
      ForEach(VisualEffectPreset.allCases) { item in
        Button {
          onInteraction()
          withAnimation(.easeInOut(duration: 0.22)) { preset = item }
        } label: {
          Label(item.title, systemImage: item.icon)
            .labelStyle(.iconOnly)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 40, height: 36)
            .background(item == preset ? .white.opacity(0.16) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.accessibilityTitle)
        .accessibilityAddTraits(item == preset ? .isSelected : [])
      }
    }
    .padding(3)
    .background(.black.opacity(0.26), in: Capsule())
  }

  private var presetMenu: some View {
    Menu {
      ForEach(VisualEffectPreset.allCases) { item in
        Button {
          onInteraction()
          withAnimation(.easeInOut(duration: 0.22)) { preset = item }
        } label: {
          Label(item.title, systemImage: item.icon)
        }
      }
    } label: {
      Image(systemName: preset.icon)
        .font(.system(size: 17, weight: .semibold))
        .frame(width: 44, height: 44)
        .background(.black.opacity(0.28), in: Circle())
    }
    .accessibilityLabel(preset.accessibilityTitle)
  }

  private var progress: some View {
    VStack(spacing: 4) {
        Slider(
          value: Binding(
            get: { playback.currentTime },
            set: { playback.seek(to: $0) }),
          in: 0...max(playback.duration, 1),
          onEditingChanged: onScrubbingChanged
        )
        .tint(Color(red: 0.66, green: 0.55, blue: 0.98))
        .frame(minHeight: 44)
        HStack {
          Text(DurationFormatter.string(from: playback.currentTime))
          Spacer()
          Text("-\(DurationFormatter.string(from: max(playback.duration - playback.currentTime, 0)))")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.62))
    }
  }

  private var playbackControls: some View {
    HStack(spacing: isLandscape ? 8 : 30) {
          playbackButton(
            playback.playbackOrder.icon,
            label: "当前\(playback.playbackOrder.title)，切换播放顺序",
            size: isLandscape ? 46 : 56
          ) { playback.togglePlaybackOrder() }
          playbackButton("backward.fill", label: "上一首", size: isLandscape ? 46 : 56) {
            Task { await playback.playPrevious() }
          }
          playbackButton(
            playback.isPlaybackRequested ? "pause.fill" : "play.fill",
            label: playback.isPlaybackRequested ? "暂停" : "播放",
            size: isLandscape ? 58 : 72
          ) { playback.togglePlayback() }
          playbackButton("forward.fill", label: "下一首", size: isLandscape ? 46 : 56) {
            Task { await playback.playNext() }
          }
    }
  }

  private func chromeButton(
    _ icon: String, label: LocalizedStringKey, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon).font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
    }
    .buttonStyle(.plain)
    .background(.black.opacity(0.28), in: Circle())
    .accessibilityLabel(Text(label))
  }

  private func playbackButton(
    _ icon: String, label: LocalizedStringKey, size: CGFloat, action: @escaping () -> Void
  ) -> some View {
    Button {
      onInteraction()
      action()
    } label: {
      Image(systemName: icon)
        .font(.system(size: size == 72 ? 28 : 20, weight: .semibold))
        .frame(width: size, height: size)
        .background(size == 72 ? Color.white : Color.white.opacity(0.10), in: Circle())
        .foregroundStyle(size == 72 ? Color(red: 0.10, green: 0.08, blue: 0.22) : .white)
        .overlay {
          if differentiateWithoutColor, size == 72 { Circle().stroke(.white.opacity(0.9), lineWidth: 2) }
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(label))
  }
}
