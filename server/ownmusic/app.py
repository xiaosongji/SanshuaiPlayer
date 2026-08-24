from __future__ import annotations

import signal
import ssl
import threading
from contextlib import suppress

from .config import Config
from .http_api import MusicHTTPServer
from .scanner import CatalogRepository, MusicScanner


def main() -> None:
    config = Config.from_environment()
    repositories = _repositories_for_config(config)

    stop_event = threading.Event()
    scan_thread = threading.Thread(
        target=_scan_loop,
        args=(repositories, config.scan_interval_seconds, stop_event),
        name="music-scanner",
        daemon=True,
    )
    scan_thread.start()

    server = MusicHTTPServer((config.listen_host, config.listen_port), config, repositories)
    if config.tls_certificate_file and config.tls_private_key_file:
        tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_context.minimum_version = ssl.TLSVersion.TLSv1_2
        tls_context.load_cert_chain(
            certfile=config.tls_certificate_file,
            keyfile=config.tls_private_key_file,
        )
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)

    def stop_server(_signal: int, _frame: object) -> None:
        stop_event.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop_server)
    signal.signal(signal.SIGINT, stop_server)
    scheme = "https" if config.tls_certificate_file else "http"
    print(f"Own Music listening on {scheme}://{config.listen_host}:{config.listen_port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        stop_event.set()
        server.server_close()
        scan_thread.join(timeout=2)


def _repositories_for_config(config: Config) -> dict[str, CatalogRepository]:
    accounts = config.accounts or ()
    if not accounts:
        return {config.account_name or config.api_username: CatalogRepository(MusicScanner(config))}
    return {
        account.username: CatalogRepository(MusicScanner(config.for_account(account)))
        for account in accounts
    }


def _scan_loop(repositories: dict[str, CatalogRepository], interval: int, stop_event: threading.Event) -> None:
    while not stop_event.is_set():
        for repository in repositories.values():
            with suppress(Exception):
                repository.refresh()
        if stop_event.wait(interval):
            return


if __name__ == "__main__":
    main()
