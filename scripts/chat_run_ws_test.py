#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Validate the Hermes Socket.IO chat-run flow *through the proxy WS tunnel*.

This is the Python counterpart of the Dart implementation in
lib/reader/services/{proxy_client,socket_io_client}.dart. It re-uses the exact
handshake, ChaCha20-Poly1305 framing, and WS-tunnel message types so we can
confirm the protocol end-to-end against a live `hermes-proxy` before trusting
the Flutter code.

Flow:
  1. WebSocket connect to the proxy, do the X25519 handshake.
  2. Open a WS tunnel (type 0x20) to the server's /socket.io endpoint.
  3. Inside the tunnel, run a tiny Socket.IO client:
       40/chat-run,{"token":...}      # namespace connect
       42/chat-run,["resume",{...}]   # subscribe to session events
       42/chat-run,["run",{...}]      # send the user input
  4. Print every Engine.IO / Socket.IO frame for 60s so we can eyeball the
     event names (run.started / message.delta / run.completed / run.failed).

Usage:
  pip install websocket-client cryptography
  python3 scripts/chat_run_ws_test.py \
      --proxy-url ws://localhost:8649/ws \
      --proxy-token O1KseSrfoNAy8fIFFtIuK67gL6U2idIu \
      --server 32 \
      --auth-token <STUDIO_BEARER> \
      --session-id <SESSION_ID> \
      --input "你好，介绍一下你自己" \
      --profile default
