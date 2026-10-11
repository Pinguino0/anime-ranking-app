import 'dart:async';

import 'package:animerank/features/notifications/data/push_messaging.dart';

/// Servizio push finto: nessun Firebase, stato deciso dal test.
///
/// I tre stream copiano quelli veri e si pilotano con [emitMessage],
/// [emitOpened] e [emitTokenRefresh].
class FakePushMessaging implements PushMessaging {
  FakePushMessaging({
    this.supported = true,
    this.granted = true,
    this.deviceToken = 'token-di-prova',
    this.platform = 'android',
    this.initial,
  });

  bool supported;
  bool granted;
  String? deviceToken;

  @override
  final String platform;

  /// Messaggio che ha avviato l'app, se il test ne simula uno.
  final PushMessage? initial;

  int permissionRequests = 0;

  @override
  bool get isSupported => supported;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return granted;
  }

  @override
  Future<String?> token() async => deviceToken;

  final _refresh = StreamController<String>.broadcast();
  final _messages = StreamController<PushMessage>.broadcast();
  final _opened = StreamController<PushMessage>.broadcast();

  @override
  Stream<String> get onTokenRefresh => _refresh.stream;

  @override
  Stream<PushMessage> get onMessage => _messages.stream;

  @override
  Stream<PushMessage> get onMessageOpenedApp => _opened.stream;

  @override
  Future<PushMessage?> initialMessage() async => initial;

  void emitMessage(PushMessage message) => _messages.add(message);

  void emitOpened(PushMessage message) => _opened.add(message);

  void emitTokenRefresh(String token) => _refresh.add(token);

  void dispose() {
    _refresh.close();
    _messages.close();
    _opened.close();
  }
}
