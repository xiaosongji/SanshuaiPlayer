from __future__ import annotations

import hashlib
import hmac
import time


def create_signature(secret: bytes, track_id: str, expires: int) -> str:
    message = f"{track_id}\n{expires}".encode("utf-8")
    return hmac.new(secret, message, hashlib.sha256).hexdigest()


def verify_signature(
    secret: bytes,
    track_id: str,
    expires: int,
    signature: str,
    now: int | None = None,
) -> bool:
    current_time = int(time.time()) if now is None else now
    if expires <= current_time:
        return False
    expected = create_signature(secret, track_id, expires)
    return hmac.compare_digest(expected, signature)
