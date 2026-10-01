import 'dart:async';

import '../../features/auth/domain/auth_status.dart';
import '../../features/ranking/data/cached_ranking_repository.dart';

/// Butta via la copia su disco dell'utente che esce.
///
/// Sta qui e non dentro `AuthController` perche' l'unico sapere che serve e'
/// "l'id di chi sta uscendo": accollare al controller di autenticazione la
/// conoscenza della cache classifica legherebbe due cose che non hanno bisogno
/// di conoscersi, e ogni schermata con cache dovrebbe ricordarsi di farsi
/// registrare.
///
/// Non e' solo privacy. Le chiavi sono gia' per utente, quindi il nuovo account
/// non puo' leggere la classifica del precedente: ma senza questa pulizia i
/// titoli che quello ha consultato resterebbero sul telefono, e chi lo apre
/// dopo legge cosa frequentava.
///
/// Si ascolta il canale auth invece di agganciarsi al logout esplicito perche'
/// la sessione sparisce anche da sola: token scaduto, account eliminato da
/// un'altra sessione, revoca. Agganciarsi al solo pulsante di logout lascerebbe
/// fuori tutti quei casi, che sono esattamente quelli che piu' interessano.
class SessionCacheCleanup {
  SessionCacheCleanup(this._repository, this._statuses);

  final CachedRankingRepository _repository;
  final Stream<AuthStatus> _statuses;

  /// Tiene vivo l'ascolto.
  ///
  /// Senza questa il canale verrebbe chiuso appena [start] restituisce, e la
  /// pulizia non accadrebbe mai.
  StreamSubscription<AuthStatus>? _subscription;

  void start() {
    _subscription ??= _statuses.listen(
      _onStatus,
      // Un errore sul canale non deve portare a uccidere l'app: al massimo la
      // copia resta sul disco, che e' il caso che si voleva evitare ma non un
      // crash. Meglio cosi' che far fallire il bootstrap.
      onError: (_, _) {},
    );
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _onStatus(AuthStatus status) async {
    final leaving = _lastUserId;
    final current = status.user?.id;

    // L'utente e' cambiato: chi non sta piu' usando il dispositivo non ha piu'
    // niente a che fare con quello che e' rimasto su disco. Il logout porta un
    // id vuoto, ma anche un cambio account diretto arriva come un solo evento
    // `signedIn` con un id diverso, quindi il confronto e' fra id e non sullo
    // stato di sessione. Il refresh del token invece lascia l'id uguale e non
    // tocca niente, che e' il comportamento giusto.
    if (leaving != null && leaving != current) {
      await _repository.invalidateUser(leaving);
    }

    _lastUserId = current;
  }

  /// Ultimo utente visto collegato.
  ///
  /// Serve perche' il logout non porta con se' l'id di chi esce: arriva uno
  /// stato vuoto, e senza questa traccia non ci sarebbe niente da cancellare.
  String? _lastUserId;
}