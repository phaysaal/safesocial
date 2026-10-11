import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/crypto/mailbox.dart';
import 'package:spheres_app/services/relay_config.dart';
import 'package:spheres_app/services/relay_service.dart';

/// A socket that records what the client sent and lets the test answer.
class FakeSocket implements RelaySocket {
  final sent = <Map<String, dynamic>>[];
  final _incoming = StreamController<dynamic>.broadcast();
  final Completer<void> _ready = Completer();
  bool closed = false;

  FakeSocket({bool failHandshake = false}) {
    if (failHandshake) {
      _ready.completeError(Exception('refused'));
    } else {
      _ready.complete();
    }
  }

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  void send(String frame) => sent.add(jsonDecode(frame) as Map<String, dynamic>);

  @override
  Future<void> close() async {
    closed = true;
    await _incoming.close();
  }

  void receive(Map<String, Object?> frame) => _incoming.add(jsonEncode(frame));

  void dropConnection() => _incoming.close();

  Iterable<Map<String, dynamic>> ofType(String t) => sent.where((f) => f['t'] == t);
}

/// One socket at a time, handed out in order so a test can see reconnects.
class SocketFactory {
  final List<FakeSocket> created = [];
  final List<bool> failures;
  SocketFactory({this.failures = const []});

  RelaySocket call(Uri uri) {
    final fail = created.length < failures.length && failures[created.length];
    final s = FakeSocket(failHandshake: fail);
    created.add(s);
    return s;
  }

  FakeSocket get current => created.last;
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

/// Publish and answer it the way the relay does: with a `sent` frame carrying
/// the publish's id. The hub only reports success once that arrives.
Future<bool> publishAcked(SocketFactory sockets, RelayService service,
    String key, String payload) async {
  final result = service.sendViaRelay(key, payload);
  await settle();
  final pub = sockets.current.ofType('pub').last;
  sockets.current.receive({'t': 'sent', 'a': pub['a'], 'id': pub['id']});
  return result;
}

void main() {
  late SocketFactory sockets;

  setUp(() {
    RelayHub.instance.debugReset();
    sockets = SocketFactory();
    RelayHub.instance.connector = sockets.call;
    RelayHub.instance.syncOverride = (_, __) async => 0;
  });

  tearDown(() => RelayHub.instance.debugReset());

  Future<Mailbox> mailbox(String secret) =>
      Mailbox.fromLocalSecret(secret: secret, purpose: 'test');

  test('two services on two mailboxes share one socket', () async {
    final chat = RelayService();
    final feed = RelayService();
    final a = await mailbox('a');
    final b = await mailbox('b');

    await chat.connectMailbox('alice', a);
    await feed.connectMailbox('alice', b);
    await settle();

    expect(sockets.created.length, 1, reason: 'one hub socket for everything');
    final subs = sockets.current.ofType('sub').toList();
    expect(subs.map((s) => s['a']), containsAll([a.id, b.id]));
    // Each subscription is signed by its own mailbox.
    for (final s in subs) {
      expect(s['sig'], isA<String>());
      expect((s['sig'] as String).length, 128);
    }
    expect(chat.stateFor('alice'), RelayConnectionState.connecting);
  });

  test('a confirmed subscription becomes connected and flushes onConnected',
      () async {
    final chat = RelayService();
    final a = await mailbox('a');
    final connected = <String>[];
    chat.onConnected = connected.add;

    await chat.connectMailbox('alice', a);
    await settle();

    sockets.current.receive({'t': 'ok', 'a': a.id});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(chat.isConnected('alice'), isTrue);
    expect(connected, ['alice']);
  });

  test('messages are routed to the service that owns the mailbox', () async {
    final chat = RelayService();
    final feed = RelayService();
    final a = await mailbox('a');
    final b = await mailbox('b');
    final chatGot = <String>[];
    final feedGot = <String>[];
    chat.onMessageReceived = (key, p) => chatGot.add('$key:$p');
    feed.onMessageReceived = (key, p) => feedGot.add('$key:$p');

    await chat.connectMailbox('alice', a);
    await feed.connectMailbox('alice', b);
    await settle();
    sockets.current.receive({'t': 'ok', 'a': a.id});
    sockets.current.receive({'t': 'ok', 'a': b.id});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    sockets.current.receive({'t': 'msg', 'a': a.id, 'd': '5:hello     '});
    sockets.current.receive({'t': 'msg', 'a': b.id, 'd': '4:post    '});
    await settle();

    expect(chatGot, ['alice:hello']);
    expect(feedGot, ['alice:post']);
  });

  test('live frames that arrive during the offline drain are held back',
      () async {
    final chat = RelayService();
    final a = await mailbox('a');
    final got = <String>[];
    chat.onMessageReceived = (_, p) => got.add(p);

    // A slow drain that finds one queued message.
    final drained = Completer<void>();
    RelayHub.instance.syncOverride = (_, deliver) async {
      await drained.future;
      deliver('queued');
      return 1;
    };

    await chat.connectMailbox('alice', a);
    await settle();
    sockets.current.receive({'t': 'ok', 'a': a.id});
    await settle();
    // The drain is in flight; a live frame arrives meanwhile.
    sockets.current.receive({'t': 'msg', 'a': a.id, 'd': '4:live'});
    await settle();
    expect(got, isEmpty, reason: 'held until the mailbox is drained');
    expect(chat.isConnected('alice'), isFalse);

    drained.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(got, ['queued', 'live'], reason: 'offline mail first, then live');
    expect(chat.isConnected('alice'), isTrue);
  });

  test('publishing before the subscription is confirmed is refused', () async {
    final chat = RelayService();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();

    expect(await chat.sendViaRelay('alice', 'x'), isFalse);

    sockets.current.receive({'t': 'ok', 'a': a.id});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await publishAcked(sockets, chat, 'alice', 'x'), isTrue);
    final pub = sockets.current.ofType('pub').single;
    expect(pub['a'], a.id);
    expect((pub['d'] as String).startsWith('1:x'), isTrue);
    expect((pub['d'] as String).length, 512, reason: 'padded to a bucket');
  });

