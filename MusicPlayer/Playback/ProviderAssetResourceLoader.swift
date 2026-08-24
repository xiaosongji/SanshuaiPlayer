import AVFoundation
import Foundation
import OSLog
import UniformTypeIdentifiers

final class ProviderAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate,
  @unchecked Sendable
{
  private static let logger = Logger(
    subsystem: "com.himhuu.music", category: "MediaResourceLoader")
  private let provider: any MusicSourceProvider
  private let originalScheme: String
  private let publicURL: URL
  private let callbackQueue = DispatchQueue(label: "music.media-resource-loader")
  private let lock = NSLock()
  private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var isInvalidated = false
  private static let initialRangeChunkLength: Int64 = 64 * 1_024
  private static let maximumRangeChunkLength: Int64 = 512 * 1_024

  init(url: URL, provider: any MusicSourceProvider) throws {
    guard let scheme = url.scheme,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { throw MusicSourceError.playbackURLUnavailable }
    originalScheme = scheme
    components.scheme = "personal-music"
    guard let publicURL = components.url else { throw MusicSourceError.playbackURLUnavailable }
    self.publicURL = publicURL
    self.provider = provider
  }

  deinit { cancelAllTasks(invalidating: true) }

  /// Stops every in-flight range request. The playback controller calls this the moment a
  /// loader stops backing the current item, because AVFoundation only cancels outstanding
  /// loading requests on a best-effort basis; without it an abandoned track keeps streaming
  /// to the end of the file.
  func invalidate() { cancelAllTasks(invalidating: true) }

  private func cancelAllTasks(invalidating: Bool) {
    let running = lock.withLock { () -> [Task<Void, Never>] in
      if invalidating { isInvalidated = true }
      let values = Array(tasks.values)
      tasks.removeAll()
      return values
    }
    for task in running { task.cancel() }
  }

  func makeAsset() -> AVURLAsset {
    let asset = AVURLAsset(url: publicURL)
    asset.resourceLoader.setDelegate(self, queue: callbackQueue)
    return asset
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard let requestedURL = loadingRequest.request.url,
      let sourceURL = sourceURL(from: requestedURL)
    else { return false }
    let identifier = ObjectIdentifier(loadingRequest)
    let box = LoadingRequestBox(loadingRequest)
    let plan = LoadingRequestPlan(dataRequest: loadingRequest.dataRequest)
    let needsContentType = loadingRequest.contentInformationRequest != nil
    // The task must never capture `self` strongly: it would keep the loader alive for the
    // whole transfer, so `deinit` could never fire and the request would run to completion
    // long after the track was switched away from.
    let task = Task { [provider, callbackQueue, weak self] in
      defer { self?.removeTask(identifier) }
      do {
        try await Self.fulfill(
          box, sourceURL: sourceURL, plan: plan, needsContentType: needsContentType,
          provider: provider, callbackQueue: callbackQueue)
        guard !Task.isCancelled else { return }
        Self.finish(box, on: callbackQueue)
      } catch {
        guard !Task.isCancelled else { return }
        Self.logger.error(
          "媒体 Range 请求失败：\(error.localizedDescription, privacy: .public)")
        Self.finish(box, error: error, on: callbackQueue)
      }
    }
    let accepted = lock.withLock { () -> Bool in
      guard !isInvalidated else { return false }
      tasks[identifier] = task
      return true
    }
    guard accepted else {
      task.cancel()
      return false
    }
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    let identifier = ObjectIdentifier(loadingRequest)
    let task = lock.withLock { tasks.removeValue(forKey: identifier) }
    task?.cancel()
  }

  private func sourceURL(from url: URL) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.scheme = originalScheme
    return components.url
  }

  private static func fulfill(
    _ box: LoadingRequestBox, sourceURL: URL, plan: LoadingRequestPlan,
    needsContentType: Bool, provider: any MusicSourceProvider, callbackQueue: DispatchQueue
  ) async throws {
    guard plan.hasDataRequest else {
      let range = "bytes=0-63"
      try await provider.streamMediaResource(
        at: sourceURL, range: range,
        onResponse: { response in
          try MediaRangeResponseValidator.validate(
            requestedRange: range, response: response)
          _ = try await Self.deliverStreamChunk(
            box, response: response, probeData: Data(), data: Data(),
            needsContentType: needsContentType, callbackQueue: callbackQueue)
          return false
        },
        onData: { _ in false })
      return
    }

    var offset = plan.startOffset
    var remaining = plan.requestedLength
    var shouldProvideContentInformation = needsContentType
    var isFirstChunk = true
    while plan.requestsAllDataToEndOfResource || remaining > 0 {
      try Task.checkCancellation()
      let maximumChunkLength =
        isFirstChunk ? Self.initialRangeChunkLength : Self.maximumRangeChunkLength
      let chunkLength = min(
        maximumChunkLength,
        plan.requestsAllDataToEndOfResource ? maximumChunkLength : remaining)
      let range = Self.requestedRange(start: offset, length: chunkLength)
      let delivery = StreamingRangeDelivery(
        requestedOffset: offset, requestedLength: remaining,
        requestsAllDataToEndOfResource: plan.requestsAllDataToEndOfResource,
        partialResponseMaximumLength: chunkLength,
        needsContentType: shouldProvideContentInformation)
      try await provider.streamMediaResource(
        at: sourceURL, range: range,
        onResponse: { response in
          try MediaRangeResponseValidator.validate(
            requestedRange: range, response: response)
          delivery.configure(response)
          return true
        },
        onData: { data in
          let chunk = try delivery.consume(data)
          if chunk.needsDelivery {
            _ = try await Self.deliverStreamChunk(
              box, response: chunk.response, probeData: chunk.probeData,
              data: chunk.data, needsContentType: chunk.needsContentType,
              callbackQueue: callbackQueue)
          }
          return chunk.shouldContinue
        })
      try delivery.validateCompletion()
      let delivered = delivery.deliveredByteCount
      let total = delivery.totalLength
      shouldProvideContentInformation = false
      guard delivered > 0 else { throw MusicSourceError.invalidResponse }
      isFirstChunk = false
      offset += Int64(delivered)
      remaining = max(remaining - Int64(delivered), 0)
      if offset >= total { return }
    }
  }

  private static func requestedRange(start: Int64, length: Int64) -> String {
    let (candidate, overflow) = start.addingReportingOverflow(length - 1)
    return "bytes=\(start)-\(overflow ? Int64.max : candidate)"
  }

  private static func deliverStreamChunk(
    _ box: LoadingRequestBox, response: MusicMediaResponseMetadata, probeData: Data,
    data: Data, needsContentType: Bool, callbackQueue: DispatchQueue
  ) async throws -> Int {
    try await withCheckedThrowingContinuation { continuation in
      callbackQueue.async {
        if needsContentType, let information = box.request.contentInformationRequest {
          let detectedType = MediaContentTypeDetector.contentType(
            declaredMIMEType: response.mimeType, data: probeData)
          information.contentType = detectedType
          information.contentLength = Self.totalLength(response)
          information.isByteRangeAccessSupported =
            response.statusCode == 206
            || response.headers["accept-ranges"]?.lowercased().contains("bytes") == true
          #if DEBUG
            let declaredType = response.mimeType ?? "unknown"
            Self.logger.info(
              "媒体类型：declared=\(declaredType, privacy: .public), resolved=\(detectedType ?? "unknown", privacy: .public), length=\(information.contentLength, privacy: .public)")
          #endif
        }
        if !data.isEmpty { box.request.dataRequest?.respond(with: data) }
        continuation.resume(returning: data.count)
      }
    }
  }

  private static func totalLength(_ response: MusicMediaResponseMetadata) -> Int64 {
    if let contentRange = response.headers["content-range"],
      let total = contentRange.split(separator: "/").last.flatMap({ Int64($0) })
    {
      return total
    }
    if let value = response.headers["content-length"].flatMap(Int64.init) { return value }
    return max(response.expectedContentLength, 0)
  }

  private func removeTask(_ identifier: ObjectIdentifier) {
    _ = lock.withLock { tasks.removeValue(forKey: identifier) }
  }

  private static func finish(
    _ box: LoadingRequestBox, error: Error? = nil, on callbackQueue: DispatchQueue
  ) {
    callbackQueue.async {
      if let error {
        box.request.finishLoading(with: error)
      } else {
        box.request.finishLoading()
      }
    }
  }
}

