# fnOS 接入 OpenSubsonic / Navidrome

Navidrome 是本项目推荐的自托管音乐服务之一。App 通过公开 OpenSubsonic API 连接，不需要也不应读取 fnOS 管理接口。

## 推荐拓扑

```text
只读音乐目录 -> Navidrome :4533 -> Caddy / 有效 HTTPS -> iPhone / iPad
```

- 音乐目录只读挂载，不修改原文件。
- Navidrome 数据写入独立目录或 named volume。
- 关闭不需要的遥测和外部服务。
- 使用独立音乐域名，不复用或暴露 NAS 管理入口。
- App 使用普通音乐账号，不使用 Navidrome 管理员或 fnOS 管理账号。

## 配置

```sh
cd server
cp .env.example .env
```

编辑 `.env`：

```text
MUSIC_DIRECTORY=/path/to/your/music
NAVIDROME_DATA_DIRECTORY=/path/to/navidrome/data
NAVIDROME_HOSTNAME=navidrome.example.com
ACME_EMAIL=admin@example.com
```

确保 Navidrome 运行用户对音乐目录只有读取权限，并对数据目录拥有读写权限。

## 启动

若主机 `80/443` 可用：

```sh
docker compose \
  -f compose.fnos.yml \
  -f compose.fnos-caddy.yml \
  up -d navidrome caddy
```

如果 fnOS 已占用标准 HTTPS 端口，可使用 `compose.fnos-navidrome-live.yml` 作为参考，把容器 `443` 映射到单独端口。该模板从 fnOS 证书配置中只读同步匹配 `CERT_HOSTNAME` 的证书；使用前必须核对本机证书路径、权限和端口冲突。

## 可选外部元数据

Navidrome 的 Last.fm Agent 需要 API Key 与 Shared Secret。真实值只保存在 `.env`：

```text
LASTFM_API_KEY=<your-key>
LASTFM_SHARED_SECRET=<your-secret>
```

没有这些凭据时，应在 Compose 中关闭 Last.fm Agent，而不是提交占位值或把密钥写进 YAML。Deezer、ListenBrainz 等服务也应根据各自条款与隐私要求决定是否启用。

## 验证 OpenSubsonic

下面的命令交互式读取密码，避免把密码直接写入 shell history：

```sh
read -r -p 'Navidrome user: ' ND_USER
read -r -s -p 'Navidrome password: ' ND_PASSWORD; echo
SALT=$(openssl rand -hex 6)
TOKEN=$(printf '%s' "${ND_PASSWORD}${SALT}" | openssl dgst -md5 -r | awk '{print $1}')
curl --fail --show-error \
  "https://navidrome.example.com/rest/ping.view?u=${ND_USER}&t=${TOKEN}&s=${SALT}&v=1.13.0&c=SanshuaiPlayer&f=json"
unset ND_PASSWORD TOKEN
```

随后在 App 中验证登录、资料库、搜索、封面、播放、HTTP Range 拖动、转码、收藏、歌单和播放进度上报。

## 无后端路线

也可以完全不部署 Navidrome：

1. 在系统“文件”App 中连接 SMB 服务器。
2. 在散帅播放器中选择“本机音乐”。
3. 通过系统文件选择器选择文件或文件夹。
4. App 将获授权文件复制到自己的私有资料库，再在本地完成哈希、元数据和封面解析。

此路线不在 App 内保存 SMB 密码，但会占用设备本地空间。

## 许可证边界

Navidrome 使用 GPL-3.0。仓库只提供独立容器的配置示例，iOS App 通过 OpenSubsonic 协议通信，没有复制、修改或链接 Navidrome 代码。重新分发 Navidrome 容器或修改版时，发布者必须自行履行 GPL-3.0 义务。

参考：

- [Navidrome Docker 文档](https://www.navidrome.org/docs/installation/docker/)
- [Navidrome 配置选项](https://www.navidrome.org/docs/usage/configuration/options/)
- [OpenSubsonic API](https://opensubsonic.netlify.app/docs/opensubsonic-api/)
- [Navidrome 源码与 GPL-3.0](https://github.com/navidrome/navidrome)
