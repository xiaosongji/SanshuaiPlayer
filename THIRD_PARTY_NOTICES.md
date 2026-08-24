# 第三方软件说明

## iOS App

iOS App 目标未链接第三方软件包或音频解码器。

缺少音乐服务器可用时间轴歌词时，App 可按需访问 LRCLIB 和中文歌词聚合服务；缺少
封面时可访问中文封面聚合服务。这些服务作为独立 HTTPS 服务运行，代码未被复制或
链接进 App；请求只包含匹配歌词或封面所需的歌曲名、艺人、专辑名和时长。服务可用性、
返回内容和相关权利归各自提供方及权利人所有。

- LRCLIB API 与官方客户端：https://lrclib.net / https://github.com/tranxuanthang/lrcget
- 中文歌词与封面聚合服务：https://github.com/HisAtri/LrcApi

## OwnMusic NAS 服务

服务端 Docker 镜像通过 Debian 软件仓库安装 FFmpeg，用于音频探测、封面提取及非 iOS 原生格式的兼容转码。

- 项目：FFmpeg
- 官方网站：https://ffmpeg.org/
- 使用位置：仅 `server/` 部署镜像和服务进程，不进入 iOS App 二进制
- 许可证：FFmpeg 主体为 LGPL-2.1-or-later；若实际发行二进制启用了 GPL 组件，则整体适用 GPL-2.0-or-later
- 修改：本项目未修改 FFmpeg 源代码，通过独立命令行进程调用

分发 NAS Docker 镜像前，发布者必须核对镜像内 `ffmpeg -buildconf`、Debian 包版权文件及对应源代码提供义务。不得使用启用了 `nonfree`、不可再分发组件的构建。

官方许可说明：https://ffmpeg.org/legal.html

## 可选 Navidrome NAS 服务

`server/compose.fnos.yml` 可拉取官方 `deluan/navidrome:0.63.2` 容器，将其作为独立
OpenSubsonic 服务进程运行。Navidrome 不进入 iOS App 二进制，本项目未复制、修改或
链接其源代码。

- 项目：Navidrome
- 源码：https://github.com/navidrome/navidrome
- 许可证：GPL-3.0
- 使用位置：用户自行选择部署的 NAS 容器
- 修改：无；只提供配置、只读音乐目录挂载和公开协议客户端连接

重新分发 Navidrome 容器或其修改版时，分发者必须履行 GPL-3.0 对应义务。仅发布 iOS
App 时不会把该容器一并打包。
