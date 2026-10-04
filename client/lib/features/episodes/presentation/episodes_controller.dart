import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/episodes_repository.dart';
import '../domain/episode.dart';

final episodesRepositoryProvider = Provider<EpisodesRepository>((ref) {
  throw StateError('episodesRepositoryProvider non e stato inizializzato.');
});

/// Episodi di un anime.
///
/// L'id arriva dal costruttore e non da un campo `arg`: in Riverpod 3 la
/// factory di una family passa l'argomento al costruttore del notifier, quindi
/// e' l'unico posto dove e' garantito essere disponibile.
class EpisodesController extends AsyncNotifier<List<Episode>> {
  EpisodesController(this.animeId);

  final String animeId;

  @override
  Future<List<Episode>> build() async {
    final repository = ref.watch(episodesRepositoryProvider);
    return repository.forAnime(animeId);
  }

  /// Aggiorna una riga dopo un voto senza rileggere tutto.
  ///
  /// Rileggere l'intera lista a ogni mezzo punto di voto sarebbe una richiesta
  /// ogni volta che l'utente trascina il cursore. Il cambiamento e' locale e
  /// l'elenco non cambia ordine, quindi basta sostituire la riga.
  void patch(Episode episode) {
    // `asData` e non `valueOrNull`: in Riverpod 3 lo stato "ha un valore" e'
    // dentro `asData`, e controllare il dato senza spacchettarlo direbbe
    // "nessuno" anche quando l'errore e' null e il valore c'e'.
    final current = state.asData?.value;
    if (current == null) return;

    state = AsyncData([
      for (final entry in current)
        if (entry.id == episode.id) episode else entry,
    ]);
  }
}

final episodesProvider =
    AsyncNotifierProvider.family<EpisodesController, List<Episode>, String>(
  EpisodesController.new,
);

/// Fonti attive di un episodio.
///
/// Un [FutureProvider] e non un controller: le fonti non si modificano dal
/// client e non vanno invalidate dopo un voto, quindi non c'e' niente da
/// scriverci dentro.
final episodeSourcesProvider =
    FutureProvider.family<List<EpisodeSource>, String>((ref, episodeId) async {
  final repository = ref.watch(episodesRepositoryProvider);
  return repository.sources(episodeId);
});

/// Registra il voto su un episodio.
///
/// Non e' un provider: il voto personale e' gia' un campo della riga
/// dell'episodio, e [EpisodesController.patch] lo aggiorna in locale dopo la
/// scrittura. Qui serve solo l'azione, che e' una scrittura e non uno stato da
/// mostrare.
class EpisodeRater {
  const EpisodeRater(this._repository);

  final EpisodesRepository _repository;

  /// Registra [score], o cancella il voto se e' `null`.
  ///
  /// L'episodio aggiornato viene restituito perche' il chiamante lo mostri
  /// subito: aspettare che la lista si ricarichi lascerebbe il numero del
  /// voto fermo sul vecchio valore per tutto il tempo di una richiesta di rete.
  Future<Episode> save({
    required Episode episode,
    required double? score,
  }) async {
    final stored = await _repository.rate(episode.id, score);

    return Episode(
      id: episode.id,
      number: episode.number,
      title: episode.title,
      airedAt: episode.airedAt,
      filler: episode.filler,
      recap: episode.recap,
      thumbnail: episode.thumbnail,
      sourceCount: episode.sourceCount,
      progressTime: episode.progressTime,
      completed: episode.completed,
      myScore: stored,
      communityAverage: episode.communityAverage,
      communityCount: episode.communityCount,
    );
  }
}

final episodeRaterProvider = Provider<EpisodeRater>(
  (ref) => EpisodeRater(ref.watch(episodesRepositoryProvider)),
);

/// Scrive il progresso di visione.
///
/// Non e' un provider perche' non e' uno stato che qualcuno guarda: e' un
/// canale di scrittura che il player chiama mentre avanza e all'uscita. E' una
/// classe e non una funzione libera perche' tiene lo stato interno necessario
/// a non scrivere quattro volte al secondo.
class WatchProgressSaver {
  WatchProgressSaver(this._repository);

  final EpisodesRepository _repository;

  /// Secondi di video fra un salvataggio e l'altro.
  ///
  /// Dieci corrispondono a richieste leggibili nei log del backend e a una
  /// perdita massima di dieci secondi se la rete cade. Piu' fitto non guadagna
  /// niente e spreca banda su una connessione mobile.
  static const Duration interval = Duration(seconds: 10);

  /// Posizione dell'ultimo salvataggio, `null` se non se n'e' ancora scritto.
  ///
  /// Si confronta la *posizione* e non l'orologio perche' quello che conta e'
  /// quanta visione andrebbe persa se la rete cade: dieci secondi di video
  /// guardati. Il caso "dieci secondi di attesa" non si presenta da solo — in
  /// pausa il video non avanza — quindi i due criteri danno lo stesso risultato
  /// mentre quello sulla posizione resta corretto anche in un test.
  Duration? _lastSavedPosition;

  /// Salva se e' passato abbastanza video, o se l'episodio e' finito.
  Future<void> maybeSave(
    String episodeId,
    Duration position, {
    bool completed = false,
  }) async {
    final last = _lastSavedPosition;

    // Il primo salvataggio parte subito: l'utente che riapre un episodio a
    // meta' non deve aspettare dieci secondi per registrare quel punto.
    final advanced = last == null ||
        (position - last).inSeconds >= interval.inSeconds;

    // Tornare indietro conta come cambiamento anche se non si e' ancora
    // superato il punto di prima: e' una posizione diversa, e senza questa
    // riga un rewatch non aggiornerebbe mai niente.
    final rewound = last != null && position < last;

    if (!completed && !advanced && !rewound) return;

    await _write(episodeId, position, completed: completed);
  }

  /// Segna l'episodio come finito, scrivendo la posizione finale.
  ///
  /// Scrive subito e non passa dall'intervallo: la fine dell'episodio e' un
  /// evento, non una posizione che si raggiunge con calma, e tra l'altro e'
  /// l'unica scrittura che porta anche `completed`, quindi rimandarla
  /// lascerebbe la riga senza quel flag.
  Future<void> markCompleted(String episodeId, Duration position) =>
      _write(episodeId, position, completed: true);

  Future<void> _write(
    String episodeId,
    Duration position, {
    bool? completed,
  }) async {
    _lastSavedPosition = position;

    await _repository.saveProgress(
      episodeId,
      position.inSeconds,
      completed: completed,
    );
  }

  /// Scrive subito, ignorando l'intervallo.
  ///
  /// Va chiamata quando l'utente esce dalla schermata: e' l'ultima occasione
  /// di registrare dove si era fermati, e aspettare i dieci secondi successivi
  /// significherebbe perderli.
  Future<void> flush(String episodeId, Duration position) =>
      _write(episodeId, position);
}