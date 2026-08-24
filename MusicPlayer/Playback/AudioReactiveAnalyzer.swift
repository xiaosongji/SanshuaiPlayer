import AVFoundation
import Foundation
import MediaToolbox
import OSLog

struct AudioReactiveSnapshot: Equatable, Sendable {
  var energy: Float
  var low: Float
  var mid: Float
  var high: Float
  var spectralFlux: Float
  var beatPulse: Float
  var beatConfidence: Float
  var tempo: Float
  var spectrum0: SIMD4<Float>
  var spectrum1: SIMD4<Float>
  var spectrum2: SIMD4<Float>
  var spectrum3: SIMD4<Float>

  static let silent = AudioReactiveSnapshot(
    energy: 0, low: 0, mid: 0, high: 0, spectralFlux: 0, beatPulse: 0,
    beatConfidence: 0, tempo: 0, spectrum0: .zero, spectrum1: .zero,
    spectrum2: .zero, spectrum3: .zero)
}

/// Reads post-effect PCM from AVPlayer without changing the playback engine.
/// The renderer only sees a small immutable snapshot, keeping AVFoundation and Metal replaceable.
final class AudioReactiveAnalyzer: @unchecked Sendable {
  private static let logger = Logger(subsystem: "com.himhuu.music", category: "AudioAnalysis")
  private let snapshotLock = NSLock()
  private var currentSnapshot = AudioReactiveSnapshot.silent
  private var previewMode = false
  private var analysisEnabled = false

  // The following state is owned by the audio tap callback.
  private var sampleRate = 44_100.0
  private var channelCount = 2
  private var isFloatPCM = true
  private var isSignedIntegerPCM = false
  private var isInterleaved = false
  private var isBigEndian = false
  private var isAlignedHigh = false
  private var bitsPerChannel: UInt32 = 32
  private var bytesPerSample = 4
  private var monoSamples = [Float](repeating: 0, count: 512)
  private var previousSpectrum = [Float](repeating: 0, count: 16)
  private var spectrumPeaks = [Float](repeating: 0.035, count: 16)
  private var smoothedSpectrum = [Float](repeating: 0, count: 16)
  private var onsetTimes = [Double](repeating: 0, count: 16)
  private var onsetCount = 0
  private var onsetWriteIndex = 0
  private var elapsedFrames: Int64 = 0
  private var lastOnsetTime = -10.0
  private var nextPredictedBeat = Double.infinity
  private var beatInterval = 0.0
  private var fluxMean: Float = 0
  private var fluxVariance: Float = 0
  private var energyPeak: Float = 0.05
  private var smoothedEnergy: Float = 0
  private var smoothedLow: Float = 0
  private var smoothedMid: Float = 0
  private var smoothedHigh: Float = 0
  private var pulse: Float = 0
  #if DEBUG
    private var didLogFirstSignal = false
  #endif

