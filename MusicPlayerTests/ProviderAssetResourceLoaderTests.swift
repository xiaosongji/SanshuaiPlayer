import AVFoundation
import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import MusicPlayer

final class ProviderAssetResourceLoaderTests: XCTestCase {
  func testProviderAssetLoaderServesRangeBasedAudio() async throws {
    let provider = MockMusicSourceProvider(mediaData: makeSilentWAV(), mediaMimeType: "audio/wav")
    let loader = try ProviderAssetResourceLoader(
      url: URL(string: "https://media.example.test/test.wav")!, provider: provider)
    let asset = loader.makeAsset()
    let duration = try await asset.load(.duration)
    XCTAssertGreaterThan(duration.seconds, 0.9)
    XCTAssertLessThan(duration.seconds, 1.1)
    _ = loader
  }

  func testProviderAssetLoaderContinuesPastFirst512KiBChunk() async throws {
    let provider = MockMusicSourceProvider(
      mediaData: makeSilentWAV(sampleRate: 44_100, duration: 8), mediaMimeType: "audio/wav")
    let loader = try ProviderAssetResourceLoader(
      url: URL(string: "https://media.example.test/large.wav")!, provider: provider)
    let asset = loader.makeAsset()
    let reader = try AVAssetReader(asset: asset)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let track = try XCTUnwrap(tracks.first)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
    XCTAssertTrue(reader.canAdd(output))
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    while output.copyNextSampleBuffer() != nil {}
    XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "")

