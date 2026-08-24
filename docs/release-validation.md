# Release 验证记录

## 4.2.0（51）锁屏封面闪退修复（2026-08-12）

- 已从 `MusicPlayer-2026-08-11-220336.ips` 确认崩溃为 `EXC_BREAKPOINT / SIGTRAP`：`MPMediaItemArtwork` 的图片请求回调继承了 `UnifiedPlaybackController` 的 `MainActor` 隔离，但 MediaPlayer 会从自身 `accessQueue` 调用它，Swift 6 运行时队列检查因此终止进程。封面网络请求/缓存完成的延迟使用户感知为播放约 8 秒后闪退。
- 将锁屏、控制中心和灵动岛使用的封面回调改为显式 `@Sendable` 非隔离回调，通过不可变 `@unchecked Sendable` 图片容器只读返回已经解码的 `UIImage`；控制器状态更新仍留在主执行器。
- 新增 `testNowPlayingArtworkCallbackIsSafeOnMediaPlayerQueue`，从独立串行队列调用 `MPMediaItemArtwork.image(at:)`，复现 MediaPlayer 的调用方式并验证不再触发执行器断言。
- 完整测试共 85 项：81 通过、0 失败、4 个真实外部服务契约按配置跳过。无签名 Release device 构建通过。
- 修复版已提升为 `4.2.0 (51)`。签名 Archive 为 `release/MusicPlayer-4.2.0-51.xcarchive`；本地 App Store IPA 为 `release/AppStore-4.2.0-51/MusicPlayer.ipa`，SHA-256 `6a8b30d374ccb8fa369992dd5bd4d15907b7a73dbbf8d4f2662aa46143bcbb1a`。IPA 实测 `get-task-allow=false`、`beta-reports-active=true`、CarPlay Audio entitlement 存在且严格签名校验通过。
- 按产品所有者要求，本轮未上传 build 51，也未继续操作 App Store Connect 或提交审核；线上 build 50 不应被选为 4.2.0 的审核构建。

## 4.2.0（50）全量发布门禁（2026-08-11）

- iOS 自动测试 84 项：80 通过、0 失败、4 项外部契约按配置跳过；OwnMusic 服务端 21 项全部通过。另使用临时测试账号完成 Navidrome HTTPS 真实契约，覆盖认证、资料库、首页、搜索、Range 播放、收藏、播放上报及歌单 CRUD，凭据未写入仓库。
- Release 分析、构建、Archive 与 App Store 导出均通过。Archive 为 `release/MusicPlayer-4.2.0-50.xcarchive`，IPA 为 `release/AppStore-4.2.0-50/MusicPlayer.ipa`，SHA-256 `7381417d9d12a12891e03ad16a63b08e203b8be1bcf97445882ec3ce52ac07eb`。
- IPA 实测为 `com.himhuu.music` / `4.2.0` / `50`，Apple Distribution 签名，`codesign --verify --deep --strict` 通过，`get-task-allow=false`、Beta Reports 与 CarPlay Audio entitlement 均存在。
- Xcode 上传成功，Apple 已处理完成；Build 50 已关联至 App Store Connect 的 4.2.0 版本。简体中文与 en-US 元数据、App 信息、分类以及产品/隐私/条款/支持规范 URL 已保存。
- himhuu.com 当前 App 的四个规范页面已部署并验证 HTTP 200、HTTPS 有效及移动端可读；官网提交为 `246513df78f665f96fa90f01cc6bed85eec62213`。
- 已生成并逐张检查 12 张 Cream / Clay 商店截图：iPhone 6.9 与 iPad 13、简体中文与 en-US 各 3 张，均为 JPEG、无 Alpha，尺寸分别为 1320×2868 和 2064×2752；已上传 App Store Connect。运行画面来自 4.2.0 (50) Debug 真实 UI，内容来自仅 Debug 的原创演示 fixture，不冒充 Archive 安装证据。
- 当前结论为 **Conditional Go**：App Store Connect 简体中文 iPhone/iPad 槽位仍各有 3 张旧版截图排在新版之前。获得删除确认后，清理旧图、复核新版顺序并提交审核；在此之前不得宣称已提审或已发布。

## 4.1.6（46）全量发布门禁（2026-08-09）

