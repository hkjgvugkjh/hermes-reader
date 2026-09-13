#!/usr/bin/env python3
"""Validate the hermes-proxy protocol used by hermes-reader.

Replicates the Dart `ProxyClient` wire protocol end-to-end:
  * WebSocket connect (+ `?token=`) to `<host>:8649/ws`
  * X25519 ECDH handshake (client sends public_key, server replies theirs)
  * symmetric key = SHA-256(shared_secret), used for ChaCha20-Poly1305
  * TypeHTTPRequest (0x10): nonce(12) + ct  carried in `[0x10][len:4][data]`
  * DI list (0x32) to enumerate backend servers
  * HTTP request/response round-trip through the proxy (chat-run / voice-turn)

Usage:
  python3 proxy_protocol_test.py [--proxy ws://host:8649/ws?token=...] \
      [--server 32] [--chat] [--voice]

Default proxy points at the local hermes-proxy from config.json.
"""
import argparse
import asyncio
import base64
import json
import os
import struct
import wave

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
import websockets

DEFAULT_PROXY = "ws://localhost:8649/ws?token=O1KseSrfoNAy8fIFFtIuK67gL6U2idIu"

# Proxy message types (must match lib/reader/services/proxy_client.dart)
T_HANDSHAKE = 0x00
T_HTTP_REQUEST = 0x10
T_HTTP_RESPONSE = 0x11
T_DI_CONNECT = 0x30
T_DI_CONNECT_ACK = 0x31
T_DI_LIST = 0x32          # C->S request
T_DI_LIST_RESP = 0x33     # S->C response (server list)
T_DI_SESSION_POLL = 0x34
T_DI_SESSION_UPDATE = 0x35


def sha256(b: bytes) -> bytes:
    h = hashes.Hash(hashes.SHA256())
    h.update(b)
    return h.finalize()


def rid() -> str:
    return os.urandom(4).hex()


def make_wav(path: str, seconds: float = 1.0) -> None:
    """Create a tiny silent mono 16kHz WAV so we can exercise the voice-turn path."""
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\x00\x00" * int(16000 * seconds))


