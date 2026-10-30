"""Opaque encrypted storage. The service never generates TOTP or receives vault keys.

Run: python3 -m server.app --database .local/server.sqlite
Production requires TLS termination, SMTP settings and SIX_TICK_PEPPER.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import smtplib
import sqlite3
import ssl
import threading
import time
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

MAX_BODY = 16 * 1024 * 1024
SESSION_SECONDS = 30 * 86400


class ApiError(Exception):
    def __init__(self, status: int, code: str):
        self.status, self.code = status, code
        super().__init__(code)


def require(condition, code="invalid_request", status=400):
    if not condition:
        raise ApiError(status, code)


def encoded(value, length=None, maximum=MAX_BODY):
    require(isinstance(value, str) and len(value) <= maximum * 2)
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise ApiError(400, "invalid_encoding") from None
    require(len(raw) <= maximum and (length is None or len(raw) == length))
    return raw


def envelope(value, purpose):
    require(isinstance(value, dict))
    require(set(value) == {"v", "purpose", "nonce", "ciphertext", "tag"})
    require(value["v"] == 1 and value["purpose"] == purpose, "unsupported_version")
    encoded(value["nonce"], 12)
    encoded(value["tag"], 16)
    require(len(encoded(value["ciphertext"])) > 0)
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def email_address(value):
    require(isinstance(value, str) and len(value) <= 254)
    value = value.strip().lower()
    require(re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", value) is not None, "invalid_email")
    return value


def identifier(value):
    require(isinstance(value, str) and re.fullmatch(r"[a-zA-Z0-9_-]{16,100}", value) is not None)
    return value


def short_text(value, limit=100):
    require(isinstance(value, str) and 0 < len(value.strip()) <= limit)
    require(all(ord(c) >= 32 for c in value))
    return value.strip()


SCHEMA = """
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL);
CREATE TABLE IF NOT EXISTS challenges(email TEXT PRIMARY KEY, digest TEXT NOT NULL, sent REAL NOT NULL,
 expires REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS rates(key TEXT PRIMARY KEY, start REAL NOT NULL, count INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sessions(digest TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 challenge TEXT NOT NULL, device_id TEXT, created REAL NOT NULL, expires REAL NOT NULL);
CREATE TABLE IF NOT EXISTS vaults(user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
 epoch INTEGER NOT NULL, revision INTEGER NOT NULL, base_revision INTEGER NOT NULL, verify_key TEXT NOT NULL, recovery TEXT NOT NULL, payload TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS patches(user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(user_id,revision));
CREATE TABLE IF NOT EXISTS devices(id TEXT NOT NULL, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 name TEXT NOT NULL, platform TEXT NOT NULL, epoch INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0,
 created REAL NOT NULL, seen REAL NOT NULL, PRIMARY KEY(user_id,id));
CREATE TABLE IF NOT EXISTS mutations(user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 id TEXT NOT NULL, digest TEXT NOT NULL, revision INTEGER NOT NULL, epoch INTEGER NOT NULL, PRIMARY KEY(user_id,id));
CREATE TABLE IF NOT EXISTS pairings(id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 session_digest TEXT NOT NULL REFERENCES sessions(digest) ON DELETE CASCADE, public_key TEXT NOT NULL,
 device_id TEXT NOT NULL, name TEXT NOT NULL, platform TEXT NOT NULL,
 expires REAL NOT NULL, payload TEXT, consumed INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS deleted_accounts(id TEXT PRIMARY KEY, deleted REAL NOT NULL);
"""


class Service:
    def __init__(self, database: str, pepper: bytes, mailer: Callable[[str, str], None], clock=time.time):
        require(len(pepper) >= 32, "server_key_too_short", 500)
        self.db = sqlite3.connect(database, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA secure_delete=ON")
        self.lock = threading.RLock()
        self.pepper, self.mailer, self.clock = pepper, mailer, clock

    def digest(self, value):
        return hmac.new(self.pepper, value.encode(), hashlib.sha256).hexdigest()

    def one(self, sql, args=()):
        return self.db.execute(sql, args).fetchone()

    def rate(self, key, limit, window):
        now = self.clock()
        row = self.one("SELECT * FROM rates WHERE key=?", (key,))
        if row is None or now - row["start"] >= window:
            self.db.execute("INSERT OR REPLACE INTO rates VALUES(?,?,1)", (key, now))
        else:
            require(row["count"] < limit, "rate_limited", 429)
            self.db.execute("UPDATE rates SET count=count+1 WHERE key=?", (key,))

    def session(self, token):
        require(isinstance(token, str) and len(token) <= 200, "unauthorized", 401)
        row = self.one("SELECT s.*,u.email FROM sessions s JOIN users u ON s.user_id=u.id WHERE digest=?", (self.digest(token),))
        require(row is not None and row["expires"] > self.clock(), "unauthorized", 401)
        return row

    def vault(self, session, authorized=True):
        row = self.one("SELECT * FROM vaults WHERE user_id=?", (session["user_id"],))
        require(row is not None, "vault_missing", 404)
        if authorized:
            device = self.one("SELECT * FROM devices WHERE user_id=? AND id=?", (session["user_id"], session["device_id"]))
            require(device is not None and not device["revoked"] and device["epoch"] == row["epoch"], "device_revoked", 403)
            self.db.execute("UPDATE devices SET seen=? WHERE user_id=? AND id=?", (self.clock(), session["user_id"], session["device_id"]))
        return row

    def fresh(self, session):
        require(self.clock() - session["created"] <= 600, "reauthentication_required", 403)

    def authorize(self, session, data, vault):
        device_id = identifier(data.get("deviceId"))
        message = f'six-tick:authorize:v1:{session["user_id"]}:{session["challenge"]}:{device_id}:{vault["epoch"]}'
        try:
            Ed25519PublicKey.from_public_bytes(encoded(vault["verify_key"], 32)).verify(encoded(data.get("signature"), 64), message.encode())
        except InvalidSignature:
            raise ApiError(403, "authorization_failed") from None
        name, platform = short_text(data.get("name")), short_text(data.get("platform"), 30)
        existing = self.one("SELECT created FROM devices WHERE user_id=? AND id=?", (session["user_id"], device_id))
        self.db.execute("INSERT OR REPLACE INTO devices VALUES(?,?,?,?,?,0,?,?)", (device_id, session["user_id"], name, platform, vault["epoch"], existing["created"] if existing else self.clock(), self.clock()))
        self.db.execute("UPDATE sessions SET device_id=? WHERE digest=?", (device_id, session["digest"]))

    def dispatch(self, method, path, data=None, token="", source="local"):
        data = {} if data is None else data
        require(isinstance(data, dict))
        # Serialize SQLite transactions; failed OTP attempts and throttling must commit.
        with self.lock:
            try:
                result = self._dispatch(method, path, data, token, source)
            except ApiError:
                self.db.commit()
                raise
            except Exception:
                self.db.rollback()
                raise
            self.db.commit()
            return result

    def _dispatch(self, method, path, data, token, source):
        now = self.clock()
        if (method, path) == ("GET", "/health"):
            return {"status": "ok", "protocol": 1}
        if (method, path) == ("POST", "/v1/auth/request"):
            email = email_address(data.get("email"))
            self.rate("send-ip:" + self.digest(source), 30, 3600)
            self.rate("send-email:" + self.digest(email), 10, 3600)
            old = self.one("SELECT sent FROM challenges WHERE email=?", (email,))
            require(old is None or now - old["sent"] >= 60, "rate_limited", 429)
            code = f"{secrets.randbelow(1000000):06d}"
            # Never persist the code itself; the database cannot be brute-forced without the pepper.
            self.db.execute("INSERT OR REPLACE INTO challenges VALUES(?,?,?,?,0)", (email, self.digest(email + ":" + code), now, now + 600))
            try:
                self.mailer(email, code)
            except Exception:
                self.db.execute("DELETE FROM challenges WHERE email=?", (email,))
                raise ApiError(503, "mail_unavailable") from None
            return {"accepted": True, "retryAfter": 60}
        if (method, path) == ("POST", "/v1/auth/verify"):
            email = email_address(data.get("email"))
            code = data.get("code")
            require(isinstance(code, str) and re.fullmatch(r"\d{6}", code) is not None)
            self.rate("verify-ip:" + self.digest(source), 100, 3600)
            row = self.one("SELECT * FROM challenges WHERE email=?", (email,))
            require(row is not None and row["expires"] > now and row["attempts"] < 5, "invalid_code", 401)
            self.db.execute("UPDATE challenges SET attempts=attempts+1 WHERE email=?", (email,))
            require(hmac.compare_digest(row["digest"], self.digest(email + ":" + code)), "invalid_code", 401)
            self.db.execute("DELETE FROM challenges WHERE email=?", (email,))
            user = self.one("SELECT * FROM users WHERE email=?", (email,))
            uid = user["id"] if user else secrets.token_hex(16)
            if not user:
                self.db.execute("INSERT INTO users VALUES(?,?)", (uid, email))
            session_token, challenge = secrets.token_urlsafe(32), secrets.token_hex(32)
            self.db.execute("INSERT INTO sessions VALUES(?,?,?,NULL,?,?)", (self.digest(session_token), uid, challenge, now, now + SESSION_SECONDS))
            return {"token": session_token, "accountId": uid, "challenge": challenge, "expiresAt": now + SESSION_SECONDS}
        session = self.session(token)
        uid = session["user_id"]
        self.rate("api:" + uid, 600, 60)
        if (method, path) == ("GET", "/v1/vault/info"):
            vault = self.one("SELECT * FROM vaults WHERE user_id=?", (uid,))
            return {"accountId": uid, "challenge": session["challenge"], "vault": None if vault is None else {"epoch": vault["epoch"], "revision": vault["revision"], "verifyKey": vault["verify_key"], "recovery": json.loads(vault["recovery"])}}
        if (method, path) == ("POST", "/v1/vault/create"):
            self.fresh(session)
            require(self.one("SELECT 1 FROM vaults WHERE user_id=?", (uid,)) is None, "vault_exists", 409)
            verify = data.get("verifyKey")
            encoded(verify, 32)
            recovery = envelope(data.get("recovery"), f"recovery:{uid}:1")
            payload = envelope(data.get("payload"), f"vault:{uid}:1")
            # Validate the proof before writing any state.
            provisional = {"verify_key": verify, "epoch": 1}
            self.authorize(session, data, provisional)
            self.db.execute("INSERT INTO vaults VALUES(?,1,1,1,?,?,?)", (uid, verify, recovery, payload))
            return {"epoch": 1, "revision": 1}
        if (method, path) == ("POST", "/v1/devices/authorize"):
            self.fresh(session)
            vault = self.vault(session, authorized=False)
            self.authorize(session, data, vault)
            return {"authorized": True, "epoch": vault["epoch"]}
        if (method, path) == ("POST", "/v1/pairings"):
            self.fresh(session)
            self.vault(session, authorized=False)
            public = data.get("publicKey")
            encoded(public, 32)
            device_id = identifier(data.get("deviceId"))
            name, platform = short_text(data.get("name")), short_text(data.get("platform"), 30)
            self.rate("pair:" + uid, 10, 600)
            pair_id = secrets.token_hex(16)
            self.db.execute("INSERT INTO pairings VALUES(?,?,?,?,?,?,?,?,NULL,0)", (pair_id, uid, session["digest"], public, device_id, name, platform, now + 300))
            return {"id": pair_id, "publicKey": public, "expiresAt": now + 300}
        if path.startswith("/v1/pairings/"):
            pair_id = identifier(path.removeprefix("/v1/pairings/"))
            pair = self.one("SELECT * FROM pairings WHERE id=? AND user_id=?", (pair_id, uid))
            require(pair is not None and pair["expires"] > now and not pair["consumed"], "pairing_expired", 410)
            if method == "GET":
                if pair["session_digest"] == session["digest"]:
                    return {"ready": pair["payload"] is not None, "payload": json.loads(pair["payload"]) if pair["payload"] else None}
                self.vault(session)
                return {"id": pair_id, "publicKey": pair["public_key"], "deviceId": pair["device_id"], "name": pair["name"], "platform": pair["platform"], "expiresAt": pair["expires"]}
            if method == "PUT":
                self.vault(session)
                require(pair["payload"] is None, "pairing_already_approved", 409)
                packet = data.get("payload")
                require(isinstance(packet, dict) and set(packet) == {"publicKey", "box"})
                encoded(packet["publicKey"], 32)
                envelope(packet["box"], "pair:" + pair_id)
                self.db.execute("UPDATE pairings SET payload=? WHERE id=?", (json.dumps(packet), pair_id))
                return {"approved": True}
            if method == "DELETE":
                require(pair["session_digest"] == session["digest"], "forbidden", 403)
                self.db.execute("UPDATE pairings SET consumed=1,payload=NULL WHERE id=?", (pair_id,))
                return {"consumed": True}
        if (method, path) in (("POST", "/v1/account/delete"), ("POST", "/v1/vault/reset")):
            self.fresh(session)
            require(data.get("confirmation") == session["email"], "confirmation_required")
            if path.endswith("delete"):
                self.db.execute("INSERT OR REPLACE INTO deleted_accounts VALUES(?,?)", (uid, now))
                self.db.execute("DELETE FROM users WHERE id=?", (uid,))
                return {"deleted": True}
            vault = self.vault(session, authorized=False)
            require(data.get("epoch") == vault["epoch"] and data.get("revision") == vault["revision"], "sync_conflict", 409)
            self.db.execute("DELETE FROM vaults WHERE user_id=?", (uid,))
            self.db.execute("DELETE FROM patches WHERE user_id=?", (uid,))
            self.db.execute("DELETE FROM devices WHERE user_id=?", (uid,))
            self.db.execute("DELETE FROM mutations WHERE user_id=?", (uid,))
            self.db.execute("DELETE FROM pairings WHERE user_id=?", (uid,))
            self.db.execute("DELETE FROM sessions WHERE user_id=? AND digest<>?", (uid, session["digest"]))
            self.db.execute("UPDATE sessions SET device_id=NULL WHERE digest=?", (session["digest"],))
            return {"reset": True}
        vault = self.vault(session)
        if (method, path) in (("GET", "/v1/vault"), ("POST", "/v1/vault/pull")):
            cursor = 0 if method == "GET" else data.get("revision", 0)
            require(type(cursor) is int and 0 <= cursor <= vault["revision"], "invalid_cursor")
            require(method == "GET" or data.get("epoch") == vault["epoch"], "device_revoked", 403)
            checkpoint = cursor < vault["base_revision"]
            after = vault["base_revision"] if checkpoint else cursor
            patches = self.db.execute("SELECT revision,payload FROM patches WHERE user_id=? AND revision>? ORDER BY revision", (uid, after)).fetchall()
            return {"epoch": vault["epoch"], "revision": vault["revision"], "baseRevision": vault["base_revision"],
                    "payload": json.loads(vault["payload"]) if checkpoint else None,
                    "patches": [{"revision": p["revision"], "payload": json.loads(p["payload"])} for p in patches]}
        if (method, path) == ("PUT", "/v1/vault"):
            request_id = identifier(data.get("requestId"))
            payload = envelope(data.get("payload"), f'vault:{uid}:{vault["epoch"]}')
            digest = hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()
            previous = self.one("SELECT * FROM mutations WHERE user_id=? AND id=?", (uid, request_id))
            if previous:
                require(previous["digest"] == digest and previous["epoch"] == vault["epoch"], "idempotency_conflict", 409)
                return {"revision": previous["revision"], "epoch": previous["epoch"]}
            require(data.get("epoch") == vault["epoch"] and data.get("revision") == vault["revision"], "sync_conflict", 409)
            revision = vault["revision"] + 1
            self.db.execute("INSERT INTO patches VALUES(?,?,?)", (uid, revision, payload))
            self.db.execute("UPDATE vaults SET revision=? WHERE user_id=?", (revision, uid))
            self.db.execute("INSERT INTO mutations VALUES(?,?,?,?,?)", (uid, request_id, digest, revision, vault["epoch"]))
            return {"revision": revision, "epoch": vault["epoch"]}
        if (method, path) == ("POST", "/v1/vault/rotate"):
            self.fresh(session)
            require(data.get("revision") == vault["revision"] and data.get("epoch") == vault["epoch"], "sync_conflict", 409)
            epoch = vault["epoch"] + 1
            verify = data.get("verifyKey")
            encoded(verify, 32)
            recovery = envelope(data.get("recovery"), f"recovery:{uid}:{epoch}")
            payload = envelope(data.get("payload"), f"vault:{uid}:{epoch}")
            self.db.execute("UPDATE vaults SET epoch=?,base_revision=revision+1,revision=revision+1,verify_key=?,recovery=?,payload=? WHERE user_id=?", (epoch, verify, recovery, payload, uid))
            self.db.execute("DELETE FROM patches WHERE user_id=?", (uid,))
            self.db.execute("UPDATE devices SET revoked=1 WHERE user_id=? AND id<>?", (uid, session["device_id"]))
            self.db.execute("UPDATE devices SET epoch=? WHERE user_id=? AND id=?", (epoch, uid, session["device_id"]))
            self.db.execute("DELETE FROM sessions WHERE user_id=? AND digest<>?", (uid, session["digest"]))
            self.db.execute("DELETE FROM pairings WHERE user_id=?", (uid,))
            return {"epoch": epoch, "revision": vault["revision"] + 1}
        if (method, path) == ("GET", "/v1/devices"):
            rows = self.db.execute("SELECT * FROM devices WHERE user_id=? ORDER BY created", (uid,)).fetchall()
            return {"devices": [{"id": r["id"], "name": r["name"], "platform": r["platform"], "createdAt": r["created"], "lastSeen": r["seen"], "revoked": bool(r["revoked"]), "current": r["id"] == session["device_id"]} for r in rows]}
        if (method, path) == ("POST", "/v1/devices/rename"):
            device_id, name = identifier(data.get("deviceId")), short_text(data.get("name"))
            require(self.one("SELECT 1 FROM devices WHERE user_id=? AND id=?", (uid, device_id)) is not None, "not_found", 404)
            self.db.execute("UPDATE devices SET name=? WHERE user_id=? AND id=?", (name, uid, device_id))
            return {"renamed": True}
        if (method, path) == ("POST", "/v1/devices/revoke"):
            self.fresh(session)
            device_id = identifier(data.get("deviceId"))
            require(device_id != session["device_id"], "cannot_revoke_current_device")
            require(self.one("SELECT 1 FROM devices WHERE user_id=? AND id=?", (uid, device_id)) is not None, "not_found", 404)
            self.db.execute("UPDATE devices SET revoked=1 WHERE user_id=? AND id=?", (uid, device_id))
            self.db.execute("DELETE FROM sessions WHERE user_id=? AND device_id=?", (uid, device_id))
            return {"revoked": True}
        raise ApiError(404, "not_found")

    def cleanup(self):
        with self.lock, self.db:
            now = self.clock()
            self.db.execute("DELETE FROM challenges WHERE expires<?", (now,))
            self.db.execute("DELETE FROM sessions WHERE expires<?", (now,))
            self.db.execute("DELETE FROM pairings WHERE expires<? OR consumed=1", (now,))
            self.db.execute("DELETE FROM rates WHERE start<?", (now - 86400,))
            self.db.commit()
            self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")


def smtp_mailer(email, code):
    message = EmailMessage()
    message["Subject"] = "Six Tick 登录验证码 / Sign-in code"
    message["From"] = os.environ["SMTP_FROM"]
    message["To"] = email
    message.set_content(f"Six Tick: {code}\n10 分钟内有效。请勿将验证码透露给他人。\nExpires in 10 minutes. Never share this code.")
    with smtplib.SMTP(os.environ["SMTP_HOST"], int(os.getenv("SMTP_PORT", "587")), timeout=15) as smtp:
        smtp.starttls(context=ssl.create_default_context())
        if os.getenv("SMTP_USER"):
            smtp.login(os.environ["SMTP_USER"], os.environ["SMTP_PASSWORD"])
        smtp.send_message(message)


def make_handler(service):
    class Handler(BaseHTTPRequestHandler):
        server_version = "SixTick/1"

        def log_message(self, *_):
            pass  # No URLs, credentials, emails or request bodies in access logs.

        def handle_request(self):
            started = time.monotonic()
            status, output = 200, None
            try:
                require("?" not in self.path, "query_not_supported")
                require(self.headers.get("Transfer-Encoding") is None, "invalid_request")
                size = int(self.headers.get("Content-Length", "0"))
                require(0 <= size <= MAX_BODY, "request_too_large", 413)
                if self.command in ("POST", "PUT"):
                    require(self.headers.get_content_type() == "application/json", "json_required", 415)
                data = json.loads(self.rfile.read(size)) if size else {}
                auth = self.headers.get("Authorization", "")
                token = auth[7:] if auth.startswith("Bearer ") else ""
                output = service.dispatch(self.command, self.path, data, token, self.client_address[0])
            except ApiError as exc:
                status, output = exc.status, {"error": exc.code}
            except (ValueError, UnicodeError):
                status, output = 400, {"error": "invalid_json"}
            except Exception:
                status, output = 500, {"error": "internal_error"}
            raw = json.dumps(output).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(raw)
            # Operational output intentionally excludes paths and identifiers.
            if os.getenv("SIX_TICK_METRICS") == "1":
                print(json.dumps({"status": status, "durationMs": round((time.monotonic()-started)*1000)}), flush=True)

        do_GET = do_POST = do_PUT = do_DELETE = handle_request

        def setup(self):
            super().setup()
            self.connection.settimeout(20)

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", default=".local/server.sqlite")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--development", action="store_true", help="Loopback only; email OTPs go to a private local file.")
    args = parser.parse_args()
    path = Path(args.database)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.umask(0o077)
    if args.development:
        if args.host not in ("127.0.0.1", "::1"):
            parser.error("development mode must bind to loopback")
        pepper_path = path.parent / "development.key"
        if not pepper_path.exists():
            pepper_path.write_bytes(secrets.token_bytes(32))
        pepper = pepper_path.read_bytes()
        def mailer(email, code):
            target = path.parent / "development-mail.json"
            target.write_text(json.dumps({"email": email, "code": code, "expiresIn": 600}))
            target.chmod(0o600)
    else:
        pepper = os.environ.get("SIX_TICK_PEPPER", "").encode()
        if len(pepper) < 32 or not os.getenv("SMTP_HOST") or not os.getenv("SMTP_FROM"):
            parser.error("SIX_TICK_PEPPER (32+ characters), SMTP_HOST and SMTP_FROM are required")
        mailer = smtp_mailer
    service = Service(str(path), pepper, mailer)
    path.chmod(0o600)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(service))
    print(f"Six Tick listening on {args.host}:{args.port}; protocol v1", flush=True)
    def maintenance():
        while True:
            time.sleep(60)
            service.cleanup()
    threading.Thread(target=maintenance, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        service.db.close()


if __name__ == "__main__":
    main()
