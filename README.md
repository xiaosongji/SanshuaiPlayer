# 散帅播放器（Sanshuai Player）

一款面向个人音乐收藏的原生 iPhone / iPad 播放器。它连接由用户本人拥有、控制或获授权访问的音乐服务器和本地文件，不提供、托管、聚合或分发音乐内容。

<p align="center">
  <img src="MusicPlayer/Resources/Assets.xcassets/AppIcon.appiconset/HimhuuMusic-ArchivePlayer-AppIcon-v4.png" width="144" alt="散帅播放器 App 图标">
</p>

## 主要能力

- OpenSubsonic / Subsonic：支持 Navidrome、Airsonic、Gonic 等常见兼容服务
- Jellyfin：资料库、搜索、收藏、歌单、歌词和播放进度同步
- 本机与 SMB：通过系统文件选择器导入歌曲或文件夹，提取元数据、封面和歌词
- 多音乐源：添加、编辑、测试、切换并独立保存各服务器凭据
- 原生播放：AVPlayer 队列、后台音频、锁屏、耳机和 CarPlay 控制
- 沉浸舞台：由实时 PCM 分析驱动的原创 Metal 音频视觉效果
- 隐私优先：服务器密码和 Token 存入 Keychain，不包含广告或统计 SDK

## 系统要求

- macOS 与 Xcode 26 或更新版本
- iOS / iPadOS 17.0+
- Swift 6
- 可选：[XcodeGen](https://github.com/yonaskolb/XcodeGen)，用于从 `project.yml` 重新生成工程

## 构建

```sh
git clone https://github.com/xiaosongji/SanshuaiPlayer.git
cd SanshuaiPlayer

# 可选：重新生成 Xcode 工程
brew install xcodegen
xcodegen generate

# 无签名构建检查
xcodebuild -project MusicPlayer.xcodeproj \
  -scheme MusicPlayer \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

也可以直接打开 `MusicPlayer.xcodeproj`，选择本机已有的 Simulator 运行。真机安装前，请在 Xcode 中改为自己的 Bundle ID、Development Team 和签名配置。

> `CODE_SIGNING_ALLOWED=NO` 只适合构建检查。未签名 Simulator 产物可能因缺少 Keychain entitlement 返回 `-34018`；测试真实凭据持久化时请使用正常签名构建。

## 测试

```sh
xcodebuild -project MusicPlayer.xcodeproj \
  -scheme MusicPlayer \
  -destination 'platform=iOS Simulator,name=<你的模拟器名称>' \
  test
```

真实服务契约测试使用以下环境变量，未设置时会自动跳过：

- `MUSICPLAYER_NAVIDROME_*`
- `MUSICPLAYER_SECONDARY_SUBSONIC_*`
- `MUSICPLAYER_JELLYFIN_*`

不要把真实服务器地址、用户名、密码、证书、Token 或测试结果日志提交到仓库。

## 架构

```text
SwiftUI Views
  ├─ MusicSourceStore
  ├─ UnifiedLibraryStore
  └─ UnifiedPlaybackController
             │
      MusicSourceProvider
       ├─ OpenSubsonicProvider
       ├─ JellyfinProvider
       ├─ ExistingNASProvider
       ├─ LocalMusicProvider
       └─ MockMusicSourceProvider
```

SwiftUI 页面只依赖统一领域模型，协议 DTO 封装在各 Provider 内。进一步说明见[架构文档](docs/architecture.md)、[验收矩阵](docs/acceptance.md)和[已知问题](docs/known-issues.md)。

## 可选 NAS 服务

`server/` 提供 OwnMusic 示例服务和 Navidrome / Caddy 通用部署模板。iOS App 并不依赖该服务，也可以直接连接已有 OpenSubsonic 或 Jellyfin 实例，或仅使用本机 / SMB 导入。

- [通用部署建议](docs/deployment.md)
- [fnOS / Navidrome 示例](docs/navidrome-fnos.md)
- [OwnMusic API](docs/backend-api.md)

所有示例都使用占位域名和环境变量。请勿将 NAS 管理端口直接暴露到公网。

## 隐私与第三方服务

项目不包含广告或统计 SDK。用户主动连接自己的音乐服务器时，请求会发送到该服务器；缺少歌词或封面时，App 可按需向 LRCLIB 或中文歌词/封面聚合服务发送匹配所需的歌曲名、艺人、专辑名和时长。

详情见[隐私说明](docs/privacy.md)与[第三方软件说明](THIRD_PARTY_NOTICES.md)。

## 贡献与安全

欢迎提交 Issue 和 Pull Request。开始前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告，不要在公开 Issue 中附带真实凭据或服务器信息。

## 许可证

源码采用 [MIT License](LICENSE)。仓库内视觉素材、第三方项目与品牌标识的适用范围见 [ASSET_LICENSES.md](ASSET_LICENSES.md) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；MIT License 不授予任何 Himhuu 商标权。

## 官方页面

- [产品页](https://himhuu.com/apps/sanshuai-player)
- [隐私政策](https://himhuu.com/apps/sanshuai-player/privacy)
- [用户协议](https://himhuu.com/apps/sanshuai-player/terms)
- [技术支持](https://himhuu.com/apps/sanshuai-player/support)
