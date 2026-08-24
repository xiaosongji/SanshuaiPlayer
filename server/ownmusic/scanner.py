from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .config import Config


SUPPORTED_AUDIO_EXTENSIONS = {
    ".aac",
    ".ac3",
    ".aif",
    ".aiff",
    ".alac",
    ".amr",
    ".ape",
    ".caf",
    ".dff",
    ".dsf",
    ".dts",
    ".eac3",
    ".flac",
    ".m4a",
    ".m4b",
    ".mka",
    ".mp2",
    ".mp3",
    ".mp4",
    ".mpc",
    ".oga",
    ".ogg",
    ".opus",
    ".shn",
    ".tak",
    ".tta",
    ".wav",
    ".wma",
    ".wv",
}
IOS_NATIVE_AUDIO_EXTENSIONS = {
    ".aac",
    ".aif",
    ".aiff",
    ".caf",
    ".flac",
    ".m4a",
    ".m4b",
    ".mp3",
    ".mp4",
    ".wav",
}
LOSSLESS_AUDIO_CODECS = {
    "alac",
    "ape",
    "flac",
    "mlp",
    "shorten",
    "tak",
    "tta",
    "wavpack",
    "wmalossless",
}
IOS_NATIVE_AUDIO_CODECS = {"aac", "alac", "flac", "mp3"}
COVER_FILENAMES = ("cover.webp", "cover.jpg", "cover.jpeg", "cover.png", "folder.jpg")
COVER_FILENAME_KEYS = {name.casefold() for name in COVER_FILENAMES}
SCANNER_STATE_VERSION = 8
LYRICS_CACHE_VERSION = 1
LYRICS_TAG_KEYS = {
    "lyrics",
    "lyric",
    "unsyncedlyrics",
    "unsynchronisedlyrics",
    "unsynchronizedlyrics",
    "syncedlyrics",
    "synchronizedlyrics",
    "synchronisedlyrics",
    "uslt",
    "sylt",
    "©lyr",
}


@dataclass(frozen=True)
class ScanSnapshot:
    catalog: dict[str, Any]
    media_paths: dict[str, Path]
    cellular_media_paths: dict[str, Path]
    artwork_paths: dict[str, Path]
    errors: list[dict[str, str]]


Probe = Callable[[Path], dict[str, Any]]
OnlineLyricsLookup = Callable[[str, str, str, float], Optional[str]]
Transcoder = Callable[[Path, Path, str], None]