  func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
    let context = AudioTapContext(analyzer: self)
    let retainedContext = Unmanaged.passRetained(context)
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: retainedContext.toOpaque(),
      init: audioTapInit,
      finalize: audioTapFinalize,
      prepare: audioTapPrepare,
      unprepare: audioTapUnprepare,
      process: audioTapProcess)
    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(
      kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects,
      &tap)
    guard status == noErr, let tap else {
      retainedContext.release()
      Self.logger.error("无法创建音频分析 Tap，状态码：\(status, privacy: .public)")
      return nil
    }

    let parameters = AVMutableAudioMixInputParameters(track: track)
    parameters.audioTapProcessor = tap
    let mix = AVMutableAudioMix()
    mix.inputParameters = [parameters]
    Self.logger.info("音频分析 Tap 已附加")
    return mix
  }

  func snapshot(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AudioReactiveSnapshot {
    snapshotLock.lock()
    let isPreview = previewMode
    let value = currentSnapshot
    snapshotLock.unlock()
    #if DEBUG
      if isPreview { return Self.previewSnapshot(at: time) }
    #endif
    return value
  }

  func setAnalysisEnabled(_ enabled: Bool) {
    snapshotLock.lock()
    analysisEnabled = enabled
    if !enabled {
      currentSnapshot = .silent
    }
    snapshotLock.unlock()
  }

  func reset() {
    snapshotLock.lock()
    currentSnapshot = .silent
    previewMode = false
    snapshotLock.unlock()
  }

  #if DEBUG
    func enablePreviewMode() {
      snapshotLock.lock()
      previewMode = true
      snapshotLock.unlock()
    }

    func analyzeForTesting(samples: [Float], sampleRate: Double) -> AudioReactiveSnapshot {
      setAnalysisEnabled(true)
      prepare(maxFrames: samples.count, format: Self.floatMonoFormat(sampleRate: sampleRate))
      let count = min(samples.count, monoSamples.count)
      monoSamples.replaceSubrange(0..<count, with: samples.prefix(count))
      analyzeMonoSampleCount(count, sourceFrameCount: samples.count)
      return snapshot()
    }
  #endif

  fileprivate func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
    sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
    channelCount = max(Int(format.mChannelsPerFrame), 1)
    bitsPerChannel = format.mBitsPerChannel
    isFloatPCM = format.mFormatID == kAudioFormatLinearPCM
      && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
    isSignedIntegerPCM = format.mFormatID == kAudioFormatLinearPCM
      && format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
    isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    isBigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
    isAlignedHigh = format.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
    let samplesPerFrame = isInterleaved ? channelCount : 1
    bytesPerSample = max(
      Int(format.mBytesPerFrame) / max(samplesPerFrame, 1),
      Int((bitsPerChannel + 7) / 8))
    #if DEBUG
      didLogFirstSignal = false
      Self.logger.info(
        "音频分析 Tap 已准备：rate=\(self.sampleRate, privacy: .public), channels=\(self.channelCount, privacy: .public), bits=\(self.bitsPerChannel, privacy: .public), flags=\(format.mFormatFlags, privacy: .public), float=\(self.isFloatPCM, privacy: .public), interleaved=\(self.isInterleaved, privacy: .public)")
    #endif
    resetAnalysisState()
  }

  fileprivate func consume(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
    snapshotLock.lock()
    let enabled = analysisEnabled
    snapshotLock.unlock()
    guard enabled else { return }
    guard frameCount > 0, isFloatPCM || isSignedIntegerPCM else { return }
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    guard !buffers.isEmpty else { return }
    let stride = max(frameCount / monoSamples.count, 1)
    let count = min((frameCount + stride - 1) / stride, monoSamples.count)

    for outputIndex in 0..<count {
      let frame = min(outputIndex * stride, frameCount - 1)
      var sum: Float = 0
      var contributors = 0
      if isInterleaved, let data = buffers[0].mData {
        let channels = max(Int(buffers[0].mNumberChannels), channelCount)
        for channel in 0..<min(channels, 2) {
          sum += sample(from: data, index: frame * channels + channel)
          contributors += 1
        }
      } else {
        for channel in 0..<min(buffers.count, 2) {
          guard let data = buffers[channel].mData else { continue }
          sum += sample(from: data, index: frame)
          contributors += 1
        }
      }
      monoSamples[outputIndex] = contributors > 0 ? sum / Float(contributors) : 0
    }
    analyzeMonoSampleCount(count, sourceFrameCount: frameCount)
  }

  private func sample(from data: UnsafeMutableRawPointer, index: Int) -> Float {
    if isFloatPCM, bitsPerChannel == 32 {
      return data.assumingMemoryBound(to: Float.self)[index]
    }
    if isFloatPCM, bitsPerChannel == 64 {
      return Float(data.assumingMemoryBound(to: Double.self)[index])
    }
    if isSignedIntegerPCM, bitsPerChannel == 16 {
      return Float(data.assumingMemoryBound(to: Int16.self)[index]) / Float(Int16.max)
    }
    if isSignedIntegerPCM, bitsPerChannel == 24 {
      let bytes = data.assumingMemoryBound(to: UInt8.self)
      let sampleOffset = index * bytesPerSample
      let payloadOffset: Int
      if bytesPerSample > 3, isAlignedHigh {
        payloadOffset = isBigEndian ? 0 : bytesPerSample - 3
      } else {
        payloadOffset = isBigEndian ? max(bytesPerSample - 3, 0) : 0
      }
      let offset = sampleOffset + payloadOffset
      let raw: UInt32
      if isBigEndian {
        raw = UInt32(bytes[offset + 2]) | UInt32(bytes[offset + 1]) << 8
          | UInt32(bytes[offset]) << 16
      } else {
        raw = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
          | UInt32(bytes[offset + 2]) << 16
      }
      let signed = Int32(bitPattern: raw & 0x80_0000 == 0 ? raw : raw | 0xFF00_0000)
      return Float(signed) / 8_388_607
    }
    if isSignedIntegerPCM, bitsPerChannel == 32 {
      return Float(data.assumingMemoryBound(to: Int32.self)[index]) / Float(Int32.max)
    }
    return 0
  }

  private func analyzeMonoSampleCount(_ count: Int, sourceFrameCount: Int) {
    guard count >= 32 else { return }
    var mean: Float = 0
    for index in 0..<count { mean += monoSamples[index] }
    mean /= Float(count)
    var squared: Float = 0
    for index in 0..<count {
      monoSamples[index] -= mean
      squared += monoSamples[index] * monoSamples[index]
    }
    let rms = sqrt(squared / Float(count))
    energyPeak = max(rms, energyPeak * 0.996)
    let normalizedEnergy = min(rms / max(energyPeak, 0.012), 1.25)
    smoothedEnergy = smooth(smoothedEnergy, toward: normalizedEnergy, attack: 0.34, release: 0.07)

    let effectiveSampleRate = sampleRate * Double(count) / Double(max(sourceFrameCount, 1))
    let nyquist = effectiveSampleRate * 0.48
    var spectrum = SIMD16<Float>(repeating: 0)
    var flux: Float = 0
    var low: Float = 0
    var mid: Float = 0
    var high: Float = 0
    var lowCount: Float = 0
    var midCount: Float = 0
    var highCount: Float = 0

    for band in 0..<16 {
      let t = Double(band) / 15
      let frequency = min(48 * pow(250, t), nyquist)
      let omega = 2 * Double.pi * frequency / effectiveSampleRate
      let coefficient = Float(2 * cos(omega))
      var q1: Float = 0
      var q2: Float = 0
      for index in 0..<count {
        let q0 = coefficient * q1 - q2 + monoSamples[index]
        q2 = q1
        q1 = q0
      }
      let magnitude = sqrt(max(q1 * q1 + q2 * q2 - coefficient * q1 * q2, 0)) / Float(count)
      spectrumPeaks[band] = max(magnitude, spectrumPeaks[band] * 0.994)
      let normalized = min(magnitude / max(spectrumPeaks[band], 0.000_8), 1.35)
      smoothedSpectrum[band] = smooth(
        smoothedSpectrum[band], toward: normalized, attack: 0.40, release: 0.085)
      spectrum[band] = smoothedSpectrum[band]
      flux += max(0, normalized - previousSpectrum[band])
      previousSpectrum[band] = normalized
      if frequency < 190 {
        low += smoothedSpectrum[band]
        lowCount += 1
      } else if frequency < 2_400 {
        mid += smoothedSpectrum[band]
        midCount += 1
      } else {
        high += smoothedSpectrum[band]
        highCount += 1
      }
    }

    low /= max(lowCount, 1)
    mid /= max(midCount, 1)
    high /= max(highCount, 1)
    smoothedLow = smooth(smoothedLow, toward: low, attack: 0.42, release: 0.075)
    smoothedMid = smooth(smoothedMid, toward: mid, attack: 0.30, release: 0.065)
    smoothedHigh = smooth(smoothedHigh, toward: high, attack: 0.48, release: 0.12)

    flux /= 16
    let delta = flux - fluxMean
    fluxMean += delta * 0.035
    fluxVariance += (delta * delta - fluxVariance) * 0.035
    let now = Double(elapsedFrames) / sampleRate
    let onsetThreshold = fluxMean + max(0.026, sqrt(max(fluxVariance, 0)) * 1.45)
    let isOnset = flux > onsetThreshold && normalizedEnergy > 0.13 && now - lastOnsetTime > 0.105
    if isOnset {
      registerOnset(at: now)
      pulse = 1
    } else if beatInterval > 0, now >= nextPredictedBeat {
      pulse = max(pulse, 0.70)
      nextPredictedBeat += beatInterval
    } else {
      pulse *= 0.86
    }
    elapsedFrames += Int64(sourceFrameCount)

    let value = AudioReactiveSnapshot(
      energy: clamp(smoothedEnergy), low: clamp(smoothedLow), mid: clamp(smoothedMid),
      high: clamp(smoothedHigh), spectralFlux: clamp(flux * 2.2), beatPulse: clamp(pulse),
      beatConfidence: min(Float(onsetCount) / 8, 1),
      tempo: beatInterval > 0 ? Float(60 / beatInterval) : 0,
      spectrum0: SIMD4(spectrum[0], spectrum[1], spectrum[2], spectrum[3]),
      spectrum1: SIMD4(spectrum[4], spectrum[5], spectrum[6], spectrum[7]),
      spectrum2: SIMD4(spectrum[8], spectrum[9], spectrum[10], spectrum[11]),
      spectrum3: SIMD4(spectrum[12], spectrum[13], spectrum[14], spectrum[15]))
    #if DEBUG
      if !didLogFirstSignal, value.energy > 0.01 {
        didLogFirstSignal = true
        Self.logger.info(
          "音频分析已收到非零 PCM：energy=\(value.energy, privacy: .public), low=\(value.low, privacy: .public), mid=\(value.mid, privacy: .public), high=\(value.high, privacy: .public)")
      }
    #endif
    snapshotLock.lock()
    if analysisEnabled, !previewMode { currentSnapshot = value }
    snapshotLock.unlock()
  }

  private func registerOnset(at time: Double) {
    lastOnsetTime = time
    onsetTimes[onsetWriteIndex] = time
    onsetWriteIndex = (onsetWriteIndex + 1) % onsetTimes.count
    onsetCount = min(onsetCount + 1, onsetTimes.count)
    guard onsetCount >= 3 else { return }

    var intervalTotal = 0.0
    var intervalCount = 0
    for offset in 1..<onsetCount {
      let newerIndex = (onsetWriteIndex - offset + onsetTimes.count) % onsetTimes.count
      let olderIndex = (onsetWriteIndex - offset - 1 + onsetTimes.count) % onsetTimes.count
      var interval = onsetTimes[newerIndex] - onsetTimes[olderIndex]
      guard interval > 0.12, interval < 1.8 else { continue }
      while interval < 0.34 { interval *= 2 }
      while interval > 0.86 { interval /= 2 }
      intervalTotal += interval
      intervalCount += 1
    }
    guard intervalCount > 0 else { return }
    let estimate = intervalTotal / Double(intervalCount)
    beatInterval = beatInterval == 0 ? estimate : beatInterval * 0.78 + estimate * 0.22
    nextPredictedBeat = time + beatInterval
  }

  private func resetAnalysisState() {
    previousSpectrum = [Float](repeating: 0, count: 16)
    spectrumPeaks = [Float](repeating: 0.035, count: 16)
    smoothedSpectrum = [Float](repeating: 0, count: 16)
    onsetTimes = [Double](repeating: 0, count: 16)
    onsetCount = 0
    onsetWriteIndex = 0
    elapsedFrames = 0
    lastOnsetTime = -10
    nextPredictedBeat = .infinity
    beatInterval = 0
    fluxMean = 0
    fluxVariance = 0
    energyPeak = 0.05
    smoothedEnergy = 0
    smoothedLow = 0
    smoothedMid = 0
    smoothedHigh = 0
    pulse = 0
  }

  private func smooth(_ current: Float, toward target: Float, attack: Float, release: Float) -> Float {
    current + (target - current) * (target > current ? attack : release)
  }

  private func clamp(_ value: Float) -> Float { min(max(value, 0), 1) }

  #if DEBUG
    private static func previewSnapshot(at time: TimeInterval) -> AudioReactiveSnapshot {
      let beatPhase = Float(time.truncatingRemainder(dividingBy: 0.47) / 0.47)
      let beat = exp(-beatPhase * 8.5)
      let low = min(0.24 + beat * 0.90 + Float(sin(time * 1.9)) * 0.08, 1)
      let mid = 0.36 + Float(sin(time * 3.4) * 0.18 + sin(time * 0.71) * 0.10)
      let high = 0.29 + Float(sin(time * 8.8) * 0.13 + sin(time * 2.1) * 0.09)
      var values = SIMD16<Float>(repeating: 0)
      for index in 0..<16 {
        values[index] = min(max(
          0.18 + 0.36 * Float(sin(time * (1.1 + Double(index) * 0.17) + Double(index)))
            + beat * Float(1 - Double(index) / 22), 0), 1)
      }
      return AudioReactiveSnapshot(
        energy: min(0.46 + beat * 0.52, 1), low: max(low, 0), mid: max(mid, 0),
        high: max(high, 0), spectralFlux: min(0.18 + beat * 0.76, 1), beatPulse: beat,
        beatConfidence: 0.88, tempo: 127.7,
        spectrum0: SIMD4(values[0], values[1], values[2], values[3]),
        spectrum1: SIMD4(values[4], values[5], values[6], values[7]),
        spectrum2: SIMD4(values[8], values[9], values[10], values[11]),
        spectrum3: SIMD4(values[12], values[13], values[14], values[15]))
    }

    private static func floatMonoFormat(sampleRate: Double) -> AudioStreamBasicDescription {
      AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    }
  #endif
}

private final class AudioTapContext {
  let analyzer: AudioReactiveAnalyzer
  init(analyzer: AudioReactiveAnalyzer) { self.analyzer = analyzer }
}

private func audioTapContext(_ tap: MTAudioProcessingTap) -> AudioTapContext {
  Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private let audioTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
  tapStorageOut.pointee = clientInfo
}

private let audioTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
  Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let audioTapPrepare: MTAudioProcessingTapPrepareCallback = {
  tap, maxFrames, processingFormat in
  audioTapContext(tap).analyzer.prepare(
    maxFrames: Int(maxFrames), format: processingFormat.pointee)
}

private let audioTapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let audioTapProcess: MTAudioProcessingTapProcessCallback = {
  tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
  let status = MTAudioProcessingTapGetSourceAudio(
    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
  guard status == noErr else {
    numberFramesOut.pointee = 0
    return
  }
  audioTapContext(tap).analyzer.consume(
    bufferListInOut, frameCount: Int(numberFramesOut.pointee))
}
