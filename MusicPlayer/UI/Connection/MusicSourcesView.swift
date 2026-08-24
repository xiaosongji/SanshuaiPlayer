import SwiftUI

struct MusicSourcesView: View {
  @Environment(MusicSourceStore.self) private var sources
  @Environment(\.colorScheme) private var colorScheme
  @State private var showsAdd = false
  @State private var pendingRemoval: MusicServer?
  @State private var operationError: String?
  @State private var showsMigrationDetails = false

  var body: some View {
    ZStack {
      sourceBackground
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          sourceHero

          if sources.isUsingEphemeralSimulatorCredentials {
            sourceNotice(
              title: "模拟器临时凭据，重启后需重新输入",
              detail: String(localized: "凭据只保留在当前 App 进程内，不会写入磁盘。真机与正式版本始终使用 Keychain。"),
              icon: "key.slash.fill")
          }

          if !sources.servers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              Text("我的音乐源")
                .font(.title3.weight(.bold))
                .foregroundStyle(HimhuuVisualTheme.foreground(for: colorScheme))
              ForEach(sources.servers) { server in sourceRow(server) }
            }
          }

          VStack(alignment: .leading, spacing: 12) {
            if sources.servers.isEmpty {
              Text("尚未配置音乐源")
                .font(.title3.weight(.bold))
                .foregroundStyle(HimhuuVisualTheme.foreground(for: colorScheme))
            }
            sourceAction(
              title: "使用本机或 NAS 文件夹",
              detail: "可通过系统“文件”连接 SMB NAS",
              icon: "folder.badge.plus", tint: HimhuuVisualTheme.peach,
              action: addLocalSource)
            sourceAction(
              title: "添加音乐源",
              detail: "Navidrome、Jellyfin 或已有 NAS 服务",
              icon: "plus", tint: HimhuuVisualTheme.lavender
            ) { showsAdd = true }
          }

