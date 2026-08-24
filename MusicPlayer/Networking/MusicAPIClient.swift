import Foundation

actor MusicAPIClient: MusicCatalogServing {
  enum APIError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case unauthorized
    case invalidPlaybackURL

    var errorDescription: String? {
      switch self {
      case .invalidResponse:
        "服务器返回了无法识别的数据。"
      case .httpStatus(let status):
        "服务器请求失败（HTTP \(status)）。"
      case .unauthorized:
        "账号或密码不正确。"
      case .invalidPlaybackURL:
        "服务器没有返回有效的播放地址。"
      }
    }
  }

  private struct PlaybackResponse: Decodable {
    let url: URL
    let expiresAt: Date
  }

  private let baseURL: URL
  private let authorizationHeader: String
  private let http: ProviderHTTPClient
  private let decoder: JSONDecoder

  init(connection: ServerConnection, http: ProviderHTTPClient) {
    baseURL = connection.baseURL
    let credentials = Data("\(connection.username):\(connection.password)".utf8)
      .base64EncodedString()
    authorizationHeader = "Basic \(credentials)"
    self.http = http
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  func fetchCatalog() async throws -> MusicCatalog {
    let request = request(pathComponents: ["v1", "catalog"], method: "GET")
    let data = try await execute(request)
    return try decoder.decode(MusicCatalog.self, from: data)
  }

  func fetchPlaybackURL(for trackID: UUID, encoding: MusicPlaybackEncoding?) async throws -> URL {
    let request = request(
      pathComponents: ["v1", "tracks", trackID.uuidString.lowercased(), "playback"],
      method: "POST", queryItems: encoding.map { [URLQueryItem(name: "format", value: $0.rawValue)] } ?? []
    )
    let data = try await execute(request)
    let response = try decoder.decode(PlaybackResponse.self, from: data)
    guard response.url.scheme == "https", response.expiresAt > Date() else {
      throw APIError.invalidPlaybackURL
    }
    return response.url
  }

  private func request(
    pathComponents: [String], method: String, queryItems: [URLQueryItem] = []
  ) -> URLRequest {
    var url = baseURL
    for component in pathComponents {
      url.append(path: component)
    }
    if !queryItems.isEmpty {
      url.append(queryItems: queryItems)
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 12
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("PrivateAudioLibrary-iOS", forHTTPHeaderField: "X-Client")
    request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
    return request
  }

  private func execute(_ request: URLRequest) async throws -> Data {
    try await http.data(for: request, retryPolicy: .transient(maxAttempts: 3))
  }
}
