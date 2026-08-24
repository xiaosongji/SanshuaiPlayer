# 音乐服务 API 契约

## 通用要求

- Base URL：`https://api.your-domain.com`
- 所有响应使用 UTF-8 JSON
- 时间使用 ISO 8601，例如 `2026-06-22T08:00:00Z`
- UUID 使用标准带连字符格式
- 只返回 NAS 扫描器已完整处理、可以播放的内容；扫描成功即自动进入目录
- 错误响应包含稳定错误码、面向用户的消息和请求追踪 ID

## 获取音乐目录

除带短时签名的媒体 URL 外，目录和播放地址接口使用 HTTPS Basic Authentication。账号密码由 NAS 服务的 `API_USERNAME`、`API_PASSWORD` 配置。

`GET /v1/catalog`

```json
{
  "artist": {
    "id": "6f0a9f20-f5d1-4d4a-80a7-38337a28b70d",
    "name": "艺人名称",
    "biography": "艺人介绍",
    "artworkURL": "https://media.your-domain.com/images/artist.webp"
  },
  "albums": [
    {
      "id": "d847125f-2b75-45c7-bcff-c09eb8c3f822",
      "title": "专辑名称",
      "subtitle": "专辑副标题",
      "releaseDate": "2026-06-22T08:00:00Z",
      "artworkURL": "https://media.your-domain.com/images/album.webp",
      "accentHex": "#7C3AED",
      "isPublished": true
    }
  ],
  "tracks": [
    {
      "id": "e27d3131-bbe7-4473-a0be-ed0b72a06f46",
      "albumID": "d847125f-2b75-45c7-bcff-c09eb8c3f822",
      "title": "歌曲名称",
      "artistName": "艺人名称",
      "discNumber": 1,
      "trackNumber": 1,
      "durationSeconds": 213.4,
      "artworkURL": "https://media.your-domain.com/images/album.webp",
      "lyrics": "歌词内容",
      "isExplicit": false
    }
  ],
  "featuredAlbumIDs": [
    "d847125f-2b75-45c7-bcff-c09eb8c3f822"
  ]
}
```

建议响应包含 `ETag` 和短时 `Cache-Control`。每次扫描成功后原子替换目录版本并主动刷新 API/CDN 缓存，App 最迟约一分钟获取新目录。

## 获取临时播放地址

`POST /v1/tracks/{trackID}/playback`

蜂窝网络客户端使用 `POST /v1/tracks/{trackID}/playback?format=mp3`，服务端优先返回固定 192 kbps MP3 变体。该变体在扫描阶段生成并通过独立签名 URL 提供；如果单曲无法生成 MP3，可返回原始文件，但必须保留正确的文件签名、`Content-Type` 和 Range 语义，不得将原格式伪装为 MP3。

```json
{
  "url": "https://media.your-domain.com/audio/song.m4a?signature=...",
  "expiresAt": "2026-06-22T09:00:00Z"
}
```

服务端必须：

1. 验证曲目存在并已被扫描器标记为可播放；非 iOS 原生格式必须已经生成并验证兼容缓存。
2. 签发短时有效的 HTTPS 地址。
3. 不返回 NAS 内部地址、挂载路径或永久访问令牌。
4. 记录曲目、匿名设备会话、IP 摘要和请求追踪 ID。
5. 对单设备和单 IP 做合理限流。

音频服务器需要支持 HTTP Range 请求，以保证拖动进度和断点读取正常。

播放地址可能指向原始音频，也可能指向扫描阶段生成的 FLAC/M4A 兼容缓存。客户端不应根据原始文件扩展名猜测实际响应格式，而应使用响应 `Content-Type` 和 AVFoundation 的可播放性检查。

## 后续正式接口

- `POST /v1/sessions/anonymous`：匿名安装会话与风控令牌
- `GET /v1/catalog/changes?since=`：增量目录同步与扫描结果通知
- `POST /v1/events/playback`：聚合播放统计，避免逐秒上报
- `GET /v1/health`：监控探针，不暴露内部依赖详情