private final class StreamingRangeDelivery: @unchecked Sendable {
  struct Chunk: Sendable {
    let response: MusicMediaResponseMetadata
    let probeData: Data
    let data: Data
    let needsContentType: Bool
    let shouldContinue: Bool
    var needsDelivery: Bool { needsContentType || !data.isEmpty }
  }

  private let lock = NSLock()
  private let requestedOffset: Int64
  private let requestedLength: Int64
  private let requestsAllDataToEndOfResource: Bool
  private let partialResponseMaximumLength: Int64
  private let initiallyNeedsContentType: Bool
  private var response: MusicMediaResponseMetadata?
  private var maximumDeliveryLength: Int64 = 0
  private var skippedBytes: Int64 = 0
  private var receivedBytes: Int64 = 0
  private var deliveredBytes: Int64 = 0
  private var probeData = Data()
  private var didDeliverContentType = false

  init(
    requestedOffset: Int64, requestedLength: Int64,
    requestsAllDataToEndOfResource: Bool, partialResponseMaximumLength: Int64,
    needsContentType: Bool
  ) {
    self.requestedOffset = requestedOffset
    self.requestedLength = requestedLength
    self.requestsAllDataToEndOfResource = requestsAllDataToEndOfResource
    self.partialResponseMaximumLength = partialResponseMaximumLength
    initiallyNeedsContentType = needsContentType
  }