class MusicScanner:
    def __init__(
        self,
        config: Config,
        probe: Probe | None = None,
        online_lyrics_lookup: OnlineLyricsLookup | None = None,
        transcoder: Transcoder | None = None,
    ) -> None:
        self.config = config
        self.probe = probe or probe_audio
        self.online_lyrics_lookup = online_lyrics_lookup or self._fetch_online_lyrics
        self.transcoder = transcoder or transcode_audio
        self._state_path = config.data_root / "scanner-state.json"
        self._catalog_path = config.data_root / "catalog.json"
        self._lyrics_cache_path = config.data_root / "lyrics-cache.json"
        self._artwork_root = config.data_root / "artwork"
        self._artwork_root.mkdir(parents=True, exist_ok=True)
        self._transcode_root = config.data_root / "transcodes"
        self._transcode_root.mkdir(parents=True, exist_ok=True)
        self._cached_files = self._load_state()
        self._lyrics_cache = self._load_lyrics_cache()
        self._online_lyrics_lookups_remaining = 0

    def scan(self) -> ScanSnapshot:
        now = time.time()
        files: dict[str, dict[str, Any]] = {}
        errors: list[dict[str, str]] = []
        seen_hashes: set[str] = set()
        self._online_lyrics_lookups_remaining = self.config.online_lyrics_lookup_limit_per_scan

        for path in self._audio_files():
            relative_path = path.relative_to(self.config.music_root).as_posix()
            try:
                signature = _source_signature(path)
                cached = self._cached_files.get(relative_path)
                if cached and cached.get("signature") == signature and self._cached_playback_exists(cached):
                    record = _repair_cached_record(path, cached) if _record_needs_text_repair(cached) else cached
                else:
                    if now - _latest_source_mtime(path) < self.config.stable_age_seconds:
                        continue
                    record = self._build_record(path, relative_path, signature)
                record = self._record_with_online_lyrics(record)

                content_hash = str(record["content_hash"])
                if content_hash in seen_hashes:
                    errors.append({"path": relative_path, "error": "duplicate audio content"})
                    continue
                seen_hashes.add(content_hash)
                files[relative_path] = record
            except Exception as error:  # A bad file must not block the rest of the library.
                errors.append({"path": relative_path, "error": str(error)[:500]})

        self._prune_transcodes(files)
        snapshot = self._make_snapshot(files, errors)
        self._cached_files = files
        _atomic_write_json(self._state_path, {"version": SCANNER_STATE_VERSION, "files": files})
        _atomic_write_json(self._lyrics_cache_path, {"version": LYRICS_CACHE_VERSION, "items": self._lyrics_cache})
        _atomic_write_json(self._catalog_path, snapshot.catalog)
        return snapshot

    def empty_snapshot(self) -> ScanSnapshot:
        return self._make_snapshot({}, [])

    def cached_snapshot(self) -> ScanSnapshot:
        return self._make_snapshot(self._cached_files, [])

    def _audio_files(self) -> list[Path]:
        root = self.config.music_root
        paths: list[Path] = []
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in SUPPORTED_AUDIO_EXTENSIONS:
                continue
            resolved = path.resolve()
            if not resolved.is_relative_to(root):
                continue
            paths.append(resolved)
        return sorted(paths, key=lambda item: item.as_posix().casefold())

    def _cached_playback_exists(self, record: dict[str, Any]) -> bool:
        try:
            playback = record.get("playback_relative") or f"music:{record.get('source_relative', '')}"
            cellular = record.get("cellular_playback_relative")
            return (
                self._resolve_stored_file(str(playback)).stat().st_size > 0
                and isinstance(cellular, str)
                and self._resolve_stored_file(cellular).stat().st_size > 0
            )
        except (OSError, ValueError):
            return False

    def _build_record(self, path: Path, relative_path: str, signature: str) -> dict[str, Any]:
        probe_result = self.probe(path)
        sidecar_tags = _read_sidecar_tags(path)
        embedded_tags = {
            str(key).lower(): str(value).strip()
            for key, value in probe_result.get("tags", {}).items()
            if value is not None
        }
        embedded_tags = _repair_embedded_tags(embedded_tags)
        if any(_looks_garbled(value) for value in embedded_tags.values()):
            embedded_tags = _merge_embedded_tags(embedded_tags, _read_embedded_text_tags(path))
        tags = {**embedded_tags, **sidecar_tags}
        duration = float(probe_result.get("duration", 0))
        if duration <= 0:
            raise ValueError("audio duration is missing or invalid")

        content_hash = _audio_content_fingerprint(path)
        track_id = _stable_uuid("track", relative_path.casefold())
        audio_codec = str(probe_result.get("audio_codec") or "")
        playback_relative = self._prepare_playback(
            path,
            relative_path,
            track_id,
            signature,
            audio_codec,
        )
        cellular_playback_relative = self._prepare_cellular_playback(
            path, relative_path, track_id, signature, audio_codec
        )
        fallback_album = "单曲与 EP" if path.parent == self.config.music_root else path.parent.name
        filename_artist, filename_title = _artist_title_from_filename(path.stem)
        tag_title = _clean_or_none(tags.get("title"))
        tag_artist = _clean_or_none(tags.get("artist"))
        album_name = _clean_or_none(tags.get("album")) or fallback_album or "单曲与 EP"
        if tag_title is None and filename_artist and (tag_artist is None or len(tag_artist) <= 2):
            artist_name = filename_artist
        else:
            artist_name = tag_artist or filename_artist or self.config.artist_name
        album_artist = _clean_or_none(tags.get("album_artist") or tags.get("albumartist")) or artist_name
        title = tag_title or filename_title or _title_from_filename(path.stem)
        lyrics = _read_lyrics(path, tags)
        artwork = self._find_or_extract_artwork(path, track_id, bool(probe_result.get("has_artwork")))

        return {
            "signature": signature,
            "content_hash": content_hash,
            "source_relative": relative_path,
            "playback_relative": playback_relative,
            "cellular_playback_relative": cellular_playback_relative,
            "artwork_relative": artwork,
            "track": {
                "id": track_id,
                "album_key": f"{album_artist.casefold()}\n{album_name.casefold()}",
                "album_name": album_name,
                "album_artist": album_artist,
                "title": title,
                "artist_name": artist_name,
                "disc_number": _tag_number(tags.get("disc") or tags.get("discnumber"), 1),
                "track_number": _tag_number(tags.get("track") or tags.get("tracknumber"), _number_from_filename(path.stem)),
                "duration_seconds": round(duration, 3),
                "release_date": _release_date(tags.get("date") or tags.get("year"), path.stat().st_mtime),
                "lyrics": lyrics,
                "is_explicit": _is_truthy(tags.get("explicit")),
            },
        }

    def _prepare_playback(
        self,
        source: Path,
        source_relative: str,
        track_id: str,
        signature: str,
        audio_codec: str,
    ) -> str:
        if is_natively_playable_on_ios(source.suffix, audio_codec):
            return f"music:{source_relative}"

        profile = transcode_profile(audio_codec)
        output_suffix = ".flac" if profile in {"lossless", "high_resolution"} else ".m4a"
        destination = self._transcode_root / f"{track_id}-{signature[:12]}{output_suffix}"
        if destination.is_file() and destination.stat().st_size > 0:
            return f"data:transcodes/{destination.name}"

        temporary = self._transcode_root / f".{track_id}-{uuid.uuid4().hex}{output_suffix}"
        try:
            self.transcoder(source, temporary, profile)
            if not temporary.is_file() or temporary.stat().st_size <= 0:
                raise ValueError("audio compatibility transcode produced no output")
            os.replace(temporary, destination)
        except Exception:
            temporary.unlink(missing_ok=True)
            raise
        return f"data:transcodes/{destination.name}"

    def _prepare_cellular_playback(
        self,
        source: Path,
        source_relative: str,
        track_id: str,
        signature: str,
        audio_codec: str,
    ) -> str:
        codec = audio_codec.strip().casefold()
        if source.suffix.casefold() == ".mp3" and codec in {"", "mp3"}:
            return f"music:{source_relative}"

        destination = self._transcode_root / f"{track_id}-{signature[:12]}-cellular.mp3"
        if destination.is_file() and destination.stat().st_size > 0:
            return f"data:transcodes/{destination.name}"

        temporary = self._transcode_root / f".{track_id}-{uuid.uuid4().hex}-cellular.mp3"
        try:
            self.transcoder(source, temporary, "cellular_mp3")
            if not temporary.is_file() or temporary.stat().st_size <= 0:
                raise ValueError("cellular MP3 transcode produced no output")
            os.replace(temporary, destination)
        except Exception:
            temporary.unlink(missing_ok=True)
            return f"music:{source_relative}"
        return f"data:transcodes/{destination.name}"

    def _prune_transcodes(self, files: dict[str, dict[str, Any]]) -> None:
        referenced = set()
        for record in files.values():
            for key in ("playback_relative", "cellular_playback_relative"):
                value = str(record.get(key, ""))
                if value.startswith("data:transcodes/"):
                    referenced.add(value.split(":", 1)[1])
        for path in self._transcode_root.iterdir():
            relative = f"transcodes/{path.name}"
            if path.is_file() and relative not in referenced:
                path.unlink(missing_ok=True)

    def _record_with_online_lyrics(self, record: dict[str, Any]) -> dict[str, Any]:
        if not self.config.online_lyrics_enabled:
            return record
        track = record.get("track")
        if not isinstance(track, dict):
            return record
        current_lyrics = track.get("lyrics")
        if isinstance(current_lyrics, str) and current_lyrics.strip():
            return record

        title = _clean_or_none(str(track.get("title", "")))
        artist = _clean_or_none(str(track.get("artist_name", "")))
        album = _clean_or_none(str(track.get("album_name", ""))) or ""
        duration = float(track.get("duration_seconds") or 0)
        if not title or not artist or duration <= 0:
            return record

        cache_key = _lyrics_cache_key(title, artist, album, duration)
        cached = self._lyrics_cache.get(cache_key)
        if isinstance(cached, dict):
            lyrics = cached.get("lyrics")
            if isinstance(lyrics, str) and lyrics.strip():
                return _copy_record_with_lyrics(record, lyrics)
            return record

        if self._online_lyrics_lookups_remaining <= 0:
            return record
        self._online_lyrics_lookups_remaining -= 1

        try:
            lyrics = self.online_lyrics_lookup(title, artist, album, duration)
        except Exception:
            lyrics = None
        cleaned = _clean_lyrics_text(lyrics)
        self._lyrics_cache[cache_key] = {
            "lyrics": cleaned,
            "source": "lrclib",
            "fetched_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "title": title,
            "artist": artist,
            "album": album,
            "duration": round(duration),
        }
        if cleaned:
            return _copy_record_with_lyrics(record, cleaned)
        return record

    def _fetch_online_lyrics(self, title: str, artist: str, album: str, duration: float) -> str | None:
        parameters: dict[str, str] = {
            "track_name": title,
            "artist_name": artist,
            "duration": str(round(duration)),
        }
        if album:
            parameters["album_name"] = album
        url = f"{self.config.online_lyrics_base_url}/api/get?{urlencode(parameters)}"
        request = Request(
            url,
            headers={"User-Agent": "OwnMusic/1.0 (private NAS lyrics lookup)"},
        )
        try:
            with urlopen(request, timeout=self.config.online_lyrics_timeout_seconds) as response:
                payload = json.loads(response.read(2 * 1024 * 1024).decode("utf-8"))
        except HTTPError as error:
            if error.code == 404:
                return None
            raise
        except (OSError, URLError, ValueError):
            return None

        if not isinstance(payload, dict) or payload.get("instrumental") is True:
            return None
        synced = payload.get("syncedLyrics")
        if isinstance(synced, str) and synced.strip():
            return synced
        plain = payload.get("plainLyrics")
        if isinstance(plain, str) and plain.strip():
            return plain
        return None

    def _find_or_extract_artwork(self, audio_path: Path, track_id: str, has_artwork: bool) -> str | None:
        directory_files = {
            candidate.name.casefold(): candidate
            for candidate in audio_path.parent.iterdir()
            if candidate.is_file()
        }
        for filename in COVER_FILENAMES:
            candidate = directory_files.get(filename.casefold())
            if candidate is not None:
                return f"music:{candidate.relative_to(self.config.music_root).as_posix()}"

        if not has_artwork:
            return None

        destination = self._artwork_root / f"{track_id}.jpg"
        command = [
            "ffmpeg",
            "-v",
            "error",
            "-y",
            "-i",
            str(audio_path),
            "-map",
            "0:v:0",
            "-frames:v",
            "1",
            "-q:v",
            "2",
            str(destination),
        ]
        result = subprocess.run(command, capture_output=True, text=True, timeout=45, check=False)
        if result.returncode != 0 or not destination.is_file():
            return None
        return f"data:artwork/{destination.name}"

    def _make_snapshot(
        self,
        files: dict[str, dict[str, Any]],
        errors: list[dict[str, str]],
    ) -> ScanSnapshot:
        albums_by_key: dict[str, list[dict[str, Any]]] = {}
        media_paths: dict[str, Path] = {}
        cellular_media_paths: dict[str, Path] = {}
        artwork_paths: dict[str, Path] = {}

        for record in files.values():
            track = record["track"]
            albums_by_key.setdefault(track["album_key"], []).append(record)
            track_id = track["id"]
            playback_relative = record.get("playback_relative") or f"music:{record['source_relative']}"
            media_paths[track_id] = self._resolve_stored_file(playback_relative)
            cellular_relative = record.get("cellular_playback_relative")
            if isinstance(cellular_relative, str):
                cellular_media_paths[track_id] = self._resolve_stored_file(cellular_relative)
            artwork_path = self._resolve_artwork(record.get("artwork_relative"))
            if artwork_path:
                artwork_paths[track_id] = artwork_path

        albums: list[dict[str, Any]] = []
        tracks: list[dict[str, Any]] = []
        album_artwork: dict[str, str | None] = {}

        for album_key, records in albums_by_key.items():
            first = records[0]["track"]
            album_id = _stable_uuid("album", album_key)
            artwork_url = next(
                (
                    f"{self.config.public_base_url}/v1/artwork/{record['track']['id']}?{self._artwork_query(record)}"
                    for record in records
                    if record["track"]["id"] in artwork_paths
                ),
                None,
            )
            album_artwork[album_id] = artwork_url
            release_date = min(record["track"]["release_date"] for record in records)
            albums.append(
                {
                    "id": album_id,
                    "title": first["album_name"],
                    "subtitle": first["album_artist"],
                    "releaseDate": release_date,
                    "artworkURL": artwork_url,
                    "accentHex": None,
                    "isPublished": True,
                }
            )
            for record in records:
                track = record["track"]
                tracks.append(
                    {
                        "id": track["id"],
                        "albumID": album_id,
                        "title": track["title"],
                        "artistName": track["artist_name"],
                        "discNumber": track["disc_number"],
                        "trackNumber": track["track_number"],
                        "durationSeconds": track["duration_seconds"],
                        "artworkURL": artwork_url,
                        "lyrics": track["lyrics"],
                        "isExplicit": track["is_explicit"],
                    }
                )

        albums.sort(key=lambda album: (album["releaseDate"], album["title"]), reverse=True)
        tracks.sort(key=lambda track: (track["albumID"], track["discNumber"], track["trackNumber"], track["title"]))
        first_artwork = next((album["artworkURL"] for album in albums if album["artworkURL"]), None)
        catalog = {
            "artist": {
                "id": _stable_uuid("artist", self.config.artist_name.casefold()),
                "name": self.config.artist_name,
                "biography": None,
                "artworkURL": first_artwork,
            },
            "albums": albums,
            "tracks": tracks,
            "featuredAlbumIDs": [album["id"] for album in albums[:4]],
        }
        return ScanSnapshot(catalog, media_paths, cellular_media_paths, artwork_paths, errors)

    def _artwork_query(self, record: dict[str, Any]) -> str:
        values = {"v": record["signature"][:12]}
        if self.config.account_name:
            values["account"] = self.config.account_name
        return urlencode(values)

    def _resolve_music_path(self, relative_path: str) -> Path:
        path = (self.config.music_root / relative_path).resolve()
        if not path.is_relative_to(self.config.music_root) or not path.is_file():
            raise ValueError("music path escaped the configured root")
        return path

    def _resolve_stored_file(self, value: str) -> Path:
        prefix, separator, relative_path = value.partition(":")
        if not separator or prefix not in {"music", "data"}:
            raise ValueError("invalid stored media path")
        root = self.config.music_root if prefix == "music" else self.config.data_root
        path = (root / relative_path).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            raise ValueError("stored media path escaped its configured root")
        return path

    def _resolve_artwork(self, value: str | None) -> Path | None:
        if not value:
            return None
        prefix, relative_path = value.split(":", 1)
        root = self.config.music_root if prefix == "music" else self.config.data_root
        path = (root / relative_path).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            return None
        return path

    def _load_state(self) -> dict[str, dict[str, Any]]:
        try:
            payload = json.loads(self._state_path.read_text(encoding="utf-8"))
            if payload.get("version") == SCANNER_STATE_VERSION and isinstance(payload.get("files"), dict):
                return payload["files"]
        except (OSError, ValueError, TypeError):
            pass
        return {}

    def _load_lyrics_cache(self) -> dict[str, dict[str, Any]]:
        try:
            payload = json.loads(self._lyrics_cache_path.read_text(encoding="utf-8"))
            items = payload.get("items")
            if payload.get("version") == LYRICS_CACHE_VERSION and isinstance(items, dict):
                return {str(key): value for key, value in items.items() if isinstance(value, dict)}
        except (OSError, ValueError, TypeError):
            pass
        return {}