    let ranges = await provider.requestedMediaRanges()
    let starts = ranges.compactMap(rangeStart)
    XCTAssertTrue(
      ranges.contains("bytes=0-65535"),
      "The first playable response must stay small enough for fast cellular startup: \(ranges)")
    XCTAssertTrue(starts.contains(64 * 1_024), "ranges=\(starts)")
    XCTAssertTrue(starts.contains(where: { $0 >= 512 * 1_024 }), "ranges=\(starts)")
    XCTAssertLessThan(starts.filter { $0 == 0 }.count, starts.count, "ranges=\(starts)")
    _ = loader
  }

  func testInvalidatingLoaderStopsAbandonedTrackFromStreamingToTheEnd() async throws {
    let provider = MockMusicSourceProvider(
      mediaData: makeSilentWAV(sampleRate: 44_100, duration: 20), mediaMimeType: "audio/wav",
      mediaStreamChunkSize: 8 * 1_024, mediaStreamChunkDelay: .milliseconds(10))
    let loader = try ProviderAssetResourceLoader(
      url: URL(string: "https://media.example.test/abandoned.wav")!, provider: provider)
    let asset = loader.makeAsset()

    // Read the way playback does, then walk away from it mid-transfer.
    let reading = Task {
      let reader = try AVAssetReader(asset: asset)
      let tracks = try await asset.loadTracks(withMediaType: .audio)
      guard let track = tracks.first else { return }
      let output = AVAssetReaderTrackOutput(
        track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
      guard reader.canAdd(output) else { return }
      reader.add(output)
      guard reader.startReading() else { return }
      while output.copyNextSampleBuffer() != nil {}
    }
    try await Task.sleep(for: .milliseconds(300))
    let inFlightRequestCount = await provider.requestedMediaRanges().count
    XCTAssertGreaterThan(
      inFlightRequestCount, 0, "The loader should have started streaming before it is abandoned")

    loader.invalidate()
    reading.cancel()
    let requestCountAtInvalidation = await provider.requestedMediaRanges().count
    try await Task.sleep(for: .milliseconds(600))

    let finalRequestCount = await provider.requestedMediaRanges().count
    XCTAssertEqual(
      finalRequestCount, requestCountAtInvalidation,
      "An invalidated loader must stop requesting ranges; otherwise every skipped track keeps "
        + "downloading to the end of the file and starves the next one")
    _ = loader
  }

  func testProviderAssetLoaderStartsBeforeColdTranscode200ResponseCompletes() async throws {
    let source = makeSilentWAV(sampleRate: 44_100, duration: 8)
    let provider = MockMusicSourceProvider(
      mediaData: source, mediaMimeType: "audio/wav", mediaIgnoresRange: true,
      mediaStreamChunkSize: 4 * 1_024, mediaStreamChunkDelay: .milliseconds(5))
    let loader = try ProviderAssetResourceLoader(
      url: URL(string: "https://media.example.test/cold-transcode.wav")!, provider: provider)
    let asset = loader.makeAsset()

    let duration = try await asset.load(.duration)
    let completedStreams = await provider.completedMediaStreamCount()
    let deliveredChunks = await provider.deliveredMediaStreamChunkCount()
    let requestedRanges = await provider.requestedMediaRanges()

    XCTAssertGreaterThan(duration.seconds, 7.9)
    XCTAssertLessThan(duration.seconds, 8.1)
    XCTAssertEqual(
      completedStreams, 0,
      "AVFoundation should receive enough leading bytes without waiting for the full 200 body")
    XCTAssertGreaterThan(deliveredChunks, 0)
    XCTAssertTrue(
      requestedRanges.contains("bytes=0-65535"),
      "The cold-transcode path must still begin with the small startup range")
    _ = loader
  }

  func testFileSignatureWinsWhenServerMislabelsM4AAsMP3() {
    var data = Data(repeating: 0, count: 32)
    data.replaceSubrange(4..<12, with: Data("ftypM4A ".utf8))

    XCTAssertEqual(
      MediaContentTypeDetector.contentType(declaredMIMEType: "audio/mpeg", data: data),
      UTType.mpeg4Audio.identifier)
  }

  func testCommonAudioSignaturesAreDetected() {
    XCTAssertEqual(
      MediaContentTypeDetector.signatureType(for: Data("fLaC\u{0}\u{0}\u{0}\u{0}".utf8)),
      UTType(filenameExtension: "flac")?.identifier)
    XCTAssertEqual(
      MediaContentTypeDetector.signatureType(for: Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVE".utf8)),
      UTType.wav.identifier)
    XCTAssertEqual(
      MediaContentTypeDetector.signatureType(for: Data("ID3\u{4}\u{0}\u{0}".utf8)),
      UTType.mp3.identifier)
  }

  func testRangeValidatorAcceptsMatchingPartialContent() throws {
    try MediaRangeResponseValidator.validate(
      requestedRange: "bytes=100-199",
      response: .init(
        data: Data(repeating: 1, count: 100), statusCode: 206, mimeType: "audio/mpeg",
        expectedContentLength: 100,
        headers: [
          "content-range": "bytes 100-199/1000", "content-length": "100",
          "accept-ranges": "bytes",
        ]))
  }

  func testRangeValidatorRejectsServerRestartingAtBeginning() {
    XCTAssertThrowsError(
      try MediaRangeResponseValidator.validate(
        requestedRange: "bytes=500-999",
        response: .init(
          data: Data(repeating: 1, count: 500), statusCode: 200, mimeType: "audio/mpeg",
          expectedContentLength: 500, headers: ["content-length": "500"])))
  }

  func testRangeValidatorRejectsWrongPartialOffset() {
    XCTAssertThrowsError(
      try MediaRangeResponseValidator.validate(
        requestedRange: "bytes=500-999",
        response: .init(
          data: Data(repeating: 1, count: 500), statusCode: 206, mimeType: "audio/mpeg",
          expectedContentLength: 500,
          headers: ["content-range": "bytes 0-499/1000", "content-length": "500"])))
  }

  private func makeSilentWAV(sampleRate: UInt32 = 8_000, duration: UInt32 = 1) -> Data {
    let payloadSize = sampleRate * 2 * duration
    var data = Data()
    func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
    func append16(_ value: UInt16) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    func append32(_ value: UInt32) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    appendASCII("RIFF")
    append32(36 + payloadSize)
    appendASCII("WAVEfmt ")
    append32(16)
    append16(1)
    append16(1)
    append32(sampleRate)
    append32(sampleRate * 2)
    append16(2)
    append16(16)
    appendASCII("data")
    append32(payloadSize)
    data.append(Data(repeating: 0, count: Int(payloadSize)))
    return data
  }

  private func rangeStart(_ range: String?) -> Int? {
    guard let range, range.hasPrefix("bytes=") else { return nil }
    return Int(range.dropFirst(6).split(separator: "-", maxSplits: 1)[0])
  }
}
