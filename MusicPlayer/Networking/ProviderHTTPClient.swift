import CryptoKit
import Foundation
import OSLog
import Security

enum ProviderRequestRetryPolicy: Sendable, Equatable {
  case none
  case transient(maxAttempts: Int)
}

struct ProviderHTTPClient: Sendable {
  private let session: URLSession
  private let mediaStreamer: ProviderMediaStreamer
  private let trustFailureState: TrustFailureState
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MusicPlayer", category: "ProviderNetwork")

  init(server: MusicServer, session: URLSession? = nil) {
    let trustFailureState = TrustFailureState()
    self.trustFailureState = trustFailureState
    let streamingConfiguration: URLSessionConfiguration
    if let session {
      self.session = session
      streamingConfiguration = session.configuration
    } else {
      let configuration = URLSessionConfiguration.default
      configuration.timeoutIntervalForRequest = 20
      // A whole-track download is a legitimate multi-minute transfer on a slow link; the old
      // 120 s resource cap aborted and retried it, which reads as a stall.
      configuration.timeoutIntervalForResource = 600
      configuration.waitsForConnectivity = true
      configuration.requestCachePolicy = .reloadRevalidatingCacheData
      configuration.urlCache = URLCache(
        memoryCapacity: 32 * 1_024 * 1_024, diskCapacity: 256 * 1_024 * 1_024)
      let delegate = ServerTrustDelegate(server: server, failureState: trustFailureState)
      self.session = URLSession(
        configuration: configuration, delegate: delegate, delegateQueue: nil)
      streamingConfiguration = configuration
    }
    mediaStreamer = ProviderMediaStreamer(
      configuration: streamingConfiguration, server: server,
      failureState: trustFailureState)
  }

  func data(
    for request: URLRequest, validStatusCodes: Range<Int> = 200..<300,
    retryPolicy: ProviderRequestRetryPolicy = .none
  ) async throws -> Data
  {
    try await mediaResponse(
      for: request, validStatusCodes: validStatusCodes, retryPolicy: retryPolicy
    ).data
  }

  func mediaResponse(
    for request: URLRequest, validStatusCodes: Range<Int> = 200..<300,
    retryPolicy: ProviderRequestRetryPolicy = .none
  ) async throws -> MusicMediaResponse {
    let maximumAttempts = switch retryPolicy {
    case .none: 1
    case .transient(let maxAttempts): max(1, min(maxAttempts, 4))
    }
    var attempt = 1
    while true {
      do {
        return try await perform(request, validStatusCodes: validStatusCodes)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if let trustError = trustFailureState.consume() { throw trustError }
        let mapped = MusicSourceError.map(error)
        guard attempt < maximumAttempts, shouldRetry(mapped) else {
          logger.error("Provider request failed: \(mapped.localizedDescription, privacy: .public)")
          throw mapped
        }
        logger.notice(
          "Retrying transient provider request (attempt \(attempt + 1, privacy: .public) of \(maximumAttempts, privacy: .public))")
        try await Task.sleep(for: .milliseconds(attempt == 1 ? 250 : 750))
        attempt += 1
      }
    }
  }

  func streamMediaResponse(
    for request: URLRequest, validStatusCodes: Range<Int> = 200..<300,
    retryPolicy: ProviderRequestRetryPolicy = .none,
    onResponse: @escaping @Sendable (MusicMediaResponseMetadata) async throws -> Bool,
    onData: @escaping @Sendable (Data) async throws -> Bool
  ) async throws {
    let maximumAttempts = switch retryPolicy {
    case .none: 1
    case .transient(let maxAttempts): max(1, min(maxAttempts, 4))
    }
    var attempt = 1
    while true {
      let progress = ProviderMediaStreamProgress()
      do {
        try await mediaStreamer.consume(request) { event in
          switch event {
          case .response(let response):
            switch response.statusCode {
            case 401: throw MusicSourceError.authenticationFailed
            case 403: throw MusicSourceError.permissionDenied
            case 404: throw MusicSourceError.fileNotFound
            default: break
            }
            guard validStatusCodes.contains(response.statusCode) else {
              throw MusicSourceError.httpStatus(response.statusCode)
            }
            return try await onResponse(response)
          case .data(let data):
            progress.record(data.count)
            return try await onData(data)
          }
        }
        return
      } catch {
        if Task.isCancelled || Self.isCancellation(error) { throw CancellationError() }
        if let trustError = trustFailureState.consume() { throw trustError }
        let mapped = MusicSourceError.map(error)
        guard !progress.hasDeliveredData, attempt < maximumAttempts, shouldRetry(mapped) else {
          logger.error(
            "Provider streaming request failed: \(mapped.localizedDescription, privacy: .public)")
          throw mapped
        }
        logger.notice(
          "Retrying transient provider stream (attempt \(attempt + 1, privacy: .public) of \(maximumAttempts, privacy: .public))")
        try await Task.sleep(for: .milliseconds(attempt == 1 ? 250 : 750))
        attempt += 1
      }
    }
  }