  test('a dropped socket resubscribes everything on reconnect', () async {
    final chat = RelayService();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();
    sockets.current.receive({'t': 'ok', 'a': a.id});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(chat.isConnected('alice'), isTrue);

    sockets.current.dropConnection();
    await settle();
    expect(chat.stateFor('alice'), RelayConnectionState.connecting);
    expect(await chat.sendViaRelay('alice', 'x'), isFalse);

    // Reconnect is on a backoff timer; a resume check forces it now.
    await RelayService.verifyAll();
    await settle();
    expect(sockets.created.length, 2);
    expect(sockets.current.ofType('sub').single['a'], a.id);
  });

  test('a mailbox that forgot us is re-proven, not abandoned', () async {
    final chat = RelayService();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();
    sockets.current.receive({'t': 'ok', 'a': a.id});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    sockets.current.receive({'t': 'err', 'a': a.id, 'e': 'unsubscribed'});
    await settle();

    expect(sockets.current.ofType('sub').length, 2);
  });

  test('the last listener leaving unsubscribes and closes the socket', () async {
    final chat = RelayService();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();
    sockets.current.receive({'t': 'ok', 'a': a.id});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    chat.disconnect('alice');
    await settle();

    expect(sockets.current.ofType('unsub').single['a'], a.id);
    expect(sockets.current.closed, isTrue);
    expect(RelayHub.instance.subscriptionCount, 0);
    expect(chat.stateFor('alice'), RelayConnectionState.disconnected);
  });

  test('one service leaving does not disturb another on a different mailbox',
      () async {
    final chat = RelayService();
    final feed = RelayService();
    final a = await mailbox('a');
    final b = await mailbox('b');
    await chat.connectMailbox('alice', a);
    await feed.connectMailbox('alice', b);
    await settle();
    sockets.current.receive({'t': 'ok', 'a': a.id});
    sockets.current.receive({'t': 'ok', 'a': b.id});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    chat.disconnectAll();
    await settle();

    expect(sockets.current.closed, isFalse);
    expect(feed.isConnected('alice'), isTrue);
    expect(RelayHub.instance.subscriptionCount, 1);
  });