          if let report = sources.lastMigrationReport {
            DisclosureGroup(isExpanded: $showsMigrationDetails) {
              Text(report)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            } label: {
              Label("迁移与连接记录", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
            }
            .padding(16)
            .sourceGlassSurface(tint: HimhuuVisualTheme.softPeach.opacity(0.20))
          }

          if let operationError {
            sourceNotice(
              title: "暂时无法连接音乐源", detail: operationError,
              icon: "exclamationmark.triangle.fill")
          }

          Text(
            sources.isUsingEphemeralSimulatorCredentials
              ? String(localized: "当前模拟器凭据仅保留在内存中。不同音乐源的缓存彼此隔离。")
              : String(localized: "密码和令牌只保存在本机 Keychain。不同音乐源的缓存彼此隔离。"))
            .font(.footnote)
            .foregroundStyle(.secondary)
          PlayerDockScrollFooter()
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .frame(maxWidth: .infinity)
      }
    }
    .navigationTitle("")
    .toolbarBackground(.hidden, for: .navigationBar)
    .sheet(isPresented: $showsAdd) { AddMusicSourceView() }
    .confirmationDialog(
      "删除 \(pendingRemoval?.name ?? "音乐源")",
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      titleVisibility: .visible
    ) {
      if let server = pendingRemoval {
        Button("删除音乐源和缓存", role: .destructive) { remove(server, deleteCache: true) }
        Button("删除音乐源，保留缓存", role: .destructive) { remove(server, deleteCache: false) }
      }
      Button("取消", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text("凭据会从 Keychain 删除。你可以选择是否同时删除该音乐源的缓存。")
    }
  }

  private var sourceBackground: some View {
    LinearGradient(
      colors: colorScheme == .dark
        ? [
          HimhuuVisualTheme.cocoa,
          Color(red: 0.28, green: 0.16, blue: 0.14),
          Color(red: 0.24, green: 0.17, blue: 0.25),
        ]
        : [
          HimhuuVisualTheme.cream,
          Color(red: 1.00, green: 0.89, blue: 0.82),
          Color(red: 0.95, green: 0.90, blue: 0.98),
        ],
      startPoint: .topLeading, endPoint: .bottomTrailing)
      .ignoresSafeArea()
  }

  private var sourceHero: some View {
    HStack(spacing: 20) {
      SourceClayArchiveMark()
        .frame(width: 104, height: 112)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text("音乐源")
          .font(.system(.largeTitle, design: .rounded, weight: .black))
        Text("我的音乐源")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .foregroundStyle(HimhuuVisualTheme.foreground(for: colorScheme))
    }
  }

  private func sourceAction(
    title: LocalizedStringKey, detail: LocalizedStringKey, icon: String, tint: Color,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: icon)
          .font(.system(size: 21, weight: .bold))
          .foregroundStyle(colorScheme == .dark ? HimhuuVisualTheme.cream : .white)
          .frame(width: 48, height: 48)
          .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .shadow(color: tint.opacity(0.28), radius: 8, y: 5)
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.headline)
            .foregroundStyle(HimhuuVisualTheme.foreground(for: colorScheme))
          Text(detail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.subheadline.weight(.bold))
          .foregroundStyle(.secondary)
      }
      .padding(16)
      .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
      .sourceGlassSurface(tint: tint.opacity(colorScheme == .dark ? 0.12 : 0.10))
    }
    .buttonStyle(.plain)
  }

  private func sourceRow(_ server: MusicServer) -> some View {
    NavigationLink {
      MusicSourceDetailView(serverID: server.id)
    } label: {
      HStack(spacing: 14) {
        Image(
          systemName: server.sourceType == .local ? "iphone.and.arrow.forward"
            : server.sourceType == .jellyfin
              ? "play.tv" : "externaldrive.connected.to.line.below"
        )
        .font(.system(size: 20, weight: .semibold))
        .frame(width: 44, height: 44)
        .background(HimhuuVisualTheme.softPeach.opacity(0.28), in: Circle())
        VStack(alignment: .leading, spacing: 3) {
          Text(server.name).font(.headline)
          Text(server.sourceType.title).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Circle()
          .fill(server.status == .online ? .green : server.status == .offline ? .red : .secondary)
          .frame(width: 8, height: 8)
        if server.id == sources.activeServerID {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(HimhuuVisualTheme.peach)
        }
      }
      .foregroundStyle(HimhuuVisualTheme.foreground(for: colorScheme))
      .padding(16)
      .sourceGlassSurface(tint: HimhuuVisualTheme.cream.opacity(0.10))
    }
    .buttonStyle(.plain)
    .swipeActions {
      Button(role: .destructive) {
        pendingRemoval = server
      } label: {
        Label("删除", systemImage: "trash")
      }
    }
  }

  private func sourceNotice(
    title: LocalizedStringKey, detail: String, icon: String
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon).foregroundStyle(HimhuuVisualTheme.peach)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.subheadline.weight(.semibold))
        Text(detail).font(.footnote).foregroundStyle(.secondary)
      }
    }
    .foregroundStyle(HimhuuVisualTheme.foreground(for: colorScheme))
    .padding(16)
    .sourceGlassSurface(tint: HimhuuVisualTheme.softPeach.opacity(0.16))
  }

  private func remove(_ server: MusicServer, deleteCache: Bool) {
    Task {
      do {
        try await sources.remove(server.id, deleteCache: deleteCache)
        pendingRemoval = nil
        operationError = nil
      } catch { operationError = MusicSourceError.map(error).localizedDescription }
    }
  }

  private func addLocalSource() {
    Task {
      do {
        try await sources.addLocalSource()
        operationError = nil
      } catch { operationError = MusicSourceError.map(error).localizedDescription }
    }
  }
}

private struct SourceClayArchiveMark: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 30, style: .continuous)
        .fill(
          LinearGradient(
            colors: [HimhuuVisualTheme.softPeach, HimhuuVisualTheme.peach],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        .frame(width: 96, height: 88)
        .offset(y: 10)
        .shadow(color: HimhuuVisualTheme.warmInk.opacity(0.20), radius: 14, y: 10)
      Capsule()
        .fill(HimhuuVisualTheme.lavender)
        .frame(width: 64, height: 20)
        .offset(y: -35)
      Circle()
        .fill(HimhuuVisualTheme.cream)
        .frame(width: 58, height: 58)
        .offset(y: 10)
        .shadow(color: HimhuuVisualTheme.warmInk.opacity(0.14), radius: 5, y: 3)
      HStack(alignment: .center, spacing: 5) {
        Capsule().fill(HimhuuVisualTheme.peach).frame(width: 7, height: 22)
        Capsule().fill(HimhuuVisualTheme.lavender).frame(width: 7, height: 34)
        Capsule().fill(HimhuuVisualTheme.peach).frame(width: 7, height: 22)
      }
      .offset(y: 10)
    }
  }
}

private struct SourceGlassSurfaceModifier: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme
  let tint: Color

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    content
      .background(
        reduceTransparency
          ? colorScheme == .dark
            ? HimhuuVisualTheme.cocoa : HimhuuVisualTheme.cream
          : colorScheme == .dark
            ? HimhuuVisualTheme.cocoa.opacity(0.68) : HimhuuVisualTheme.cream.opacity(0.58),
        in: shape)
      .background(reduceTransparency ? AnyShapeStyle(.clear) : AnyShapeStyle(.regularMaterial), in: shape)
      .overlay { shape.fill(tint).allowsHitTesting(false) }
      .shadow(
        color: HimhuuVisualTheme.warmInk.opacity(colorScheme == .dark ? 0.24 : 0.12),
        radius: 16, y: 9)
  }
}

