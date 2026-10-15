import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../anime/domain/anime.dart';
import '../anime/presentation/anime_controller.dart';
import '../auth/presentation/auth_controller.dart';
import '../groups/domain/group.dart';
import '../groups/presentation/groups_controller.dart';
import '../novita/novita_controller.dart';
import '../ranking/domain/ranking.dart';
import '../ranking/presentation/ranking_controller.dart';
import '../watchlist/domain/watchlist.dart';
import '../watchlist/presentation/watchlist_controller.dart';
import 'data/home_activities_repository.dart';
import 'domain/friend_activity.dart';

/// Quanti titoli mostra una riga orizzontale della home.
///
/// Venti e' il numero che riempie una riga su desktop senza costringere a
/// scaricare due schermate di contenuto per una sola sezione.
const int homeRowSize = 20;

/// Repository del feed di attivita', iniettato in `main`.
///
/// Stessa regola degli altri moduli: in produzione non si costruisce qui ma si
/// sovrascrive. Un `StateError` rumoroso e' meglio di una sezione social che
/// finge di non avere nulla da mostrare.
final homeActivitiesRepositoryProvider = Provider<HomeActivitiesRepository>((
  ref,
) {
  throw StateError(
    'homeActivitiesRepositoryProvider non e stato inizializzato.',
  );
});

/// Il gruppo di riferimento per le sezioni condivise della home.
///
/// Classifica e attivita' sono legate a un gruppo: senza sceglierne uno,
/// "i piu' votati dalla community" e "attivita' degli amici" non saprebbero di
/// quale gruppo parlare. Si preferisce un gruppo che l'utente possiede — e' li'
/// che la sua attivita' pesa di piu' — altrimenti il primo. `null` quando non
/// ha gruppi: in quel caso le due sezioni spariscono invece di inventare una
/// community.
final primaryGroupProvider = Provider<AsyncValue<AnimeGroup?>>((ref) {
  return ref.watch(groupsListProvider).whenData(primaryGroupOf);
});

/// Sceglie il gruppo di riferimento da un elenco, in modo deterministico.
@visibleForTesting
AnimeGroup? primaryGroupOf(List<AnimeGroup> groups) {
  if (groups.isEmpty) return null;
  for (final group in groups) {
    if (group.myRole == GroupRole.owner) return group;
  }
  for (final group in groups) {
    if (group.myRole.canManage) return group;
  }
  return groups.first;
}

/// L'anime in evidenza nel banner.
///
/// Prima scelta fra quelli della stagione corrente, che e' cio' che interessa
/// adesso; se la stagione non arriva si ripiega sui piu' popolari. Quando non
/// c'e' ne' l'una ne' gli altri vale `null` e la home mostra un invito alla
/// ricerca invece di un banner vuoto. Un guasto di una delle due sorgenti non
/// fa sparire il banner se l'altra ha risposto.
final featuredAnimeProvider = FutureProvider<AnimeEntry?>((ref) async {
  try {
    final pick = featuredOf(await ref.watch(upcomingAnimeProvider.future));
    if (pick != null) return pick;
  } on Exception {
    // La stagione e' un di piu': senza di lei si prova con i popolari.
  }

  try {
    return featuredOf(await ref.watch(popularAnimeProvider.future));
  } on Exception {
    return null;
  }
});

/// Sceglie l'opera del banner in modo stabile.
///
/// Il banner non deve cambiare a ogni ricostruzione: un titolo che cambia
/// mentre si guarda la schermata sembra un difetto. Il giorno dell'anno come
/// indice cambia la scelta una volta al giorno e mai prima, e la funzione e'
/// pura perche' il test possa fissare la data. Si preferiscono le opere con
/// copertina, perche' un banner senza immagine non e' un banner.
@visibleForTesting
AnimeEntry? featuredOf(List<AnimeEntry> pool, {DateTime? now}) {
  if (pool.isEmpty) return null;

  final withImage = [
    for (final entry in pool)
      if ((entry.imageUrl ?? '').isNotEmpty) entry,
  ];
  final candidates = withImage.isEmpty ? pool : withImage;

  final at = now ?? DateTime.now();
  final day = at.difference(DateTime(at.year, 1, 1)).inDays;
  return candidates[day % candidates.length];
}

