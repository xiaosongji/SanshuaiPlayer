# 下一轮规格：模拟器安全存储与横屏视觉舞台

状态：2.9 已实现；真机性能与长时间录屏仍待发布主体验收
更新日期：2026-07-13

## 1. 问题与目标

本轮新增两个发行级目标：

1. 修复模拟器连接 NAS 时“无法访问本机安全存储”导致无法保存凭据、无法完成连接的问题。
2. 当用户把正在播放页从竖屏旋转到横屏时，进入原创的沉浸式视觉舞台。体验参考 Mineradio 对“音乐 + 电影镜头 + 粒子 + 歌词舞台”的产品方向，但不复制其代码、界面、参数、素材或品牌。

本文档是实施与验收依据，不代表功能已经完成。

> 2026-07-13 实施记录：`CredentialVaultFactory`、Simulator 进程内降级、凭据提示与脱敏诊断已接入；正在播放页已支持旋转自动进入原创横屏舞台、显式舞台入口、唱片旋转、播放状态驱动粒子、同步歌词、自动隐藏控件、顺序/随机播放和辅助功能降级。Simulator 已完成真实截图与一轮布局修正，真机性能预算、连续切歌内存和三段录屏仍属于发布前人工验收。

---

## 2. 模拟器 Keychain 问题

### 2.1 已确认原因

当 Security Framework 返回 `-34018` 时，对应 `errSecMissingEntitlement`，意味着当前运行产物缺少可用的 Keychain access group entitlement。本项目使用 `CODE_SIGNING_ALLOWED=NO` 的未签名模拟器产物时可稳定复现该错误。

官方依据：

- Apple `errSecMissingEntitlement`：<https://developer.apple.com/documentation/security/errsecmissingentitlement>
- Apple 排查 `-34018` Keychain 错误：<https://developer.apple.com/forums/thread/114456>

该错误不得被映射成模糊的“网络错误”或“NAS 不可达”，因为连接请求可能尚未开始。

### 2.2 生产环境安全边界

- Release、TestFlight 和 App Store 版必须继续仅使用 Keychain 持久保存密码和 Token。
- 生产版不允许降级到 UserDefaults、JSON、SQLite、普通文件或日志。
- 不为解决模拟器问题而全局关闭 Keychain、TLS 或证书校验。
- 正式归档时必须检查“已构建 App 的实际 entitlements”，不能只检查工程中的 `.entitlements` 输入文件。

### 2.3 开发与模拟器策略

实现独立的 `CredentialVaultFactory`，不在 `MusicSourceStore` 里硬编码环境判断：

```text
CredentialVaultFactory
├─ signed app / device / TestFlight / App Store
│    └─ KeychainCredentialVault
└─ unsigned iOS Simulator + errSecMissingEntitlement
     └─ EphemeralSimulatorCredentialVault
```

`EphemeralSimulatorCredentialVault` 必须满足：

- 只在 iOS Simulator 且实际收到 `errSecMissingEntitlement` 后启用。
- 仅存在于当前 App 进程内存，退出或重启 App 后自动丢弃。
- 不写入磁盘、UserDefaults、数据库、剪贴板或日志。
- 在音乐源页明确显示“模拟器临时凭据，重启后需重新输入”。
- 连接成功后可在当前会话内浏览和播放 NAS，不得因为凭据无法持久化而阻止本次连接。

优先级高于降级的正常修复仍是：使用 Xcode 正常签名并运行模拟器 Debug App，使 Keychain 获得默认 application identifier access group。

### 2.4 错误与诊断文案

`-34018` 在模拟器上应显示：

> 当前模拟器构建缺少 Keychain 签名权限。本次可使用临时凭据继续连接；重启 App 后需重新输入。

真机或签名构建收到同样错误时不允许静默降级，应显示：

> 无法访问系统安全存储。请检查 App 签名和 Keychain 权限后重试。

诊断页只记录：错误类型、OSStatus、是否模拟器、是否签名构建和发生时间。不记录密码、Token、用户名、完整服务器地址或媒体路径。

### 2.5 Keychain 验收