class CatalogRepository:
    def __init__(self, scanner: MusicScanner) -> None:
        self._scanner = scanner
        self._lock = threading.RLock()
        initial_snapshot = scanner.cached_snapshot()
        self._catalog_bytes = json.dumps(
            initial_snapshot.catalog,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        self._etag = f'"{hashlib.sha256(self._catalog_bytes).hexdigest()}"'
        self._media_paths = initial_snapshot.media_paths
        self._cellular_media_paths = initial_snapshot.cellular_media_paths
        self._artwork_paths = initial_snapshot.artwork_paths
        self._errors = initial_snapshot.errors
        self._last_scan_at: str | None = None
        self._is_scanning = False

    def refresh(self) -> None:
        with self._lock:
            self._is_scanning = True
        try:
            snapshot = self._scanner.scan()
            catalog_bytes = json.dumps(
                snapshot.catalog,
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode("utf-8")
            etag = f'"{hashlib.sha256(catalog_bytes).hexdigest()}"'
            with self._lock:
                self._catalog_bytes = catalog_bytes
                self._etag = etag
                self._media_paths = snapshot.media_paths
                self._cellular_media_paths = snapshot.cellular_media_paths
                self._artwork_paths = snapshot.artwork_paths
                self._errors = snapshot.errors
                self._last_scan_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        finally:
            with self._lock:
                self._is_scanning = False

    def catalog(self) -> tuple[bytes, str]:
        with self._lock:
            return self._catalog_bytes, self._etag

    def media_path(self, track_id: str, encoding: str | None = None) -> Path | None:
        with self._lock:
            if encoding == "mp3":
                return self._cellular_media_paths.get(track_id)
            return self._media_paths.get(track_id)

    def artwork_path(self, track_id: str) -> Path | None:
        with self._lock:
            return self._artwork_paths.get(track_id)

    def status(self) -> dict[str, Any]:
        with self._lock:
            return {
                "ready": self._last_scan_at is not None,
                "scanning": self._is_scanning,
                "tracks": len(self._media_paths),
                "scanErrors": len(self._errors),
                "lastScanAt": self._last_scan_at,
            }


def probe_audio(path: Path) -> dict[str, Any]:
    command = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration:format_tags:stream=codec_name,codec_type:stream_disposition=attached_pic",
        "-of",
        "json",
        str(path),
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=45, check=False)
    if result.returncode != 0:
        message = result.stderr.strip() or "ffprobe failed"
        raise ValueError(message[-500:])
    payload = json.loads(result.stdout)
    format_info = payload.get("format", {})
    streams = payload.get("streams", [])
    audio_stream = next((stream for stream in streams if stream.get("codec_type") == "audio"), {})
    return {
        "duration": format_info.get("duration", 0),
        "tags": format_info.get("tags", {}),
        "audio_codec": audio_stream.get("codec_name", ""),
        "has_artwork": any(
            stream.get("codec_type") == "video" and stream.get("disposition", {}).get("attached_pic") == 1
            for stream in streams
        ),
    }


def transcode_profile(audio_codec: str) -> str:
    codec = audio_codec.strip().casefold()
    if codec.startswith("dsd_"):
        return "high_resolution"
    if codec in LOSSLESS_AUDIO_CODECS or codec.startswith("pcm_"):
        return "lossless"
    return "compatible"


def is_natively_playable_on_ios(suffix: str, audio_codec: str) -> bool:
    container = suffix.strip().casefold()
    if container not in IOS_NATIVE_AUDIO_EXTENSIONS:
        return False
    codec = audio_codec.strip().casefold()
    if not codec:
        return True
    if container in {".m4a", ".m4b", ".mp4"}:
        return codec in {"aac", "alac"}
    if container == ".mp3":
        return codec == "mp3"
    if container == ".flac":
        return codec == "flac"
    if container == ".aac":
        return codec == "aac"
    if container in {".wav", ".aif", ".aiff", ".caf"}:
        return codec.startswith(("pcm_", "adpcm_ima_")) or codec in {"alaw", "mulaw"}
    return False


def transcode_audio(source: Path, destination: Path, profile: str) -> None:
    command = [
        "ffmpeg",
        "-nostdin",
        "-v",
        "error",
        "-y",
        "-i",
        str(source),
        "-map",
        "0:a:0",
        "-vn",
        "-map_metadata",
        "0",
    ]
    if profile in {"lossless", "high_resolution"}:
        command.extend(("-c:a", "flac", "-compression_level", "5"))
        if profile == "high_resolution":
            command.extend(("-ar", "192000"))
    elif profile == "cellular_mp3":
        command.extend(("-c:a", "libmp3lame", "-b:a", "192k", "-id3v2_version", "3"))
    else:
        command.extend(("-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart"))
    command.append(str(destination))
    result = subprocess.run(command, capture_output=True, text=True, timeout=900, check=False)
    if result.returncode != 0:
        message = result.stderr.strip() or "ffmpeg compatibility transcode failed"
        raise ValueError(message[-500:])


def _stable_uuid(namespace: str, value: str) -> str:
    digest = hashlib.sha256(f"{namespace}\n{value}".encode("utf-8")).digest()[:16]
    return str(uuid.UUID(bytes=digest, version=5))


def _lyrics_cache_key(title: str, artist: str, album: str, duration: float) -> str:
    value = "\n".join(
        (
            _normalize_lookup_text(title),
            _normalize_lookup_text(artist),
            _normalize_lookup_text(album),
            str(round(duration)),
        )
    )
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _normalize_lookup_text(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip().casefold()


def _copy_record_with_lyrics(record: dict[str, Any], lyrics: str) -> dict[str, Any]:
    copied = dict(record)
    track = dict(copied["track"])
    track["lyrics"] = lyrics
    copied["track"] = track
    return copied


def _audio_content_fingerprint(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        size = path.stat().st_size
        digest.update(str(size).encode("ascii"))
        digest.update(file.read(128 * 1024))
        if size > 256 * 1024:
            file.seek(max(0, size - 128 * 1024))
            digest.update(file.read(128 * 1024))
    return digest.hexdigest()


def _source_signature(audio_path: Path) -> str:
    fingerprint: list[str] = []
    for candidate in _source_files(audio_path):
        stat = candidate.stat()
        fingerprint.append(f"{candidate.name}\n{stat.st_size}\n{stat.st_mtime_ns}")
    return hashlib.sha256("\n".join(fingerprint).encode("utf-8")).hexdigest()


def _latest_source_mtime(audio_path: Path) -> float:
    return max(candidate.stat().st_mtime for candidate in _source_files(audio_path))


def _source_files(audio_path: Path) -> list[Path]:
    candidates = [audio_path, audio_path.with_suffix(".lrc"), audio_path.with_suffix(".txt")]
    candidates.append(audio_path.parent / "metadata.json")
    candidates.extend(
        candidate
        for candidate in audio_path.parent.iterdir()
        if candidate.is_file() and candidate.name.casefold() in COVER_FILENAME_KEYS
    )
    return sorted(
        {candidate for candidate in candidates if candidate.is_file()},
        key=lambda item: item.name.casefold(),
    )


def _read_sidecar_tags(audio_path: Path) -> dict[str, str]:
    metadata_path = audio_path.parent / "metadata.json"
    if not metadata_path.is_file() or metadata_path.stat().st_size > 1024 * 1024:
        return {}
    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeDecodeError, ValueError):
        return {}
    if not isinstance(payload, dict):
        return {}

    values: dict[str, Any] = dict(payload)
    tracks = payload.get("tracks")
    if isinstance(tracks, dict):
        track_values = tracks.get(audio_path.name) or tracks.get(audio_path.stem)
        if isinstance(track_values, dict):
            values.update(track_values)

    aliases = {
        "title": "title",
        "artist": "artist",
        "album": "album",
        "albumArtist": "album_artist",
        "album_artist": "album_artist",
        "track": "track",
        "disc": "disc",
        "date": "date",
        "releaseDate": "date",
        "explicit": "explicit",
    }
    return {
        normalized_key: str(values[source_key]).strip()
        for source_key, normalized_key in aliases.items()
        if source_key in values and values[source_key] is not None and str(values[source_key]).strip()
    }


def _read_embedded_text_tags(audio_path: Path) -> dict[str, str]:
    suffix = audio_path.suffix.lower()
    if suffix == ".mp3":
        return _read_id3v2_text_tags(audio_path)
    if suffix == ".wav":
        return _read_riff_info_tags(audio_path)
    return {}


def _read_id3v2_text_tags(audio_path: Path) -> dict[str, str]:
    try:
        with audio_path.open("rb") as file:
            header = file.read(10)
            if len(header) != 10 or header[:3] != b"ID3":
                return {}
            version = header[3]
            tag_size = _synchsafe_to_int(header[6:10])
            data = file.read(min(tag_size, 2 * 1024 * 1024))
    except OSError:
        return {}

    frame_map = {
        "TIT2": "title",
        "TPE1": "artist",
        "TALB": "album",
        "TPE2": "album_artist",
        "TRCK": "track",
        "TPOS": "disc",
        "TDRC": "date",
        "TYER": "date",
        "USLT": "lyrics",
        "SYLT": "lyrics",
    }
    tags: dict[str, str] = {}
    position = 0
    while position + 10 <= len(data):
        frame_id_bytes = data[position:position + 4]
        if not frame_id_bytes.strip(b"\x00"):
            break
        try:
            frame_id = frame_id_bytes.decode("ascii")
        except UnicodeDecodeError:
            break
        if not re.fullmatch(r"[A-Z0-9]{4}", frame_id):
            break

        raw_size = data[position + 4:position + 8]
        frame_size = _synchsafe_to_int(raw_size) if version == 4 else int.from_bytes(raw_size, "big")
        if frame_size <= 0:
            break
        body = data[position + 10:position + 10 + frame_size]
        position += 10 + frame_size

        normalized_key = frame_map.get(frame_id)
        if not normalized_key or not body:
            continue
        if frame_id == "USLT":
            value = _decode_id3_uslt_body(body)
        elif frame_id == "SYLT":
            value = _decode_id3_sylt_body(body)
        else:
            value = _decode_id3_text_body(body)
        if value:
            tags[normalized_key] = value
    return tags


def _read_riff_info_tags(audio_path: Path) -> dict[str, str]:
    info_map = {
        "INAM": "title",
        "IART": "artist",
        "IPRD": "album",
        "IPRT": "track",
        "ICRD": "date",
        "ILYR": "lyrics",
    }
    tags: dict[str, str] = {}
    try:
        with audio_path.open("rb") as file:
            if file.read(4) != b"RIFF":
                return {}
            _riff_size = int.from_bytes(file.read(4), "little")
            if file.read(4) != b"WAVE":
                return {}
            while True:
                header = file.read(8)
                if len(header) != 8:
                    break
                chunk_id = header[:4]
                chunk_size = int.from_bytes(header[4:8], "little")
                if chunk_id == b"LIST" and chunk_size >= 4 and chunk_size <= 2 * 1024 * 1024:
                    body = file.read(chunk_size)
                    if body[:4] == b"INFO":
                        _read_riff_info_body(body[4:], info_map, tags)
                else:
                    file.seek(chunk_size, os.SEEK_CUR)
                if chunk_size % 2:
                    file.seek(1, os.SEEK_CUR)
    except OSError:
        return {}
    return tags


def _read_riff_info_body(body: bytes, info_map: dict[str, str], tags: dict[str, str]) -> None:
    position = 0
    while position + 8 <= len(body):
        chunk_id = body[position:position + 4].decode("latin1")
        chunk_size = int.from_bytes(body[position + 4:position + 8], "little")
        value = body[position + 8:position + 8 + chunk_size]
        normalized_key = info_map.get(chunk_id)
        if normalized_key:
            decoded = _decode_legacy_text_bytes(value)
            if decoded:
                tags[normalized_key] = decoded
        position += 8 + chunk_size + (chunk_size % 2)


def _merge_embedded_tags(probed_tags: dict[str, str], raw_tags: dict[str, str]) -> dict[str, str]:
    merged = dict(probed_tags)
    for key, value in raw_tags.items():
        if not value:
            continue
        current = merged.get(key)
        if current is None or _looks_garbled(current) or _text_score(value) > _text_score(current) + 3:
            merged[key] = value
    return merged


def _repair_embedded_tags(probed_tags: dict[str, str]) -> dict[str, str]:
    return {key: _repair_latin1_mojibake(value) for key, value in probed_tags.items() if value}


def _record_needs_text_repair(record: dict[str, Any]) -> bool:
    track = record.get("track")
    if not isinstance(track, dict):
        return True
    for key in ("title", "artist_name", "album_name", "album_artist"):
        value = track.get(key)
        if isinstance(value, str) and _looks_garbled(value):
            return True
    return False


def _repair_cached_record(audio_path: Path, record: dict[str, Any]) -> dict[str, Any]:
    track = record.get("track")
    if not isinstance(track, dict):
        return record

    repaired = dict(record)
    repaired_track = dict(track)
    repaired["track"] = repaired_track

    raw_tags = _read_embedded_text_tags(audio_path)
    sidecar_tags = _read_sidecar_tags(audio_path)
    tags = {**raw_tags, **sidecar_tags}
    filename_artist, filename_title = _artist_title_from_filename(audio_path.stem)

    current_title = _clean_or_none(str(repaired_track.get("title", "")))
    current_artist = _clean_or_none(str(repaired_track.get("artist_name", "")))
    current_album = _clean_or_none(str(repaired_track.get("album_name", "")))
    current_album_artist = _clean_or_none(str(repaired_track.get("album_artist", "")))

    tag_title = _clean_or_none(tags.get("title"))
    tag_artist = _clean_or_none(tags.get("artist"))
    tag_album = _clean_or_none(tags.get("album"))
    tag_album_artist = _clean_or_none(tags.get("album_artist") or tags.get("albumartist"))

    title = current_title or tag_title or filename_title or _title_from_filename(audio_path.stem)
    if current_title is None and filename_artist and (current_artist is None or len(current_artist) <= 2):
        artist = tag_artist or filename_artist
    else:
        artist = current_artist or tag_artist or filename_artist
    album = current_album or tag_album or audio_path.parent.name
    album_artist = current_album_artist or tag_album_artist or artist

    if title:
        repaired_track["title"] = title
    if artist:
        repaired_track["artist_name"] = artist
    if album:
        repaired_track["album_name"] = album
    if album_artist:
        repaired_track["album_artist"] = album_artist
    repaired_track["album_key"] = f"{repaired_track['album_artist'].casefold()}\n{repaired_track['album_name'].casefold()}"
    return repaired


def _decode_id3_uslt_body(body: bytes) -> str | None:
    if len(body) < 5:
        return None
    encoding = body[0]
    payload = body[4:]
    separator = b"\x00\x00" if encoding in (1, 2) else b"\x00"
    parts = payload.split(separator, 1)
    lyrics_payload = parts[1] if len(parts) == 2 else payload
    return _decode_id3_text_payload(encoding, lyrics_payload)


def _decode_id3_sylt_body(body: bytes) -> str | None:
    if len(body) < 7:
        return None
    encoding = body[0]
    payload = body[6:]
    separator = b"\x00\x00" if encoding in (1, 2) else b"\x00"
    parts = payload.split(separator, 1)
    syllable_payload = parts[1] if len(parts) == 2 else payload
    lines: list[str] = []
    position = 0
    while position < len(syllable_payload):
        next_separator = syllable_payload.find(separator, position)
        if next_separator < 0:
            break
        text_payload = syllable_payload[position:next_separator]
        text = _decode_id3_text_payload(encoding, text_payload)
        if text:
            lines.append(text)
        position = next_separator + len(separator) + 4
    if lines:
        return "\n".join(lines)
    return _decode_id3_text_payload(encoding, syllable_payload)


def _decode_id3_text_body(body: bytes) -> str | None:
    encoding = body[0]
    return _decode_id3_text_payload(encoding, body[1:])


def _decode_id3_text_payload(encoding: int, payload: bytes) -> str | None:
    if encoding == 1:
        return _clean_decoded_text(_decode_with(payload, "utf-16"))
    if encoding == 2:
        return _clean_decoded_text(_decode_with(payload, "utf-16-be"))
    if encoding == 3:
        return _clean_decoded_text(_decode_with(payload, "utf-8"))
    return _decode_legacy_text_bytes(payload)


def _decode_legacy_text_bytes(value: bytes) -> str | None:
    payload = value.strip(b"\x00 \r\n\t")
    if not payload:
        return None
    candidates = [
        _decode_with(payload, "utf-8-sig"),
        _decode_with(payload, "gb18030"),
        _decode_with(payload, "big5"),
        _decode_with(payload, "latin1"),
    ]
    candidates = [_clean_decoded_text(candidate) for candidate in candidates if candidate is not None]
    candidates = [candidate for candidate in candidates if candidate]
    if not candidates:
        return None
    return max(candidates, key=_text_score)


def _decode_with(value: bytes, encoding: str) -> str | None:
    try:
        return value.decode(encoding)
    except UnicodeDecodeError:
        return None


def _clean_decoded_text(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = value.replace("\x00", "").strip()
    return cleaned or None


def _repair_latin1_mojibake(value: str) -> str:
    if not value:
        return value
    candidates = [value]
    for source_encoding in ("latin1", "cp1252"):
        try:
            raw = value.encode(source_encoding)
        except UnicodeEncodeError:
            continue
        for target_encoding in ("utf-8", "gb18030"):
            decoded = _decode_with(raw, target_encoding)
            if decoded:
                candidates.append(decoded)
    return max(candidates, key=_text_score)


def _clean_or_none(value: str | None) -> str | None:
    if not value:
        return None
    repaired = _repair_latin1_mojibake(value.strip())
    if not repaired or _looks_garbled(repaired):
        return None
    return repaired


def _looks_garbled(value: str) -> bool:
    if "\ufffd" in value:
        return True
    if "??" in value or re.search(r"[^\W\d_]\?[^\W\d_]", value, flags=re.UNICODE):
        return True
    return _text_score(value) < -6


def _text_score(value: str) -> int:
    if not value:
        return -100
    score = 0
    mojibake_markers = "ÃÂÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ"
    for character in value:
        codepoint = ord(character)
        if character == "\ufffd":
            score -= 12
        elif character in mojibake_markers:
            score -= 3
        elif character in "\r\n\t":
            score -= 2
        elif codepoint < 32:
            score -= 8
        elif "\u4e00" <= character <= "\u9fff":
            score += 3
        elif character.isalpha() or character.isdigit():
            score += 1
        elif character in " -_.,'()[]&/·:":
            score += 0
        else:
            score -= 1
    return score


def _synchsafe_to_int(value: bytes) -> int:
    total = 0
    for byte in value:
        total = (total << 7) | (byte & 0x7F)
    return total


def _title_from_filename(stem: str) -> str:
    title = re.sub(r"^\s*\d{1,3}\s*[-_. ]+\s*", "", stem).strip()
    return title or stem


def _artist_title_from_filename(stem: str) -> tuple[str | None, str | None]:
    cleaned = re.sub(r"^\s*\d{1,3}\s*[-_. ]+\s*", "", stem).strip()
    for separator in (" - ", " – ", " — "):
        if separator not in cleaned:
            continue
        artist, title = cleaned.split(separator, 1)
        artist = artist.strip()
        title = title.strip()
        if artist and title:
            return artist, title
    if "-" in cleaned:
        artist, title = cleaned.rsplit("-", 1)
        artist = artist.strip()
        title = title.strip()
        if artist and title:
            return artist, title
    return None, cleaned or None


def _number_from_filename(stem: str) -> int:
    match = re.match(r"^\s*(\d{1,3})", stem)
    return int(match.group(1)) if match else 0


def _tag_number(value: str | None, fallback: int) -> int:
    if value:
        match = re.search(r"\d+", value)
        if match:
            return int(match.group())
    return fallback


def _release_date(value: str | None, modified_time: float) -> str:
    if value:
        match = re.match(r"^(\d{4})(?:[-/.](\d{1,2}))?(?:[-/.](\d{1,2}))?", value)
        if match:
            year = int(match.group(1))
            month = int(match.group(2) or 1)
            day = int(match.group(3) or 1)
            try:
                return datetime(year, month, day, tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")
            except ValueError:
                pass
    return datetime.fromtimestamp(modified_time, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def _read_lyrics(audio_path: Path, embedded_tags: dict[str, str] | None = None) -> str | None:
    embedded_lyrics = _read_embedded_lyrics(audio_path, embedded_tags or {})
    if embedded_lyrics:
        return embedded_lyrics

    for extension in (".lrc", ".txt"):
        candidate = audio_path.with_suffix(extension)
        if not candidate.is_file() or candidate.stat().st_size > 1024 * 1024:
            continue
        try:
            return candidate.read_text(encoding="utf-8-sig").strip() or None
        except UnicodeDecodeError:
            try:
                return candidate.read_text(encoding="gb18030").strip() or None
            except UnicodeDecodeError:
                continue
    return None


def _read_embedded_lyrics(audio_path: Path, embedded_tags: dict[str, str]) -> str | None:
    for key, value in embedded_tags.items():
        normalized_key = key.strip().casefold()
        if normalized_key in LYRICS_TAG_KEYS:
            cleaned = _clean_lyrics_text(value)
            if cleaned:
                return cleaned

    raw_tags = _read_embedded_text_tags(audio_path)
    for key, value in raw_tags.items():
        if key.casefold() == "lyrics":
            cleaned = _clean_lyrics_text(value)
            if cleaned:
                return cleaned
    return None


def _clean_lyrics_text(value: str | None) -> str | None:
    if not value:
        return None
    cleaned = _repair_latin1_mojibake(value).replace("\r\n", "\n").replace("\r", "\n").strip()
    if not cleaned or _looks_garbled(cleaned):
        return None
    return cleaned


def _is_truthy(value: str | None) -> bool:
    return value is not None and value.casefold() in {"1", "true", "yes", "explicit"}


def _atomic_write_json(path: Path, payload: Any) -> None:
    temporary = path.with_suffix(f"{path.suffix}.tmp")
    with temporary.open("w", encoding="utf-8") as file:
        json.dump(payload, file, ensure_ascii=False, separators=(",", ":"))
        file.flush()
        os.fsync(file.fileno())
    temporary.replace(path)
