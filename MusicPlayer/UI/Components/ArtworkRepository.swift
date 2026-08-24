import Foundation
import ImageIO
import Network
import OSLog
import UIKit

final class ArtworkImageBox: @unchecked Sendable {
  let image: UIImage
  let encodedData: Data
  let memoryCost: Int

  init(image: UIImage, encodedData: Data) {
    self.image = image
    self.encodedData = encodedData
    let pixelsWide = image.cgImage?.width ?? Int(image.size.width * image.scale)
    let pixelsHigh = image.cgImage?.height ?? Int(image.size.height * image.scale)
    memoryCost = max(1, pixelsWide * pixelsHigh * 4)
  }
}

@MainActor
final class ArtworkRepository {
  static let shared = ArtworkRepository()

  private nonisolated static let logger = Logger(
    subsystem: "com.himhuu.music", category: "Artwork")
  private let cache: MusicCache
  private let memory = NSCache<NSString, ArtworkImageBox>()
  private let network = ArtworkNetworkQualityMonitor()
  private let cellularPlaybackGate = ArtworkCellularPlaybackGate()
  private var inFlight: [String: Task<ArtworkImageBox?, Never>] = [:]

  init(cache: MusicCache = .shared) {
    self.cache = cache
    memory.totalCostLimit = 48 * 1_024 * 1_024
    memory.countLimit = 180
  }

  func image(
    for url: URL,
    serverID: UUID?,
    fetcher: MusicArtworkFetcher?,
    cacheIdentity: String? = nil,
    maximumPixelSize: CGFloat = 768
  ) async -> UIImage? {
    let pixelBucket = Self.pixelBucket(maximumPixelSize)
    let sources = ArtworkURLFallback.sources(from: url)
    let diskKey = Self.cacheKey(
      primaryURL: sources.primary, identity: cacheIdentity, pixelBucket: pixelBucket)
    let memoryKey = "\(serverID?.uuidString.lowercased() ?? "public")|\(diskKey)"
    if let cached = memory.object(forKey: memoryKey as NSString) {
      return cached.image
    }
    if let existing = inFlight[memoryKey] {
      return await existing.value?.image
    }

    let cache = self.cache
    let network = self.network
    let cellularPlaybackGate = self.cellularPlaybackGate
    let task = Task(priority: .utility) {
      await Self.load(
        sources: sources, serverID: serverID, fetcher: fetcher, cache: cache,
        diskKey: diskKey, cacheIdentity: cacheIdentity, maximumPixelSize: pixelBucket,
        network: network,
        cellularPlaybackGate: cellularPlaybackGate)
    }
    inFlight[memoryKey] = task
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    inFlight[memoryKey] = nil
    if let result {
      memory.setObject(result, forKey: memoryKey as NSString, cost: result.memoryCost)
    }
    return result?.image
  }

  func removeAllMemoryImages() {
    memory.removeAllObjects()
  }

  func beginPlaybackArtworkDeferral() {
    cellularPlaybackGate.close()
  }

  func allowCellularArtworkNetworking() {
    cellularPlaybackGate.open()
  }

  private nonisolated static func load(
    sources: (primary: URL, fallback: URL?),
    serverID: UUID?,
    fetcher: MusicArtworkFetcher?,
    cache: MusicCache,
    diskKey: String,
    cacheIdentity: String?,
    maximumPixelSize: CGFloat,
    network: ArtworkNetworkQualityMonitor,
    cellularPlaybackGate: ArtworkCellularPlaybackGate
  ) async -> ArtworkImageBox? {
    if let serverID, let cachedData = try? await cache.artworkData(serverID: serverID, key: diskKey)
    {
      if let prepared = await prepare(cachedData, maximumPixelSize: maximumPixelSize) {
        return prepared
      }
      await cache.removeArtwork(serverID: serverID, key: diskKey)
    }

    while ArtworkFetchPolicy.shouldWaitForPlayback(
      usesExpensiveNetwork: network.isConstrainedOrExpensive,
      cellularPlaybackGateOpen: cellularPlaybackGate.isOpen)
    {
      do {
        try await Task.sleep(for: .milliseconds(250))
      } catch {
        return nil
      }
    }
    guard !Task.isCancelled else { return nil }

    if let primaryData = await fetch(sources.primary, fetcher: fetcher),
      !ArtworkPlaceholderDetector.isKnownPlaceholder(primaryData),
      let prepared = await prepare(primaryData, maximumPixelSize: maximumPixelSize)
    {
      if let serverID {
        try? await cache.storeArtwork(
          prepared.encodedData, serverID: serverID, key: diskKey, owner: cacheIdentity)
      }
      return prepared
    }
    if let fallback = sources.fallback,
      let fallbackData = await fetch(fallback, fetcher: fetcher),
      let prepared = await prepare(fallbackData, maximumPixelSize: maximumPixelSize)
    {
      if let serverID {
        try? await cache.storeArtwork(
          prepared.encodedData, serverID: serverID, key: diskKey, owner: cacheIdentity)
      }
      return prepared
    }
    return nil
  }