private extension View {
  func sourceGlassSurface(tint: Color) -> some View {
    modifier(SourceGlassSurfaceModifier(tint: tint))
  }
}

private struct MusicSourceDetailView: View {
  @Environment(MusicSourceStore.self) private var sources
  let serverID: UUID
  @State private var isTesting = false
  @State private var message: String?
  @State private var showsEdit = false
  @State private var libraries: [MusicLibrary] = []
  private var server: MusicServer? { sources.servers.first { $0.id == serverID } }
  var body: some View {
    Form {
      if let server {
        Section("服务器") {
          LabeledContent("名称", value: server.name)
          LabeledContent("类型", value: server.sourceType.title)
          if server.sourceType != .local {
            LabeledContent("主机", value: server.baseURL.host() ?? "-")
          }
          LabeledContent(
            "状态", value: server.status == .online ? String(localized: "在线")
              : server.status == .offline ? String(localized: "离线") : String(localized: "尚未检查")
          )
          if let date = server.lastConnectedAt {
            LabeledContent("上次连接") { Text(date, style: .relative) }
          }
          if let error = server.lastError { Text(error).foregroundStyle(.red) }
        }
        if server.sourceType != .local && !libraries.isEmpty {
          Section("默认音乐库") {
            Picker(
              "音乐库",
              selection: Binding(get: { server.defaultLibraryID }, set: { selectLibrary($0) })
            ) {
              Text("全部音乐库").tag(String?.none)
              ForEach(libraries) { library in Text(library.name).tag(Optional(library.id)) }
            }
          }
        }
        Section {
          Button(server.id == sources.activeServerID ? "当前正在使用" : "切换到此音乐源") {
            do {
              try sources.select(server.id)
              message = nil
            } catch { message = MusicSourceError.map(error).localizedDescription }
          }.disabled(server.id == sources.activeServerID)
          if server.sourceType != .local {
            Button(isTesting ? "正在测试…" : "测试连接") { test() }.disabled(isTesting)
            Button("编辑设置") { showsEdit = true }
          }
        }
        if let message { Section { Text(message) } }
      }
      PlayerDockScrollFooter()
    }.navigationTitle(server?.name ?? "音乐源").sheet(isPresented: $showsEdit) {
      if let server { EditMusicSourceView(server: server) }
    }.task { await loadLibraries() }
  }
  private func test() {
    isTesting = true
    message = nil
    Task {
      do {
        let info = try await sources.testConnection(serverID: serverID)
        message = String(localized: "连接成功：\(info.name) \(info.version ?? "")")
      } catch { message = MusicSourceError.map(error).localizedDescription }
      isTesting = false
    }
  }
  private func loadLibraries() async {
    do { libraries = try await sources.libraries(serverID: serverID) } catch {
      message = MusicSourceError.map(error).localizedDescription
    }
  }
  private func selectLibrary(_ libraryID: String?) {
    do {
      try sources.setDefaultLibrary(serverID: serverID, libraryID: libraryID)
      message = nil
    } catch { message = MusicSourceError.map(error).localizedDescription }
  }
}

private struct EditMusicSourceView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(MusicSourceStore.self) private var sources
  @State private var server: MusicServer
  @State private var address: String
  @State private var password = ""
  @State private var originalUsername: String
  @State private var error: String?
  init(server: MusicServer) {
    _server = State(initialValue: server)
    _address = State(initialValue: server.baseURL.absoluteString)
    _originalUsername = State(initialValue: server.username)
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("服务器") {
          TextField("名称", text: $server.name)
          TextField("地址", text: $address).keyboardType(.URL).textInputAutocapitalization(.never)
          TextField("用户名", text: $server.username)
          SecureField("新密码（不修改可留空）", text: $password)
        }
        Section("安全") {
          Toggle("允许自签名证书", isOn: $server.allowsSelfSignedCertificate)
          if server.allowsSelfSignedCertificate {
            TextField(
              "SHA-256 指纹",
              text: Binding(
                get: { server.certificateFingerprint ?? "" },
                set: { server.certificateFingerprint = $0.isEmpty ? nil : $0 }))
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
      }.navigationTitle("编辑音乐源").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
      }
    }
  }
  private func save() {
    guard server.username == originalUsername || !password.isEmpty else {
      error = String(localized: "修改用户名时需要同时输入新密码。")
      return
    }
    guard let url = URL(string: address), url.host != nil else {
      error = MusicSourceError.invalidAddress.localizedDescription
      return
    }
    if !server.allowsSelfSignedCertificate { server.certificateFingerprint = nil }
    if let fingerprint = server.certificateFingerprint, !fingerprint.isEmpty,
      fingerprint.filter(\.isHexDigit).count != 64
    {
      error = String(localized: "SHA-256 证书指纹应包含 64 个十六进制字符。")
      return
    }
    server.baseURL = url
    server.usesHTTPS = url.scheme?.lowercased() == "https"
    Task {
      do {
        let credentials = password.isEmpty ? nil : ProviderCredentials(password: password)
        try await sources.update(server, credentials: credentials)
        dismiss()
      } catch { self.error = MusicSourceError.map(error).localizedDescription }
    }
  }
}