- Apple Lookup API 按 Bundle ID `com.himhuu.music` 返回唯一匹配的“散帅播放器”，数字 App Store ID 为 `6784067140`；常驻评价 URL 已集中配置为 `https://apps.apple.com/app/id6784067140?action=write-review`，并新增自动测试。
- Xcode 工程与 `project.yml` 已统一为 `4.1.6 (46)`；最终 Archive 的 `Info.plist` 实测包含版本、构建号、Bundle ID、数字 App Store ID、iOS 17.0 最低版本、本地网络用途说明及品牌 Launch Screen 配置。
- `UILaunchScreen` 使用原创 `BrandIcon` 与深浅模式 `LaunchBackground`；App 第一帧使用同一背景。移除原有固定 900 ms 启动等待，持久化配置读取移到主线程之外，超过 300 ms 才显示真实恢复状态。
- iPhone 17 Pro / iOS 26.5 Simulator：80 个 XCTest 中 77 个通过、0 失败、3 个真实外部服务契约按未配置凭据跳过；4 个 Swift Testing 音频分析测试全部通过。新增覆盖后台读取、读取失败结束加载、恢复完成前不暴露可交互空状态、评价 URL 与规范官网 URL。
- OwnMusic 服务端 21 个 Python 测试全部通过；认证隔离、签名 Range、蜂窝 MP3、扫描与转码策略未回归。
- Release generic iOS Simulator 构建通过；合入最终视觉修正后的 device Archive 位于 `release/MusicPlayer-4.1.6-46-candidate.xcarchive`，Archive 成功且包含 dSYM 与 Privacy Manifest。
- App Store 分发导出成功，候选 IPA 位于 `release/AppStore-4.1.6-46-candidate/MusicPlayer.ipa`，大小 5.0 MB，SHA-256 为 `633f6427e28fc25f25ab769d79288edb9e3b152b539f4d16594680fa362a1392`。导出摘要显示 Cloud Managed Apple Distribution、`get-task-allow=false`、CarPlay Audio entitlement 与 Store provisioning profile；但本机 `codesign --verify --deep --strict` 仍返回 `CSSMERR_TP_NOT_TRUSTED`，须以 Xcode Validate App / App Store Connect 校验为准，当前不能标为上传就绪。
- `https://himhuu.com/apps/sanshuai-player`、`/privacy`、`/terms`、`/support` 在 2026-08-09 均返回 HTTP 200；App 内入口目前指向该 slug。官网本地修改使用了 `/apps/sanshuai`，尚未部署，线上也未完成逐路由浏览器渲染取证，不能排除 SPA 首页 fallback；发布前必须统一唯一 slug 并验证四个最终 URL。
- 当前仍为 **No-Go**：尚未完成 Validate App 与上传；App Store Connect API 返回 401；现有商店截图早于 4.1.6 首页改版且包含“测试”“本地受控音轨”，不能上传；仍缺本版本中英文 iPhone/iPad/横屏/CarPlay 截图矩阵、官网安全部署与线上渲染验证，以及基准真机冷启动/Instruments、后台/蓝牙/弱网、实体 iPad和 CarPlay 车机验收。

验证日期：2026-07-15

## 自动化结果

- `plutil -lint MusicPlayer/Resources/PrivacyInfo.xcprivacy`：通过
- iPhone 17 / iOS Simulator 26.5 全量测试：10 个测试全部通过
- OpenSubsonic Stub：认证响应、分页/并发缓存、结构化歌词、重复查询参数、token+salt 鉴权、收藏首页和转码 URL 通过
- Jellyfin Stub：登录、搜索解析、Token/用户 ID 恢复、直播 `/stream` 和 192 kbps 转码 URL 通过
- 多服务器：添加、Keychain 隔离、自动激活与切换测试通过
- 稳定领域 ID：同源稳定、跨源隔离测试通过
- 媒体资源加载：AVAsset Resource Loader 真实 WAV Range 请求通过
- Existing NAS Python 服务：认证、账号根目录隔离、目录扫描、歌词、签名 URL 和 Range 播放共 15 个测试通过
- Navidrome 0.61.2 真实 HTTPS 契约：认证、资料库、首页、搜索、Range 直播、收藏、播放上报、歌单 CRUD 和指纹固定通过
- Airsonic 10.6.0 真实 HTTPS 契约：认证、库/艺人/专辑/歌曲/歌单端点、搜索、首页降级、旧版歌单创建回退和指纹固定通过
- Jellyfin 10.11.11 真实契约：登录、音乐库/艺人/专辑/歌曲、搜索、首页、Range 直播、收藏、进度上报和歌单 CRUD 通过
- Release / generic iOS Simulator / Swift 6 / iOS 17 deployment target：构建通过
- Release 产物包含并通过校验的 `PrivacyInfo.xcprivacy`
- Release App 重新安装并启动（PID 16086），启动后错误日志无崩溃、白屏或循环请求迹象

## 提交前仍需人工完成