  test('a failed handshake falls back once, then retries the primary', () async {
    sockets = SocketFactory(failures: [true, false]);
    RelayHub.instance.connector = sockets.call;
    final chat = RelayService();
    final a = await mailbox('a');

    await chat.connectMailbox('alice', a);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(sockets.created.length, 2, reason: 'primary failed, fallback tried');
    expect(sockets.current.ofType('sub').single['a'], a.id);
  });

  test('a malformed frame is ignored', () async {
    final chat = RelayService();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();

    RelayHub.instance.debugReceive('not json');
    RelayHub.instance.debugReceive('{"t":"msg"}');
    RelayHub.instance.debugReceive('{"t":"msg","a":"unknown","d":"x"}');
    await settle();

    expect(chat.stateFor('alice'), RelayConnectionState.connecting);
  });

  test('a peer on another relay is sent to there, signed, not over our socket',
      () async {
    final chat = RelayService();
    final a = await mailbox('a');
    final posted = <(String, String, String)>[];
    RelayHub.instance.remotePostOverride = (host, mb, payload) async {
      posted.add((host, mb.id, payload));
      return true;
    };
    RelayHub.instance.peerHostResolver =
        (key) => key == 'alice' ? 'relay.elsewhere.eu' : null;

    await chat.connectMailbox('alice', a);
    await settle();
    sockets.current.receive({'t': 'ok', 'a': a.id});
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(await chat.sendViaRelay('alice', 'hi'), isTrue);

    expect(posted.single.$1, 'relay.elsewhere.eu');
    expect(posted.single.$2, a.id);
    expect(posted.single.$3, startsWith('2:hi'), reason: 'padded like any frame');
    expect(sockets.current.ofType('pub'), isEmpty,
        reason: 'nothing for them goes to our relay');
  });

  test('a peer on another relay can be reached before our socket is up',
      () async {
    final chat = RelayService();
    final a = await mailbox('a');
    var posts = 0;
    RelayHub.instance.remotePostOverride = (_, __, ___) async {
      posts++;
      return true;
    };
    RelayHub.instance.peerHostResolver = (_) => 'relay.elsewhere.eu';

    await chat.connectMailbox('alice', a);
    // No 'ok' yet: our own subscription is still pending.
    expect(await chat.sendViaRelay('alice', 'hi'), isTrue);
    expect(posts, 1);
  });

  test('a peer on our own relay still goes over the socket', () async {
    final chat = RelayService();
    final a = await mailbox('a');
    var posts = 0;
    RelayHub.instance.remotePostOverride = (_, __, ___) async {
      posts++;
      return true;
    };
    RelayHub.instance.peerHostResolver = (_) => RelayConfig.primaryHost;

    await chat.connectMailbox('alice', a);
    await settle();
    sockets.current.receive({'t': 'ok', 'a': a.id});
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(await publishAcked(sockets, chat, 'alice', 'hi'), isTrue);
    expect(posts, 0);
    expect(sockets.current.ofType('pub'), hasLength(1));
  });