  func downloadResponse(
    for request: URLRequest, validStatusCodes: Range<Int> = 200..<300,
    retryPolicy: ProviderRequestRetryPolicy = .none
  ) async throws -> MusicMediaDownload {
    let maximumAttempts = switch retryPolicy {
    case .none: 1
    case .transient(let maxAttempts): max(1, min(maxAttempts, 4))
    }
    var attempt = 1
    while true {
      do {
        return try await performDownload(request, validStatusCodes: validStatusCodes)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if let trustError = trustFailureState.consume() { throw trustError }
        let mapped = MusicSourceError.map(error)
        guard attempt < maximumAttempts, shouldRetry(mapped) else {
          logger.error("Provider download failed: \(mapped.localizedDescription, privacy: .public)")
          throw mapped
        }
        logger.notice(
          "Retrying transient provider download (attempt \(attempt + 1, privacy: .public) of \(maximumAttempts, privacy: .public))")
        try await Task.sleep(for: .milliseconds(attempt == 1 ? 250 : 750))
        attempt += 1
      }
    }
  }

  func decoded<T: Decodable & Sendable>(
    _ type: T.Type, for request: URLRequest, decoder: JSONDecoder = JSONDecoder(),
    retryPolicy: ProviderRequestRetryPolicy = .none
  ) async throws -> T {
    let data = try await data(for: request, retryPolicy: retryPolicy)
    do { return try decoder.decode(type, from: data) } catch {
      logger.error(
        "Provider response decoding failed for \(String(describing: type), privacy: .public)")
      throw MusicSourceError.invalidResponse
    }
  }

  private func perform(_ request: URLRequest, validStatusCodes: Range<Int>) async throws
    -> MusicMediaResponse
  {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MusicSourceError.invalidResponse
    }
    switch response.statusCode {
    case 401: throw MusicSourceError.authenticationFailed
    case 403: throw MusicSourceError.permissionDenied
    case 404: throw MusicSourceError.fileNotFound
    default: break
    }
    guard validStatusCodes.contains(response.statusCode) else {
      logger.error(
        "Provider request failed with HTTP status \(response.statusCode, privacy: .public)")
      throw MusicSourceError.httpStatus(response.statusCode)
    }
    let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, value in
      result[String(describing: value.key).lowercased()] = String(describing: value.value)
    }
    return MusicMediaResponse(
      data: data, statusCode: response.statusCode, mimeType: response.mimeType,
      expectedContentLength: response.expectedContentLength, headers: headers)
  }

  private func performDownload(_ request: URLRequest, validStatusCodes: Range<Int>) async throws
    -> MusicMediaDownload
  {
    let (temporaryURL, response) = try await session.download(for: request)
    do {
      guard let response = response as? HTTPURLResponse else {
        throw MusicSourceError.invalidResponse
      }
      switch response.statusCode {
      case 401: throw MusicSourceError.authenticationFailed
      case 403: throw MusicSourceError.permissionDenied
      case 404: throw MusicSourceError.fileNotFound
      default: break
      }
      guard validStatusCodes.contains(response.statusCode) else {
        logger.error(
          "Provider download failed with HTTP status \(response.statusCode, privacy: .public)")
        throw MusicSourceError.httpStatus(response.statusCode)
      }
      let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, value in
        result[String(describing: value.key).lowercased()] = String(describing: value.value)
      }
      return MusicMediaDownload(
        temporaryURL: temporaryURL, statusCode: response.statusCode, mimeType: response.mimeType,
        expectedContentLength: response.expectedContentLength, headers: headers)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }

  private func shouldRetry(_ error: MusicSourceError) -> Bool {
    switch error {
    case .dnsFailure, .networkUnavailable, .timeout, .tlsFailure:
      true
    case .httpStatus(let status):
      [408, 425, 429, 500, 502, 503, 504].contains(status)
    default:
      false
    }
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let value = error as NSError
    return value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled
  }
}

private enum ProviderMediaStreamEvent: Sendable {
  case response(MusicMediaResponseMetadata)
  case data(Data)
}

private final class ProviderMediaStreamer: @unchecked Sendable {
  private let delegate: ProviderMediaStreamDelegate
  private let session: URLSession

