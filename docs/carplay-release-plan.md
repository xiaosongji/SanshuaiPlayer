# CarPlay 音频版产品与技术决策

## 产品定位与成功标准

CarPlay 版本服务于已经在 iPhone 上完成音乐源配置的个人音乐收藏用户。核心场景是在驾驶前后或驾驶过程中，以尽可能少的交互浏览常听内容并开始播放。

本次发行必须满足：

- CarPlay 首页两次以内操作开始播放常听歌曲。
- iPhone 锁定时仍可浏览已恢复的资料库缓存、播放、暂停和切歌。
- 不自动抢占车载音频；只有用户选择歌曲或主动恢复时才播放。
- 不在车机端提供服务器配置、导入、编辑歌单、设置、歌词或复杂搜索。
- 加载、空库、断网、缺封面和播放失败都有驾驶场景可读的状态。

## 官方能力边界

采用 Apple 当前推荐的 CarPlay framework：

- `CPTemplateApplicationScene` 管理独立 CarPlay 场景。
- `CPTabBarTemplate`、`CPListTemplate` 和 `CPListItem` 构建驾驶界面。
- `CPNowPlayingTemplate.shared` 显示系统正在播放页。
- `MPNowPlayingInfoCenter` 与 `MPRemoteCommandCenter` 继续作为播放元数据和车载控制来源。
- entitlement 使用 `com.apple.developer.carplay-audio`。

旧的 `MPPlayableContent` 路线已经废弃，不作为兼容层引入。CarPlay 的字体、颜色、布局、焦点、触控区域和不同车机分辨率适配均由系统模板负责。

## 信息架构

根界面最多三个标签，并在运行时服从 `CPTabBarTemplate.maximumTabCount`：

1. 现在就听：从现有首页内容中最多选三节，每节最多四项。
2. 资料库：喜欢的歌曲、专辑、艺人和全部歌曲。
3. 歌单：只读浏览用户已有歌单。

大列表每页最多二十项，通过“更多”继续浏览，避免一次加载大量封面或超过系统模板上限。点击歌曲后沿用现有播放队列并进入系统正在播放页；专辑、艺人和歌单进入不超过三层的内容列表。

## 复用与自研决策

| 候选 | 许可证与状态 | 结论 |
| --- | --- | --- |
| Apple “Integrating CarPlay with Your Music App” | Apple 官方示例 | 采用场景、列表和 Now Playing 的公开 API 模式 |
| `aws-samples/aws-serverless-fullstack-swift-apple-carplay-example` | MIT；面向导航与云端示例 | 仅核对场景生命周期，不复制导航实现 |
| `oguzhnatly/flutter_carplay` | 第三方 Flutter 插件 | 技术栈不匹配，增加桥接和长期兼容成本，不引入 |
| 其他小型 SwiftUI CarPlay 演示 | 多为实验性质、维护和授权信息不一 | 不引入 |

项目不新增第三方运行时依赖。CarPlay 层只桥接现有 `UnifiedLibraryStore`、`UnifiedPlaybackController`、`ArtworkRepository` 和 Provider 边界，避免产生第二套鉴权、缓存或播放器。

## 视觉与素材

CarPlay 严格使用系统模板，不移植手机端玻璃材质、实时粒子、歌词或自绘播放控件。品牌通过与 iPhone 一致的 App Icon、用户曲库封面、项目原创缺图占位和简洁中文文案表达。

不新增第三方视觉素材。现有 App Icon、BrandIcon、ArtworkPlaceholder 和收藏脉冲的来源与许可继续由 `ASSET_LICENSES.md` 和 `docs/asset-provenance.md` 管理。

## 审核与风险

- Apple Developer 的 App ID 必须启用 CarPlay Audio App。
- 新生成的开发与分发描述文件必须包含 `com.apple.developer.carplay-audio`。
- App Store 审核仍会检查应用是否属于合格的音频类别，以及驾驶交互是否简洁。
- NAS 与在线音乐源必须在 iPhone 锁定和后台场景验证 Keychain、局域网与网络恢复行为。
- 模拟器可验证模板与基本播放；真实车辆或 CarPlay 测试设备仍是最终兼容性证据。

## 验证计划

- 单元测试：首页节数/项目数裁剪、播放队列和远程控制回归。
- 构建测试：Debug、Release、测试目标和签名 entitlement。
- CarPlay Simulator：800×480 根页、资料库、歌单、Now Playing、加载、空库、离线、缺封面、长文案、昼夜模式。
- 发布验证：Archive 后检查 `CFBundleShortVersionString`、`CFBundleVersion` 和签名 entitlement。
- 上架：撤回 4.1.3，上传 4.1.5（构建 45），补充 CarPlay 发行说明并重新提交审核。

## 参考资料

- [Requesting CarPlay Entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
- [Integrating CarPlay with Your Music App](https://developer.apple.com/documentation/carplay/integrating-carplay-with-your-music-app)
- [CarPlay Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/carplay/)
- [CarPlay framework](https://developer.apple.com/documentation/carplay)