/// Gli anime che piu' persone hanno in lista.
final popularAnimeProvider = FutureProvider<List<AnimeEntry>>((ref) {
  return ref.watch(animeRepositoryProvider).popular(limit: homeRowSize);
});

/// I piu' votati dalla community di AnimeRank.
///
/// Non e' il voto esterno: e' la media dei voti lasciati dai membri del gruppo
/// di riferimento, ordinata dal backend. Vuota quando l'utente non ha gruppi,
/// e la sezione si nasconde.
final communityTopProvider =
    Provider<AsyncValue<List<SpecialRankingEntry>>>((ref) {
      final group = ref.watch(primaryGroupProvider).asData?.value;
      if (group == null) {
        return const AsyncValue.data(<SpecialRankingEntry>[]);
      }
      return ref.watch(
        specialRankingProvider((group.id, SpecialRankingKind.top)),
      );
    });

/// Il voto della community sull'opera in evidenza, se il gruppo l'ha votata.
///
/// Il banner lo mostra **solo** quando esiste: un voto esterno spacciato per
/// voto del gruppo sarebbe la cosa piu' facile da fare e la meno onesta. La
/// ricerca e' fra le prime posizioni del gruppo, che sono gia' caricate per la
/// sezione dedicata: nessuna richiesta in piu'.
final featuredCommunityScoreProvider = Provider<SpecialRankingEntry?>((ref) {
  final animeId = ref.watch(featuredAnimeProvider).asData?.value?.id;
  if (animeId == null) return null;

  final top = ref.watch(communityTopProvider).asData?.value ?? const [];
  for (final row in top) {
    if (row.animeId == animeId) return row;
  }
  return null;
});

/// Le ultime azioni degli altri membri dei gruppi.
final friendActivityProvider = FutureProvider<List<FriendActivity>>((
  ref,
) async {
  final groups =
      ref.watch(groupsListProvider).asData?.value ?? const <AnimeGroup>[];
  final userId = ref.watch(authStatusProvider).user?.id;
  if (groups.isEmpty || userId == null) return const [];

  return ref
      .watch(homeActivitiesRepositoryProvider)
      .friendActivity(
        groupIds: [for (final group in groups) group.id],
        forUserId: userId,
        limit: homeRowSize,
      );
});

/// Le regole con cui si decide se c'e' abbastanza segnale per consigliare.
class RecommendationRules {
  const RecommendationRules._();

  /// Quante volte un genere deve ricorrere per essere "il preferito".
  ///
  /// Con una sola occorrenza il consiglio sarebbe casuale travestito da
  /// personalizzazione: due e' il minimo per dire che un genere torna.
  static const int minGenreHits = 2;

  /// Da che voto in su un anime conta come "piaciuto".
  static const double lovedScore = 7;
}

/// Il segnale personale su cui si basa "Consigliati per te".
@immutable
class RecommendationSignal {
  const RecommendationSignal({
    this.genre,
    this.savedAnimeIds = const {},
    this.lovedAnimeIds = const {},
  });

  /// Il genere che ricorre di piu' fra i dati personali, `null` se il segnale
  /// e' troppo debole.
  final String? genre;

  /// Anime gia' in watchlist, da non riproporre.
  final Set<String> savedAnimeIds;

  /// Anime gia' votati bene, da non riproporre: consigliare qualcosa che
  /// l'utente ha gia' votato vuol dire non averlo ascoltato.
  final Set<String> lovedAnimeIds;

  /// Tutto quello che non va rimostrato sotto "Consigliati per te".
  Set<String> get excludeAnimeIds => {...savedAnimeIds, ...lovedAnimeIds};

  static const empty = RecommendationSignal();
}

/// Il segnale personale: generi della watchlist piu' i generi degli anime
/// votati bene in AnimeRank.
final recommendationSignalProvider = Provider<RecommendationSignal>((ref) {
  final saved =
      ref.watch(myListProvider).asData?.value ?? const <WatchlistEntry>[];
  final group = ref.watch(primaryGroupProvider).asData?.value;

  final loved = <String>[];
  final lovedIds = <String>{};
  if (group != null) {
    final rows =
        ref.watch(rankingProvider(group.id)).asData?.value ??
        const <RankingEntry>[];
    for (final row in rows) {
      final score = row.myScore;
      if (score != null && score >= RecommendationRules.lovedScore) {
        loved.addAll(row.genres);
        lovedIds.add(row.animeId);
      }
    }
  }

  return RecommendationSignal(
    genre: favouriteGenre([
      for (final entry in saved) ...entry.genres,
      ...loved,
    ]),
    savedAnimeIds: {for (final entry in saved) entry.animeId},
    lovedAnimeIds: lovedIds,
  );
});

