// Re-export the canonical ProxyClient implementation from hermes_shared.
//
// The shared package is now the single source of truth for the hermes-proxy
// DI protocol (X25519 handshake, ChaCha20-Poly1305, HTTP tunneling, backend
// JWT, WS tunnels) plus the high-level TTS/personal-library clients. Keeping a
// thin re-export here means existing `import '../services/proxy_client.dart'`
// sites in the reader keep working without code changes while we dogfood the
// shared package. Import `package:hermes_shared/hermes_shared.dart` directly in
// new code.
export 'package:hermes_shared/hermes_shared.dart'
    show
        ProxyClient,
        ProxyTunnel,
        ProxyTunnelException,
        KeyExchangeException,
        ConnectionClosedException;
