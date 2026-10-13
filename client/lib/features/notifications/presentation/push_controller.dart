import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/app_router.dart';
import '../../auth/domain/auth_status.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/device_token_repository.dart';
import '../data/push_messaging.dart';
import '../data/push_notifications.dart';

/// Il servizio push disponibile.
///
/// Di default e' muto: [main] lo sostituisce con quello vero dopo aver
/// inizializzato Firebase. Cosi' i test, il desktop e una build senza
/// `google-services.json` non toccano mai l'SDK di Google.
final pushMessagingProvider = Provider<PushMessaging>(
  (ref) => const UnsupportedPushMessaging(),
);

/// Scrittura del token sul database.
final deviceTokenRepositoryProvider = Provider<DeviceTokenRepository>((ref) {
  throw StateError(
    'deviceTokenRepositoryProvider non e stato inizializzato. '
    'Deve essere sovrascritto in main() con ProviderScope(overrides: ...).',
  );
});

/// Tiene allineati dispositivo e account, e apre la schermata giusta al tocco.
///
/// Va letto una volta all'avvio (in [main]) e resta vivo per tutta l'esecuzione:
/// non e' uno stato da guardare, e' un servizio con degli ascoltatori.
final pushControllerProvider = Provider<PushController>((ref) {
  final controller = PushController(ref);
  ref.listen(
    authStatusProvider,
    (_, next) => controller.onAuthChanged(next),
    fireImmediately: true,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// Tiene allineati il token del dispositivo e l'account collegato.
///
/// Un solo pezzo di logica, tre ingressi:
///
///   * l'account cambia (login/logout) e il token va registrato o tolto;
///   * FCM rinnova il token e va riscritto;
///   * arriva un push, che va mostrato o aperto.
class PushController {
  PushController(this._ref) {
    final messaging = _ref.read(pushMessagingProvider);
    _subscriptions.addAll([
      messaging.onTokenRefresh.listen(_onTokenRefresh),
      messaging.onMessage.listen(_onMessage),
      messaging.onMessageOpenedApp.listen(_open),
    ]);
    unawaited(_openInitial());
  }

  final Ref _ref;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// Il permesso si chiede una volta per esecuzione: ripeterlo a ogni accesso
  /// non aggiunge nulla, il sistema risponde con la scelta gia' presa.
  bool _permissionAsked = false;

  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
  }

  /// Chiamato a ogni cambio di stato dell'accesso.
  Future<void> onAuthChanged(AuthStatus status) async {
    switch (status) {
      case AuthSignedIn():
        await _register();
      case AuthSignedOut():
        await _unregister();
    }
  }

  Future<void> _register() async {
    final messaging = _ref.read(pushMessagingProvider);
    if (!messaging.isSupported) return;

    if (!_permissionAsked) {
      _permissionAsked = true;
      final granted = await messaging.requestPermission();
      if (!granted) return;
    }

    final token = await messaging.token();
    await _write(token: token, platform: messaging.platform);
  }

  Future<void> _unregister() async {
    final messaging = _ref.read(pushMessagingProvider);
    if (!messaging.isSupported) return;

    final token = await messaging.token();
    if (token == null || token.isEmpty) return;

    try {
      await _ref.read(deviceTokenRepositoryProvider).remove(token: token);
    } catch (error, stack) {
      // Un logout non deve fallire perche' il token non si e' tolto: al
      // prossimo accesso viene comunque riassegnato.
      debugPrint('Rimozione del token push fallita: $error');
      debugPrintStack(stackTrace: stack);
    }
  }

  void _onTokenRefresh(String token) {
    if (!_ref.read(authStatusProvider).isSignedIn) return;
    unawaited(
      _write(token: token, platform: _ref.read(pushMessagingProvider).platform),
    );
  }

  Future<void> _write({required String? token, required String platform}) async {
    if (token == null || token.isEmpty) return;
    try {
      await _ref
          .read(deviceTokenRepositoryProvider)
          .register(token: token, platform: platform);
    } catch (error, stack) {
      // Senza token registrato non arrivano push, ma l'app funziona lo stesso.
      debugPrint('Registrazione del token push fallita: $error');
      debugPrintStack(stackTrace: stack);
    }
  }

  void _onMessage(PushMessage message) {
    unawaited(_show(message));
  }

  Future<void> _show(PushMessage message) async {
    try {
      await PushNotifications.instance.show(message);
    } catch (error) {
      debugPrint('Notifica in primo piano non mostrata: $error');
    }
  }

  Future<void> _openInitial() async {
    final message = await _ref.read(pushMessagingProvider).initialMessage();
    if (message != null) _open(message);
  }

  /// Apre la schermata giusta al tocco della notifica.
  ///
  /// Un "nuovo episodio" porta subito all'episodio annunciato: e' l'unica cosa
  /// utile che l'utente puo' fare con quell'avviso, e il numero viaggia nel link
  /// proprio per aprirlo davvero invece del primo.
  ///
  /// Un consiglio porta al gruppo che l'ha mandato, dove l'opera compare nella
  /// sezione "Consigliati dal gruppo". Senza gruppo (o con un payload inatteso)
  /// si va alla home: meglio una schermata sensata che una vuota.
  void _open(PushMessage message) {
    final router = _ref.read(appRouterProvider);

    if (message.type == 'new_episode') {
      final animeId = message.animeId;
      if (animeId != null) {
        router.go(AppRoutes.latestEpisode(animeId, message.episodeNumber));
        return;
      }
    }

    final groupId = message.groupId;
    router.go(groupId == null ? AppRoutes.home : AppRoutes.watchlist(groupId));
  }
}