1. 签名 Simulator Debug 构建可添加 NAS，重启后自动恢复。
2. 未签名 Simulator 产物收到 `-34018` 后可使用临时凭据连接。
3. 临时凭据不落盘，重启后显示需重新认证，但不删除服务器配置。
4. 真机 Release 只使用 Keychain，人为模拟 `-34018` 时不启用临时降级。
5. 日志与诊断导出不包含任何凭据或完整私有地址。

---

## 3. Mineradio 参考边界

参考项目：<https://github.com/XxHuberrr/Mineradio>

截至 2026-07-13 的公开信息：

- 项目定位是 Windows / Electron 沉浸式音乐播放器。
- 公开特色包括粒子视觉、歌词舞台、基于节奏的电影镜头和 3D 歌单架。
- GitHub 显示约 8.2k stars、52 次提交，最新公开 Release 为 2026-06-25 的 `v1.1.1`。
- 仓库采用 GPL-3.0；Mineradio 名称、Logo、界面视觉和原创视觉表达仍归其作者。

本项目的决策：

- 仅参考“横屏进入视觉舞台、画面与播放状态关联”的产品思路。
- 不复制或移植其 JavaScript、GLSL、HTML/CSS、预设、素材、配色、相机路径和界面布局。
- 不将 GPL-3.0 源码直接合入本 iOS App，不新增 Electron、WebView 或第三方音乐平台依赖。
- 动效使用 SwiftUI / Core Animation / Metal 的原创实现，保持独立的可替换渲染边界。

---

## 4. 横屏沉浸式视觉舞台

### 4.1 交互入口

本需求包含两层“旋转”：

1. 用户将设备由竖屏旋转为横屏时，正在播放页转换为沉浸式视觉舞台。
2. 舞台中的原创唱片 / 封面组件在播放时持续旋转，暂停时平滑减速并保留停止角度。

只有正在播放页进入完整音频响应舞台。根据 2026-07-26 首页改版决策，首页横屏可以进入独立的 3D 专辑/歌手选择流，但不自动播放粒子动效；搜索、资料库和设置在横屏下仍只进行可用性适配。首页选择流规格见 [首页“浮游唱片馆”重大改版规格](home-floating-gallery-spec.md)。

同时提供正在播放页中的“视觉舞台”按钮，作为不便旋转设备时的显式入口。不得依赖私有方向 API。

### 4.2 舞台视觉层级

```text
ImmersiveVisualStage
├─ ArtworkColorBackdrop       封面主色静态背景
├─ ParticleRenderer           低频粒子 / 流光场
├─ RotatingRecordArtwork      原创唱片与封面旋转层
├─ SyncedLyricsOverlay        同步歌词
└─ AutoHidingPlaybackControls 自动隐藏播放控件
```

- 背景颜色只在曲目变更时采样一次，不逐帧采样或模糊。
- 粒子与流光强度由 `isPlaying`、缓冲状态、播放进度和稳定噪声函数驱动。在没有可靠 PCM / FFT 数据时，不得声称“音频频谱或鼓点驱动”。
- 真实音频反应属于独立的 `AudioAnalysisProvider` 扩展，必须先验证对本机文件、AVPlayer 远程串流、转码流和后台播放的兼容性，不能为视觉效果破坏现有播放器。
- 歌词与粒子不同时争抢对比度；当前句后方有稳定暗场。
- 播放控件在无交互 3 秒后淡出，轻点屏幕恢复，所有按钮仍保留至少 44 × 44 pt 命中区。

### 4.3 横竖屏转场

- 转场是布局状态过渡，不是对整张截图做旋转。
- 封面通过 matched geometry 从竖屏中央过渡到横屏舞台左侧；歌词与控件在右侧重排。
- 总转场时长 0.45–0.65 秒，可在任意时刻被新的旋转或退出操作取消。
- 不等待动画完成才允许播放、暂停、上一首或下一首。
- 快速往复旋转设备 10 次不得出现重复页面、丢失播放状态、多重动画 Task 或崩溃。

### 4.4 唱片旋转状态

- 正常播放：约 33⅓ RPM，即约 1.8 秒一圈。
- 开始播放：0.65 秒 ease-out 加速。
- 暂停 / 中断：0.38 秒 ease-out 减速，保留当前角度。
- 恢复：从已保留角度继续，不跳回 0°。
- 缓冲：0.30 秒减速停止，中心显示低亮度呼吸环；缓冲恢复后再加速。
- 切歌：旧唱片位移 18 pt、缩小到 94% 并淡出；新唱片从反方向进入。切歌请求可取消上一次过渡。
- 角度变化必须使用单一 transform 层，禁止用高频 `Timer` 逐帧写入 SwiftUI 状态。

