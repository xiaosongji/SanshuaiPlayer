import AVFoundation
import Foundation

enum MusicSourceError: LocalizedError, Equatable, Sendable {
  case invalidAddress
  case dnsFailure
  case networkUnavailable
  case timeout
  case tlsFailure
  case untrustedCertificate
  case authenticationFailed
  case tokenExpired
  case permissionDenied
  case incompatibleServer
  case invalidResponse
  case httpStatus(Int)
  case emptyLibrary
  case playbackURLUnavailable
  case transcodingFailed
  case fileNotFound
  case unsupportedFormat
  case unsupportedFeature
  case keychainFailure(Int32)

  var errorDescription: String? {
    switch self {
    case .invalidAddress: String(localized: "服务器地址无效，请检查地址和端口。")
    case .dnsFailure: String(localized: "无法解析服务器地址，请检查域名或 DNS。")
    case .networkUnavailable: String(localized: "当前网络不可用，请检查网络连接。")
    case .timeout: String(localized: "连接服务器超时，请稍后重试。")
    case .tlsFailure: String(localized: "无法建立安全连接，请检查服务器证书。")
    case .untrustedCertificate: String(localized: "服务器证书不受信任。请核对证书后再决定是否允许。")
    case .authenticationFailed: String(localized: "账号、密码或访问令牌不正确。")
    case .tokenExpired: String(localized: "登录已过期，请重新验证账号。")
    case .permissionDenied: String(localized: "当前账号没有执行此操作的权限。")
    case .incompatibleServer: String(localized: "服务器版本或协议不兼容。")
    case .invalidResponse: String(localized: "服务器返回了无法识别的数据。")
    case .httpStatus(let code): String(localized: "服务器请求失败（状态码 \(code)）。")
    case .emptyLibrary: String(localized: "这个音乐库中还没有可浏览的音乐。")
    case .playbackURLUnavailable: String(localized: "暂时无法获取歌曲播放地址。")
    case .transcodingFailed: String(localized: "服务器无法完成音频转码。")
    case .fileNotFound: String(localized: "服务器上的音乐文件已不存在。")
    case .unsupportedFormat: String(localized: "此音频格式当前无法播放。")
    case .unsupportedFeature: String(localized: "当前音乐源不支持此功能。")
    case .keychainFailure(let status):
      if status == -34_018 {
        #if targetEnvironment(simulator)
          String(localized: "当前模拟器构建缺少 Keychain 签名权限。本次可使用临时凭据继续连接；重启 App 后需重新输入。")
        #else
          String(localized: "无法访问系统安全存储。请检查 App 签名和 Keychain 权限后重试。")
        #endif
      } else {
        String(localized: "无法访问本机安全存储，请稍后重试。")
      }
    }
  }

  static func map(_ error: Error) -> MusicSourceError {
    if let sourceError = error as? MusicSourceError { return sourceError }
    let nsError = error as NSError
    if let networkError = underlyingURLError(in: nsError) {
      return mapURL(networkError)
    }
    if nsError.domain == AVFoundationErrorDomain {
      return explicitlyUnsupportedAVErrorCodes.contains(nsError.code)
        ? .unsupportedFormat : .invalidResponse
    }
    guard let error = error as? URLError else { return .invalidResponse }
    return mapURL(error)
  }

  private static let explicitlyUnsupportedAVErrorCodes: Set<Int> = [
    AVError.fileFormatNotRecognized.rawValue,
    AVError.fileFailedToParse.rawValue,
    AVError.decoderNotFound.rawValue,
  ]

  private static func underlyingURLError(in error: NSError) -> URLError? {
    var current: NSError? = error
    var visited = Set<ObjectIdentifier>()
    while let value = current, visited.insert(ObjectIdentifier(value)).inserted {
      if value.domain == NSURLErrorDomain {
        return URLError(URLError.Code(rawValue: value.code), userInfo: value.userInfo)
      }
      current = value.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return nil
  }

  private static func mapURL(_ error: URLError) -> MusicSourceError {
    switch error.code {
    case .badURL, .unsupportedURL: .invalidAddress
    case .cannotFindHost, .dnsLookupFailed: .dnsFailure
    case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost: .networkUnavailable
    case .timedOut: .timeout
    case .serverCertificateUntrusted, .serverCertificateHasBadDate,
      .serverCertificateHasUnknownRoot, .clientCertificateRejected:
      .untrustedCertificate
    case .secureConnectionFailed, .clientCertificateRequired: .tlsFailure
    default: .networkUnavailable
    }
  }
}
