from __future__ import annotations

import json
import mimetypes
import re
import time
from base64 import b64decode
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlencode, urlparse

from .config import AccountConfig, Config
from .scanner import CatalogRepository
from .signing import create_signature, verify_signature


TRACK_PLAYBACK_PATTERN = re.compile(r"^/v1/tracks/([0-9a-f-]{36})/playback$")
MEDIA_PATTERN = re.compile(r"^/v1/media/([0-9a-f-]{36})$")
ARTWORK_PATTERN = re.compile(r"^/v1/artwork/([0-9a-f-]{36})$")


class MusicHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        config: Config,
        repositories: CatalogRepository | dict[str, CatalogRepository],
    ) -> None:
        super().__init__(address, MusicRequestHandler)
        self.config = config
        if isinstance(repositories, CatalogRepository):
            account_name = config.account_name or config.api_username
            credentials = config.api_credentials or ((config.api_username, config.api_password),)
            self.repositories = {
                username: repositories
                for username, _password in credentials
            } or {account_name: repositories}
            self.default_account_name = account_name
        else:
            self.repositories = repositories
            self.default_account_name = config.account_name or next(iter(repositories))


class MusicRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "OwnMusic/1.0"

    @property
    def music_server(self) -> MusicHTTPServer:
        return self.server  # type: ignore[return-value]

    def do_GET(self) -> None:
        self._route(head_only=False)

    def do_HEAD(self) -> None:
        self._route(head_only=True)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        match = TRACK_PLAYBACK_PATTERN.fullmatch(parsed.path)
        if not match:
            self._send_json(HTTPStatus.NOT_FOUND, {"code": "not_found", "message": "接口不存在。"})
            return
        account = self._authorized_account()
        if account is None:
            self._send_unauthorized()
            return
        repository = self._repository_for_account(account.username)
        if repository is None:
            self._send_json(HTTPStatus.NOT_FOUND, {"code": "library_not_found", "message": "音乐库不存在。"})
            return

        track_id = match.group(1)
        requested_format = parse_qs(parsed.query).get("format", [""])[0].casefold()
        if requested_format not in {"", "mp3"}:
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                {"code": "unsupported_format", "message": "仅支持 MP3 蜂窝网络转码。"},
            )
            return
        encoding = requested_format or None
        if repository.media_path(track_id, encoding=encoding) is None:
            self._send_json(HTTPStatus.NOT_FOUND, {"code": "track_not_found", "message": "歌曲不存在。"})
            return

        expires = int(time.time()) + self.music_server.config.playback_url_ttl_seconds
        signed_track_id = self._signed_track_id(account.username, track_id, encoding=encoding)
        signature = create_signature(self.music_server.config.signing_secret, signed_track_id, expires)
        query_values = {"account": account.username, "expires": expires, "signature": signature}
        if encoding:
            query_values["format"] = encoding
        query = urlencode(query_values)
        url = f"{self.music_server.config.public_base_url}/v1/media/{track_id}?{query}"
        expires_at = datetime.fromtimestamp(expires, tz=timezone.utc).isoformat().replace("+00:00", "Z")
        self._send_json(HTTPStatus.OK, {"url": url, "expiresAt": expires_at})

    def _route(self, head_only: bool) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/v1/health":
            self._send_json(HTTPStatus.OK, self._status(), head_only=head_only)
            return

        if path == "/v1/catalog":
            account = self._authorized_account()
            if account is None:
                self._send_unauthorized(head_only=head_only)
                return
            repository = self._repository_for_account(account.username)
            if repository is None:
                self._send_json(HTTPStatus.NOT_FOUND, {"code": "library_not_found", "message": "音乐库不存在。"})
                return
            payload, etag = repository.catalog()
            if self.headers.get("If-None-Match") == etag:
                self.send_response(HTTPStatus.NOT_MODIFIED)
                self._common_headers()
                self.send_header("ETag", etag)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(HTTPStatus.OK)
            self._common_headers()
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "public, max-age=30, must-revalidate")
            self.send_header("ETag", etag)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if not head_only:
                self.wfile.write(payload)
            return

        artwork_match = ARTWORK_PATTERN.fullmatch(path)
        if artwork_match:
            repository = self._repository_from_query(parse_qs(parsed.query))
            if repository is None:
                self._send_json(HTTPStatus.NOT_FOUND, {"code": "library_not_found", "message": "音乐库不存在。"})
                return
            artwork_path = repository.artwork_path(artwork_match.group(1))
            if artwork_path is None:
                self._send_json(HTTPStatus.NOT_FOUND, {"code": "artwork_not_found", "message": "封面不存在。"})
                return
            self._send_file(artwork_path, head_only=head_only, cache_control="public, max-age=86400")
            return

        media_match = MEDIA_PATTERN.fullmatch(path)
        if media_match:
            self._serve_media(media_match.group(1), parse_qs(parsed.query), head_only)
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"code": "not_found", "message": "接口不存在。"})

    def _serve_media(self, track_id: str, query: dict[str, list[str]], head_only: bool) -> None:
        try:
            expires = int(query.get("expires", [""])[0])
            signature = query.get("signature", [""])[0]
        except ValueError:
            expires = 0
            signature = ""

        account_name = query.get("account", [self.music_server.default_account_name])[0]
        requested_format = query.get("format", [""])[0].casefold()
        if requested_format not in {"", "mp3"}:
            self._send_json(HTTPStatus.BAD_REQUEST, {"code": "unsupported_format", "message": "不支持的音频格式。"})
            return
        encoding = requested_format or None
        signed_track_id = self._signed_track_id(account_name, track_id, encoding=encoding)
        if not verify_signature(self.music_server.config.signing_secret, signed_track_id, expires, signature):
            if encoding is None and account_name == self.music_server.default_account_name and not verify_signature(
                self.music_server.config.signing_secret,
                track_id,
                expires,
                signature,
            ):
                self._send_json(HTTPStatus.FORBIDDEN, {"code": "invalid_signature", "message": "播放地址已失效。"})
                return
            if account_name != self.music_server.default_account_name:
                self._send_json(HTTPStatus.FORBIDDEN, {"code": "invalid_signature", "message": "播放地址已失效。"})
                return

        repository = self._repository_for_account(account_name)
        if repository is None:
            self._send_json(HTTPStatus.NOT_FOUND, {"code": "library_not_found", "message": "音乐库不存在。"})
            return

        media_path = repository.media_path(track_id, encoding=encoding)
        if media_path is None:
            self._send_json(HTTPStatus.NOT_FOUND, {"code": "track_not_found", "message": "歌曲不存在。"})
            return
        self._send_file(media_path, head_only=head_only, cache_control="private, no-store", allow_range=True)

    def _status(self) -> dict[str, Any]:
        statuses = {name: repository.status() for name, repository in self.music_server.repositories.items()}
        last_scan_values = [status["lastScanAt"] for status in statuses.values() if status["lastScanAt"]]
        return {
            "ready": bool(statuses) and all(status["ready"] for status in statuses.values()),
            "scanning": any(status["scanning"] for status in statuses.values()),
            "tracks": sum(status["tracks"] for status in statuses.values()),
            "scanErrors": sum(status["scanErrors"] for status in statuses.values()),
            "lastScanAt": max(last_scan_values) if last_scan_values else None,
            "libraries": {
                name: {
                    "ready": status["ready"],
                    "scanning": status["scanning"],
                    "tracks": status["tracks"],
                    "scanErrors": status["scanErrors"],
                    "lastScanAt": status["lastScanAt"],
                }
                for name, status in statuses.items()
            },
        }

    def _repository_from_query(self, query: dict[str, list[str]]) -> CatalogRepository | None:
        return self._repository_for_account(query.get("account", [self.music_server.default_account_name])[0])

    def _repository_for_account(self, account_name: str) -> CatalogRepository | None:
        return self.music_server.repositories.get(account_name)

    @staticmethod
    def _signed_track_id(
        account_name: str, track_id: str, encoding: str | None = None
    ) -> str:
        value = f"{account_name}:{track_id}"
        return f"{value}:{encoding}" if encoding else value

    def _authorized_account(self) -> AccountConfig | None:
        scheme, _, encoded = self.headers.get("Authorization", "").partition(" ")
        if scheme.lower() != "basic" or not encoded:
            return None
        try:
            decoded = b64decode(encoded, validate=True).decode("utf-8")
            username, separator, password = decoded.partition(":")
        except (ValueError, UnicodeDecodeError):
            return None
        if not separator:
            return None
        return self.music_server.config.account_for_credentials(username, password)

    def _is_authorized(self) -> bool:
        return self._authorized_account() is not None

    def _send_file(
        self,
        path: Path,
        *,
        head_only: bool,
        cache_control: str,
        allow_range: bool = False,
    ) -> None:
        try:
            size = path.stat().st_size
            start, end = 0, max(0, size - 1)
            status = HTTPStatus.OK
            if allow_range and self.headers.get("Range"):
                start, end = parse_byte_range(self.headers["Range"], size)
                status = HTTPStatus.PARTIAL_CONTENT
        except (OSError, ValueError):
            self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            self._common_headers()
            self.send_header("Content-Range", f"bytes */{path.stat().st_size if path.exists() else 0}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        content_length = max(0, end - start + 1)
        content_type = media_content_type(path)
        self.send_response(status)
        self._common_headers()
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(content_length))
        self.send_header("Cache-Control", cache_control)
        if allow_range:
            self.send_header("Accept-Ranges", "bytes")
        if status == HTTPStatus.PARTIAL_CONTENT:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head_only or content_length == 0:
            return

        try:
            with path.open("rb") as file:
                file.seek(start)
                remaining = content_length
                while remaining > 0:
                    chunk = file.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _send_json(self, status: HTTPStatus, payload: dict[str, Any], head_only: bool = False) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self._common_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _send_unauthorized(self, head_only: bool = False) -> None:
        body = json.dumps(
            {"code": "unauthorized", "message": "账号或密码不正确。"},
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        self.send_response(HTTPStatus.UNAUTHORIZED)
        self._common_headers()
        self.send_header("WWW-Authenticate", 'Basic realm="Private Audio Library", charset="UTF-8"')
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _common_headers(self) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")

    def log_message(self, format_string: str, *args: object) -> None:
        message = format_string % args
        print(f"{self.address_string()} {message}", flush=True)


def parse_byte_range(header: str, size: int) -> tuple[int, int]:
    if size <= 0 or not header.startswith("bytes=") or "," in header:
        raise ValueError("unsupported range")
    raw_start, separator, raw_end = header[6:].partition("-")
    if not separator:
        raise ValueError("invalid range")

    if raw_start:
        start = int(raw_start)
        end = int(raw_end) if raw_end else size - 1
    elif raw_end:
        suffix_length = int(raw_end)
        if suffix_length <= 0:
            raise ValueError("invalid suffix range")
        start = max(0, size - suffix_length)
        end = size - 1
    else:
        raise ValueError("empty range")

    if start < 0 or start >= size or end < start:
        raise ValueError("range outside file")
    return start, min(end, size - 1)


def media_content_type(path: Path) -> str:
    try:
        with path.open("rb") as file:
            header = file.read(16)
    except OSError:
        header = b""
    if len(header) >= 12 and header[4:8] == b"ftyp":
        return "audio/mp4"
    if header.startswith(b"fLaC"):
        return "audio/flac"
    if header.startswith(b"RIFF") and header[8:12] == b"WAVE":
        return "audio/wav"
    if header.startswith(b"FORM") and header[8:12] in {b"AIFF", b"AIFC"}:
        return "audio/aiff"
    if header.startswith(b"caff"):
        return "audio/x-caf"
    if header.startswith(b"ID3") or (
        len(header) >= 2 and header[0] == 0xFF and header[1] & 0xE0 == 0xE0
    ):
        return "audio/mpeg"
    return mimetypes.guess_type(path.name)[0] or "application/octet-stream"
