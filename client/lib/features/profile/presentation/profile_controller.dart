import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_retry.dart';
import '../data/profile_repository.dart';
import '../domain/user_profile.dart';

/// Repository del profilo.
final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  throw StateError('profileRepositoryProvider non e stato inizializzato.');
});

/// Profilo dell'utente collegato.
///
/// Le preferenze di notifica vivono tutte sulla stessa riga di `profiles`, ma
/// sono un gruppo diverso dal profilo pubblico: sono impostazioni del device e
/// non vanno mostrate accanto a username e bio. Sono quindi in un controller
/// separato, perche' cosi' salvare una preferenza non ricostruisce la
/// schermata del profilo (e viceversa).
class ProfileController extends AsyncNotifier<UserProfile> {
  @override
  Future<UserProfile> build() => ref.watch(profileRepositoryProvider).loadMine();

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }

  /// Salva i campi del profilo e mette subito in stato il risultato.
  ///
  /// Lo stato locale viene aggiornato prima ancora che la schermata venga
  /// chiusa, cosi' il campo mostra quello che l'utente ha scritto e non
  /// torna indietro per un frame durante il salvataggio.
  Future<void> save({String? username, String? bio, String? avatarUrl}) async {
    final updated = await ref.read(profileRepositoryProvider).updateMine(
          username: username,
          bio: bio,
          avatarUrl: avatarUrl,
        );
    state = AsyncData(updated);
  }

  /// Cancella l'account.
  ///
  /// Non tocca lo stato del provider: dopo la cancellazione la sessione non
  /// esiste piu' e il router porta al login. Provare a impostare qui uno stato
  /// significherebbe ridisegnare il profello di un utente inesistente.
  Future<void> deleteAccount() => ref.read(profileRepositoryProvider).deleteAccount();
}

final profileProvider = AsyncNotifierProvider<ProfileController, UserProfile>(
  ProfileController.new,
  retry: appRetry,
);

/// Preferenze di notifica.
class NotificationPreferencesController extends AsyncNotifier<NotificationPreferences> {
  @override
  Future<NotificationPreferences> build() =>
      ref.watch(profileRepositoryProvider).loadNotifications();

  Future<void> set({
    bool? push,
    bool? votes,
    bool? friends,
    bool? tournaments,
    bool? rankChanges,
    bool? recommendations,
  }) async {
    final current = state.value;
    if (current == null) return;

    final next = current.copyWith(
      push: push,
      votes: votes,
      friends: friends,
      tournaments: tournaments,
      rankChanges: rankChanges,
      recommendations: recommendations,
    );

    // Aggiornamento ottimistico: un interruttore che scatta e torna indietro
    // solo dopo mezzo secondo sembra rotto. Se il salvataggio fallisce si
    // torna al valore precedente, cosi' l'interruttore non mente.
    state = AsyncData(next);

    try {
      await ref.read(profileRepositoryProvider).saveNotifications(next);
    } catch (_) {
      state = AsyncData(current);
      rethrow;
    }
  }
}

final notificationPreferencesProvider =
    AsyncNotifierProvider<NotificationPreferencesController, NotificationPreferences>(
  NotificationPreferencesController.new,
  retry: appRetry,
);