/// Il genere che ricorre di piu', se ricorre abbastanza da valere un consiglio.
///
/// Pura e deterministica: a parita' di conteggio vince il genere che viene
/// prima in ordine alfabetico, cosi' due ricostruzioni danno lo stesso
/// risultato.
@visibleForTesting
String? favouriteGenre(Iterable<String> genres) {
  final counts = <String, int>{};
  for (final genre in genres) {
    final trimmed = genre.trim();
    if (trimmed.isEmpty) continue;
    counts[trimmed] = (counts[trimmed] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;

  var best = '';
  var bestCount = 0;
  for (final entry in counts.entries) {
    if (entry.value > bestCount ||
        (entry.value == bestCount && entry.key.compareTo(best) < 0)) {
      best = entry.key;
      bestCount = entry.value;
    }
  }

  return bestCount >= RecommendationRules.minGenreHits ? best : null;
}

/// Altri anime del genere preferito, esclusi quelli gia' in lista.
///
/// Vuota quando non c'e' un segnale abbastanza forte: e' meglio non mostrare
/// la sezione che intitolarla "Consigliati per te" mostrando titoli a caso.
final recommendedAnimeProvider = FutureProvider<List<AnimeEntry>>((
  ref,
) async {
  final signal = ref.watch(recommendationSignalProvider);
  final genre = signal.genre;
  if (genre == null) return const [];

  final page = await ref.watch(animeRepositoryProvider).searchLocal(
    '',
    filters: AnimeFilters(genres: [genre]),
    limit: homeRowSize * 3,
  );

  final exclude = signal.excludeAnimeIds;
  final picks = [
    for (final entry in page.results)
      if (!exclude.contains(entry.id) && !exclude.contains(entry.externalId))
        entry,
  ];

  return picks.take(homeRowSize).toList();
});

/// L'anime della sezione "Anime casuale".
///
/// Un [Notifier] e non un provider puro perche' la scelta deve poter cambiare
/// **su richiesta** e restare ferma altrimenti: se fosse ricalcolata a ogni
/// ricostruzione, il titolo cambierebbe mentre l'utente legge la card, cosa che
/// nessuna sezione "casuale" dovrebbe fare.
///
/// Il passo e' almeno 1 e al massimo `lunghezza - 1`: cosi' il nuovo titolo non
/// e' mai lo stesso di quello appena mostrato.
class RandomAnimeController extends Notifier<AnimeEntry?> {
  final Random _random = Random();
  int _cursor = 0;

  List<AnimeEntry> _pool() => [
    // Solo opere votabili: senza id interno la card non porterebbe da nessuna
    // parte, e un "Scopri" che non apre niente e' peggio di una sezione in meno.
    for (final entry in ref.watch(popularAnimeProvider).asData?.value ?? const [])
      if (entry.canRate) entry,
  ];

  @override
  AnimeEntry? build() {
    final pool = _pool();
    if (pool.isEmpty) return null;
    _cursor %= pool.length;
    return pool[_cursor];
  }

  /// Sceglie un altro titolo, mai lo stesso.
  void shuffle() {
    final pool = _pool();
    if (pool.length <= 1) return;
    _cursor = (_cursor + 1 + _random.nextInt(pool.length - 1)) % pool.length;
    ref.invalidateSelf();
  }
}

final randomAnimeProvider =
    NotifierProvider<RandomAnimeController, AnimeEntry?>(
      RandomAnimeController.new,
    );

/// Etichetta della stagione corrente, calcolata dalla data.
///
/// Dicembre appartiene all'inverno dell'anno dopo: senza lo scarto la home
/// direbbe "Inverno 2026" a dicembre, quando la stagione in corso e' quella del
/// 2027.
String currentSeasonLabel(DateTime now) {
  final season = AnimeSeason.fromMonth(now.month);
  final year = now.month == 12 ? now.year + 1 : now.year;
  return '${season?.label ?? 'Stagione'} $year';
}
