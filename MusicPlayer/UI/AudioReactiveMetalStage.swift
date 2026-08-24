import CoreImage
import MetalKit
import OSLog
import SwiftUI
import UIKit

enum VisualEffectPreset: String, CaseIterable, Identifiable, Sendable {
  case starTide
  case auroraVeil
  case archiveOrbit

  var id: String { rawValue }
  var title: String {
    switch self {
    case .starTide: String(localized: "星潮")
    case .auroraVeil: String(localized: "极光")
    case .archiveOrbit: String(localized: "轨道")
    }
  }
  var accessibilityTitle: String {
    switch self {
    case .starTide: String(localized: "星潮脉冲")
    case .auroraVeil: String(localized: "极光丝幕")
    case .archiveOrbit: String(localized: "收藏轨道")
    }
  }
  var icon: String {
    switch self {
    case .starTide: "sparkles"
    case .auroraVeil: "waveform.path"
    case .archiveOrbit: "circle.hexagongrid"
    }
  }
  var shaderIndex: UInt32 {
    switch self {
    case .starTide: 0
    case .auroraVeil: 1
    case .archiveOrbit: 2
    }
  }
}

struct StagePalette: Equatable, Sendable {
  let base: SIMD3<Float>
  let accent: SIMD3<Float>
  let spark: SIMD3<Float>

  static let fallback = StagePalette(
    base: SIMD3(0.055, 0.045, 0.13),
    accent: SIMD3(0.55, 0.36, 0.96),
    spark: SIMD3(0.54, 0.88, 1.0))

  static func stable(for trackID: UUID?) -> StagePalette {
    guard let trackID else { return fallback }
    let bytes = withUnsafeBytes(of: trackID.uuid) { Array($0) }
    let hue = Float(bytes.reduce(0) { ($0 &* 31) &+ Int($1) } % 360) / 360
    let accent = UIColor(hue: CGFloat(hue), saturation: 0.58, brightness: 0.94, alpha: 1)
    let spark = UIColor(
      hue: CGFloat((hue + 0.13).truncatingRemainder(dividingBy: 1)), saturation: 0.38,
      brightness: 1, alpha: 1)
    return StagePalette(
      base: SIMD3(0.045 + hue * 0.025, 0.038, 0.105 + (1 - hue) * 0.045),
      accent: accent.rgb, spark: spark.rgb)
  }
}

@MainActor
final class ArtworkPaletteLoader {
  static let shared = ArtworkPaletteLoader()
  private var cache: [URL: StagePalette] = [:]
  private let context = CIContext(options: [.workingColorSpace: NSNull()])

  func palette(
    for url: URL?, trackID: UUID?, cacheIdentity: String?, serverID: UUID?,
    fetcher: MusicArtworkFetcher?
  ) async -> StagePalette {
    guard let url else { return .stable(for: trackID) }
    if let cached = cache[url] { return cached }
    guard
      let artwork = await ArtworkRepository.shared.image(
        for: url, serverID: serverID, fetcher: fetcher, cacheIdentity: cacheIdentity,
        maximumPixelSize: 192),
      let image = CIImage(image: artwork), !image.extent.isEmpty,
      let filter = CIFilter(name: "CIAreaAverage")
    else { return .stable(for: trackID) }
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)
    guard let output = filter.outputImage else { return .stable(for: trackID) }
    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(
      output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    let source = UIColor(
      red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
      blue: CGFloat(pixel[2]) / 255, alpha: 1)
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
    let accent = UIColor(
      hue: hue, saturation: min(max(saturation, 0.46), 0.78), brightness: 0.94, alpha: 1)
    let spark = UIColor(
      hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.32,
      brightness: 1, alpha: 1)
    let result = StagePalette(
      base: SIMD3(
        Float(accent.rgb.x) * 0.10 + 0.025, Float(accent.rgb.y) * 0.085 + 0.022,
        Float(accent.rgb.z) * 0.14 + 0.055),
      accent: accent.rgb, spark: spark.rgb)
    cache[url] = result
    return result
  }
}