"""
import argparse
import base64
import hashlib
import json
import os
import struct
import sys
import threading
import time

try:
    import websocket  # websocket-client
except ImportError:
    sys.exit("need websocket-client:  pip install websocket-client")
try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
except ImportError:
    sys.exit("need cryptography:  pip install cryptography")


# ---- protocol constants (mirror protocol.go) ----
T_HANDSHAKE = 0x00
T_HTTP_REQUEST = 0x10
T_DI_LIST = 0x32
T_DI_LIST_RESP = 0x33
T_WS_OPEN = 0x20
T_WS_OPENED = 0x21
T_WS_DATA = 0x22
T_WS_CLOSE = 0x23
T_WS_ERROR = 0x24


def _x25519_shared(priv_raw: bytes, peer_pub_b64: str) -> bytes:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
    priv = X25519PrivateKey.from_private_bytes(priv_raw)
    peer = X25519PublicKey.from_public_bytes(base64.b64decode(peer_pub_b64))
    shared = priv.exchange(peer)
    return hashlib.sha256(shared).digest()


class ProxyClient:
    def __init__(self, url: str, token: str):
        self.url = url
        self.token = token
        self.key = None  # 32-byte symmetric key
        self.ws = None
        self._lock = threading.Lock()
        self._tunnels = {}  # conn_id -> ProxyTunnel
        self._opened = {}  # conn_id -> threading.Event
        self._stop = threading.Event()
        self._thread = None

    # ---- crypto ----
    def _encrypt(self, plaintext: str) -> bytes:
        aead = ChaCha20Poly1305(self.key)
        nonce = os.urandom(12)
        # cryptography's ChaCha20Poly1305.encrypt returns ciphertext+tag
        ct = aead.encrypt(plaintext.encode(), nonce)
        return nonce + ct  # nonce(12) + ciphertext + tag(16)

    def _decrypt(self, blob: bytes) -> str:
        aead = ChaCha20Poly1305(self.key)
        nonce, ct = blob[:12], blob[12:]
        return aead.decrypt(ct, nonce).decode()

    # ---- framing ----
    def _send_frame(self, type_: int, payload: str):
        enc = self._encrypt(payload)
        frame = bytes([type_]) + struct.pack(">I", len(enc)) + enc
        with self._lock:
            self.ws.send(frame, opcode=websocket.ABNF.OPCODE_BINARY)

    def _on_message(self, ws, data):
        if not isinstance(data, (bytes, bytearray)):
            # handshake response is plaintext JSON
            return
        data = bytes(data)
        type_ = data[0]
        length = struct.unpack(">I", data[1:5])[0]
        enc = data[5:5 + length]
        resp = json.loads(self._decrypt(enc))
        if type_ == T_WS_OPENED:
            cid = resp.get("conn_id")
            ev = self._opened.get(cid)
            if ev:
                ev.set()
            print(f"[WS] opened conn_id={cid}")
        elif type_ == T_WS_DATA:
            cid = resp.get("conn_id")
            raw = resp.get("data")
            text = base64.b64decode(raw).decode() if raw else ""
            tunnel = self._tunnels.get(cid)
            if tunnel:
                tunnel.on_data(text)
        elif type_ == T_WS_CLOSE:
            cid = resp.get("conn_id")
            print(f"[WS] closed conn_id={cid} reason={resp.get('reason')}")
            tunnel = self._tunnels.pop(cid, None)
            if tunnel:
                tunnel.on_close()
        elif type_ == T_WS_ERROR:
            cid = resp.get("conn_id")
            print(f"[WS] error conn_id={cid} {resp.get('error')}")
            tunnel = self._tunnels.pop(cid, None)
            if tunnel:
                tunnel.on_close()
        else:
            print(f"[proxy] type=0x{type_:02x} {resp}")

    def connect(self):
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        priv = X25519PrivateKey.generate()
        pub = base64.b64encode(
            priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        ).decode()

        self.ws = websocket.create_connection(self.url)
        self.ws.send(json.dumps({"public_key": pub, "token": self.token}))
        # handshake reply is plaintext
        hs = json.loads(self.ws.recv())
        peer = hs["public_key"]
        self.key = _x25519_shared(priv.private_bytes_raw(), peer)
        self._thread = threading.Thread(target=self._read_loop, daemon=True)
        self._thread.start()

    def _read_loop(self):
        while not self._stop.is_set():
            try:
                self._on_message(self.ws, self.ws.recv())
            except Exception as e:  # noqa
                if not self._stop.is_set():
                    print(f"[proxy] read loop error: {e}")
                break

    def open_tunnel(self, server_id: str, path: str, headers: dict, timeout=15):
        cid = f"ws_{int(time.time()*1000)}"
        ev = threading.Event()
        self._opened[cid] = ev
        tunnel = ProxyTunnel(self, cid, server_id, path)
        self._tunnels[cid] = tunnel
        payload = {"conn_id": cid, "server_id": server_id, "path": path}
        if headers:
            payload["headers"] = headers
        self._send_frame(T_WS_OPEN, json.dumps(payload))
        if not ev.wait(timeout):
            raise RuntimeError("tunnel open timeout")
        return tunnel

    def send_tunnel(self, cid: str, text: str):
        self._send_frame(T_WS_DATA, json.dumps({
            "conn_id": cid, "binary": False,
            "data": base64.b64encode(text.encode()).decode(),
        }))

    def close_tunnel(self, cid: str):
        try:
            self._send_frame(T_WS_CLOSE, json.dumps({"conn_id": cid, "reason": "client close"}))
        except Exception:
            pass


class ProxyTunnel:
    def __init__(self, client: ProxyClient, cid: str, server_id: str, path: str):
        self.client = client
        self.cid = cid
        self.server_id = server_id
        self.path = path
        self._done = threading.Event()

    def on_data(self, text: str):
        # Engine.IO frame received from upstream.
        print(f"[ws<] {text!r}")
        # Respond to ping immediately.
        if text == "2":
            self.client.send_tunnel(self.cid, "3")
            return
        # Parse Socket.IO events (42<ns>,[name,data]) for visibility.
        if text.startswith("42"):
            rest = text[2:]
            if rest.startswith("/"):
                rest = rest.split(",", 1)[1] if "," in rest else ""
            try:
                arr = json.loads(rest)
                print(f"[event] {arr[0]} {json.dumps(arr[1]) if len(arr) > 1 else ''}")
            except Exception:
                pass

    def on_close(self):
        self._done.set()

    def send(self, text: str):
        self.client.send_tunnel(self.cid, text)

    def wait(self, seconds: float):
        self._done.wait(seconds)

    def close(self):
        self.client.close_tunnel(self.cid)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--proxy-url", default="ws://localhost:8649/ws")
    ap.add_argument("--proxy-token", default="O1KseSrfoNAy8fIFFtIuK67gL6U2idIu")
    ap.add_argument("--server", required=True)
    ap.add_argument("--auth-token", default="")
    ap.add_argument("--session-id", required=True)
    ap.add_argument("--input", default="你好")
    ap.add_argument("--profile", default="default")
    ap.add_argument("--timeout", type=float, default=60.0)
    args = ap.parse_args()

    c = ProxyClient(args.proxy_url, args.proxy_token)
    c.connect()
    print("[proxy] handshake ok")

    headers = {}
    if args.auth_token:
        headers["Authorization"] = f"Bearer {args.auth_token}"
    path = f"/socket.io/?EIO=4&transport=websocket&profile={args.profile}"
    if args.auth_token:
        from urllib.parse import quote
        path += f"&token={quote(args.auth_token)}"

    tunnel = c.open_tunnel(args.server, path, headers)
    print(f"[tunnel] open -> {path}")

    ns = "/chat-run"
    tunnel.send(f"40{ns}," + json.dumps({"token": args.auth_token}))
    print("[io] connect namespace")
    tunnel.send(f"42{ns}," + json.dumps(["resume", {"session_id": args.session_id, "profile": args.profile}]))
    print("[io] resume")
    tunnel.send(f"42{ns}," + json.dumps(["run", {
        "session_id": args.session_id,
        "input": args.input,
        "profile": args.profile,
    }]))
    print(f"[io] run: {args.input!r}")

    print("=== listening for events (Ctrl-C to stop early) ===")
    try:
        tunnel.wait(args.timeout)
    except KeyboardInterrupt:
        pass
    finally:
        tunnel.close()
        c._stop.set()
        print("=== done ===")


if __name__ == "__main__":
    main()
