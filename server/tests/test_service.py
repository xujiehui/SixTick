import base64
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from server.app import ApiError, Service, make_handler


def b64(raw):
    return base64.b64encode(raw).decode()


def box(purpose, content=b"opaque-ciphertext"):
    return {"v": 1, "purpose": purpose, "nonce": b64(b"n" * 12), "ciphertext": b64(content), "tag": b64(b"t" * 16)}


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.clock = [1000.0]
        self.mail = {}
        self.service = Service(":memory:", b"p" * 32, lambda email, code: self.mail.update({email: code}), lambda: self.clock[0])
        self.key = Ed25519PrivateKey.generate()

    def tearDown(self):
        self.service.db.close()

    def call(self, method, path, data=None, session=None):
        return self.service.dispatch(method, "/v1" + path, data, (session or {}).get("token", ""))

    def login(self, email="user@example.com"):
        self.clock[0] += 61
        self.call("POST", "/auth/request", {"email": email})
        return self.call("POST", "/auth/verify", {"email": email, "code": self.mail[email]})

    def proof(self, session, device="a" * 32, epoch=1, key=None):
        message = f'six-tick:authorize:v1:{session["accountId"]}:{session["challenge"]}:{device}:{epoch}'
        return {"deviceId": device, "name": "My device", "platform": "test", "signature": b64((key or self.key).sign(message.encode()))}

    def create(self, session):
        uid = session["accountId"]
        return self.call("POST", "/vault/create", {**self.proof(session), "verifyKey": b64(self.key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)), "recovery": box(f"recovery:{uid}:1"), "payload": box(f"vault:{uid}:1")}, session)

    def assert_error(self, code, func):
        with self.assertRaises(ApiError) as caught:
            func()
        self.assertEqual(caught.exception.code, code)

    def test_login_is_not_decryption_or_device_authorization(self):
        first = self.login()
        self.create(first)
        second = self.login()
        self.assertIsNotNone(self.call("GET", "/vault/info", session=second)["vault"])
        self.assert_error("device_revoked", lambda: self.call("GET", "/vault", session=second))
        self.assert_error("authorization_failed", lambda: self.call("POST", "/devices/authorize", self.proof(second, key=Ed25519PrivateKey.generate()), second))
        self.call("POST", "/devices/authorize", self.proof(second, "b" * 32), second)
        self.assertEqual(self.call("GET", "/vault", session=second)["revision"], 1)

    def test_email_codes_expire_are_one_use_and_lock_after_five_attempts(self):
        self.call("POST", "/auth/request", {"email": "a@example.com"})
        correct = self.mail["a@example.com"]
        wrong = "000000" if correct != "000000" else "111111"
        for _ in range(5):
            self.assert_error("invalid_code", lambda: self.call("POST", "/auth/verify", {"email": "a@example.com", "code": wrong}))
        self.assert_error("invalid_code", lambda: self.call("POST", "/auth/verify", {"email": "a@example.com", "code": correct}))
        self.clock[0] += 61
        self.call("POST", "/auth/request", {"email": "a@example.com"})
        self.clock[0] += 601
        self.assert_error("invalid_code", lambda: self.call("POST", "/auth/verify", {"email": "a@example.com", "code": self.mail["a@example.com"]}))
        self.login()
        self.assert_error("invalid_code", lambda: self.call("POST", "/auth/verify", {"email": "user@example.com", "code": self.mail["user@example.com"]}))

    def test_resend_rate_limit_and_old_code_invalidated(self):
        self.call("POST", "/auth/request", {"email": "a@example.com"})
        self.assert_error("rate_limited", lambda: self.call("POST", "/auth/request", {"email": "a@example.com"}))
        old_digest = self.service.one("SELECT digest FROM challenges")["digest"]
        self.clock[0] += 60
        self.call("POST", "/auth/request", {"email": "a@example.com"})
        self.assertNotEqual(old_digest, self.service.one("SELECT digest FROM challenges")["digest"])

    def test_cas_idempotency_and_cross_account_isolation(self):
        session = self.login()
        self.create(session)
        payload = {"requestId": "r" * 32, "epoch": 1, "revision": 1, "payload": box(f'vault:{session["accountId"]}:1', b"new")}
        self.assertEqual(self.call("PUT", "/vault", payload, session)["revision"], 2)
        self.assertEqual(self.call("PUT", "/vault", payload, session)["revision"], 2)
        self.assert_error("idempotency_conflict", lambda: self.call("PUT", "/vault", {**payload, "revision": 2}, session))
        self.assert_error("sync_conflict", lambda: self.call("PUT", "/vault", {**payload, "requestId": "s" * 32}, session))
        other = self.login("other@example.com")
        self.assert_error("vault_missing", lambda: self.call("GET", "/vault", session=other))
        self.assert_error("vault_exists", lambda: self.create(session))

    def test_device_revocation_blocks_existing_session(self):
        owner = self.login()
        self.create(owner)
        second = self.login()
        self.call("POST", "/devices/authorize", self.proof(second, "b" * 32), second)
        self.call("POST", "/devices/revoke", {"deviceId": "b" * 32}, owner)
        self.assert_error("unauthorized", lambda: self.call("GET", "/vault", session=second))
        self.assert_error("cannot_revoke_current_device", lambda: self.call("POST", "/devices/revoke", {"deviceId": "a" * 32}, owner))

    def test_recovery_rotation_changes_epoch_and_authorization_key(self):
        owner = self.login()
        self.create(owner)
        second = self.login()
        self.call("POST", "/devices/authorize", self.proof(second, "b" * 32), second)
        new_key = Ed25519PrivateKey.generate()
        uid = owner["accountId"]
        result = self.call("POST", "/vault/rotate", {"epoch": 1, "revision": 1, "verifyKey": b64(new_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)), "recovery": box(f"recovery:{uid}:2"), "payload": box(f"vault:{uid}:2")}, owner)
        self.assertEqual(result, {"epoch": 2, "revision": 2})
        self.assert_error("unauthorized", lambda: self.call("GET", "/vault", session=second))
        again = self.login()
        self.assert_error("authorization_failed", lambda: self.call("POST", "/devices/authorize", self.proof(again, "b" * 32, 2), again))
        self.call("POST", "/devices/authorize", self.proof(again, "b" * 32, 2, new_key), again)

    def test_pairing_expiry_single_use_and_account_boundary(self):
        owner = self.login()
        self.create(owner)
        target = self.login()
        pairing = self.call("POST", "/pairings", {"deviceId": "b" * 32, "publicKey": b64(b"x" * 32), "name": "new", "platform": "test"}, target)
        path = "/pairings/" + pairing["id"]
        self.assertFalse(self.call("GET", path, session=target)["ready"])
        packet = {"publicKey": b64(b"y" * 32), "box": box("pair:" + pairing["id"])}
        self.assert_error("device_revoked", lambda: self.call("PUT", path, {"payload": packet}, target))
        self.call("PUT", path, {"payload": packet}, owner)
        self.assert_error("pairing_already_approved", lambda: self.call("PUT", path, {"payload": packet}, owner))
        outsider = self.login("other@example.com")
        self.assert_error("pairing_expired", lambda: self.call("GET", path, session=outsider))
        self.assertTrue(self.call("GET", path, session=target)["ready"])
        self.call("DELETE", path, session=target)
        self.assert_error("pairing_expired", lambda: self.call("GET", path, session=target))

    def test_deletion_and_reset_require_fresh_login_and_confirmation(self):
        session = self.login()
        self.create(session)
        self.assert_error("confirmation_required", lambda: self.call("POST", "/account/delete", {}, session))
        self.clock[0] += 601
        self.assert_error("reauthentication_required", lambda: self.call("POST", "/account/delete", {"confirmation": "user@example.com"}, session))
        fresh = self.login()
        self.call("POST", "/account/delete", {"confirmation": "user@example.com"}, fresh)
        self.assertEqual(self.service.one("SELECT count(*) AS n FROM vaults")["n"], 0)
        self.assertEqual(self.service.one("SELECT count(*) AS n FROM deleted_accounts")["n"], 1)
        self.assert_error("unauthorized", lambda: self.call("GET", "/vault", session=session))
        self.assertNotEqual(self.login()["accountId"], session["accountId"])

    def test_plaintext_and_unsupported_payloads_rejected(self):
        session = self.login()
        self.create(session)
        for value in ({"secret": "JBSWY3DPEHPK3PXP"}, {**box("wrong"), "v": 2}, box("wrong")):
            self.assert_error("invalid_request" if "secret" in value else "unsupported_version", lambda: self.call("PUT", "/vault", {"requestId": "z" * 32, "payload": value}, session))

    def test_mail_failure_does_not_return_otp(self):
        self.service.mailer = lambda *_: (_ for _ in ()).throw(RuntimeError("smtp detail"))
        self.assert_error("mail_unavailable", lambda: self.call("POST", "/auth/request", {"email": "a@example.com"}))
        self.assertIsNone(self.service.one("SELECT * FROM challenges"))

    def test_cleanup(self):
        self.login()
        self.clock[0] += 31 * 86400
        self.service.cleanup()
        self.assertEqual(self.service.one("SELECT count(*) AS n FROM sessions")["n"], 0)

    def test_http_transport_and_redacted_errors(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}"
        try:
            with urllib.request.urlopen(url + "/health") as response:
                self.assertEqual(json.load(response)["protocol"], 1)
                self.assertEqual(response.headers["Cache-Control"], "no-store")
            req = urllib.request.Request(url + "/v1/auth/request", b"broken", {"Content-Type": "application/json"})
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(req)
            self.assertEqual(json.load(caught.exception), {"error": "invalid_json"})
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


    def test_delta_pull_returns_only_new_ciphertext_and_rotation_replaces_checkpoint(self):
        session = self.login()
        self.create(session)
        uid = session['accountId']
        initial = self.call('POST', '/vault/pull', {'epoch': 1, 'revision': 0}, session)
        self.assertIsNotNone(initial['payload'])
        self.assertEqual(initial['patches'], [])
        self.call('PUT', '/vault', {'requestId': 'd' * 32, 'epoch': 1, 'revision': 1,
                                  'payload': box(f'vault:{uid}:1', b'new encrypted delta')}, session)
        delta = self.call('POST', '/vault/pull', {'epoch': 1, 'revision': 1}, session)
        self.assertIsNone(delta['payload'])
        self.assertEqual([p['revision'] for p in delta['patches']], [2])
        unchanged = self.call('POST', '/vault/pull', {'epoch': 1, 'revision': 2}, session)
        self.assertIsNone(unchanged['payload'])
        self.assertEqual(unchanged['patches'], [])
        self.assert_error('invalid_cursor', lambda: self.call('POST', '/vault/pull', {'epoch': 1, 'revision': 3}, session))
        self.assert_error('device_revoked', lambda: self.call('POST', '/vault/pull', {'epoch': 2, 'revision': 1}, session))


if __name__ == "__main__":
    unittest.main()