private extension UIColor {
  var rgb: SIMD3<Float> {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    getRed(&red, green: &green, blue: &blue, alpha: nil)
    return SIMD3(Float(red), Float(green), Float(blue))
  }
}

struct AudioReactiveMetalStage: UIViewRepresentable {
  let analyzer: AudioReactiveAnalyzer
  let preset: VisualEffectPreset
  let palette: StagePalette
  let trackID: UUID?
  let isPlaying: Bool
  let allowsMotion: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> MTKView {
    let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    view.isOpaque = true
    view.backgroundColor = .black
    view.colorPixelFormat = .bgra8Unorm
    view.preferredFramesPerSecond = 60
    view.enableSetNeedsDisplay = false
    view.isPaused = false
    view.framebufferOnly = true
    context.coordinator.install(on: view)
    return view
  }

  func updateUIView(_ view: MTKView, context: Context) {
    context.coordinator.update(
      analyzer: analyzer, preset: preset, palette: palette,
      seed: Self.seed(for: trackID), isPlaying: isPlaying, allowsMotion: allowsMotion)
    view.preferredFramesPerSecond = allowsMotion ? 60 : 30
    view.enableSetNeedsDisplay = false
    view.isPaused = !allowsMotion || !isPlaying
    view.draw()
  }

  static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
    view.isPaused = true
    view.delegate = nil
  }

  private static func seed(for id: UUID?) -> Float {
    guard let id else { return 0.37 }
    return withUnsafeBytes(of: id.uuid) { bytes in
      let value = bytes.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
      return Float(value % 10_000) / 10_000
    }
  }

  final class Coordinator: NSObject, MTKViewDelegate {
    private static let logger = Logger(subsystem: "com.himhuu.music", category: "VisualStage")
    private struct Configuration {
      var analyzer: AudioReactiveAnalyzer?
      var preset = VisualEffectPreset.starTide
      var palette = StagePalette.fallback
      var seed: Float = 0.37
      var isPlaying = false
      var allowsMotion = false
    }

    private let lock = NSLock()
    private var configuration = Configuration()
    private var commandQueue: MTLCommandQueue?
    private var backgroundPipeline: MTLRenderPipelineState?
    private var particlePipeline: MTLRenderPipelineState?
    private var phaseTime: Float = 0
    private var lastFrameTime = ProcessInfo.processInfo.systemUptime
    #if DEBUG
      private var lastDiagnosticTime = 0.0
    #endif

    @MainActor
    func install(on view: MTKView) {
      guard let device = view.device, let library = device.makeDefaultLibrary() else { return }
      commandQueue = device.makeCommandQueue()

      let backgroundDescriptor = MTLRenderPipelineDescriptor()
      backgroundDescriptor.label = "Audio reactive background"
      backgroundDescriptor.vertexFunction = library.makeFunction(name: "reactiveFullscreenVertex")
      backgroundDescriptor.fragmentFunction = library.makeFunction(name: "reactiveBackgroundFragment")
      backgroundDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
      backgroundDescriptor.inputPrimitiveTopology = .triangle

      let particleDescriptor = MTLRenderPipelineDescriptor()
      particleDescriptor.label = "Audio reactive particles"
      particleDescriptor.vertexFunction = library.makeFunction(name: "reactiveParticleVertex")
      particleDescriptor.fragmentFunction = library.makeFunction(name: "reactiveParticleFragment")
      particleDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
      particleDescriptor.colorAttachments[0].isBlendingEnabled = true
      particleDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
      particleDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
      particleDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
      particleDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
      particleDescriptor.inputPrimitiveTopology = .point
      do {
        backgroundPipeline = try device.makeRenderPipelineState(descriptor: backgroundDescriptor)
        particlePipeline = try device.makeRenderPipelineState(descriptor: particleDescriptor)
      } catch {
        Self.logger.error("无法创建视觉舞台渲染管线：\(error.localizedDescription, privacy: .public)")
      }
      view.delegate = self
    }

    func update(
      analyzer: AudioReactiveAnalyzer, preset: VisualEffectPreset, palette: StagePalette,
      seed: Float, isPlaying: Bool, allowsMotion: Bool
    ) {
      lock.lock()
      configuration = Configuration(
        analyzer: analyzer, preset: preset, palette: palette, seed: seed,
        isPlaying: isPlaying, allowsMotion: allowsMotion)
      lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
      guard let descriptor = view.currentRenderPassDescriptor,
        let drawable = view.currentDrawable,
        let commandQueue, let backgroundPipeline, let particlePipeline,
        view.drawableSize.width > 0, view.drawableSize.height > 0
      else { return }

      lock.lock()
      let config = configuration
      lock.unlock()
      let now = ProcessInfo.processInfo.systemUptime
      let delta = min(max(now - lastFrameTime, 0), 1 / 15)
      lastFrameTime = now
      if config.isPlaying && config.allowsMotion { phaseTime += Float(delta) }
      let audio = config.analyzer?.snapshot(at: now) ?? .silent
      #if DEBUG
        if now - lastDiagnosticTime >= 2 {
          lastDiagnosticTime = now
          Self.logger.info(
            "舞台帧：playing=\(config.isPlaying, privacy: .public), motion=\(config.allowsMotion, privacy: .public), energy=\(audio.energy, privacy: .public), low=\(audio.low, privacy: .public), mid=\(audio.mid, privacy: .public), high=\(audio.high, privacy: .public)")
        }
      #endif
      var uniforms = ReactiveMetalUniforms(
        resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
        time: phaseTime, deltaTime: Float(delta), energy: audio.energy, low: audio.low,
        mid: audio.mid, high: audio.high, flux: audio.spectralFlux, beat: audio.beatPulse,
        beatConfidence: audio.beatConfidence, tempo: audio.tempo,
        style: config.preset.shaderIndex, motion: config.allowsMotion ? 1 : 0,
        seed: config.seed, padding: 0, baseColor: SIMD4(config.palette.base, 1),
        accentColor: SIMD4(config.palette.accent, 1),
        sparkColor: SIMD4(config.palette.spark, 1),
        spectrum0: audio.spectrum0, spectrum1: audio.spectrum1,
        spectrum2: audio.spectrum2, spectrum3: audio.spectrum3)

      descriptor.colorAttachments[0].loadAction = .clear
      descriptor.colorAttachments[0].storeAction = .store
      descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.012, green: 0.009, blue: 0.028, alpha: 1)
      guard let commandBuffer = commandQueue.makeCommandBuffer(),
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
      else { return }
      encoder.setRenderPipelineState(backgroundPipeline)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<ReactiveMetalUniforms>.stride, index: 0)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ReactiveMetalUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      encoder.setRenderPipelineState(particlePipeline)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<ReactiveMetalUniforms>.stride, index: 0)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ReactiveMetalUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 6_144)
      encoder.endEncoding()
      commandBuffer.present(drawable)
      commandBuffer.commit()
    }
  }
}

private struct ReactiveMetalUniforms {
  var resolution: SIMD2<Float>
  var time: Float
  var deltaTime: Float
  var energy: Float
  var low: Float
  var mid: Float
  var high: Float
  var flux: Float
  var beat: Float
  var beatConfidence: Float
  var tempo: Float
  var style: UInt32
  var motion: Float
  var seed: Float
  var padding: Float
  var baseColor: SIMD4<Float>
  var accentColor: SIMD4<Float>
  var sparkColor: SIMD4<Float>
  var spectrum0: SIMD4<Float>
  var spectrum1: SIMD4<Float>
  var spectrum2: SIMD4<Float>
  var spectrum3: SIMD4<Float>
}
