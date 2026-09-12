import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_reader/reader/services/proxy_client.dart';

/// The shelf failed to connect because the WebSocket URL was malformed:
/// `https://hermes-proxy.example.org:0/ws?token=a?token=b`.
/// The `:0` came from `Uri.hasPort` being true on a default-port URL, and the
/// doubled token from appending to a query string that already had one.
void main() {
  Uri build(String url, {String? token}) =>
      ProxyClient(proxyUrl: url, authToken: token).buildUri();

  test('https becomes wss without a bogus port', () {
    final uri = build('https://hermes-proxy.example.org/ws');

    expect(uri.scheme, 'wss');
    expect(uri.host, 'hermes-proxy.example.org');
    expect(uri.hasPort, isFalse, reason: ':0 must not appear');
    expect(uri.toString(), isNot(contains(':443')),
        reason: 'the default wss port must not be spelled out');
    expect(uri.path, '/ws');
  });

  test('http becomes ws on the default port', () {
    final uri = build('http://192.168.1.10/ws');

    expect(uri.scheme, 'ws');
    expect(uri.hasPort, isFalse);
    expect(uri.toString(), isNot(contains(':80')),
        reason: 'the default ws port must not be spelled out');
  });

  test('a non-default port is preserved', () {
    final uri = build('https://proxy.example.org:8443/ws');

    expect(uri.scheme, 'wss');
    expect(uri.port, 8443);
    expect(uri.hasPort, isTrue);
  });

  test('ws and wss pass through unchanged', () {
    expect(build('wss://a.example.org/ws').scheme, 'wss');
    expect(build('ws://a.example.org/ws').scheme, 'ws');
  });

  test('the auth token is set once, not appended', () {
    final uri = build('https://proxy.example.org/ws', token: 'SECRET');

    expect(uri.queryParameters['token'], 'SECRET');
    expect(uri.query, 'token=SECRET',
        reason: 'a doubled ?token= would mean it was appended twice');
  });

  test('a token in the url is replaced by the explicit one', () {
    final uri = build('https://proxy.example.org/ws?token=OLD', token: 'NEW');

    expect(uri.queryParameters['token'], 'NEW');
    expect(uri.queryParameters.length, 1);
  });

  test('a token in the url survives when no explicit token is given', () {
    final uri = build('https://proxy.example.org/ws?token=KEEP');

    expect(uri.queryParameters['token'], 'KEEP');
  });

  test('a missing path falls back to the websocket path', () {
    expect(build('https://proxy.example.org').path, '/ws');
  });

  test('the resulting url is parseable and diallable', () {
    // The original bug produced a URL Uri.parse accepted but nothing could use.
    final uri = build(
      'https://hermes-proxy.willam.eu.org/ws?token=O1KseSrfoNAy8fIFFtIuK67gL6U2idIu',
      token: 'O1KseSrfoNAy8fIFFtIuK67gL6U2idIu',
    );

    expect(uri.toString(), isNot(contains(':0')));
    expect(uri.toString(), isNot(contains('?token=O1KseSrfoNAy8fIFFtIuK67gL6U2idIu?token=')));
    expect(uri.toString(),
        'wss://hermes-proxy.willam.eu.org/ws?token=O1KseSrfoNAy8fIFFtIuK67gL6U2idIu');
  });
}
