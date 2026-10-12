import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'episodes_controller.dart';

/// Riallineamento degli episodi col provider.
///
/// Non e' un job del server: e' l'app a chiedere se sono usciti episodi nuovi,
/// quando si apre. AnimeUnity risponde 403 a un indirizzo di datacenter e 200
/// all'IP residenziale dell'utente, quindi il telefono e' l'unico posto dove la
/// domanda ha una risposta — e l'unico che puo' farla.
///
/// Quello che *non* cambia e' da dove nascono le notifiche: l'insert degli
/// episodi nuovi vive nel database (`sync_anime_episodes` -> `notifications`),
/// quindi la catena dei push resta quella di sempre.
final episodeSyncProvider = Provider<EpisodeSyncController>((ref) {
  return EpisodeSyncController(ref);
});

class EpisodeSyncController {
  EpisodeSyncController(this._ref);

  final Ref _ref;

  /// Un giro alla volta.
  ///
  /// Due sincronizzazioni in parallelo userebbero la stessa sessione di
  /// AnimeUnity due volte: la seconda non aggiungerebbe niente, perche' il
  /// database ha gia' creato quello che serviva. Un giro solo e' anche il modo
  /// perche' un tocco sulla scheda non moltiplichi le richieste di un elenco.
  bool _running = false;

  /// Riallinea un anime.
  ///
  /// Best effort: `0` se non cambia niente o la rete non c'e'. Non solleva,
  /// perche' a chiamarla e' una schermata che sta gia' mostrando una lista
  /// valida — un errore silenzioso li e' meglio di un banner per una cosa che
  /// l'utente non ha chiesto.
  Future<int> syncAnime(String animeId) async {
    if (_running) return 0;
    _running = true;

    try {
      final added =
          await _ref.read(episodesRepositoryProvider).syncEpisodes(animeId);

      if (added > 0) {
        // La lista a schermo era quella vecchia: solo ora vale la pena
        // rileggerla, e solo se l'anime e' davvero cambiato.
        _ref.invalidate(episodesProvider(animeId));
      }

      return added;
    } catch (_) {
      return 0;
    } finally {
      _running = false;
    }
  }

  /// Riallinea gli anime che l'utente segue, uno per uno.
  ///
  /// In sequenza e non in parallelo: il provider si guarda da poche richieste
  /// per volta, e una raffica verrebbe bloccata facendo fallire tutto insieme.
  /// Il tetto evita che una lista lunga diventi decine di richieste a ogni
  /// apertura.
  Future<int> syncFollowed(Iterable<String> animeIds, {int max = 8}) async {
    var added = 0;

    for (final id in animeIds.toSet().take(max)) {
      added += await syncAnime(id);
    }

    return added;
  }
}
