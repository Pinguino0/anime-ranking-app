import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../anime/data/anime_repository.dart';
import '../anime/presentation/anime_controller.dart';
import '../anime/domain/anime.dart';

/// Una riga della home: un titolo e gli anime da sfogliare in orizzontale.
@immutable
class HomeRow {
  const HomeRow({required this.title, required this.entries, this.subtitle});

  final String title;

  /// Sotto il titolo: dice perche' questi titoli sono qui ("voto medio 8.4",
  /// "stagione corrente"). Una riga senza spiegazione costringe l'utente a
  /// indovinare il criterio con cui e' stata scelta.
  final String? subtitle;

  final List<AnimeEntry> entries;

  /// true se la riga non ha nulla da mostrare.
  bool get isEmpty => entries.isEmpty;
}

/// Contenuto della home.
///
/// I titoli non vengono scaricati tre volte per tre righe diverse: una sola
/// lettura del catalogo alimenta tutte le righe, e ogni riga la riordina per il
/// proprio criterio. Costa meno di tre richieste e, soprattutto, i tre
/// elenchi restano coerenti fra loro: non puo' succedere che "aggiornati" e
/// "votati" mostrino lo stesso anime in posizioni diverse senza che ve ne sia
/// un motivo.
@immutable
class HomeFeed {
  const HomeFeed({required this.rows, this.feature, this.catalog = const []});

  final List<HomeRow> rows;

  /// Opera in evidenza nel banner.
  ///
  /// Va decisa qui e non nella schermata perche' la scelta dipende dai dati:
  /// il banner prende il primo dei piu' votati fra le quattro righe, cosi' non
  /// capita mai che lo stesso anime sia contemporaneamente il banner e la
  /// prima card della prima riga sotto.
  final AnimeEntry? feature;

  /// Ultimi titoli del catalogo, per la griglia "tutti gli anime".
  final List<AnimeEntry> catalog;

  static const empty = HomeFeed(rows: []);
}

/// Provider dei titoli della home.
///
/// `keepAlive` e' il punto: senza, leaving e rientrando nella schermata
/// rifarebbe la richiesta ogni volta, e l'utente che torna dal profilo
/// aspetterebbe di nuovo la stessa lista. Con, la home resta in memoria e si
/// aggiorna solo quando lo si chiede esplicitamente con [refresh].
final homeFeedProvider =
    AsyncNotifierProvider<HomeFeedController, HomeFeed>(HomeFeedController.new);

/// Quanto tempo la home resta valida prima di essere ricaricata da sola.
///
/// Non e' "per sempre": il catalogo cambia, e una home congelata per giorni
/// mostrerebbe serie finite da anni. Non e' "sempre": un'ora non serve a
/// niente per dati che non cambiano al minuto.
const _homeTtl = Duration(hours: 6);

class HomeFeedController extends AsyncNotifier<HomeFeed> {
  /// Quando i dati sono stati presi, per decidere se sono scaduti.
  DateTime? _loadedAt;

  @override
  Future<HomeFeed> build() async {
    ref.keepAlive();
    return _load();
  }

  Future<HomeFeed> _load() async {
    final repository = ref.watch(animeRepositoryProvider);
    _loadedAt = DateTime.now();
    return _build(repository);
  }

