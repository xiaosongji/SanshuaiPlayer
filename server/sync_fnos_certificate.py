from __future__ import annotations

import json
import os
import subprocess
import sys
from argparse import ArgumentParser
from pathlib import Path


HOSTNAME = os.getenv("OWNMUSIC_HOSTNAME", "music.example.com")
CERTIFICATE_CONFIG = Path("/usr/trim/etc/network_gateway_cert.conf")
RUNTIME_ROOT = Path(os.getenv("OWNMUSIC_RUNTIME_ROOT", "/opt/ownmusic/runtime"))
CERTIFICATE_LINK = RUNTIME_ROOT / "fullchain.crt"
PRIVATE_KEY_LINK = RUNTIME_ROOT / "private.key"


def main() -> None:
    parser = ArgumentParser()
    parser.add_argument("--restart-service")
    args = parser.parse_args()

    changed = sync_certificate()
    if args.restart_service:
        if changed:
            subprocess.run(["/bin/systemctl", "try-restart", args.restart_service], check=True)
            print(f"certificate changed; restarted {args.restart_service}")
        else:
            print("certificate unchanged; service restart skipped")


def sync_certificate() -> bool:
    entries = json.loads(CERTIFICATE_CONFIG.read_text(encoding="utf-8"))
    entry = next((item for item in entries if item.get("host") == HOSTNAME), None)
    if entry is None:
        raise RuntimeError(f"fnOS certificate is not configured for {HOSTNAME}")

    certificate = Path(entry["cert"]).resolve()
    private_key = Path(entry["key"]).resolve()
    if not certificate.is_file() or not private_key.is_file():
        raise RuntimeError("fnOS certificate files are missing")

    RUNTIME_ROOT.mkdir(parents=True, exist_ok=True)
    certificate_changed = replace_symlink(CERTIFICATE_LINK, certificate)
    key_changed = replace_symlink(PRIVATE_KEY_LINK, private_key)
    return certificate_changed or key_changed


def replace_symlink(link: Path, target: Path) -> bool:
    if current_target(link) == target:
        return False

    temporary_link = link.with_name(f".{link.name}.tmp")
    temporary_link.unlink(missing_ok=True)
    temporary_link.symlink_to(target)
    temporary_link.replace(link)
    return True


def current_target(link: Path) -> Path | None:
    try:
        return link.resolve(strict=True)
    except FileNotFoundError:
        return None
    except OSError as error:
        print(f"certificate link check failed for {link}: {error}", file=sys.stderr)
        return None


if __name__ == "__main__":
    main()