- 使用真实长音频确认后台播放、锁屏控制、蜂窝/Wi-Fi 切换和服务端转码资源占用
- 设置正式 Development Team、签名、隐私政策网址、支持邮箱和 App Store 审核账号
- 在真机上生成 Archive 并执行 App Store Connect Validate App

契约测试使用临时本机服务、临时媒体和临时账号，不将地址或凭据写入仓库。真机长时间运行和 App Store 签名仍不能由 Simulator 替代。

## 2026-07-13 后续阻塞项

- 已确认将 `CODE_SIGNING_ALLOWED=NO` 产物安装到 Simulator 时可触发 Keychain `errSecMissingEntitlement (-34018)`，该产物不适合用于验证 NAS 凭据保存与重启恢复。
- 下一轮修复必须分别验收签名 Simulator、未签名 Simulator 临时会话凭据和真机 Release Keychain，不得用普通文件持久化密码。
- 新增横屏视觉舞台属于新的发布验收项；实现前保持 No-Go，必须补齐旋转快速往复、Reduce Motion、低电量、内存、帧率、横屏录屏与真机验收证据。

完整规格见 `docs/next-iteration-keychain-motion-spec.md`。

## 2.9 重构验证（2026-07-13）

- iPhone 17 Pro / iOS 26.5 Debug 构建通过。
- XCTest 共 14 项：11 项通过、0 失败；3 项真实服务契约测试因未配置凭据明确跳过。
- 新增 Simulator Keychain `-34018` 进程内降级与禁止降级测试均通过；测试不会把凭据写入磁盘。
- 竖屏播放页、横屏舞台与 Apple Music 式底栏 accessory 均已用真实运行 App 截图；横屏根据第一轮截图完成一轮唱片尺寸与控制区修正。
- 横屏舞台已完成第二轮电影感增强，使用原创 SwiftUI Canvas 放射星流、光带、扩散光环和景深微粒；运行证据为 `docs/visual-audit/12-cinematic-particle-stage-v2.9.png`。
- App Icon 为 1024 × 1024、sRGB、无透明通道；素材来源与许可记录已补齐。
- 仍需发布主体在真机完成性能预算、后台播放、网络切换、快速旋转、Reduce Motion 与三段录屏，因此当前结论仍为 **No-Go（等待真机与签名发布验收）**。

## 2.9.1 音频格式兼容验证（2026-07-13）

- iOS XCTest 共 16 项：13 项通过、0 失败；3 项真实服务契约测试因未配置凭据明确跳过。新增覆盖转码响应按真实 MIME 写入缓存、无原扩展名发现缓存和错误后缀隔离。
- OwnMusic 服务端共 18 项测试全部通过，新增覆盖非原生扩展名扫描、容器与编码双重判断、无损/高解析/兼容转码策略、缓存路径隔离和旧有签名 Range 播放。
- 2.9.1（21）无签名 generic iOS Simulator Release 构建通过，iOS App 未链接 FFmpeg 或新增第三方软件包。
- 本机缺少 FFmpeg 且无可用 Docker CLI，尚未完成容器内真实 APE/Opus/OGG/WMA/WavPack/TTA/DSD 样本矩阵；此项保留为 NAS 发布阻塞项，不能仅以模拟转码单元测试替代。

## 3.0.0 实时音频视觉验证（2026-07-13）

- Debug Simulator 构建通过；Metal shader 编译并打包为 `default.metallib`。
- 新增分析器单元测试覆盖低频/高频分离、静音帧和 AVPlayer 真实播放 tap 的非零 PCM 接收。
- 完整 iOS 测试共 21 项：18 项通过、0 失败；3 项外部真实服务契约测试因未配置环境变量明确跳过。OwnMusic 服务端 19 项测试全部通过。
- 两首本地生成 WAV 使用 Provider Resource Loader 与 AVPlayer 正式路径播放，不使用 UI-only 假播放状态；自动换歌通过。
- 签名 iPhone 17 Pro Simulator 已使用真实 Existing NAS 曲目复验：误报为 MP3 的 ALAC/M4A 曲目可按文件签名播放，44.1 kHz 单声道与 48 kHz 双声道 PCM 均驱动 Metal 视觉。
- 真实 NAS 播放时，极光光带与粒子在静音/低能量段仍保留环境层，在非零频谱时明显增强；暂停、恢复自动隐藏控件和关闭返回资料库均通过。
- 3.0.0（30）干净 Release Simulator 构建无警告输出，Privacy Manifest 在产物内且校验通过；产物安装、启动和使用已保存 NAS 会话播放/暂停通过。
- Release 二进制不包含模拟 Provider、模拟服务名称或视觉验收音轨；诊断日志仅在 Debug 编译。
- 真实 NAS 横屏播放已验证 3 秒前景退场：唱片、歌词、局部暗场和播放控件完全消失，Metal 曝光不跳变；隐藏态 AX 树不再暴露透明控件，轻点后前景恢复并重新计时。
- “散帅播放器”名称已进入 iOS Release 产物的 `CFBundleDisplayName`，启动页、关于、反馈、分享与诊断复用同一动态名称。
- 星潮、极光、收藏轨道三套真实运行截图和星潮录屏保存在 `docs/visual-audit/20`–`24`。
- 当前仍为 **No-Go（等待真机性能、后台/蓝牙与发布签名验收）**。

