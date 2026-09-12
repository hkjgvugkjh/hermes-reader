import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_reader/reader/services/proxy_client.dart';

/// Reproduces the shelf timeout: two overlapping `connect()` calls used to open
/// two sockets, and the loser waited out its full 30s timeout on a dead one.
void main() {
  test('overlapping connects share a single handshake', () async {
    final h = _Harness();
    h.handshake = (attempt) async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      h.succeed();
    };

    await Future.wait<void>([
      h.client.connect(),
      h.client.connect(),
      h.client.connect(),
    ]);

    expect(h.attempts, 1, reason: 'three callers must not open three sockets');
    expect(h.client.isConnected, isTrue);
  });

  test('a connected client short-circuits further calls', () async {
    final h = _Harness();
    h.handshake = (_) async => h.succeed();

    await h.client.connect();
    await h.client.connect();
    await h.client.connect();

    expect(h.attempts, 1);
  });

  test('a failed handshake is not sticky', () async {
    final h = _Harness();
    h.handshake = (attempt) async {
      if (attempt == 1) throw Exception('dial failed');
      h.succeed();
    };

    await expectLater(h.client.connect(), throwsA(isA<Exception>()));

    // The guard must have been released, or this would hang.
    await h.client.connect();

    expect(h.attempts, 2);
    expect(h.client.isConnected, isTrue);
  });

  test('all waiters see a shared failure', () async {
    final h = _Harness();
    h.handshake = (_) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      throw Exception('dial failed');
    };

    final results = await Future.wait<String>([
      h.client.connect().then((_) => 'ok', onError: (_) => 'failed'),
      h.client.connect().then((_) => 'ok', onError: (_) => 'failed'),
    ]);

    expect(results, ['failed', 'failed']);
  });

  test('disconnect resets state and allows reconnecting', () async {
    final h = _Harness();
    h.handshake = (_) async => h.succeed();

    await h.client.connect();
    h.client.disconnect();
    expect(h.client.isConnected, isFalse);

    await h.client.connect();
    expect(h.attempts, 2);
  });
}

/// A client wired to a scripted handshake, plus how many times it ran.
class _Harness {
  _Harness() {
    client.handshakeOverride = () {
      attempts++;
      return handshake(attempts);
    };
  }

  final ProxyClient client = ProxyClient(proxyUrl: 'ws://127.0.0.1:1/ws');
  int attempts = 0;

  late Future<void> Function(int attempt) handshake;

  /// Completes the handshake the way a real key exchange would.
  void succeed() => client.markConnectedForTest();
}