  init(
    configuration: URLSessionConfiguration, server: MusicServer,
    failureState: TrustFailureState
  ) {
    let configuration = configuration.copy() as! URLSessionConfiguration
    // Audio range requests must not go through the shared URLCache: they would evict the
    // metadata it exists for, and `reloadRevalidatingCacheData` adds a revalidation round trip
    // to every chunk. Media is cached by `MusicCache` instead.
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let delegate = ProviderMediaStreamDelegate(server: server, failureState: failureState)
    self.delegate = delegate
    session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  func consume(
    _ request: URLRequest,
    onEvent: (ProviderMediaStreamEvent) async throws -> Bool
  ) async throws {
    let pair = AsyncThrowingStream<ProviderMediaStreamEvent, Error>.makeStream()
    let task = session.dataTask(with: request)
    let identifier = task.taskIdentifier
    delegate.register(pair.continuation, taskIdentifier: identifier)
    try await withTaskCancellationHandler {
      defer {
        task.cancel()
        delegate.unregister(taskIdentifier: identifier)
      }
      try Task.checkCancellation()
      task.resume()
      for try await event in pair.stream {
        guard try await onEvent(event) else { return }
      }
    } onCancel: {
      task.cancel()
    }
  }
}

private final class ProviderMediaStreamDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  fileprivate typealias Continuation =
    AsyncThrowingStream<ProviderMediaStreamEvent, Error>.Continuation
  private let trustDelegate: ServerTrustDelegate
  private let lock = NSLock()
  private var continuations: [Int: Continuation] = [:]

  init(server: MusicServer, failureState: TrustFailureState) {
    trustDelegate = ServerTrustDelegate(server: server, failureState: failureState)
  }

  fileprivate func register(_ continuation: Continuation, taskIdentifier: Int) {
    lock.withLock { continuations[taskIdentifier] = continuation }
  }

  fileprivate func unregister(taskIdentifier: Int) {
    let continuation = lock.withLock { continuations.removeValue(forKey: taskIdentifier) }
    continuation?.finish()
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    trustDelegate.urlSession(
      session, didReceive: challenge, completionHandler: completionHandler)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      finish(taskIdentifier: dataTask.taskIdentifier, error: MusicSourceError.invalidResponse)
      completionHandler(.cancel)
      return
    }
    let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, value in
      result[String(describing: value.key).lowercased()] = String(describing: value.value)
    }
    let metadata = MusicMediaResponseMetadata(
      statusCode: response.statusCode, mimeType: response.mimeType,
      expectedContentLength: response.expectedContentLength, headers: headers)
    continuation(for: dataTask.taskIdentifier)?.yield(.response(metadata))
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    continuation(for: dataTask.taskIdentifier)?.yield(.data(data))
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    finish(taskIdentifier: task.taskIdentifier, error: error)
  }

  private func continuation(for taskIdentifier: Int) -> Continuation? {
    lock.withLock { continuations[taskIdentifier] }
  }

  private func finish(taskIdentifier: Int, error: Error?) {
    let continuation = lock.withLock { continuations.removeValue(forKey: taskIdentifier) }
    if let error {
      continuation?.finish(throwing: error)
    } else {
      continuation?.finish()
    }
  }
}

private final class ProviderMediaStreamProgress: @unchecked Sendable {
  private let lock = NSLock()
  private var deliveredBytes = 0

  var hasDeliveredData: Bool { lock.withLock { deliveredBytes > 0 } }

  func record(_ count: Int) {
    lock.withLock { deliveredBytes += max(count, 0) }
  }
}

private final class ServerTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
  private let host: String
  private let allowsSelfSigned: Bool
  private let fingerprint: String?
  private let failureState: TrustFailureState

  init(server: MusicServer, failureState: TrustFailureState) {
    host = server.baseURL.host()?.lowercased() ?? ""
    allowsSelfSigned = server.allowsSelfSignedCertificate
    fingerprint = server.certificateFingerprint?.filter(\.isHexDigit).lowercased()
    self.failureState = failureState
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      challenge.protectionSpace.host.lowercased() == host,
      let trust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }

    if let fingerprint {
      guard
        let certificate = SecTrustCopyCertificateChain(trust).flatMap({ $0 as? [SecCertificate] })?
          .first
      else {
        failureState.record(.untrustedCertificate)
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      let actual = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map {
        String(format: "%02x", $0)
      }.joined()
      guard actual == fingerprint else {
        failureState.record(.untrustedCertificate)
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      completionHandler(.useCredential, URLCredential(trust: trust))
      return
    }
    var error: CFError?
    if SecTrustEvaluateWithError(trust, &error) {
      completionHandler(.useCredential, URLCredential(trust: trust))
      return
    }
    guard allowsSelfSigned else {
      failureState.record(.untrustedCertificate)
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }
}

private final class TrustFailureState: @unchecked Sendable {
  private let lock = NSLock()
  private var error: MusicSourceError?
  func record(_ error: MusicSourceError) { lock.withLock { self.error = error } }
  func consume() -> MusicSourceError? {
    lock.withLock {
      defer { error = nil }
      return error
    }
  }
}

extension URL {
  func appendingAPIPath(_ path: String) -> URL {
    path.split(separator: "/").reduce(self) { $0.appending(path: String($1)) }
  }
}