struct AddMusicSourceView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(MusicSourceStore.self) private var sources
  @State private var type: MusicSourceType = .openSubsonic
  @State private var name = ""
  @State private var address = ""
  @State private var username = ""
  @State private var password = ""
  @State private var usesExistingToken = false
  @State private var remoteUserID = ""
  @State private var selfSigned = false
  @State private var fingerprint = ""
  @State private var isConnecting = false
  @State private var errorMessage: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("类型") {
          Picker("音乐源", selection: $type) {
            ForEach(MusicSourceType.allCases.filter { $0 != .local }) { Text($0.title).tag($0) }
          }
        }
        Section {
          TextField("名称（例如 家里的音乐库）", text: $name)
          TextField("https://music.example.com", text: $address).keyboardType(.URL)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          TextField("用户名", text: $username).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          if type == .jellyfin { Toggle("使用现有访问令牌", isOn: $usesExistingToken) }
          SecureField(usesExistingToken ? "访问令牌" : "密码", text: $password)
          if type == .jellyfin && usesExistingToken {
            TextField("Jellyfin 用户 ID", text: $remoteUserID).textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }
        } header: {
          Text("服务器")
        } footer: {
          if type == .openSubsonic {
            Text("Navidrome 请填写站点根地址，不要添加 /rest。NAS 上需要先运行 Navidrome，并把音乐目录以只读方式挂载到容器。")
          } else if type == .existingNAS {
            Text("这是对仓库旧版 OwnMusic HTTP 服务的兼容入口。若只想直接读取 SMB 文件夹，请返回并选择“使用本机或 NAS 文件夹”。")
          }
        }
        Section {
          Toggle("允许自签名证书", isOn: $selfSigned)
          if selfSigned {
            TextField("SHA-256 证书指纹（推荐）", text: $fingerprint).textInputAutocapitalization(.never)
            Text("仅应在你确认服务器身份后启用。此设置只作用于当前音乐源，不会降低其他网络请求的安全性。").font(.caption).foregroundStyle(
              .orange)
          }
        } header: {
          Text("连接安全")
        }
        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
          }
        }
      }.navigationTitle("添加音乐源").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(isConnecting ? "正在连接…" : "连接") { connect() }.disabled(!canConnect)
        }
      }
    }
  }
  private func connect() {
    guard let url = normalizedURL else {
      errorMessage = MusicSourceError.invalidAddress.localizedDescription
      return
    }
    guard url.scheme?.lowercased() == "https" else {
      errorMessage = String(localized: "默认仅允许 HTTPS。请为自托管服务器配置安全证书。")
      return
    }
    if !fingerprint.isEmpty, fingerprint.filter(\.isHexDigit).count != 64 {
      errorMessage = String(localized: "SHA-256 证书指纹应包含 64 个十六进制字符。")
      return
    }
    isConnecting = true
    errorMessage = nil
    let server = MusicServer(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? type.title : name,
      baseURL: url, sourceType: type, username: username,
      usesHTTPS: url.scheme?.lowercased() == "https", allowsSelfSignedCertificate: selfSigned,
      certificateFingerprint: fingerprint.isEmpty ? nil : fingerprint)
    let credentials = ProviderCredentials(
      password: usesExistingToken ? nil : password, token: usesExistingToken ? password : nil,
      remoteUserID: usesExistingToken ? remoteUserID : nil)
    Task {
      do {
        try await sources.add(server, credentials: credentials)
        dismiss()
      } catch { errorMessage = MusicSourceError.map(error).localizedDescription }
      isConnecting = false
    }
  }
  private var canConnect: Bool {
    !isConnecting && !address.isEmpty && !username.isEmpty && !password.isEmpty
      && (!usesExistingToken || type != .jellyfin || !remoteUserID.isEmpty)
  }
  private var normalizedURL: URL? {
    let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: raw), components.host != nil else { return nil }
    components.query = nil
    components.fragment = nil
    while components.path.count > 1 && components.path.hasSuffix("/") {
      components.path.removeLast()
    }
    return components.url
  }
}