## 3.0.1 NAS 与本机资料库修正（2026-07-15）

- iPhone 17 / iOS 26.5 全量自动测试通过：20 个 XCTest 中 17 个通过、3 个真实外部服务契约按配置跳过；另有 3 个 Swift Testing 音频分析测试通过。总计 20 通过、0 失败、3 跳过。
- 新增自动覆盖：SMB / File Provider 文件夹递归导入、内容去重后返回现有曲目、NAS 瞬时断线后显式读取重试。
- OwnMusic 服务端 19 项 Python 测试全部通过；目录认证、扫描、容器识别、兼容转码策略、短时签名和 Range 未回归。
- `3.0.1 (31)` generic iOS Simulator 干净 Release 构建通过；产物版本、构建号、本地网络用途说明、横竖屏方向和 Privacy Manifest 已从实际 `.app` 核对。
- Release 质量门禁发现的 `-visual-audit-player` 残留已改为编译期 `#if DEBUG` 隔离；合入最终视觉修正后重新干净构建，Release 二进制复查未发现该参数、测试环境变量或测试凭据。
- App 未新增第三方 iOS 依赖。可选 NAS 端使用官方 Navidrome `0.63.2` 独立 GPL-3.0 容器，通知记录已补入 `THIRD_PARTY_NOTICES.md`。
- fnOS Navidrome Compose 与 Caddy YAML 语法通过；当前开发机没有 Docker CLI，不能在此机拉取并启动实际容器。
- 最终横屏视觉已完成真实模拟器复查：播放控件完整进入底部安全区，3 秒后仅隐藏控制层且保留唱片与歌词；Reduce Motion 静态降级通过。证据为 `docs/visual-audit/32`–`34`。
- 用户提供的旧 OwnMusic 测试入口连续 3 次未建立 HTTP 连接，健康与目录请求均约 4 秒超时；请求未到认证阶段，因此不能用该结果判断账号有效性，也不能替代 Navidrome 契约测试。
- 本轮仍为 **No-Go**：缺少当前用户 NAS 上的 Navidrome 临时账号真实契约、真机 SMB 文件夹导入、真机性能/后台/蓝牙和发布签名 Archive 验证。

## 3.0.2 播放稳定性与封面菜单（2026-07-16）

- 新增播放请求代际保护、播放项身份校验和进程内唯一音频所有权；自动测试覆盖快速切歌乱序返回与两个控制器争用音频。
- 新增提前结束判断，目录或媒体仍声明有明显剩余时不再自动切歌；播放按钮会重新加载当前歌曲。
- 正在播放页封面保持无单击歌词手势，长按显示加入歌曲列表菜单；VoiceOver 标签、提示和等价加入操作通过 AX 树核对。
- iPhone 17 Pro / iOS 26.5 默认页和长按菜单真实截图为 `visual-audit/42-player-cover-long-press-default.png` 与 `visual-audit/43-player-cover-add-to-list-menu.png`；第一轮发现封面缺失 AX 元素后已完成可访问性修正，第二轮将预览形状收紧到封面边界。
- 完整自动测试为 26 通过、0 失败、4 个外部真实服务契约按配置跳过，另有 3 个 Swift Testing 测试通过。
- `3.0.2 (34)` generic iOS Simulator 干净 Release 构建通过；产物 `CFBundleShortVersionString=3.0.2`、`CFBundleVersion=34`、最低系统 iOS 17.0，Privacy Manifest 和本地网络用途说明存在。
- Release 二进制未发现视觉审查启动参数或外部契约测试密码环境变量；App 未新增第三方依赖。唯一构建警告为未链接 AppIntents 时 Xcode 跳过元数据提取，不影响运行。
- 本轮功能修复与 Simulator 验收通过，但 App Store 发布结论仍为 **No-Go**：需要使用用户实际故障曲目复验，并完成真机后台/蓝牙/弱网与正式签名 Archive 验证。