  Future<HomeFeed> _build(AnimeRepository repository) async {
    // La stagione corrente viene da un endpoint dedicato ed e' l'unica riga
    // che ha senso mostrare anche quando il catalogo locale e' ancora vuoto,
    // perche' arriva fresca da Jikan. Se fallisce non pero' si trascina dietro
    // tutta la home: e' un di piu', quindi l'errore si ignora qui e le altre
    // righe si costruiscono lo stesso.
    List<AnimeEntry> season = const [];
    try {
      season = await repository.currentSeason(limit: 20);
    } catch (_) {
      // Riga mancante, home intatta.
    }

    // Il catalogo locale alimenta le altre righe e la griglia. Se questa
    // lettura fallisce l'errore si propaga: e' un guasto vero, e mostrare la
    // season da sola farebbe credere all'utente di vedere tutta la home.
    //
    // 120 righe e non 60: la griglia finale mostra il catalogo per intero e un
    // paio di righe in piu' non si vedono, mentre a 60 la griglia sembrerebbe
    // piu' corta del catalogo che contiene.
    final results = await repository.searchLocal('', limit: 120, offset: 0);

    if (results.results.isEmpty && season.isEmpty) return HomeFeed.empty;

    final entries = results.results;

    final top = _row(
      title: 'I piu votati',
      subtitle: 'Voto piu alto del catalogo',
      entries: entries,
      compare: (a, b) {
        final byScore = _compareNullableDesc(a.score, b.score);
        if (byScore != 0) return byScore;
        return _compareNullableDesc(a.airedFrom, b.airedFrom);
      },
    );

    // Il banner prende il primo dei piu' votati e quella riga perde il primo
    // elemento: altrimenti l'utente vede la stessa locandina due volte a tre
    // schermate di distanza e sembra che l'app non stia caricando nulla di
    // nuovo.
    final feature = top.entries.isEmpty ? null : top.entries.first;

    return HomeFeed(
      feature: feature,
      catalog: entries,
      rows: [
        if (season.isNotEmpty)
          HomeRow(
            title: 'In uscita ora',
            subtitle: 'Aggiornamenti della stagione corrente',
            entries: season,
          ),
        _row(
          title: 'Aggiornati di recente',
          subtitle: 'Le ultime uscite nel catalogo',
          entries: entries,
          compare: (a, b) {
            // `null` in coda: un anime senza data non e' fra i piu' recenti, ma
            // non e' nemmeno da buttare, quindi resta in fondo invece di sparire.
            final byDate = _compareNullableDesc(a.airedFrom, b.airedFrom);
            if (byDate != 0) return byDate;
            return _byScore(a, b);
          },
        ),
        HomeRow(
          title: top.title,
          subtitle: top.subtitle,
          entries: feature == null ? top.entries : top.entries.skip(1).toList(),
        ),
        _row(
          title: 'I piu popolari',
          subtitle: 'I piu cercati su MyAnimeList',
          entries: entries,
          compare: (a, b) {
            final byPopularity = _compareNullableDesc(a.popularity, b.popularity);
            if (byPopularity != 0) return byPopularity;
            return _byScore(a, b);
          },
        ),
        // "Per te" e' la coda della lista ordinata per voto e data, non una
        // raccomandazione: il backend non ha un profilo di gusti da cui
        // ricavarla, e mostrare un titolo a caso sotto un'etichetta che promette
        // una scelta personale sarebbe una bugia. Qui l'etichetta dice cosa fa
        // davvero — mescola i due criteri — cosi' la riga resta utile.
        _row(
          title: 'Per te',
          subtitle: 'Voto alto e uscita recente',
          entries: entries,
          compare: (a, b) {
            // Somma dei due criteri normalizzati: e' il modo piu' semplice per
            // non far coincidere questa riga con le due precedenti, che sono
            // gia' ordinate per uno dei due.
            final byScore = _blend(a, b, (e) => e.score ?? 0);
            if (byScore != 0) return byScore;
            return _compareNullableDesc(a.airedFrom, b.airedFrom);
          },
        ),
      ],
    );
  }

  /// Confronto su un punteggio composto.
  ///
  /// Il peso della data e' volutamente basso rispetto al voto: un anime uscito
  /// tre anni fa con voto 9 e uno uscito ieri con voto 7 devono stare vicini,
  /// e il peso alto della data li separerebbe come se fossero due cose diverse.
  static int _blend(AnimeEntry a, AnimeEntry b, double Function(AnimeEntry) read) {
    const dateWeight = 0.25;
    final now = DateTime.now();
    // Gli anni senza data contano come zero: si mettono in fondo invece di
    // far saltare l'ordinamento.
    double years(AnimeEntry e) {
      final from = e.airedFrom;
      if (from == null) return 0;
      return ((now.difference(from).inDays) / 365).clamp(0, 25);
    }

    final scoreA = read(a) - dateWeight * years(a);
    final scoreB = read(b) - dateWeight * years(b);
    return scoreB.compareTo(scoreA);
  }

  /// Una riga, scartata se troppo corta per essere un carosello.
  ///
  /// Una riga con due titoli e' solo rumore: meglio non averla che mostrare
  /// uno striscia vuota che sembra un caricamento fallito.
  HomeRow _row({
    required String title,
    required String? subtitle,
    required List<AnimeEntry> entries,
    required int Function(AnimeEntry, AnimeEntry) compare,
  }) {
    final sorted = [...entries]..sort(compare);
    return HomeRow(
      title: title,
      subtitle: subtitle,
      entries: sorted.take(20).toList(),
    );
  }

  static int _byScore(AnimeEntry a, AnimeEntry b) =>
      _compareNullableDesc(a.score, b.score);

  /// Confronto decrescente che mette in fondo i valori mancanti.
  ///
  /// Serve perche' `null` non e' confrontabile con `>` in Dart: senza questo,
  /// un anime senza voto fa crashare l'ordinamento invece di finire in coda.
  static int _compareNullableDesc(Object? a, Object? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return (b as Comparable).compareTo(a);
  }

  /// Ricarica esplicita: tirare la schermata verso il basso.
  Future<void> refresh() async {
    state = const AsyncValue<HomeFeed>.loading();
    state = await AsyncValue.guard(() => _load());
  }

  /// La home e' scaduta?
  ///
  /// Esposto per la schermata, che lo usa per proporre l'aggiornamento senza
  /// farlo da sola: se si ricaricasse da sola, tornare indietro dalla scheda di
  /// un anime ripeterebbe la richiesta.
  bool get isStale {
    final at = _loadedAt;
    if (at == null) return true;
    return DateTime.now().difference(at) > _homeTtl;
  }
}