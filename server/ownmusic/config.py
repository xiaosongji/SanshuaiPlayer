from __future__ import annotations

import os
import re
import secrets
from dataclasses import dataclass, replace
from pathlib import Path
from urllib.parse import urlparse


@dataclass(frozen=True)
class AccountConfig:
    username: str
    password: str
    music_root: Path
    data_root: Path


@dataclass(frozen=True)
class Config:
    music_root: Path
    data_root: Path
    public_base_url: str
    signing_secret: bytes
    api_username: str
    api_password: str
    artist_name: str
    api_credentials: tuple[tuple[str, str], ...] = ()
    accounts: tuple[AccountConfig, ...] = ()
    account_name: str = ""
    scan_interval_seconds: int = 15
    stable_age_seconds: int = 30
    playback_url_ttl_seconds: int = 3600
    online_lyrics_enabled: bool = False
    online_lyrics_base_url: str = "https://lrclib.net"
    online_lyrics_timeout_seconds: int = 6
    online_lyrics_lookup_limit_per_scan: int = 50
    listen_host: str = "0.0.0.0"
    listen_port: int = 8080
    tls_certificate_file: Path | None = None
    tls_private_key_file: Path | None = None

    @classmethod
    def from_environment(cls) -> "Config":
        music_root = Path(os.getenv("MUSIC_ROOT", "/music")).resolve()
        data_root = Path(os.getenv("DATA_ROOT", "/data")).resolve()
        public_base_url = os.getenv("PUBLIC_BASE_URL", "").rstrip("/")
        signing_secret = os.getenv("SIGNING_SECRET", "").encode("utf-8")
        api_username = os.getenv("API_USERNAME", "").strip()
        api_password = os.getenv("API_PASSWORD", "")
        accounts = _api_accounts(api_username, api_password, music_root, data_root)
        api_credentials = tuple((account.username, account.password) for account in accounts)

        parsed_url = urlparse(public_base_url)
        if parsed_url.scheme != "https" or not parsed_url.netloc:
            raise ValueError("PUBLIC_BASE_URL must be a valid HTTPS URL")
        if len(signing_secret) < 32:
            raise ValueError("SIGNING_SECRET must contain at least 32 characters")
        if not accounts:
            raise ValueError("API_USERNAME/API_PASSWORD or API_CREDENTIALS must be configured")
        for account in accounts:
            if not account.music_root.is_dir():
                raise ValueError(f"music root for {account.username} is not a readable directory: {account.music_root}")

        data_root.mkdir(parents=True, exist_ok=True)
        for account in accounts:
            account.data_root.mkdir(parents=True, exist_ok=True)
        tls_certificate_file = _optional_file("TLS_CERT_FILE")
        tls_private_key_file = _optional_file("TLS_KEY_FILE")
        if (tls_certificate_file is None) != (tls_private_key_file is None):
            raise ValueError("TLS_CERT_FILE and TLS_KEY_FILE must be configured together")
        return cls(
            music_root=music_root,
            data_root=data_root,
            public_base_url=public_base_url,
            signing_secret=signing_secret,
            api_username=api_username,
            api_password=api_password,
            artist_name=os.getenv("ARTIST_NAME", "我的音乐").strip() or "我的音乐",
            api_credentials=api_credentials,
            accounts=accounts,
            account_name=accounts[0].username,
            scan_interval_seconds=_positive_int("SCAN_INTERVAL_SECONDS", 15),
            stable_age_seconds=_positive_int("STABLE_AGE_SECONDS", 30),
            playback_url_ttl_seconds=_positive_int("PLAYBACK_URL_TTL_SECONDS", 3600),
            online_lyrics_enabled=_truthy("ONLINE_LYRICS_ENABLED", False),
            online_lyrics_base_url=os.getenv("ONLINE_LYRICS_BASE_URL", "https://lrclib.net").rstrip("/"),
            online_lyrics_timeout_seconds=_positive_int("ONLINE_LYRICS_TIMEOUT_SECONDS", 6),
            online_lyrics_lookup_limit_per_scan=_positive_int("ONLINE_LYRICS_LOOKUP_LIMIT_PER_SCAN", 50),
            listen_host=os.getenv("LISTEN_HOST", "0.0.0.0"),
            listen_port=_positive_int("LISTEN_PORT", 8080),
            tls_certificate_file=tls_certificate_file,
            tls_private_key_file=tls_private_key_file,
        )

    def for_account(self, account: AccountConfig) -> "Config":
        return replace(
            self,
            music_root=account.music_root,
            data_root=account.data_root,
            api_username=account.username,
            api_password=account.password,
            api_credentials=((account.username, account.password),),
            accounts=(account,),
            account_name=account.username,
        )

    def account_for_credentials(self, username: str, password: str) -> AccountConfig | None:
        accounts = self.accounts or tuple(
            AccountConfig(expected_username, expected_password, self.music_root, self.data_root)
            for expected_username, expected_password in (self.api_credentials or ((self.api_username, self.api_password),))
        )
        for account in accounts:
            username_matches = secrets.compare_digest(username, account.username)
            password_matches = secrets.compare_digest(password, account.password)
            if username_matches and password_matches:
                return account
        return None

    def credentials_match(self, username: str, password: str) -> bool:
        return self.account_for_credentials(username, password) is not None


def _api_accounts(
    api_username: str,
    api_password: str,
    default_music_root: Path,
    default_data_root: Path,
) -> tuple[AccountConfig, ...]:
    accounts: list[AccountConfig] = []
    if api_username and api_password:
        accounts.append(AccountConfig(api_username, api_password, default_music_root, default_data_root))

    for raw_credential in os.getenv("API_CREDENTIALS", "").split(","):
        raw_credential = raw_credential.strip()
        if not raw_credential:
            continue
        username, separator, password_and_root = raw_credential.partition(":")
        username = username.strip()
        password, root_separator, custom_root = password_and_root.partition(":")
        if not separator or not username or not password:
            raise ValueError("API_CREDENTIALS entries must use username:password or username:password:/music/root")
        music_root = Path(custom_root).resolve() if root_separator else default_music_root
        data_root = _account_data_root(default_data_root, username) if root_separator else default_data_root
        candidate = AccountConfig(username, password, music_root, data_root)
        if not any(account.username == candidate.username and account.password == candidate.password for account in accounts):
            accounts.append(candidate)
    return tuple(accounts)


def _account_data_root(default_data_root: Path, username: str) -> Path:
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "_", username).strip("._") or "account"
    return default_data_root / "accounts" / slug


def _positive_int(name: str, default: int) -> int:
    raw_value = os.getenv(name, str(default))
    value = int(raw_value)
    if value <= 0:
        raise ValueError(f"{name} must be greater than zero")
    return value


def _truthy(name: str, default: bool) -> bool:
    raw_value = os.getenv(name)
    if raw_value is None:
        return default
    return raw_value.strip().casefold() in {"1", "true", "yes", "on"}


def _optional_file(name: str) -> Path | None:
    raw_value = os.getenv(name, "").strip()
    if not raw_value:
        return None
    path = Path(raw_value).resolve()
    if not path.is_file():
        raise ValueError(f"{name} is not a readable file: {path}")
    return path