  private nonisolated static func fetch(
    _ url: URL, fetcher: MusicArtworkFetcher?
  ) async -> Data? {
    do {
      if let fetcher {
        return try await fetcher.load(url)
      }
      let (data, response) = try await URLSession.shared.data(from: url)
      guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
        return nil
      }
      return data
    } catch is CancellationError {
      return nil
    } catch {
      logger.debug("封面下载失败：\(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  private nonisolated static func prepare(
    _ data: Data, maximumPixelSize: CGFloat
  ) async -> ArtworkImageBox? {
    await Task.detached(priority: .utility) {
      let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
      guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary)
      else { return nil }
      let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maximumPixelSize)),
      ]
      guard
        let cgImage = CGImageSourceCreateThumbnailAtIndex(
          source, 0, thumbnailOptions as CFDictionary)
      else { return nil }
      let image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
      guard let encoded = image.jpegData(compressionQuality: 0.88) else { return nil }
      return ArtworkImageBox(image: image, encodedData: encoded)
    }.value
  }

  private nonisolated static func pixelBucket(_ requested: CGFloat) -> CGFloat {
    switch requested {
    case ..<193: 192
    case ..<385: 384
    case ..<769: 768
    case ..<1_025: 1_024
    default: 1_536
    }
  }

  private nonisolated static func cacheKey(
    primaryURL: URL, identity: String?, pixelBucket: CGFloat
  ) -> String {
    let base = identity.map { "identity:\($0)" } ?? "url:\(normalized(primaryURL))"
    return "artwork-v2|\(base)|px:\(Int(pixelBucket))"
  }

  private nonisolated static func normalized(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.path
    }
    let authenticationKeys = Set([
      "access_token", "account", "api_key", "c", "expires", "f", "p", "s", "signature", "t",
      "token", "u", "v",
    ])
    components.fragment = nil
    components.queryItems = components.queryItems?.filter {
      !authenticationKeys.contains($0.name.lowercased())
    }.sorted {
      if $0.name == $1.name { return ($0.value ?? "") < ($1.value ?? "") }
      return $0.name < $1.name
    }
    return components.string ?? url.path
  }
}

enum ArtworkFetchPolicy {
  nonisolated static func shouldWaitForPlayback(
    usesExpensiveNetwork: Bool, cellularPlaybackGateOpen: Bool
  ) -> Bool {
    usesExpensiveNetwork && !cellularPlaybackGateOpen
  }
}

private final class ArtworkCellularPlaybackGate: @unchecked Sendable {
  private let lock = NSLock()
  private var openState = true

  func close() {
    lock.withLock { openState = false }
  }

  func open() {
    lock.withLock { openState = true }
  }

  var isOpen: Bool {
    lock.withLock { openState }
  }
}

private final class ArtworkNetworkQualityMonitor: @unchecked Sendable {
  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var expensive = true

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      self?.lock.withLock {
        self?.expensive =
          path.status != .satisfied || path.isExpensive || path.isConstrained
      }
    }
    monitor.start(queue: DispatchQueue(label: "music.artwork-network-quality"))
  }

  deinit { monitor.cancel() }

  var isConstrainedOrExpensive: Bool {
    lock.withLock { expensive }
  }
}
