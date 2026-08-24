import StoreKit
import SwiftUI

struct UniversalSettingsView: View {
  @Environment(MusicSourceStore.self) private var sources
  @Environment(\.openURL) private var openURL
  @State private var ratingRequestFeedback: String?
  @State private var ratingTapCount = 0
  @State private var homeContentMode: HomeContentMode = .albums
  var body: some View {
    Form {
      if let server = sources.activeServer {
        Section("当前音乐源") {
          LabeledContent("名称", value: server.name)
          LabeledContent("类型", value: server.sourceType.title)
          LabeledContent(
            "地址",
            value: server.sourceType == .local
              ? String(localized: "此 iPhone")
              : (server.baseURL.host() ?? String(localized: "私有服务器")))
          NavigationLink("管理音乐源") { MusicSourcesView() }
        }
      }
      Section {
        Picker("首页展示", selection: $homeContentMode) {
          ForEach(HomeContentMode.allCases, id: \.rawValue) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
      } header: {
        Text("首页")
      } footer: {
        Text("首页保持沉浸式图片布局；专辑或歌手的选择在这里统一设置。")
      }
      Section("播放能力") {
        Label("后台播放与锁屏控制", systemImage: "lock.iphone")
        Label("可编辑播放队列", systemImage: "list.bullet")
        Label("所有播放队列默认循环", systemImage: "repeat")
        Label("按音乐源同步播放进度", systemImage: "arrow.triangle.2.circlepath")
        Label(
          "蜂窝网络优先 MP3，转码失败回退原格式",
          systemImage: "antenna.radiowaves.left.and.right")
      }
      Section {
        LabeledContent(
          "总计已使用",
          value: ByteCountFormatter.string(fromByteCount: sources.cacheSizeBytes, countStyle: .file)
        )
        LabeledContent(
          "循环音频缓存",
          value:
            "\(ByteCountFormatter.string(fromByteCount: sources.mediaCacheSizeBytes, countStyle: .file)) / 40 MB"
        )
        LabeledContent(
          "已固化的图片、歌词及资料",
          value: ByteCountFormatter.string(
            fromByteCount: sources.resourceCacheSizeBytes, countStyle: .file)
        )
        Button("清理当前音乐源缓存") {
          Task { try? await sources.clearCache(serverID: sources.activeServerID) }
        }
        Button("清理全部缓存", role: .destructive) { Task { try? await sources.clearCache() } }
      } header: {
        Text("缓存")
      } footer: {
        Text("音乐文件使用固定 40 MB 循环缓存；已下载的图片、歌词和资料保存在本机持久资料区，仅在手动清理或 NAS 连续两次完整同步都确认对应内容已删除时移除。")
      }
      Section {
        Text("本 App 是个人音乐库客户端，不提供、托管或分发任何音乐内容。用户需要连接自己拥有或获授权访问的兼容音乐服务器。")
        Text(
          sources.isUsingEphemeralSimulatorCredentials
            ? String(localized: "当前未签名模拟器的密码与令牌仅保留在本次运行内存中；真机与正式版本只使用 Keychain。")
            : String(localized: "服务器地址、账号、音乐库和播放记录不会上传到开发者服务器；密码与令牌只保存在本机 Keychain。")
        )
        .foregroundStyle(.secondary)
      } header: {
        Text("隐私与内容边界")
      }
      Section("关于") {
        NavigationLink("关于\(AppInfo.name)") { AppAboutView() }
        NavigationLink("更新日志") { ChangelogView() }
        Link("产品官网", destination: AppInfo.productURL)
        Link("隐私政策", destination: AppInfo.privacyURL)
        Link("用户协议", destination: AppInfo.termsURL)
        Link("技术支持", destination: AppInfo.supportURL)
        NavigationLink("开源许可与致谢") { AcknowledgementsView() }
        NavigationLink("诊断信息") { DiagnosticsView() }
        Link("联系与反馈", destination: AppInfo.feedbackURL)
        ShareLink(
          item: AppInfo.appStoreURL,
          subject: Text(AppInfo.name),
          message: Text(shareText)
        ) { Label("分享 App", systemImage: "square.and.arrow.up") }
        Button {
          ratingTapCount += 1
          openURL(AppInfo.writeReviewURL) { accepted in
            ratingRequestFeedback =
              accepted
              ? String(localized: "已打开 App Store 评价页面。")
              : String(localized: "暂时无法打开 App Store 评价页面，请检查网络后重试。")
          }
        } label: {
          Label("给个评价", systemImage: "star")
        }
        .sensoryFeedback(.impact(weight: .light), trigger: ratingTapCount)
        if let ratingRequestFeedback {
          Label(ratingRequestFeedback, systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        LabeledContent("版本", value: version)
      }
      PlayerDockScrollFooter()
    }
    .navigationTitle("设置")
    .task {
      restoreHomeContentMode()
      await sources.refreshCacheUsage()
    }
    .onChange(of: homeContentMode) { _, mode in
      UserDefaults.standard.set(mode.rawValue, forKey: homeModeStorageKey)
    }
    .onChange(of: sources.activeServerID) { _, _ in restoreHomeContentMode() }
  }
  private var homeModeStorageKey: String {
    "home.gallery.mode.\(sources.activeServerID?.uuidString.lowercased() ?? "default")"
  }
  private func restoreHomeContentMode() {
    homeContentMode =
      UserDefaults.standard.string(forKey: homeModeStorageKey)
      .flatMap(HomeContentMode.init(rawValue:)) ?? .albums
  }
  private var version: String {
    "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))"
  }
  private var shareText: String {
    String(localized: "\(AppInfo.name)是一款连接用户自有 OpenSubsonic、Jellyfin、NAS 和本机音乐的个人音乐库客户端。")
  }
}

private struct AppAboutView: View {
  var body: some View {
    List {
      Section {
        VStack(spacing: 14) {
          Image("BrandIcon").resizable().scaledToFit()
            .frame(width: 104, height: 104).clipShape(.rect(cornerRadius: 22))
          Text(AppInfo.name).font(.title2.bold())
          Text("通用个人音乐库客户端").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical)
      }
      Section("版本") {
        LabeledContent("版本与构建", value: AppInfo.version)
        LabeledContent("包标识", value: Bundle.main.bundleIdentifier ?? "-")
      }
      Section("开发者") { LabeledContent("作者", value: "@2026himhuu") }
      Section("联系与政策") {
        Link("产品官网", destination: AppInfo.productURL)
        Link("技术支持", destination: AppInfo.supportURL)
        Link("隐私政策", destination: AppInfo.privacyURL)
        Link("用户协议", destination: AppInfo.termsURL)
        Link("联系开发者", destination: AppInfo.feedbackURL)
      }
      Section {
        Text("本 App 不提供、托管或分发任何音乐内容。")
      }
      PlayerDockScrollFooter()
    }.navigationTitle("关于")
  }
}

private struct PrivacyStatementView: View {
  var body: some View {
    PolicyList(
      title: String(localized: "隐私说明"),
      sections: [
        (
          String(localized: "数据存储"),
          String(localized: "服务器地址、音乐库元数据、搜索历史、队列和播放历史仅存储在本机。密码和令牌仅存入 Keychain。")
        ),
        (
          String(localized: "网络"),
          String(
            localized:
              "App 会连接用户主动配置的音乐服务器。缺少可用时间轴歌词时，会按需把歌曲名、艺人、专辑名和时长发送给 LRCLIB 与中文歌词聚合服务；浏览缺少封面的内容时，会把对应名称发送给中文封面聚合服务。不会发送账号、服务器地址或播放记录。"
          )
        ),
        (
          String(localized: "文件夹导入"),
          String(
            localized: "仅在系统授权期间读取用户选择的本地或 NAS 文件夹，并把音频复制到 App 私有资料库。SMB 凭据由系统“文件”管理，App 不读取或保存。")
        ),
        (
          String(localized: "第三方"),
          String(localized: "当前版本不包含广告、跟踪或统计 SDK。在线歌词与封面结果会缓存在本机，第三方服务不可用时不影响播放。")
        ),
        (String(localized: "删除"), String(localized: "用户可删除音乐源、清理缓存，或通过删除 App 移除本机数据。")),
      ])
  }
}

private struct TermsView: View {
  var body: some View {
    PolicyList(
      title: String(localized: "用户协议"),
      sections: [
        (String(localized: "服务边界"), String(localized: "本 App 是个人音乐库客户端，不提供、托管、聚合或分发音乐内容。")),
        (String(localized: "合法使用"), String(localized: "用户必须确保对所连接的服务器及其音乐内容拥有合法访问权。")),
        (
          String(localized: "自托管服务"),
          String(localized: "用户负责自托管服务的运行、安全、备份和可用性。允许自签名证书会降低连接保障，仅应在确认服务器身份后启用。")
        ),
      ])
  }
}

private struct ChangelogView: View {
  var body: some View {
    List {
      Section("版本 \(AppInfo.version)") {
        Label("修复任意点播歌曲可能在中途从头循环的串流问题", systemImage: "waveform.badge.checkmark")
        Label("恢复并强化灵动岛、锁屏与 App 内迷你播放器", systemImage: "music.note.house")
        Label("首页封面统一铺满与裁剪，并保持前台持续浮动", systemImage: "photo.stack")
        Label("底部导航恢复 iOS 原生 Liquid Glass 选中动画", systemImage: "dock.rectangle")
        Label("全新 Himhuu Cream / Clay 3D 图标与温暖品牌视觉", systemImage: "app.badge")
        Label("优化封面缓存、预取与播放稳定性", systemImage: "internaldrive")
      }
      PlayerDockScrollFooter()
    }.navigationTitle("更新日志")
  }
}

private struct AcknowledgementsView: View {
  var body: some View {
    List {
      Section("第三方代码") { Text("当前 App 目标未链接第三方软件包。") }
      Section("可选在线服务") {
        Text("缺少可用时间轴歌词时，App 会依次查询 LRCLIB 与中文歌词聚合服务；缺少封面时会查询中文封面聚合服务。未把其代码链接进 App。")
      }
      Section("Apple 框架") {
        Text(
          "SwiftUI、AVFoundation、MediaPlayer、Network、CryptoKit、Security 与 UniformTypeIdentifiers。")
      }
      Section("视觉素材") { Text("App 图标和界面视觉均为本项目原创，界面图标使用 Apple SF Symbols。") }
      PlayerDockScrollFooter()
    }.navigationTitle("许可与致谢")
  }
}

private struct DiagnosticsView: View {
  @Environment(MusicSourceStore.self) private var sources
  private var text: String {
    [
      "App: \(AppInfo.name) \(AppInfo.version)",
      "iOS: \(UIDevice.current.systemVersion)",
      "Device: \(UIDevice.current.model)",
      "Source: \(sources.activeServer?.sourceType.title ?? "None")",
      "Status: \(sources.activeServer?.status.rawValue ?? "none")",
      "Credential storage: \(sources.credentialVaultMode.rawValue)",
      "Credential issue: \(sources.lastCredentialIssueAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
      "Cache: \(ByteCountFormatter.string(fromByteCount: sources.cacheSizeBytes, countStyle: .file))",
    ].joined(separator: "\n")
  }
  var body: some View {
    List {
      Section {
        Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
      } footer: {
        Text("诊断信息不包含密码、令牌、私有服务器地址或媒体路径。")
      }
      Section { ShareLink(item: text) { Label("导出诊断信息", systemImage: "square.and.arrow.up") } }
      PlayerDockScrollFooter()
    }.navigationTitle("诊断信息")
  }
}

private struct PolicyList: View {
  let title: String
  let sections: [(String, String)]
  var body: some View {
    List {
      ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
        Section(section.0) { Text(section.1) }
      }
      PlayerDockScrollFooter()
    }
    .navigationTitle(title)
  }
}
