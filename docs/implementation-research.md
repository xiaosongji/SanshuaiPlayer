# 实现调研与依赖决策

更新日期：2026-07-15

## 官方能力

- SwiftUI `fileImporter` 原生支持多选和 security-scoped URL，适合用户主动选择本机或文件提供器中的音频：<https://developer.apple.com/documentation/swiftui/view/fileimporter%28ispresented%3Aallowedcontenttypes%3Aallowsmultipleselection%3Aoncompletion%3Aoncancellation%3A%29>
- AVFoundation 的异步 `AVAsset.load` 可读取可播放性、时长、通用元数据和内嵌歌词：<https://developer.apple.com/documentation/avfoundation/avasset>
- Uniform Type Identifiers 用于限制音频文件选择：<https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct>

## 开源与许可

- 调查了 MinimizableView（MIT）等 SwiftUI 迷你播放器实现，以及 GPL 音乐客户端的交互方式。由于当前项目的核心问题是安全区域、Tab 命中和 Provider 状态集成，引入第三方 UI 框架并不会降低长期复杂度。
- 最终决策是不新增第三方依赖，使用 SwiftUI、AVFoundation、CryptoKit 和已有 Provider 边界实现。此方案没有新的商用许可、供应链或维护风险，同时保留替换边界。

## 视觉素材

当前 App 图标为按 Himhuu Design System 2.0 制作的原创 Cream / Clay 3D 素材，正式文件为 `HimhuuMusic-ArchivePlayer-AppIcon-v4.png`；使用 OpenAI 内置 ImageGen 生成并由项目所有者明确选定，未使用品牌、搜索引擎图片或第三方图库。旧矢量稿仅保存在 `docs/assets/icon-archive/` 作为历史记录，不再被 App 引用。

## 2026-07-13：Mineradio 与模拟器 Keychain

- 核验项目：XxHuberrr/Mineradio，<https://github.com/XxHuberrr/Mineradio>。该项目是活跃的 Windows / Electron 沉浸式音乐播放器，公开信息显示约 8.2k stars、52 commits、2026-06-25 发布 `v1.1.1`。
- 其代码为 GPL-3.0，品牌与原创视觉另行保留。公开说明中的 galaxy wallpaper、播放粒子舞台、歌词舞台和电影化镜头只用于确认体验方向；本 iOS 项目不引入、Fork 或移植其代码、着色器、素材、预设或参数。
- Apple 明确将 `-34018` 定义为 `errSecMissingEntitlement`。决策是先修正签名与实际 entitlements，再为未签名 Simulator 提供不落盘的会话凭据降级；生产版不放宽 Keychain 要求。
- 动效优先使用 SwiftUI / Core Animation 的单层 transform 和可中断状态转场。粒子复杂度超过 Canvas 稳定能力时再评估 Metal，不引入通用动效依赖。

## 2.9 实施结论

- 最终未新增第三方依赖。唱片使用 `TimelineView` 驱动单一旋转 transform；粒子使用 30 fps SwiftUI `Canvas` 绘制原创放射星流、景深微粒、流动光带与扩散光环，并在 Reduce Motion、低电量、后台或纯歌词模式停止计算。
- iOS 26.1+ 采用系统 `tabViewBottomAccessory` 与 `tabBarMinimizeBehavior`；iOS 17–26.0 使用可替换兼容层。交互参考系统音乐 App 的层级，但未复制 Apple Music 或 Mineradio 的素材与界面资产。
- Mineradio 仍只作为抽象产品方向参考，其 GPL-3.0 代码、GLSL、素材、参数和品牌均未进入仓库。

## 2026-07-13：3.0 实时音频响应视觉

