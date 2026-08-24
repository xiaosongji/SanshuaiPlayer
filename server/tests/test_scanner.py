from __future__ import annotations

import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from server.ownmusic.config import Config
from server.ownmusic.scanner import MusicScanner, is_natively_playable_on_ios, transcode_profile


class ScannerTests(unittest.TestCase):
    def test_empty_snapshot_has_a_client_decodable_catalog_shape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()

            snapshot = MusicScanner(make_config(music_root, data_root)).empty_snapshot()

            self.assertEqual(snapshot.catalog["artist"]["name"], "测试艺人")
            self.assertEqual(snapshot.catalog["albums"], [])
            self.assertEqual(snapshot.catalog["tracks"], [])
            self.assertEqual(snapshot.catalog["featuredAlbumIDs"], [])

    def test_scan_builds_album_catalog_without_exposing_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            album_root = music_root / "我的专辑"
            album_root.mkdir(parents=True)
            data_root.mkdir()

            audio_path = album_root / "01 - 第一首.mp3"
            audio_path.write_bytes(b"fake-mp3-content")
            audio_path.with_suffix(".lrc").write_text("[00:00.00]第一句", encoding="utf-8")
            (album_root / "cover.jpg").write_bytes(b"fake-cover")
            old_time = time.time() - 120
            for path in album_root.iterdir():
                os.utime(path, (old_time, old_time))

            scanner = MusicScanner(
                make_config(music_root, data_root),
                probe=lambda _: {
                    "duration": 185.5,
                    "tags": {
                        "title": "第一首",
                        "artist": "测试艺人",
                        "album": "我的专辑",
                        "album_artist": "测试艺人",
                        "track": "1/10",
                        "date": "2026-06-22",
                    },
                    "has_artwork": False,
                },
            )

            snapshot = scanner.scan()

            self.assertEqual(snapshot.catalog["artist"]["name"], "测试艺人")
            self.assertEqual(len(snapshot.catalog["albums"]), 1)
            self.assertEqual(len(snapshot.catalog["tracks"]), 1)
            track = snapshot.catalog["tracks"][0]
            self.assertEqual(track["title"], "第一首")
            self.assertEqual(track["lyrics"], "[00:00.00]第一句")
            self.assertNotIn("source_relative", track)
            self.assertNotIn(str(music_root), json.dumps(snapshot.catalog, ensure_ascii=False))
            self.assertTrue(track["artworkURL"].startswith("https://music.example.com/v1/artwork/"))

    def test_embedded_lyrics_from_probe_tags_are_preferred_over_sidecar_lyrics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()
            audio_path = music_root / "01 - 内嵌歌词.mp3"
            audio_path.write_bytes(b"fake-mp3-content")
            audio_path.with_suffix(".lrc").write_text("[00:00.00]外置歌词", encoding="utf-8")
            old_time = time.time() - 120
            for path in music_root.iterdir():
                os.utime(path, (old_time, old_time))

            scanner = MusicScanner(
                make_config(music_root, data_root),
                probe=lambda _: {
                    "duration": 60,
                    "tags": {"title": "内嵌歌词", "lyrics": "[00:00.00]内嵌歌词"},
                    "has_artwork": False,
                },
            )

            snapshot = scanner.scan()

            track = snapshot.catalog["tracks"][0]
            self.assertEqual(track["lyrics"], "[00:00.00]内嵌歌词")

    def test_mp3_uslt_frame_is_used_when_probe_tags_do_not_include_lyrics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()
            audio_path = music_root / "01 - USLT.mp3"
            audio_path.write_bytes(make_id3v23_uslt_mp3("[00:00.00]原始 ID3 歌词"))
            old_time = time.time() - 120
            os.utime(audio_path, (old_time, old_time))

            scanner = MusicScanner(
                make_config(music_root, data_root),
                probe=lambda _: {
                    "duration": 60,
                    "tags": {"title": "USLT"},
                    "has_artwork": False,
                },
            )

            snapshot = scanner.scan()

            track = snapshot.catalog["tracks"][0]
            self.assertEqual(track["lyrics"], "[00:00.00]原始 ID3 歌词")

    def test_online_lyrics_fill_missing_lyrics_and_are_cached(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()
            audio_path = music_root / "01 - Shape of You.mp3"
            audio_path.write_bytes(b"fake-mp3-content")
            old_time = time.time() - 120
            os.utime(audio_path, (old_time, old_time))

            calls: list[tuple[str, str, str, float]] = []

            def lookup(title: str, artist: str, album: str, duration: float) -> str:
                calls.append((title, artist, album, duration))
                return "[00:09.65]The club isn't the best place to find a lover"

            scanner = MusicScanner(
                make_config(music_root, data_root, online_lyrics_enabled=True),
                probe=lambda _: {
                    "duration": 234,
                    "tags": {"title": "Shape of You", "artist": "Ed Sheeran", "album": "Divide"},
                    "has_artwork": False,
                },
                online_lyrics_lookup=lookup,
            )

            first_snapshot = scanner.scan()
            second_snapshot = scanner.scan()

            self.assertEqual(len(calls), 1)
            self.assertEqual(first_snapshot.catalog["tracks"][0]["lyrics"], "[00:09.65]The club isn't the best place to find a lover")
            self.assertEqual(second_snapshot.catalog["tracks"][0]["lyrics"], "[00:09.65]The club isn't the best place to find a lover")
            cache_path = data_root / "lyrics-cache.json"
            self.assertTrue(cache_path.is_file())

    def test_online_lyrics_are_not_requested_when_local_lyrics_exist(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()
            audio_path = music_root / "01 - Local.mp3"
            audio_path.write_bytes(b"fake-mp3-content")
            audio_path.with_suffix(".lrc").write_text("[00:00.00]本地歌词", encoding="utf-8")
            old_time = time.time() - 120
            for path in music_root.iterdir():
                os.utime(path, (old_time, old_time))

            def lookup(title: str, artist: str, album: str, duration: float) -> str:
                raise AssertionError("online lyrics lookup should not be called")

            scanner = MusicScanner(
                make_config(music_root, data_root, online_lyrics_enabled=True),
                probe=lambda _: {
                    "duration": 60,
                    "tags": {"title": "Local", "artist": "测试艺人"},
                    "has_artwork": False,
                },
                online_lyrics_lookup=lookup,
            )

            snapshot = scanner.scan()

            self.assertEqual(snapshot.catalog["tracks"][0]["lyrics"], "[00:00.00]本地歌词")

    def test_duplicate_content_only_appears_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()
            for name in ("01 - A.mp3", "02 - B.mp3"):
                path = music_root / name
                path.write_bytes(b"same-content")
                old_time = time.time() - 120
                os.utime(path, (old_time, old_time))

            scanner = MusicScanner(
                make_config(music_root, data_root),
                probe=lambda _: {"duration": 60, "tags": {}, "has_artwork": False},
            )

            snapshot = scanner.scan()

            self.assertEqual(len(snapshot.catalog["tracks"]), 1)
            self.assertEqual(len(snapshot.errors), 1)

    def test_gb18030_wav_info_tags_replace_garbled_probe_tags(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()
            audio_path = music_root / "a-lin(黄丽玲)-天若有情.wav"
            audio_path.write_bytes(make_wav_with_info({"INAM": "天若有情", "IART": "A-Lin(黄丽玲)"}))
            old_time = time.time() - 120
            os.utime(audio_path, (old_time, old_time))

            scanner = MusicScanner(
                make_config(music_root, data_root),
                probe=lambda _: {
                    "duration": 60,
                    "tags": {"title": "lin(������)-��������", "artist": "a"},
                    "has_artwork": False,
                },
            )

            snapshot = scanner.scan()

            track = snapshot.catalog["tracks"][0]
            self.assertEqual(track["title"], "天若有情")
            self.assertEqual(track["artistName"], "A-Lin(黄丽玲)")

    def test_cellular_mp3_transcode_failure_falls_back_to_original_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()
            audio_path = music_root / "Fallback.wav"
            audio_path.write_bytes(b"original-wav")
            old_time = time.time() - 120
            os.utime(audio_path, (old_time, old_time))

            def transcode(_: Path, __: Path, profile: str) -> None:
                self.assertEqual(profile, "cellular_mp3")
                raise RuntimeError("MP3 encoder unavailable")

            scanner = MusicScanner(
                make_config(music_root, data_root),
                probe=lambda _: {
                    "duration": 60,
                    "tags": {"title": "Fallback"},
                    "audio_codec": "pcm_s16le",
                    "has_artwork": False,
                },
                transcoder=transcode,
            )

            snapshot = scanner.scan()

            self.assertEqual(len(snapshot.catalog["tracks"]), 1)
            track_id = snapshot.catalog["tracks"][0]["id"]
            self.assertEqual(snapshot.cellular_media_paths[track_id], audio_path.resolve())
            self.assertEqual(snapshot.errors, [])

    def test_garbled_tags_fall_back_to_artist_and_title_from_filename(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()
            audio_path = music_root / "a-lin(黄丽玲)-天若有情.mp3"
            audio_path.write_bytes(b"fake-mp3-content")
            old_time = time.time() - 120
            os.utime(audio_path, (old_time, old_time))

            scanner = MusicScanner(
                make_config(music_root, data_root),
                probe=lambda _: {
                    "duration": 60,
                    "tags": {"title": "lin(������)-��������", "artist": "a"},
                    "has_artwork": False,
                },
            )

            snapshot = scanner.scan()

            track = snapshot.catalog["tracks"][0]
            self.assertEqual(track["title"], "天若有情")
            self.assertEqual(track["artistName"], "a-lin(黄丽玲)")

    def test_non_native_formats_are_scanned_and_cached_in_ios_compatible_formats(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()
            sources = (music_root / "Lossless.ape", music_root / "Podcast.opus")
            sources[0].write_bytes(b"fake-ape-content")
            sources[1].write_bytes(b"fake-opus-content")
            old_time = time.time() - 120
            for source in sources:
                os.utime(source, (old_time, old_time))

            calls: list[tuple[str, str]] = []

            def transcode(source: Path, destination: Path, profile: str) -> None:
                calls.append((source.suffix.lower(), profile))
                destination.write_bytes(f"converted-{profile}".encode("ascii"))

            scanner = MusicScanner(
                make_config(music_root, data_root),
                probe=lambda path: {
                    "duration": 60,
                    "tags": {"title": path.stem},
                    "audio_codec": "ape" if path.suffix.lower() == ".ape" else "opus",
                    "has_artwork": False,
                },
                transcoder=transcode,
            )

            snapshot = scanner.scan()

            self.assertEqual(len(snapshot.catalog["tracks"]), 2)
            self.assertEqual(
                set(calls),
                {
                    (".ape", "lossless"),
                    (".ape", "cellular_mp3"),
                    (".opus", "compatible"),
                    (".opus", "cellular_mp3"),
                },
            )
            self.assertEqual({path.suffix for path in snapshot.media_paths.values()}, {".flac", ".m4a"})
            self.assertEqual({path.suffix for path in snapshot.cellular_media_paths.values()}, {".mp3"})
            self.assertTrue(all(path.is_relative_to(data_root.resolve()) for path in snapshot.media_paths.values()))
            self.assertNotIn(str(music_root), json.dumps(snapshot.catalog, ensure_ascii=False))

    def test_transcode_profile_preserves_lossless_codecs(self) -> None:
        for codec in ("ape", "wavpack", "tta", "pcm_s24le"):
            self.assertEqual(transcode_profile(codec), "lossless")
        self.assertEqual(transcode_profile("dsd_lsbf_planar"), "high_resolution")
        for codec in ("vorbis", "opus", "wmav2", "mpc8"):
            self.assertEqual(transcode_profile(codec), "compatible")

    def test_native_container_with_non_native_codec_is_transcoded(self) -> None:
        self.assertTrue(is_natively_playable_on_ios(".m4a", "aac"))
        self.assertTrue(is_natively_playable_on_ios(".m4a", "alac"))
        self.assertTrue(is_natively_playable_on_ios(".mp3", "mp3"))
        self.assertTrue(is_natively_playable_on_ios(".flac", "flac"))
        self.assertTrue(is_natively_playable_on_ios(".wav", "pcm_s24le"))
        self.assertFalse(is_natively_playable_on_ios(".m4a", "opus"))
        self.assertFalse(is_natively_playable_on_ios(".mp3", "aac"))
        self.assertFalse(is_natively_playable_on_ios(".wav", "flac"))
        self.assertFalse(is_natively_playable_on_ios(".alac", "alac"))


def make_config(music_root: Path, data_root: Path, online_lyrics_enabled: bool = False) -> Config:
    return Config(
        music_root=music_root.resolve(),
        data_root=data_root.resolve(),
        public_base_url="https://music.example.com",
        signing_secret=b"a" * 32,
        api_username="listener",
        api_password="secret-password",
        artist_name="测试艺人",
        stable_age_seconds=30,
        online_lyrics_enabled=online_lyrics_enabled,
    )


def make_wav_with_info(values: dict[str, str]) -> bytes:
    def chunk(identifier: bytes, payload: bytes) -> bytes:
        padding = b"\x00" if len(payload) % 2 else b""
        return identifier + len(payload).to_bytes(4, "little") + payload + padding

    info_payload = b"INFO"
    for key, value in values.items():
        info_payload += chunk(key.encode("ascii"), value.encode("gb18030") + b"\x00")
    fmt_payload = (1).to_bytes(2, "little") + (1).to_bytes(2, "little")
    fmt_payload += (44100).to_bytes(4, "little") + (88200).to_bytes(4, "little")
    fmt_payload += (2).to_bytes(2, "little") + (16).to_bytes(2, "little")
    data = chunk(b"fmt ", fmt_payload) + chunk(b"LIST", info_payload) + chunk(b"data", b"\x00\x00")
    return b"RIFF" + (len(data) + 4).to_bytes(4, "little") + b"WAVE" + data


def make_id3v23_uslt_mp3(lyrics: str) -> bytes:
    body = b"\x03eng\x00" + lyrics.encode("utf-8")
    frame = b"USLT" + len(body).to_bytes(4, "big") + b"\x00\x00" + body
    header = b"ID3\x03\x00\x00" + synchsafe(len(frame))
    return header + frame + b"fake-mp3-content"


def synchsafe(value: int) -> bytes:
    return bytes(
        (
            (value >> 21) & 0x7F,
            (value >> 14) & 0x7F,
            (value >> 7) & 0x7F,
            value & 0x7F,
        )
    )


if __name__ == "__main__":
    unittest.main()