class ProxyTest:
    def __init__(self, uri: str):
        self.uri = uri
        self.ws = None
        self.key = None  # 32-byte ChaCha20-Poly1305 key
        self._pending = {}

    async def connect(self):
        self.ws = await websockets.connect(self.uri, max_size=None, ping_interval=20)
        await self._handshake()

    async def _handshake(self):
        priv = X25519PrivateKey.generate()
        pub = priv.public_key().public_bytes_raw()
        await self.ws.send(json.dumps({"public_key": base64.b64encode(pub).decode(),
                                       "token": _token_from_uri(self.uri)}))
        msg = await self.ws.recv()
        if not isinstance(msg, str):
            raise RuntimeError(f"handshake reply was not text: {type(msg)}")
        resp = json.loads(msg)
        srv_pub = base64.b64decode(resp["public_key"])
        shared = priv.exchange(X25519PublicKey.from_public_bytes(srv_pub))
        self.key = sha256(shared)
        print(f"[handshake] OK  shared-key(SHA256)={self.key.hex()[:16]}...")

    def _encrypt(self, msg_type: int, payload: dict) -> bytes:
        aead = ChaCha20Poly1305(self.key)
        nonce = os.urandom(12)
        ct = aead.encrypt(nonce, json.dumps(payload).encode(), None)
        data = nonce + ct
        return bytes([msg_type]) + struct.pack(">I", len(data)) + data

    async def _send(self, msg_type: int, payload: dict):
        req_id = payload.get("request_id") or rid()
        payload["request_id"] = req_id
        await self.ws.send(self._encrypt(msg_type, payload))
        return req_id

    async def _recv(self, want_type: int, want_id: str | None = None, timeout=30):
        while True:
            frame = await asyncio.wait_for(self.ws.recv(), timeout)
            if not isinstance(frame, (bytes, bytearray)):
                # ignore stray text frames (e.g. server announcements)
                print(f"[recv] ignoring text frame: {frame}")
                continue
            mtype = frame[0]
            length = struct.unpack(">I", frame[1:5])[0]
            data = bytes(frame[5:5 + length])
            nonce, ct = data[:12], data[12:]
            pt = ChaCha20Poly1305(self.key).decrypt(nonce, ct, None)
            decoded = json.loads(pt)
            # DI control responses (0x33/0x31/...) don't echo request_id; the
            # Dart client matches them by type (or server_id). Skip any frame
            # that is not the one we are waiting for and keep listening.
            if mtype != want_type:
                continue
            if want_id is not None and decoded.get("request_id") != want_id:
                continue
            return decoded

    async def list_servers(self):
        await self._send(T_DI_LIST, {})
        resp = await self._recv(T_DI_LIST_RESP)
        servers = resp.get("servers", [])
        print(f"[di-list] OK  {len(servers)} server(s): "
              + ", ".join(f"{s.get('id')}:{s.get('name')}" for s in servers))
        return servers

    async def connect_di(self, server_id: str, username="", password="", profile="default"):
        await self._send(T_DI_CONNECT, {
            "server_id": server_id,
            "credentials": {"username": username, "password": password, "profile": profile},
        })
        # DI connect returns TypeDIConnectAck (0x31); matched by type.
        resp = await self._recv(T_DI_CONNECT_ACK)
        print(f"[di-connect] OK server={server_id} -> {resp}")
        return resp

    async def send_request(self, server_id: str, method: str, path: str,
                           headers=None, body=None):
        req_id = await self._send(T_HTTP_REQUEST, {
            "server_id": server_id,
            "method": method,
            "path": path,
            "headers": headers or {},
            "body": base64.b64encode(body).decode() if body else None,
        })
        resp = await self._recv(T_HTTP_RESPONSE, req_id)
        return resp

    @staticmethod
    def decode_body(resp):
        body = resp.get("body")
        if body is None:
            return None
        if isinstance(body, (bytes, bytearray)):
            return bytes(body).decode("utf-8", "replace")
        if isinstance(body, str):
            try:
                return base64.b64decode(body).decode("utf-8", "replace")
            except Exception:
                return body
        return str(body)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--proxy", default=DEFAULT_PROXY)
    ap.add_argument("--server", default="32")
    ap.add_argument("--chat", action="store_true", help="POST /api/studio/chat-run/runs")
    ap.add_argument("--voice", action="store_true", help="POST /api/hermes/mcu/voice-turn")
    ap.add_argument("--session", default="", help="session_id for chat-run")
    args = ap.parse_args()

    client = ProxyTest(args.proxy)
    print(f"[connect] {args.proxy}")
    await client.connect()

    servers = await client.list_servers()
    ids = {str(s.get("id")) for s in servers}
    if args.server not in ids:
        print(f"[warn] server {args.server!r} not in proxy list; proceeding anyway")

    # HTTP transport validation first (no backend resource needed).
    print(f"\n[test] GET /health via proxy (server={args.server})")
    resp = await client.connect_di(args.server)
    resp = await client.send_request(args.server, "GET", "/health")
    print(f"  status={resp.get('status_code')} body={client.decode_body(resp)!r}")

    if args.chat:
        print(f"\n[test] POST /api/studio/chat-run/runs (session={args.session or '<none>'})")
        variants = [
            ("json input", "application/json",
             "/api/studio/chat-run/runs",
             json.dumps({"input": "ping", "profile": "default", "session_id": args.session}).encode()),
            ("json message", "application/json",
             "/api/studio/chat-run/runs",
             json.dumps({"message": "ping", "profile": "default"}).encode()),
            ("json text", "application/json",
             "/api/studio/chat-run/runs",
             json.dumps({"text": "ping", "profile": "default"}).encode()),
            ("json nested data.input", "application/json",
             "/api/studio/chat-run/runs",
             json.dumps({"data": {"input": "ping"}, "profile": "default"}).encode()),
            ("form-urlencoded input", "application/x-www-form-urlencoded",
             "/api/studio/chat-run/runs",
             b"input=ping&profile=default"),
            ("json input no content-type", None,
             "/api/studio/chat-run/runs",
             json.dumps({"input": "ping", "profile": "default"}).encode()),
            ("raw string body", "text/plain",
             "/api/studio/chat-run/runs",
             b"ping from raw body"),
        ]
        for label, ctype, path, payload in variants:
            headers = {"Accept": "application/json"}
            if ctype:
                headers["Content-Type"] = ctype
            resp = await client.send_request(args.server, "POST", path, headers=headers, body=payload)
            print(f"  [{label}] status={resp.get('status_code')} body={client.decode_body(resp)}")

    if args.voice:
        print(f"\n[test] POST /api/hermes/mcu/voice-turn")
        wav = "/tmp/proxy_test_voice.wav"
        make_wav(wav, 0.5)
        with open(wav, "rb") as f:
            wav_bytes = f.read()
        resp = await client.send_request(
            args.server, "POST", "/api/hermes/mcu/voice-turn",
            headers={"Content-Type": "audio/wav", "Accept": "application/json"},
            body=wav_bytes,
        )
        print(f"  status={resp.get('status_code')}")
        print(f"  body={client.decode_body(resp)}")

    print("\nALL PROTOCOL STEPS COMPLETED")


def _token_from_uri(uri: str) -> str:
    from urllib.parse import urlparse, parse_qs
    q = parse_qs(urlparse(uri).query)
    return q.get("token", [""])[0]


if __name__ == "__main__":
    asyncio.run(main())
