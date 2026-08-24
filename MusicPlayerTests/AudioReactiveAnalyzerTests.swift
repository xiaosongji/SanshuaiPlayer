import Foundation
import Testing
@testable import MusicPlayer

@Suite("Audio reactive analyzer")
struct AudioReactiveAnalyzerTests {
  @Test("Low and high tones drive different visual bands")
  func separatesFrequencyRegions() {
    let sampleRate = 48_000.0
    let lowSamples = sineWave(frequency: 110, sampleRate: sampleRate, count: 512)
    let highSamples = sineWave(frequency: 6_000, sampleRate: sampleRate, count: 512)

    let lowSnapshot = AudioReactiveAnalyzer().analyzeForTesting(
      samples: lowSamples, sampleRate: sampleRate)
    let highSnapshot = AudioReactiveAnalyzer().analyzeForTesting(
      samples: highSamples, sampleRate: sampleRate)

    #expect(lowSnapshot.low > lowSnapshot.high)
    #expect(highSnapshot.high > highSnapshot.low)
    #expect(lowSnapshot.energy > 0.1)
    #expect(highSnapshot.energy > 0.1)
  }

  @Test("Silence produces a calm frame")
  func silenceIsCalm() {
    let snapshot = AudioReactiveAnalyzer().analyzeForTesting(
      samples: [Float](repeating: 0, count: 512), sampleRate: 48_000)
    #expect(snapshot.energy == 0)
    #expect(snapshot.low == 0)
    #expect(snapshot.mid == 0)
    #expect(snapshot.high == 0)
    #expect(snapshot.beatPulse == 0)
  }

  @Test("Disabling analysis clears the visual snapshot")
  func disablingAnalysisIsSilent() {
    let analyzer = AudioReactiveAnalyzer()
    let samples = sineWave(frequency: 110, sampleRate: 48_000, count: 512)
    #expect(analyzer.analyzeForTesting(samples: samples, sampleRate: 48_000).energy > 0)
    analyzer.setAnalysisEnabled(false)
    #expect(analyzer.snapshot() == .silent)
  }

  @MainActor
  @Test("AVPlayer tap receives decoded PCM from the real playback path")
  func playerTapReceivesPCM() async {
    let providerID = UUID()
    let track = MusicTrack(
      identity: .init(providerID: providerID, remoteID: "reactive-wav", sourceType: .local),
      albumRemoteID: nil, artistRemoteID: nil, title: "Reactive Test", artistName: "Tests",
      albumTitle: nil, discNumber: 1, trackNumber: 1, duration: 3, artworkURL: nil,
      lyrics: nil, isExplicit: false, favoriteState: .unknown, contentType: "audio/wav",
      suffix: "wav", bitRate: 705, metadata: [:])
    let provider = MockMusicSourceProvider(
      id: providerID, sourceType: .local, tracks: [track], mediaData: makeTestWAV(),
      mediaMimeType: "audio/wav")
    let playback = UnifiedPlaybackController(
      provider: provider, wifiQuality: .original)

    await playback.play(track, queue: [track])
    #expect(!playback.hasAudioReactiveMixForTesting)

    playback.setAudioReactiveAnalysisEnabled(true)
    var receivedEnergy = false
    for _ in 0..<50 {
      if playback.audioReactiveAnalyzer.snapshot().energy > 0.05 {
        receivedEnergy = true
        break
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    #expect(playback.hasAudioReactiveMixForTesting)
    playback.setAudioReactiveAnalysisEnabled(false)
    #expect(!playback.hasAudioReactiveMixForTesting)
    playback.pause()
    #expect(receivedEnergy)
  }

  private func sineWave(frequency: Double, sampleRate: Double, count: Int) -> [Float] {
    (0..<count).map { index in
      Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate) * 0.72)
    }
  }

  private func makeTestWAV() -> Data {
    let sampleRate = 44_100
    let count = sampleRate * 3
    var pcm = Data()
    pcm.reserveCapacity(count * 2)
    for index in 0..<count {
      let time = Double(index) / Double(sampleRate)
      let pulse = exp(-time.truncatingRemainder(dividingBy: 0.45) * 18)
      let value = sin(2 * Double.pi * 110 * time) * (0.30 + pulse * 0.44)
      let sample = Int16(max(-0.9, min(0.9, value)) * Double(Int16.max))
      pcm.append(UInt8(truncatingIfNeeded: sample))
      pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
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
    ascii("RIFF"); little32(UInt32(36 + pcm.count)); ascii("WAVEfmt "); little32(16)
    little16(1); little16(1); little32(UInt32(sampleRate)); little32(UInt32(sampleRate * 2))
    little16(2); little16(16); ascii("data"); little32(UInt32(pcm.count)); wav.append(pcm)
    return wav
  }
}
