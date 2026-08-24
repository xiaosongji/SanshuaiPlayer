# 架构说明

## 分层

`Domain` 是服务器无关的稳定模型层。`MusicIdentity` 同时保存 App 稳定 UUID、Provider UUID、远端原始 ID 与来源类型；稳定 UUID 由 Provider UUID 和远端 ID 生成，避免不同服务器 ID 冲突。

`MusicSourceProvider` 是唯一远端业务边界。UI、首页、搜索与播放器不读取 Subsonic 或 Jellyfin DTO。Provider 负责认证、DTO 解析、能力降级、图片/串流 URL、收藏、歌单与播放事件映射。

`MusicSourceStore` 管理不含密钥的服务器配置。`KeychainCredentialVault` 以服务器 UUID 为 account 保存密码和 Token。`MusicCache` 以服务器 UUID 和命名空间分目录，支持容量上限、LRU 式裁剪和按服务器清理。

`UnifiedLibraryStore` 并发加载 Provider 能力并生成统一页面状态。`UnifiedPlaybackController` 只接收 `MusicTrack`，负责队列、AVPlayer、后台音频、系统媒体控制、队列恢复和进度上报。当前曲目就绪后顺序预取队列后 3 首，按服务器隔离存入 `media` 缓存，播放时优先使用完整缓存文件。蜂窝网络一律优先请求 192 kbps MP3 转码流，单曲转码失败则记住该曲目并回退原始格式；Wi-Fi 保留音乐源配置。串流和封面由 Provider 的专用 URLSession 加载，AVAsset Resource Loader 将 Range 请求转交给 Provider，因此媒体播放也遵守单服务器 TLS 与指纹策略。

`LocalMusicProvider` 是与网络 Provider 对等的本地数据源。文件选择器仅在用户授权期间读取 security-scoped URL，Provider 将音频原子复制到 Application Support 中的私有资料库，使用 SHA-256 去重，并用 AVFoundation 建立统一 `MusicTrack`。本机歌单仍通过 Provider 的统一 CRUD 边界管理。

## TLS

默认使用系统信任评估。自签名开关默认关闭，只创建当前服务器专用 URLSession。配置指纹后会对叶证书 SHA-256 做固定校验；不匹配立即拒绝，不影响其他服务器或系统请求。

## 凭据环境与视觉舞台

- `CredentialVaultFactory` 在真机固定使用 `KeychainCredentialVault`；Simulator 只有在 Security 实际返回 `errSecMissingEntitlement` 后，才切换到不落盘的进程内凭据仓库。
- `PlaybackVisualState` 与音频来源无关，只接收统一播放器的播放、暂停、缓冲、曲目和进度状态；视觉层不读取 Provider DTO。
- `ImmersiveVisualStage` 已拆分为背景、粒子、唱片、歌词和控件独立组件；渲染实现保持可替换，不与 Provider、队列或播放器生命周期耦合。
- 横屏舞台、真实音频分析和纯歌词模式是三个不同边界。如果未实现可靠 PCM / FFT，动效不得声称“鼓点驱动”。

详细规格见 `docs/next-iteration-keychain-motion-spec.md`。

## 新增 Provider

1. 新建独立 Provider，实现 `MusicSourceProvider`，DTO 保持 `private`。
2. 把远端 ID 映射为 `MusicIdentity(providerID:remoteID:sourceType:)`。
3. 声明真实的 `capabilities`；不支持的首页分区不要生成。
4. 在 `ProviderFactory.live` 增加一个枚举分支。
5. 添加认证、解析、搜索、串流 URL、错误映射和收藏/进度测试。

Plex、Emby、Audiobookshelf 都可以沿此方式接入，不需要修改通用页面或播放器。Plex/Emby 建议复用 Jellyfin 方向的 Token、媒体信息与进度映射；Audiobookshelf 应新增章节和书签领域模型，不得将有声书 DTO 伪装为歌曲。离线下载应新增 DownloadRepository，以 `MusicIdentity` 为主键并复用按服务器缓存隔离；不要把下载状态塞进 Provider DTO。

## 旧数据迁移

首次发现旧 `server.baseURL` / `server.username` 时，新建 Existing NAS 音乐源并复制旧 Keychain 密码。旧配置会写入 `migration.legacyNAS.backup`，迁移结果写入 `migration.legacyNAS.completed`；迁移不删除原配置或媒体缓存，因此不会静默丢失。
