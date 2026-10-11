import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_repository.dart';
import '../domain/auth_status.dart';

/// Repository di autenticazione.
///
/// Esposto come provider e non letto direttamente dal client Supabase, cosi'
/// i test possono iniettare [AuthRepository] finto con
/// `authRepositoryProvider.overrideWithValue(...)`.
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  throw StateError(
    'authRepositoryProvider non e stato inizializzato. '
    'Deve essere sovrascritto in main() o nel test.',
  );
});

/// Espone lo stato di sessione dell'app.
///
/// E' un [Notifier] e non uno `AsyncNotifier` perche' GoRouter ha bisogno di
/// uno stato sincrono in `redirect`: con uno `AsyncNotifier` la prima
/// valutazione vedrebbe "caricamento" e l'utente vedrebbe un lampo della
/// schermata sbagliata a ogni avvio.
///
/// Lo stato iniziale e' gia' definitivo perche' Supabase ripristina la
/// sessione da disco in modo sincrono prima del primo frame. Lo stream serve
/// solo per i cambi successivi (login, logout, refresh del token).
class AuthController extends Notifier<AuthStatus> {
  @override
  AuthStatus build() {
    final repo = ref.watch(authRepositoryProvider);

    final subscription = repo.watch().listen((status) => state = status);
    ref.onDispose(subscription.cancel);

    return AuthStatus.fromSession(repo.currentSession);
  }

  /// Scollega l'utente.
  ///
  /// Non tocca lo stato a mano: arriva comunque un evento dal canale auth di
  /// Supabase, e impostarlo qui creerebbe due fonti di verita' che possono
  /// divergere se un evento arriva dopo un logout locale.
  ///
  /// La copia su disco la pulisce [SessionCacheCleanup], che ascolta lo stesso
  /// canale: qui non si sa nulla di cache e non si deve indovinare.
  Future<void> signOut() async {
    await ref.read(authRepositoryProvider).signOut();
  }
}

/// Stato di sessione letto da router e schermate.
final authStatusProvider = NotifierProvider<AuthController, AuthStatus>(AuthController.new);

/// true mentre l'app e' nel mezzo di un recupero password.
///
/// Diventa true quando Supabase apre una sessione da un link di reset. Il
/// router lo usa per tenere l'utente sulla schermata di cambio password: senza,
/// l'utente entrerebbe nell'app con la password vecchia ancora valida e il
/// recupero non servirebbe a niente.
class PasswordRecoveryController extends Notifier<bool> {
  @override
  bool build() {
    final repo = ref.watch(authRepositoryProvider);
    final subscription = repo.watchPasswordRecovery().listen((_) => state = true);
    ref.onDispose(subscription.cancel);
    return false;
  }

  /// Chiude il recupero: da qui in poi valgono le regole normali di sessione.
  void finish() => state = false;
}

final passwordRecoveryPendingProvider =
    NotifierProvider<PasswordRecoveryController, bool>(
  PasswordRecoveryController.new,
);