  var deliveredByteCount: Int { lock.withLock { Int(deliveredBytes) } }

  var totalLength: Int64 {
    lock.withLock { response.map(Self.totalLength) ?? 0 }
  }

  func configure(_ response: MusicMediaResponseMetadata) {
    lock.withLock {
      self.response = response
      let total = Self.totalLength(response)
      maximumDeliveryLength =
        response.statusCode == 200
        ? (requestsAllDataToEndOfResource ? max(total - requestedOffset, 0) : requestedLength)
        : partialResponseMaximumLength
    }
  }

  func consume(_ data: Data) throws -> Chunk {
    try lock.withLock {
      guard let response, maximumDeliveryLength > 0 else {
        throw MusicSourceError.invalidResponse
      }
      receivedBytes += Int64(data.count)
      if probeData.count < 16 {
        probeData.append(data.prefix(16 - probeData.count))
      }

      var start = 0
      if response.statusCode == 200, skippedBytes < requestedOffset {
        let count = Int(min(requestedOffset - skippedBytes, Int64(data.count)))
        skippedBytes += Int64(count)
        start += count
      }
      let available = max(data.count - start, 0)
      let capacity = max(maximumDeliveryLength - deliveredBytes, 0)
      let count = Int(min(Int64(available), capacity))
      let output =
        count > 0 ? data.subdata(in: start..<(start + count)) : Data()
      deliveredBytes += Int64(count)

      let needsContentType = initiallyNeedsContentType && !didDeliverContentType
      if needsContentType { didDeliverContentType = true }
      return Chunk(
        response: response, probeData: probeData, data: output,
        needsContentType: needsContentType,
        shouldContinue: deliveredBytes < maximumDeliveryLength)
    }
  }

  func validateCompletion() throws {
    try lock.withLock {
      guard let response, deliveredBytes > 0 else {
        throw MusicSourceError.invalidResponse
      }
      if response.statusCode == 206,
        let expected = MediaRangeResponseValidator.expectedBodyLength(response: response),
        receivedBytes != expected
      {
        throw MusicSourceError.invalidResponse
      }
      if initiallyNeedsContentType, !didDeliverContentType {
        throw MusicSourceError.invalidResponse
      }
    }
  }

  private static func totalLength(_ response: MusicMediaResponseMetadata) -> Int64 {
    if let contentRange = response.headers["content-range"],
      let total = contentRange.split(separator: "/").last.flatMap({ Int64($0) })
    {
      return total
    }
    if let value = response.headers["content-length"].flatMap(Int64.init) { return value }
    return max(response.expectedContentLength, 0)
  }
}

private struct LoadingRequestPlan: Sendable {
  let hasDataRequest: Bool
  let startOffset: Int64
  let requestedLength: Int64
  let requestsAllDataToEndOfResource: Bool

  init(dataRequest: AVAssetResourceLoadingDataRequest?) {
    guard let dataRequest else {
      hasDataRequest = false
      startOffset = 0
      requestedLength = 0
      requestsAllDataToEndOfResource = false
      return
    }
    hasDataRequest = true
    startOffset = max(
      dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset, 0)
    requestedLength = Int64(max(dataRequest.requestedLength, 1))
    requestsAllDataToEndOfResource = dataRequest.requestsAllDataToEndOfResource
  }
}

enum MediaRangeResponseValidator {
  static func validate(requestedRange: String?, response: MusicMediaResponse) throws {
    try validate(requestedRange: requestedRange, response: response.metadata)
    guard requestedRange.flatMap(parseRequestedRange) != nil else { return }
    switch response.statusCode {
    case 206:
      guard let expected = expectedBodyLength(response: response.metadata),
        Int64(response.data.count) == expected
      else { throw MusicSourceError.invalidResponse }
    case 200:
      if let contentLength = response.headers["content-length"].flatMap(Int64.init) {
        guard contentLength == Int64(response.data.count) else {
          throw MusicSourceError.invalidResponse
        }
      }
    default:
      throw MusicSourceError.httpStatus(response.statusCode)
    }
  }

