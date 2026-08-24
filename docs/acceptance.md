# 验收矩阵

验收日期：2026-07-15

## 已验证

- Navidrome 可添加、认证并完成资料库、搜索、串流、收藏、进度和歌单契约。
- Airsonic 可添加和认证，旧 Subsonic 1.15.0 响应和旧版歌单创建差异已兼容。
- Jellyfin 可登录，并完成音乐库、艺人、专辑、歌曲、搜索、首页、直播、收藏、进度和歌单 CRUD 契约。
- Existing NAS 保留原 HTTP 目录服务能力，通过独立 Provider 映射为统一领域模型。
- 本机音乐可批量导入，完成元数据解析、内容去重、范围读取与本地歌单 CRUD 自动测试。
- 统一首页、艺人/专辑/歌曲/歌单页、搜索、队列、迷你播放器、收藏和多源切换只依赖 Domain 与 Provider 协议。
- 资料库主入口只保留“歌曲/歌单”；歌单页有顶部、列表首行和空状态新建入口。
- 迷你播放器可收缩为底部菜单中央项，不与 Tab 命中区重叠；播放页内可全屏切换按时间高亮和滚动的歌词。
- 密码、Token 和 Jellyfin 用户 ID 按服务器存入 Keychain；普通配置和日志不保存密钥。
- 原始/无损/高质量/标准/省流量策略、不兼容格式转码、媒体 Range 加载、后台音频声明与系统媒体控制已接入。
- 统一错误、单服务器 TLS/自签名/指纹、按服务器缓存、旧 NAS 保留式迁移和删除时缓存选择已实现。
- 自动测试覆盖本机导入、蜂窝 MP3 固定优先策略、转码失败回退原格式和队列后 3 首预取；需真实服务凭据或签名 Keychain entitlement 的契约测试在未配置时明确跳过。
- 已保留真实运行截图：展开/收起播放器、全屏同步歌词、视觉修正后首页、深色模式和无障碍大字号，见 `docs/visual-audit/`。
- README、架构说明、已知问题、隐私说明和 App Store 描述草稿已齐备。

## 上架主体必须完成

- 使用正式 Team 和证书生成真机 Archive，并执行 App Store Connect Validate App。
- 提供隐私政策 URL、支持邮箱和可从审核网络访问的专用 HTTPS 审核账号。
- 在真机上做长时间后台播放、锁屏/蓝牙控制、Wi-Fi/蜂窝切换和服务端转码压力回归。

## 2.9 新增验收

### 2.9 已自动或在 Simulator 验证

- Simulator 凭据仓库只在实际 `-34018` 后切换，凭据只保留在内存中；禁用降级时错误原样返回。新增 2 项自动测试通过。
- iPhone 17 Pro / iOS 26.5 旋转后自动进入横屏视觉舞台；竖屏播放页和横屏舞台均可切换顺序/随机播放。
- iOS 26.1+ 原生底栏 accessory 已按 Apple Music 式结构完成，支持点击、横向轻扫、向上轻扫和细线进度；旧系统保留兼容层。
- 横屏第一轮截图发现唱片与控件遮挡后已完成布局修正，证据见 `visual-audit/09-immersive-stage-landscape-v2.9-first-pass.png` 与 `visual-audit/10-immersive-stage-landscape-v2.9-polished.png`。
- 根据 Mineradio 的公开体验方向完成第二轮原创动效增强：放射星流、流动光带、扩散光环和景深微粒已在真实运行 App 中验证，证据见 `visual-audit/12-cinematic-particle-stage-v2.9.png`；未复制 GPL-3.0 代码、着色器、资产或参数。
- 2.9 自动测试共 14 项：11 项通过、0 失败；3 项真实服务契约测试因未提供环境凭据明确跳过。

### 仍需真机完成

- 签名 Simulator Debug 构建可保存 NAS 凭据并在重启后恢复。
- 未签名 Simulator 收到 `errSecMissingEntitlement (-34018)` 时，可在当前会话内使用临时凭据连接，凭据不落盘；真机 Release 不启用该降级。
- 正在播放页可随设备旋转进入和退出横屏视觉舞台，播放、队列、歌词和进度状态不丢失。
- 唱片加速、减速、暂停角度保留、切歌取消和缓冲状态均通过真实录屏验收。
- Reduce Motion 、低电量、后台和纯歌词模式会停止不必要的动画计算。
- 60 秒横屏舞台运行的 hitch ratio 低于 1%，新增常驻内存低于 18 MB，连续切换 20 首后内存不持续增长。