- 复核 Mineradio 官方仓库、官网和公开更新记录后，确认其核心体验不是单层粒子，而是实时音频分析、瞬态/节拍驱动、空间粒子、电影化镜头、发光歌词和控制层隐退的组合。其 GPL-3.0 代码与单独保留的原创视觉表达只用于能力拆解，不进入本项目。
- Apple `MTAudioProcessingTap` 可在播放/读取/导出前访问音轨音频数据；`MTKView` 提供持续 GPU 绘制循环。采用“AVPlayer 音频 tap + 可替换分析快照 + MetalKit 原创程序化视觉”，不迁移到新的播放引擎。
- 候选比较：继续使用 SwiftUI Canvas 无法稳定承载数千粒子、透视投影和 60 fps 镜头；引入 SceneKit/SpriteKit 会增加已不必要的场景框架边界；移植 Three.js/GLSL 或 GPL 实现存在平台、许可证与原创表达风险。最终不新增第三方依赖。
- 首批效果为「星潮脉冲」「极光丝幕」「收藏轨道」。完整映射、降级和验收标准见 `docs/audio-reactive-visual-spec.md`。

完整决策见 `docs/next-iteration-keychain-motion-spec.md`。

## 2026-07-15：fnOS、Navidrome 与无后端 NAS 文件夹

- Navidrome 官方 Docker 镜像支持 amd64、arm32 和 arm64；音乐目录可只读挂载到 `/music`，数据与缓存写入 `/data`。当前 fnOS 路线固定官方 `deluan/navidrome:0.63.2`，不追随 `latest`。
- OpenSubsonic 官方 API 覆盖 ping、音乐文件夹、ID3 艺人/专辑/歌曲、搜索、媒体、收藏、歌单、歌词和 scrobble，与现有 `OpenSubsonicProvider` 边界一致。
- Navidrome 为 GPL-3.0。它只作为 NAS 上的独立服务进程运行，App 通过公开协议通信；不复制、链接或分发其代码和视觉素材到 iOS App。
- 无后端候选比较：内置 SMB SDK会增加凭据、安全、协议兼容与长期维护面；系统“文件”已提供 SMB 与第三方文件提供器。最终使用 SwiftUI `fileImporter` 选择 `.folder`，在 security-scoped 生命周期内递归导入。
- 为提高 NAS 文件提供器稳定性，每个文件只从远端复制一次，然后在本地暂存区哈希、去重与解析 AVFoundation 元数据。导入后保留本地副本，不依赖长期 bookmark 或 NAS 持久在线。
- 旧 OwnMusic Provider 原先目录请求使用独立 URLSession，绕过 Provider TLS 配置且无瞬时重试。现已统一到 `ProviderHTTPClient`；只对安全读取、播放地址与 Range 媒体请求启用有限瞬时重试。
- 部署和联调步骤见 `docs/navidrome-fnos.md`。

## 2026-07-13：2.9.1 音频格式兼容

- Apple 的 Core Audio / AVFoundation 原生覆盖常见 AAC、ALAC、MP3、PCM、AIFF、CAF、WAV、FLAC 等路径，但不能把 APE、WavPack、TTA、WMA、Ogg 容器等一概视为 iOS 原生可播放。
- 候选比较：在 App 内集成 FFmpeg 会显著增加包体、供应链和 LGPL/GPL 合规面；逐格式引入解码器会形成多套维护边界；服务端兼容缓存可复用项目 Docker 镜像已有的 FFmpeg，并保持 iOS App 无第三方二进制依赖。
- 决策：同时检查容器和音频编码；原生格式直放；APE、WavPack、TTA 等无损非原生格式缓存为 FLAC；DSD 转为最高 192 kHz PCM/FLAC；有损非原生格式缓存为 256 kbps AAC/M4A。转换只在扫描阶段执行并原子替换，播放阶段继续走短时签名 URL 与 Range。
- FFmpeg 官方说明其主体为 LGPL-2.1-or-later，启用可选 GPL 部分时整体适用 GPL。项目不把 FFmpeg 链接进 App；NAS 镜像发布者仍需核对实际 Debian 二进制的配置和相应许可证义务，记录见仓库根目录 `THIRD_PARTY_NOTICES.md`。
