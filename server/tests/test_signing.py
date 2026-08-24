import unittest

from server.ownmusic.signing import create_signature, verify_signature


class SigningTests(unittest.TestCase):
    def test_valid_signature(self) -> None:
        secret = b"a" * 32
        signature = create_signature(secret, "track-id", 2_000)

        self.assertTrue(verify_signature(secret, "track-id", 2_000, signature, now=1_000))

    def test_expired_or_modified_signature_is_rejected(self) -> None:
        secret = b"a" * 32
        signature = create_signature(secret, "track-id", 2_000)

        self.assertFalse(verify_signature(secret, "track-id", 2_000, signature, now=2_000))
        self.assertFalse(verify_signature(secret, "other-track", 2_000, signature, now=1_000))


if __name__ == "__main__":
    unittest.main()