## 2.9.1 音频兼容修正

### 已自动验证

- OwnMusic NAS 扫描范围包含 AAC、AC3/EAC3、AIFF、ALAC、AMR、APE、CAF、DFF/DSF、DTS、FLAC、M4A/M4B、MKA、MP2/MP3/MP4、MPC、OGG/OGA、Opus、Shorten、TAK、TTA、WAV、WMA 与 WavPack。
- 单元测试验证 APE 选择无损 FLAC 缓存，Opus 选择 256 kbps AAC/M4A 缓存；兼容产物位于服务器数据目录，不暴露原始 NAS 路径。
- OpenSubsonic 与 Jellyfin 在扩展名缺失时会继续检查 MIME 类型；未知或非原生类型优先请求服务端转码，不再默认当作 iOS 原生格式。
- 预取缓存按实际响应 MIME 命名，支持在不知道原始扩展名时发现兼容缓存；不可播放的旧缓存会删除并回退到在线串流。
- iOS XCTest 共 16 项：13 项通过、0 失败；3 项真实服务契约测试因未配置凭据明确跳过。
- OwnMusic 服务端测试共 18 项，全部通过；iOS 2.9.1（21）Release Simulator 构建通过。

### 部署环境仍需验证

- 当前开发主机未安装 FFmpeg，也没有可用 Docker 命令；APE、Opus、OGG、WMA、WavPack、TTA 和 DSD 的真实样本转码必须在最终 NAS Docker 镜像内回归后才能标为发布通过。
- 首次全库扫描需要核对转码时间、`/data/transcodes` 空间占用、失败曲目错误记录与旧缓存清理。

## 3.0.0 实时音频视觉

### 已自动或在 Simulator 验证

- `MTAudioProcessingTap` 已接入 `AVPlayerItem.audioMix`；真实 WAV 经 Provider Range 加载、AVPlayer 解码后，分析器可收到非零 PCM 能量。
- 已登录真实 Existing NAS 播放两首用户曲目：原先因 `audio/mpeg` 误报而失败的 ALAC/M4A 曲目现可按文件签名识别并播放；分析 Tap 分别收到 44.1 kHz 单声道和 48 kHz 双声道非零 PCM。
- 真实 NAS 播放时已验证极光光带、粒子与唱片随能量变化；暂停后控件保持可见，恢复播放后控件按时自动隐藏，关闭舞台可返回资料库。
- 三套原创 Metal 视觉均在真实运行 App 中使用同一受控音轨截图，见 `visual-audit/20-real-audio-star-tide.png`、`21-real-audio-aurora-veil.png`、`22-real-audio-archive-orbit.png`。
- 两首 18 秒本地生成 WAV 可自动换歌，第二首歌词与视觉状态切换证据见 `visual-audit/23-next-track-real-audio.png`。
- 审查入口恢复“资料库 → 全屏播放器”层级，关闭播放器可返回资料库；播放队列包含两首可实际解码音轨。
- 第一轮真实截图发现 Metal 首帧未按最终配置刷新、统一缓冲布局错误和粒子不可见后，已完成显式首帧绘制、统一 `float4` ABI 与程序化星流补强。
- 客户端媒体类型探测已覆盖 M4A/MP4、FLAC、WAV、AIFF、CAF 与 MP3 文件头，独立于后缀和服务器 MIME；OwnMusic 扫描器及 HTTP 响应也使用相同的容器真实性原则。
- 完整 iOS 测试共 21 项：18 项通过、0 失败；3 项未配置的外部真实服务契约测试明确跳过。OwnMusic 服务端 19 项测试全部通过。
- 3.0.0（30）干净 Release Simulator 构建、隐私清单校验、安装、启动和真实 NAS 播放/暂停冒烟测试通过；模拟 Provider 与视觉验收音轨不进入 Release 二进制。
- 横屏播放 3 秒无操作后，唱片封面、歌词、局部暗场与 StageChrome 一起退场，仅保留真实音频驱动的 Metal 动效；隐藏态不暴露透明辅助功能控件，轻点全屏可恢复并重新计时。暂停、缓冲、纯歌词、VoiceOver 与拖动进度时不会自动隐藏。
- 对外名称已统一为“散帅播放器”：iOS 桌面显示名、启动页、关于、反馈、分享和诊断均由 `CFBundleDisplayName` 驱动。

