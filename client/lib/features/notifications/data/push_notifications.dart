import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'push_messaging.dart';

/// La notifica di sistema con cui si mostrano i push mentre l'app e' aperta.
///
/// Android non mostra da solo un push arrivato con l'app in primo piano: senza
/// questo, il consiglio comparirebbe solo nel centro notifiche in-app e non nel
/// cassetto. Il canale e' lo stesso che usa la notifica di sfondo (`send-push`
/// lo indica nel payload), cosi' l'avviso ha lo stesso aspetto nei due casi.
class PushNotifications {
  PushNotifications._();

  static final PushNotifications instance = PushNotifications._();

  static const String channelId = 'animerank_default';
  static const String channelName = 'Consigli e avvisi';
  static const String channelDescription =
      'Consigli di visione e avvisi dei gruppi.';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Id sempre diverso: ogni consiglio e' un avviso a se', e due consigli
  /// ravvicinati non devono sovrascriversi a vicenda.
  int _nextId = 1;

  Future<void> initialize() async {
    if (_initialized) return;

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        // Il permesso lo chiede [PushMessaging], non il plugin: qui ci si limita
        // a saper mostrare quello che arriva.
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(settings: settings);

    // Da Android 8 il canale e' obbligatorio: senza, sia questa notifica sia
    // quella di sfondo non compaiono.
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            channelId,
            channelName,
            description: channelDescription,
            importance: Importance.high,
          ),
        );

    _initialized = true;
  }

  /// Mostra un push in primo piano.
  Future<void> show(PushMessage message) async {
    if (message.isEmpty) return;

    await _plugin.show(
      id: _nextId++,
      title: message.title,
      body: message.body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }
}
