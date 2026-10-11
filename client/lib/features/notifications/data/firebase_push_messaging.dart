import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'push_messaging.dart';

/// Gestore dei push arrivati ad app chiusa o in secondo piano.
///
/// Gira in un isolate separato, quindi Firebase va inizializzato di nuovo: senza
/// questa chiamata il messaggio non ha un'app a cui appartenere. Non c'e' altro
/// da fare perche' i push hanno un campo `notification`, e il sistema li mostra
/// da solo; questa e' la strada che li fa comparire nel cassetto a telefono
/// bloccato.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

/// Il servizio push vero, sopra `firebase_messaging`.
///
/// Sta in un file a parte da [PushMessaging] per un motivo pratico: tutto cio'
/// che importa questo file tira dentro l'SDK di Google, e i test non devono
/// pagarne il prezzo.
class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  @override
  bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  String get platform =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  @override
  Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // In primo piano non si fa mostrare la notifica al sistema: la disegna
    // l'app, cosi' il tap puo' portare alla schermata giusta invece di
    // limitarsi a riaprire l'ultima.
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: false,
      badge: true,
      sound: true,
    );
  }

  @override
  Future<bool> requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    final status = settings.authorizationStatus;
    return status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
  }

  @override
  Future<String?> token() async {
    try {
      return await _messaging.getToken();
    } catch (error) {
      // iOS senza APNs configurato, emulatore, rete assente: nessun token, e il
      // dispositivo semplicemente non riceve push finche' il problema resta.
      debugPrint('Token FCM non disponibile: $error');
      return null;
    }
  }

  @override
  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;

  @override
  Stream<PushMessage> get onMessage =>
      FirebaseMessaging.onMessage.map(_toPushMessage);

  @override
  Stream<PushMessage> get onMessageOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp.map(_toPushMessage);

  @override
  Future<PushMessage?> initialMessage() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : _toPushMessage(message);
  }
}

String? _asString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// Riduce un `RemoteMessage` a un [PushMessage].
PushMessage _toPushMessage(RemoteMessage message) {
  // Il contenuto del webhook viaggia dentro `payload` (una stringa JSON),
  // perche' FCM accetta solo stringhe nei dati. Si scioglie e si fonde con gli
  // altri campi, cosi' una chiave sola vale per tutto.
  final payload = _decodePayload(message.data['payload']);
  final notification = message.notification;

  return PushMessage(
    title: notification?.title ?? _asString(payload['title']) ?? '',
    body: notification?.body ?? _asString(payload['body']) ?? '',
    data: {...message.data, ...payload},
  );
}

Map<String, dynamic> _decodePayload(Object? raw) {
  if (raw is! String || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) return decoded.cast<String, dynamic>();
  } catch (_) {
    // Payload illeggibile: si resta con i soli campi FCM, senza far fallire
    // l'apertura della notifica.
  }
  return const {};
}