  static func validate(
    requestedRange: String?, response: MusicMediaResponseMetadata
  ) throws {
    guard let requested = requestedRange.flatMap(parseRequestedRange) else { return }
    switch response.statusCode {
    case 206:
      guard let contentRange = response.headers["content-range"],
        let returned = parseContentRange(contentRange),
        returned.start == requested.start,
        returned.end >= returned.start,
        requested.end.map({ returned.end <= $0 }) ?? true
      else { throw MusicSourceError.invalidResponse }
    case 200:
      // A cold transcoder may ignore Range and stream the complete representation.
      // This remains safe when the requested offset exists and bytes are discarded
      // until that offset before being passed to AVFoundation.
      let total = response.headers["content-length"].flatMap(Int64.init)
        ?? (response.expectedContentLength > 0 ? response.expectedContentLength : nil)
      guard requested.start == 0 || total.map({ requested.start < $0 }) == true else {
        throw MusicSourceError.invalidResponse
      }
    default:
      throw MusicSourceError.httpStatus(response.statusCode)
    }
  }

  static func expectedBodyLength(response: MusicMediaResponseMetadata) -> Int64? {
    guard response.statusCode == 206,
      let contentRange = response.headers["content-range"],
      let returned = parseContentRange(contentRange)
    else { return nil }
    return returned.end - returned.start + 1
  }

  private static func parseRequestedRange(_ value: String) -> (start: Int64, end: Int64?)? {
    guard value.lowercased().hasPrefix("bytes=") else { return nil }
    let parts = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard let first = parts.first, let start = Int64(first), start >= 0 else { return nil }
    let end = parts.count > 1 && !parts[1].isEmpty ? Int64(parts[1]) : nil
    return (start, end)
  }

  private static func parseContentRange(_ value: String) -> (
    start: Int64, end: Int64, total: Int64
  )? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.hasPrefix("bytes ") else { return nil }
    let components = normalized.dropFirst(6).split(separator: "/", maxSplits: 1)
    guard components.count == 2, let total = Int64(components[1]) else { return nil }
    let bounds = components[0].split(separator: "-", maxSplits: 1)
    guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
      start >= 0, end >= start, total > end
    else { return nil }
    return (start, end, total)
  }
}

enum MediaContentTypeDetector {
  static func contentType(declaredMIMEType: String?, data: Data) -> String? {
    signatureType(for: data)
      ?? declaredMIMEType
        .flatMap { $0.split(separator: ";", maxSplits: 1).first.map(String.init) }
        .flatMap { UTType(mimeType: $0.trimmingCharacters(in: .whitespaces))?.identifier }
  }

  static func signatureType(for data: Data) -> String? {
    let bytes = [UInt8](data.prefix(16))
    if bytes.count >= 12,
      String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp"
    {
      return UTType.mpeg4Audio.identifier
    }
    if hasASCII("fLaC", at: 0, in: bytes) {
      return UTType(filenameExtension: "flac")?.identifier ?? "org.xiph.flac"
    }
    if hasASCII("RIFF", at: 0, in: bytes), hasASCII("WAVE", at: 8, in: bytes) {
      return UTType.wav.identifier
    }
    if hasASCII("FORM", at: 0, in: bytes),
      hasASCII("AIFF", at: 8, in: bytes) || hasASCII("AIFC", at: 8, in: bytes)
    {
      return UTType.aiff.identifier
    }
    if hasASCII("caff", at: 0, in: bytes) { return AVFileType.caf.rawValue }
    if hasASCII("ID3", at: 0, in: bytes) || looksLikeMPEGFrame(bytes) {
      return UTType.mp3.identifier
    }
    if hasASCII("OggS", at: 0, in: bytes) {
      return UTType(filenameExtension: "ogg")?.identifier ?? "org.xiph.ogg"
    }
    return nil
  }

  private static func hasASCII(_ value: String, at offset: Int, in bytes: [UInt8]) -> Bool {
    let expected = Array(value.utf8)
    guard offset >= 0, bytes.count >= offset + expected.count else { return false }
    return Array(bytes[offset..<(offset + expected.count)]) == expected
  }

  private static func looksLikeMPEGFrame(_ bytes: [UInt8]) -> Bool {
    guard bytes.count >= 2 else { return false }
    return bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0
  }
}

private final class LoadingRequestBox: @unchecked Sendable {
  let request: AVAssetResourceLoadingRequest
  init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
}
