# fnOS 部署 OwnMusic 示例

本文只提供通用模板，不包含任何真实 NAS 地址、目录、证书或凭据。优先考虑直接使用 Navidrome / OpenSubsonic；只有需要仓库内旧 OwnMusic 协议时才部署本服务。

## 安全边界

- 不要把 fnOS 管理端口、SMB 或 Docker API 暴露到公网。
- 为音乐服务使用独立域名、端口和普通用户，不复用 NAS 管理账号。
- 音乐目录只读挂载；数据目录与运行目录分离。
- `.env`、证书、私钥、账号、Token 和部署日志必须留在 NAS，不得提交到 Git。
- 公网访问应使用有效 HTTPS，或在可信局域网中显式固定自签名证书指纹。

## 目录示例

以下路径只是示例，可按设备实际目录调整：

```text
/opt/ownmusic/          # 程序与部署文件
/srv/music/             # 只读音乐目录
/var/lib/ownmusic/      # 数据与兼容缓存
```

复制配置并生成随机密钥：

```sh
cd /opt/ownmusic/server
cp .env.example .env
openssl rand -hex 32
```

编辑 `.env`，至少替换：

```text
MUSIC_DIRECTORY=/srv/music
OWNMUSIC_DATA_DIRECTORY=/var/lib/ownmusic
PUBLIC_BASE_URL=https://music.example.com
SIGNING_SECRET=<刚生成的随机值>
API_USERNAME=<独立服务账号>
API_PASSWORD=<长随机密码>
```

## Docker Compose

```sh
docker compose -f compose.fnos.yml up -d --build ownmusic
docker compose -f compose.fnos.yml logs -f ownmusic
```

若标准 `80/443` 未被占用，可叠加 Caddy：

```sh
docker compose \
  -f compose.fnos.yml \
  -f compose.fnos-caddy.yml \
  up -d ownmusic caddy
```

如果使用出站隧道，隧道目标只能指向音乐容器，不能指向 fnOS 管理服务。`compose.fnos-tunnel.yml` 中的真实 Tunnel Token 必须通过 `.env` 提供。

## 验证

```sh
curl --fail --show-error https://music.example.com/v1/health
curl --fail --show-error \
  -u '<API_USERNAME>:<API_PASSWORD>' \
  https://music.example.com/v1/catalog
```

确认健康检查、目录读取、HTTP Range、拖动播放和凭据拒绝路径均正常后，再在 App 中添加服务器。

## systemd 模板

仓库中的 `ownmusic.service` 与证书同步单元使用 `/opt/ownmusic`、`/srv/music` 和 `/var/lib/ownmusic` 占位路径。安装前必须按本机用户、组、目录和 fnOS 证书布局调整；不要直接复制到生产环境后立即启用。
