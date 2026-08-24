# 已知问题

- 4.2.0 build 50 的锁屏/控制中心封面回调存在 Swift 6 执行器隔离崩溃，可能表现为播放约 8 秒后退出。该问题已在 build 51 修复并增加非主队列回归测试；build 50 不得用于提审或发布。

- 将 `CODE_SIGNING_ALLOWED=NO` 构建的 App 安装到 Simulator 时，Keychain 仍可能返回 `errSecMissingEntitlement (-34018)`；2.9 会在实际收到该错误后改用仅限当前进程的临时凭据，重启后必须重新输入。签名 Simulator 与真机继续使用 Keychain。
- 横屏沉浸式视觉舞台已实现并完成 Simulator 截图修正；60 秒 hitch ratio、常驻内存、20 首连续切换和三段 8 秒录屏仍需在小屏 iPhone、ProMotion iPhone 与 iPad 真机完成，未完成前不应把性能项标为通过。

- 完整离线歌曲/专辑/歌单下载不在本版本范围内；当前只提供可扩展缓存基础设施。
- 本机与 SMB NAS 文件夹导入会复制音频到 App 私有资料库，因此会额外占用设备存储；当前不支持直接监听外部文件夹变更。这样可以在 NAS 暂时离线时继续播放，并避免持久安全作用域失效。
- 音频预取仅保存完整响应且单文件不超过缓存上限一半或 256 MB 的曲目；失败不影响正常串流。
- OpenSubsonic 不同实现的扩展能力存在差异。不支持 `savePlayQueue`、结构化歌词或某些首页列表的服务器会自动降级，核心播放不受影响。
- 歌词按“服务端时间轴歌词 → LRCLIB → 中文聚合源 → 可信普通歌词”回退，仅在用户打开歌词页时在线查询。网址、下载站、公众号和QQ群等广告文本会被过滤。第三方曲库可能暂时不可用或返回误匹配；结果不写回音频文件，可通过清理缓存重新查询。
- 本地和 Navidrome 都没有封面时，App 会查询中文封面聚合源并缓存结果；误匹配可通过清理缓存重新查询。歌名、专辑名或艺人标签缺失时无法保证匹配准确。
- Jellyfin 的服务端转码结果取决于服务器 FFmpeg 配置和用户权限。
- 本机文件导入仍以 AVFoundation 在当前 iOS 版本可解码的格式为准；APE、WMA、WavPack、TTA、DSD、OGG 和 Opus 的兼容转码仅由 OwnMusic NAS、OpenSubsonic 或 Jellyfin 服务端提供。
- OwnMusic NAS 首次扫描非原生格式需要生成兼容缓存，耗时和额外空间取决于曲库大小；APE、WavPack、TTA 等无损来源无损转封装为 FLAC，DSD 转为最高 192 kHz PCM/FLAC，其他不兼容来源转为 256 kbps AAC/M4A。
- 已部署的旧版 OwnMusic 服务不会自动获得本仓库新增的文件签名与容器校验；升级服务端后需重新扫描，才能在服务端层修正后缀/MIME 误报和重新生成兼容缓存。新版客户端可先行兼容常见误标容器。
- 旧 NAS Provider 继承原服务能力：没有远端歌单和远端收藏接口，收藏仍只适合迁移为客户端状态。
- App 的短重试只能缓解瞬时丢包，不能修复错误 DNS。若音乐域名同时存在有效与失效的 A/AAAA 记录，必须在 DNS / DDNS 侧删除失效记录。
- 自签名证书若不填写指纹，只应在完全可信的局域网和确认风险后使用；发布建议使用有效 HTTPS 证书或固定指纹。
- 尚未实现 Plex、Emby、Audiobookshelf、macOS 与完整离线库，这些均已保留扩展边界。CarPlay 音频版已接入系统模板；真实车型兼容性仍需持续验证。
- 已用临时本机实例验证 Navidrome 0.61.2、Airsonic 10.6.0 和 Jellyfin 10.11.11；不同部署的反向代理、SSO、权限、转码器与超大曲库仍需发布方在自有环境回归。
- 仓库不包含发布者的 Development Team 或签名资料。贡献者需要在本地配置自己的签名身份；CarPlay entitlement 还需要对应 Apple 开发者权限。
- App Store ID `6784067140`、`support@himhuu.com` 及当前 App 的产品、隐私、协议、支持规范 URL 已配置并验证可达。发布前仍需在 App Store Connect 核对这些 URL 与当前商店版本完全一致。
