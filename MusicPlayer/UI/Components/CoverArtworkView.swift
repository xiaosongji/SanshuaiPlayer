import CryptoKit
import SwiftUI
import UIKit

struct CoverArtworkView: View {
  let url: URL?
  var cornerRadius: CGFloat = 16
  var cacheIdentity: String?
  var maximumPixelSize: CGFloat = 768
  @Environment(\.musicServerID) private var serverID
  @Environment(\.musicArtworkFetcher) private var artworkFetcher
  @State private var loadedImage: UIImage?

  var body: some View {
    if url == nil {
      placeholder
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    } else {
      remoteArtwork
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
  }

  private var remoteArtwork: some View {
    Group {
      if let loadedImage {
        Image(uiImage: loadedImage).resizable().scaledToFill()
      } else {
        placeholder
      }
    }
    .task(id: requestID) { await loadArtwork() }
  }

  private var placeholder: some View {
    Image("ArtworkPlaceholder")
      .resizable()
      .scaledToFill()
  }

  private func loadArtwork() async {
    guard let url else { return }
    loadedImage = nil
    loadedImage = await ArtworkRepository.shared.image(
      for: url, serverID: serverID, fetcher: artworkFetcher, cacheIdentity: cacheIdentity,
      maximumPixelSize: maximumPixelSize)
  }

  private var requestID: String {
    "\(url?.absoluteString ?? "none")|\(cacheIdentity ?? "url")|\(Int(maximumPixelSize))"
  }
}

enum ArtworkPlaceholderDetector {
  private static let knownSHA256: Set<String> = [
    // Navidrome 0.63.x default blue album artwork returned for missing covers.
    "273a4dbd61dfbb0a12d5d8ffe780eb7a3d4d000bc9771c5411cc70ae4dfa8a1f"
  ]

  static func isKnownPlaceholder(_ data: Data) -> Bool {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return knownSHA256.contains(digest)
  }
}

private struct MusicServerIDKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
  var musicServerID: UUID? {
    get { self[MusicServerIDKey.self] }
    set { self[MusicServerIDKey.self] = newValue }
  }
}

struct MusicArtworkFetcher: Sendable {
  let load: @Sendable (URL) async throws -> Data
}
private struct MusicArtworkFetcherKey: EnvironmentKey {
  static let defaultValue: MusicArtworkFetcher? = nil
}
extension EnvironmentValues {
  var musicArtworkFetcher: MusicArtworkFetcher? {
    get { self[MusicArtworkFetcherKey.self] }
    set { self[MusicArtworkFetcherKey.self] = newValue }
  }
}

#Preview {
  HStack {
    CoverArtworkView(url: nil, cornerRadius: 8)
      .frame(width: 56, height: 56)
    CoverArtworkView(url: nil, cornerRadius: 8)
      .frame(width: 56, height: 56)
  }
}