### 4.5 歌词与舞台

- 竖屏轻点唱片或歌词图标，仍进入现有全屏同步歌词。
- 横屏舞台中默认显示当前句、前一句和后一句，当前句高亮。
- 进入纯歌词模式后停止唱片与粒子计算，避免与歌词滚动竞争注意力和 GPU。
- 返回舞台后根据真实播放状态恢复，不“补播”离屏期间的动画。

### 4.6 无障碍与降级

必须读取 `accessibilityReduceMotion`：

- 开启“减弱动态效果”时停止自动旋转、粒子流动、缩放、景深和大范围位移。
- 横竖屏仅用不超过 0.12 秒的交叉淡化和立即重排。
- 播放状态改用静态紫色环表达，暂停时为中性灰，不能让用户只通过动作判断状态。
- 运行期间修改系统减弱动态设置时，当前动效应立即平滑停止。

Apple 文档：

- `accessibilityReduceMotion`：<https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion>
- SwiftUI 分阶段与关键帧动画：<https://developer.apple.com/documentation/swiftui/controlling-the-timing-and-movements-of-your-animations>

### 4.7 性能预算

- 竖屏正常播放仅保留 1 个持续旋转层。
- 横屏同时运动的装饰层不超过 2 层；粒子数量按设备和低电量模式分档。
- 封面按显示尺寸下采样，舞台单张建议不超过 768 × 768 px。
- 禁止逐帧重新模糊、颜色采样、裁切或重建图片。
- 开启舞台新增常驻内存目标低于 18 MB，连续切换 20 首后不得持续增长。
- 目标稳定 60 fps；常规播放 60 秒 hitch ratio 低于 1%，单次 hitch 不超过 100 ms。
- 常规舞台主线程 CPU 中位数目标低于 10%。
- 低电量模式关闭呼吸环、景深和额外光影；App 后台、纯歌词模式或舞台离屏时停止视觉计算。

### 4.8 素材与版权

- 唱片纹理、中心轴、无封面占位和粒子预设必须原创制作。
- 新增 `docs/asset-provenance.md`，记录素材作者、生成或绘制工具、日期、修改权、商用权和再分发约束。
- 不使用 Mineradio 名称、Logo、截图、官方预设、动态背景或其他可识别品牌资产。
- 视觉继续使用本 App 已确立的深靛紫、暖白和“收藏脉冲”品牌语言。

### 4.9 动效验收

必须用真实 App 录屏验收，静态截图不能证明连续旋转和可中断性。

必拍截图：

1. 竖屏播放中、暂停、缓冲三种唱片状态。
2. 横屏视觉舞台，包含唱片、粒子、同步歌词和已隐藏控件。
3. 深色、浅色、提高对比度和 Reduce Motion 状态。
4. 无封面、无歌词、播放失败和网络长时缓冲状态。
5. Dynamic Type Accessibility 3，文字、唱片和控件不重叠。

必拍录屏：

1. 8 秒“竖屏播放 → 旋转到横屏 → 舞台展开 → 返回竖屏”。
2. 8 秒“播放 → 暂停 → 恢复 → 下一首”，检查旋转角度连续和切歌可中断。
3. 8 秒“舞台 → 缓冲 → 恢复 → 全屏歌词”，检查粒子和唱片计算是否按状态停止。

验收设备至少覆盖一台小屏 iPhone、一台 ProMotion iPhone 和一台 iPad。首轮实现后必须根据真实录屏完成至少一轮速度、层级或光影修正。

---

## 5. 本轮非目标

- 不接入 Mineradio 的第三方音乐平台代码。
- 不引入网易云、QQ 音乐、酷狗、YouTube Music 或 Bridge 扩展。
- 不移植 Mineradio 的 3D 歌单架、天气电台或电影镜头预设。
- 不为动效更换现有 Provider、播放队列、后台播放或锁屏控制架构。
- 不伪造基于 BPM、鼓点或频谱的响应；未实现真实音频分析时，文案只称“播放状态驱动视觉”。
