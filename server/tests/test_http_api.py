from __future__ import annotations

import json
import os
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from base64 import b64encode
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from server.ownmusic.config import AccountConfig, Config
from server.ownmusic.http_api import MusicHTTPServer, media_content_type, parse_byte_range
from server.ownmusic.scanner import CatalogRepository, MusicScanner


def basic_authorization(username: str, password: str) -> str:
    encoded = b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return f"Basic {encoded}"


class HTTPAPITests(unittest.TestCase):
    def test_playback_endpoint_returns_signed_range_capable_url(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()
            audio_path = music_root / "01 - Song.mp3"
            audio_path.write_bytes(bytes(range(100)))
            old_time = time.time() - 120
            os.utime(audio_path, (old_time, old_time))

            config = Config(
                music_root=music_root.resolve(),
                data_root=data_root.resolve(),
                public_base_url="https://music.example.com",
                signing_secret=b"b" * 32,
                api_username="listener",
                api_password="secret-password",
                artist_name="Artist",
                stable_age_seconds=30,
            )
            scanner = MusicScanner(
                config,
                probe=lambda _: {"duration": 10, "tags": {"title": "Song"}, "has_artwork": False},
            )
            repository = CatalogRepository(scanner)
            repository.refresh()
            catalog_bytes, _ = repository.catalog()
            track_id = json.loads(catalog_bytes)["tracks"][0]["id"]

            server = MusicHTTPServer(("127.0.0.1", 0), config, repository)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base_url = f"http://127.0.0.1:{server.server_port}"
            try:
                request = urllib.request.Request(
                    f"{base_url}/v1/tracks/{track_id}/playback",
                    data=b"",
                    headers={"Authorization": basic_authorization("listener", "secret-password")},
                    method="POST",
                )
                with urllib.request.urlopen(request, timeout=3) as response:
                    playback = json.load(response)

                public_url = urlparse(playback["url"])
                range_request = urllib.request.Request(
                    f"{base_url}{public_url.path}?{public_url.query}",
                    headers={"Range": "bytes=10-19"},
                )
                with urllib.request.urlopen(range_request, timeout=3) as response:
                    self.assertEqual(response.status, 206)
                    self.assertEqual(response.headers["Content-Range"], "bytes 10-19/100")
                    self.assertEqual(response.read(), bytes(range(10, 20)))
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_playback_endpoint_signs_and_serves_cellular_mp3_variant(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()
            audio_path = music_root / "01 - Lossless.wav"
            audio_path.write_bytes(b"original-wav")
            old_time = time.time() - 120
            os.utime(audio_path, (old_time, old_time))

            config = Config(
                music_root=music_root.resolve(),
                data_root=data_root.resolve(),
                public_base_url="https://music.example.com",
                signing_secret=b"b" * 32,
                api_username="listener",
                api_password="secret-password",
                artist_name="Artist",
                stable_age_seconds=30,
            )

            def transcode(_source: Path, destination: Path, profile: str) -> None:
                self.assertEqual(profile, "cellular_mp3")
                destination.write_bytes(b"ID3-cellular-mp3")

            scanner = MusicScanner(
                config,
                probe=lambda _: {
                    "duration": 10,
                    "tags": {"title": "Lossless"},
                    "audio_codec": "pcm_s16le",
                    "has_artwork": False,
                },
                transcoder=transcode,
            )
            repository = CatalogRepository(scanner)
            repository.refresh()
            catalog_bytes, _ = repository.catalog()
            track_id = json.loads(catalog_bytes)["tracks"][0]["id"]

            server = MusicHTTPServer(("127.0.0.1", 0), config, repository)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base_url = f"http://127.0.0.1:{server.server_port}"
            try:
                request = urllib.request.Request(
                    f"{base_url}/v1/tracks/{track_id}/playback?format=mp3",
                    data=b"",
                    headers={"Authorization": basic_authorization("listener", "secret-password")},
                    method="POST",
                )
                with urllib.request.urlopen(request, timeout=3) as response:
                    playback = json.load(response)

                public_url = urlparse(playback["url"])
                self.assertEqual(parse_qs(public_url.query)["format"], ["mp3"])
                with urllib.request.urlopen(
                    f"{base_url}{public_url.path}?{public_url.query}", timeout=3
                ) as response:
                    self.assertEqual(response.headers["Content-Type"], "audio/mpeg")
                    self.assertEqual(response.read(), b"ID3-cellular-mp3")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_catalog_requires_valid_basic_authentication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            music_root = root / "music"
            data_root = root / "data"
            music_root.mkdir()
            data_root.mkdir()
            config = Config(
                music_root=music_root.resolve(),
                data_root=data_root.resolve(),
                public_base_url="https://music.example.com",
                signing_secret=b"b" * 32,
                api_username="listener",
                api_password="secret-password",
                artist_name="Artist",
                api_credentials=(("listener", "secret-password"), ("admin", "admin-password")),
            )
            repository = CatalogRepository(MusicScanner(config))
            server = MusicHTTPServer(("127.0.0.1", 0), config, repository)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base_url = f"http://127.0.0.1:{server.server_port}"
            try:
                with self.assertRaises(urllib.error.HTTPError) as context:
                    urllib.request.urlopen(f"{base_url}/v1/catalog", timeout=3)
                self.assertEqual(context.exception.code, 401)

                request = urllib.request.Request(
                    f"{base_url}/v1/catalog",
                    headers={"Authorization": basic_authorization("listener", "secret-password")},
                )
                with urllib.request.urlopen(request, timeout=3) as response:
                    self.assertEqual(response.status, 200)

                admin_request = urllib.request.Request(
                    f"{base_url}/v1/catalog",
                    headers={"Authorization": basic_authorization("admin", "admin-password")},
                )
                with urllib.request.urlopen(admin_request, timeout=3) as response:
                    self.assertEqual(response.status, 200)

                invalid_request = urllib.request.Request(
                    f"{base_url}/v1/catalog",
                    headers={"Authorization": basic_authorization("admin", "wrong-password")},
                )
                with self.assertRaises(urllib.error.HTTPError) as invalid_context:
                    urllib.request.urlopen(invalid_request, timeout=3)
                self.assertEqual(invalid_context.exception.code, 401)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_accounts_are_scoped_to_separate_music_roots(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            old_music_root = root / "Mp3"
            admin_music_root = root / "Mp31"
            data_root = root / "data"
            old_music_root.mkdir()
            admin_music_root.mkdir()
            data_root.mkdir()
            old_audio = old_music_root / "01 - Old Library.mp3"
            admin_audio = admin_music_root / "01 - Admin Library.mp3"
            old_audio.write_bytes(b"old-library")
            admin_audio.write_bytes(b"admin-library")
            old_time = time.time() - 120
            os.utime(old_audio, (old_time, old_time))
            os.utime(admin_audio, (old_time, old_time))

            listener = AccountConfig(
                "listener",
                "secret-password",
                old_music_root.resolve(),
                data_root.resolve(),
            )
            admin = AccountConfig(
                "admin",
                "admin-password",
                admin_music_root.resolve(),
                (data_root / "accounts" / "admin").resolve(),
            )
            config = Config(
                music_root=old_music_root.resolve(),
                data_root=data_root.resolve(),
                public_base_url="https://music.example.com",
                signing_secret=b"b" * 32,
                api_username="listener",
                api_password="secret-password",
                artist_name="Artist",
                api_credentials=(("listener", "secret-password"), ("admin", "admin-password")),
                accounts=(listener, admin),
                account_name="listener",
                stable_age_seconds=30,
            )
            repositories = {}
            for account in config.accounts:
                scanner = MusicScanner(
                    config.for_account(account),
                    probe=lambda path: {"duration": 10, "tags": {"title": path.stem}, "has_artwork": False},
                )
                repository = CatalogRepository(scanner)
                repository.refresh()
                repositories[account.username] = repository

            server = MusicHTTPServer(("127.0.0.1", 0), config, repositories)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base_url = f"http://127.0.0.1:{server.server_port}"
            try:
                listener_request = urllib.request.Request(
                    f"{base_url}/v1/catalog",
                    headers={"Authorization": basic_authorization("listener", "secret-password")},
                )
                with urllib.request.urlopen(listener_request, timeout=3) as response:
                    listener_catalog = json.load(response)

                admin_request = urllib.request.Request(
                    f"{base_url}/v1/catalog",
                    headers={"Authorization": basic_authorization("admin", "admin-password")},
                )
                with urllib.request.urlopen(admin_request, timeout=3) as response:
                    admin_catalog = json.load(response)

                self.assertEqual(listener_catalog["tracks"][0]["title"], "01 - Old Library")
                self.assertEqual(admin_catalog["tracks"][0]["title"], "01 - Admin Library")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_range_parser_supports_open_and_suffix_ranges(self) -> None:
        self.assertEqual(parse_byte_range("bytes=5-", 100), (5, 99))
        self.assertEqual(parse_byte_range("bytes=-10", 100), (90, 99))

    def test_media_type_uses_container_signature_before_filename_suffix(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            mislabeled = Path(temporary_directory) / "renamed.mp3"
            mislabeled.write_bytes(b"\x00\x00\x00\x1cftypM4A \x00\x00\x00\x00")
            self.assertEqual(media_content_type(mislabeled), "audio/mp4")


if __name__ == "__main__":
    unittest.main()