  group('a publish is only sent once the relay says so', () {
    late RelayService chat;
    late Mailbox a;

    setUp(() async {
      chat = RelayService();
      a = await mailbox('a');
      await chat.connectMailbox('alice', a);
      await settle();
      sockets.current.receive({'t': 'ok', 'a': a.id});
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    test('a write the relay never acknowledges is reported as not sent',
        () async {
      final before = RelayHub.sendAckTimeout;
      RelayHub.sendAckTimeout = const Duration(milliseconds: 60);
      addTearDown(() => RelayHub.sendAckTimeout = before);

      // The frame goes out, so a half-dead socket looks exactly like this.
      final result = chat.sendViaRelay('alice', 'hi');
      await settle();
      expect(sockets.current.ofType('pub'), hasLength(1));
      expect(await result, isFalse,
          reason: 'the outbox must keep it and try again');
    });

    test('an error frame for the address fails the publish at once', () async {
      final result = chat.sendViaRelay('alice', 'hi');
      await settle();
      sockets.current.receive({'t': 'err', 'a': a.id, 'e': 'full'});
      expect(await result, isFalse);
    });

    test('a socket that drops mid-flight fails what was waiting', () async {
      final result = chat.sendViaRelay('alice', 'hi');
      await settle();
      sockets.current.dropConnection();
      expect(await result, isFalse);
    });

    test('acknowledgements are matched by id, not by order', () async {
      final first = chat.sendViaRelay('alice', 'one');
      final second = chat.sendViaRelay('alice', 'two');
      await settle();
      final pubs = sockets.current.ofType('pub').toList();
      expect(pubs, hasLength(2));
      sockets.current.receive({'t': 'sent', 'a': a.id, 'id': pubs[1]['id']});
      expect(await second, isTrue);
      sockets.current.receive({'t': 'sent', 'a': a.id, 'id': pubs[0]['id']});
      expect(await first, isTrue);
    });
  });

  group('a drain delivers nothing twice', () {
    late RelayService chat;
    late Mailbox a;
    late List<String> got;

    setUp(() async {
      chat = RelayService();
      a = await mailbox('a');
      got = [];
      chat.onMessageReceived = (_, p) => got.add(p);
      await chat.connectMailbox('alice', a);
      await settle();
      sockets.current.receive({'t': 'ok', 'a': a.id});
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    test('a message delivered live is acknowledged by a later drain, not redelivered',
        () async {
      sockets.current.receive({'t': 'msg', 'a': a.id, 'd': '5:hello'});
      await settle();
      expect(got, ['hello']);

      // The relay keeps it queued until acknowledged, so the drain hands it
      // back along with something genuinely new.
      var fresh = 0;
      RelayHub.instance.syncOverride = (_, deliver) async {
        if (deliver('hello')) fresh++;
        if (deliver('later')) fresh++;
        return fresh;
      };
      await RelayHub.instance.syncMailbox(RelayHub.instance.debugSubscription(a.id)!);

      expect(got, ['hello', 'later']);
      expect(fresh, 1, reason: 'only the new one counts as missed by the socket');
    });

    test('our own publish coming back from the shared mailbox is swallowed',
        () async {
      await publishAcked(sockets, chat, 'alice', 'mine');
      RelayHub.instance.syncOverride = (_, deliver) async => deliver('mine') ? 1 : 0;
      final fresh = await RelayHub.instance
          .syncMailbox(RelayHub.instance.debugSubscription(a.id)!);

      expect(fresh, 0);
      expect(got, isEmpty, reason: 'a listener never sees its own message');
    });

    test('a live frame repeated by the relay is delivered once', () async {
      sockets.current.receive({'t': 'msg', 'a': a.id, 'd': '3:one'});
      sockets.current.receive({'t': 'msg', 'a': a.id, 'd': '3:one'});
      sockets.current.receive({'t': 'msg', 'a': a.id, 'd': '3:two'});
      await settle();
      expect(got, ['one', 'two']);
    });

    test('a quiet socket is only replaced when the drain finds new mail', () async {
      sockets.current.receive({'t': 'msg', 'a': a.id, 'd': '4:seen'});
      await settle();
      final sub = RelayHub.instance.debugSubscription(a.id)!;
      sub.lastActivity = DateTime.now().subtract(RelayHub.idleBefore * 2);

      RelayHub.instance.syncOverride = (_, deliver) async => deliver('seen') ? 1 : 0;
      await RelayHub.instance.verifyIdle();
      await settle();
      expect(sockets.created.length, 1, reason: 'nothing was missed; keep the socket');

      sub.lastActivity = DateTime.now().subtract(RelayHub.idleBefore * 2);
      RelayHub.instance.syncOverride = (_, deliver) async => deliver('missed') ? 1 : 0;
      await RelayHub.instance.verifyIdle();
      await settle();
      expect(sockets.created.length, 2, reason: 'the socket had missed one');
      expect(got, ['seen', 'missed']);
    });
  });
}