### 仍需真机完成

- ProMotion 真机连续运行 60 秒的 hitch、温度、GPU/CPU 和新增常驻内存验收。
- 蓝牙/锁屏、后台切前台、低电量和 Reduce Motion 的视觉停止时延与音频不中断验证。

## 3.0.1 NAS 与本机资料库

### 已自动或在 Simulator 验证

- 本机音乐可从系统文件选择器选择单个/多个音频，也可选择整个本地或 SMB 文件夹递归导入；非音频文件会忽略。
- File Provider / SMB 文件只从远端复制一次；哈希、去重和 AVFoundation 标签读取均在本地暂存区完成。
- 重复导入会返回现有 `MusicTrack`，资料库刷新请求不会再因已有刷新正在运行而丢失；文件夹导入后可立即开始播放第一首可用曲目。
- Existing NAS 的目录、播放地址与 Range 媒体请求统一使用 Provider TLS/自签名/指纹策略；瞬时网络、超时及可恢复 HTTP 状态最多短重试三次，认证、权限、证书与数据解析错误不重试。
- 已增加 `NSLocalNetworkUsageDescription`，文案只说明连接用户本人配置的 NAS / 音乐服务器。
- fnOS Navidrome `0.63.2` 只读音乐目录编排、独立 HTTPS 域名和 App 接入文档已完成；未把 GPL 代码或容器链接到 App。
- 自动测试结果：20 通过、0 失败、3 个真实外部服务契约因没有环境凭据跳过；OwnMusic 服务端 19 项通过。
- `3.0.1 (31)` 干净 Release Simulator 构建通过。

### 仍需用户环境完成

- 在当前 fnOS 上启动 Navidrome，使用临时普通音乐账号运行 `MUSICPLAYER_NAVIDROME_*` 真实契约测试。
- 在真机“文件”中连接当前 SMB NAS，选择包含子目录的真实音乐文件夹，验证系统权限、长时间导入、剩余空间和断网后的本地播放。
- 核对音乐域名 DNS / DDNS 仅保留有效的 A/AAAA 记录；客户端短重试不能修复失效 DNS 记录。

## 3.0.2 播放稳定性与封面菜单

### 已自动或在 Simulator 验证

- 快速连续选择歌曲时，旧播放项立即停止；旧的异步地址请求、资源加载结果、结束通知和失败通知均不能覆盖最新歌曲。
- 同一 App 进程内启动第二个播放控制器后，第一个控制器立即失去音频所有权；远程控制命令只由当前音频所有者响应。
- 只有播放位置接近目录或媒体声明的完整时长时才自动切歌；4 秒即结束而目录时长为 180 秒的回归用例会保留当前歌曲。
- 正在播放页单击封面不改变页面；长按封面显示“加入歌曲列表”，并列出可编辑歌曲列表。
- VoiceOver 可识别“《歌名》封面”、长按提示和等价的加入操作，不以长按作为唯一入口。
- iPhone 17 Pro / iOS 26.5 真实运行截图见 `visual-audit/42-player-cover-long-press-default.png` 与 `visual-audit/43-player-cover-add-to-list-menu.png`。
- 自动测试结果：30 个 XCTest 中 26 个通过、4 个真实外部服务契约按配置跳过；另有 3 个 Swift Testing 音频分析测试通过，0 失败。
- `3.0.2 (34)` 干净 Release Simulator 构建通过；实际产物版本、构建号、本地网络用途说明和 Privacy Manifest 已核对。

### 仍需用户环境完成

- 使用用户实际出现故障的 NAS 曲目连续快速切歌，确认服务器响应顺序变化时也只有最新歌曲发声。
- 在真机完成长时间后台、锁屏/蓝牙、弱网中断恢复和播放地址过期后的重试验证。
