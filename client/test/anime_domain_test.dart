import 'package:animerank/features/anime/domain/anime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnimeEntry.parse', () {
    test('legge una riga completa come la restituisce la RPC', () {
      final entry = AnimeEntry.parse({
        'id': 'a1b2',
        'external_id': '16498',
        'title': 'Attack on Titan',
        'japanese_title': '進撃の巨人',
        'synopsis': 'Un villaggio vive dietro un muro.',
        'image_url': 'https://img.test/aot.jpg',
        'episodes': 89,
        'status': 'finished_airing',
        'year': 2013,
        'genres': ['Action', 'Drama'],
        'media_type': 'TV',
        'season': 'spring',
        'aired_from': '2013-04-07',
        'aired_to': '2023-11-04',
        'score': '9.1',
        'scored_by': '1200000',
        'popularity': '3000000',
        'duration': '24 min per ep',
        'studio': 'Wit Studio',
        'similarity': 0.87,
        'in_catalog': true,
      });

      expect(entry.id, 'a1b2');
      expect(entry.externalId, '16498');
      expect(entry.title, 'Attack on Titan');
      expect(entry.japaneseTitle, '進撃の巨人');
      expect(entry.genres, ['Action', 'Drama']);
      expect(entry.mediaType, AnimeMediaType.tv);
      expect(entry.season, AnimeSeason.spring);
      expect(entry.status, AnimeAirStatus.finished);
      // numeric e bigint arrivano come stringhe dal driver.
      expect(entry.score, 9.1);
      expect(entry.scoredBy, 1200000);
      expect(entry.popularity, 3000000);
      expect(entry.episodes, 89);
      expect(entry.airedFrom, DateTime(2013, 4, 7));
      expect(entry.airedTo, DateTime(2023, 11, 4));
      expect(entry.similarity, 0.87);
      expect(entry.inCatalog, isTrue);
      expect(entry.canRate, isTrue);
    });

    test('una risposta di Jikan senza id non e votabile', () {
      // E' il caso normale: l'opera esiste su Jikan ma non e' ancora stata
      // scritta in catalogo, quindi non c'e' la riga da votare.
      final entry = AnimeEntry.parse({
        'id': null,
        'external_id': '9999',
        'title': 'Non ancora in catalogo',
        'in_catalog': false,
      });

      expect(entry.id, isNull);
      expect(entry.inCatalog, isFalse);
      expect(entry.canRate, isFalse);
    });

    test('campi assenti non rompono il parsing', () {
      final entry = AnimeEntry.parse({
        'external_id': '1',
        'title': 'Solo titolo',
      });

      expect(entry.title, 'Solo titolo');
      expect(entry.japaneseTitle, isNull);
      expect(entry.genres, isEmpty);
      expect(entry.score, isNull);
      expect(entry.episodes, isNull);
      expect(entry.mediaType, isNull);
      expect(entry.status, isNull);
      expect(entry.canRate, isFalse);
    });

    test('una riga vuota non causa crash e ha un titolo leggibile', () {
      // Meglio "Senza titolo" che un'eccezione che farebbe sparire la lista.
      final entry = AnimeEntry.parse(const {});
      expect(entry.title, 'Senza titolo');
      expect(entry.externalId, '');
    });

    test('stringhe vuote e spazi diventano null', () {
      final entry = AnimeEntry.parse({
        'external_id': '1',
        'title': 'X',
        'synopsis': '   ',
        'image_url': '',
        'studio': '  ',
      });

      expect(entry.synopsis, isNull);
      expect(entry.imageUrl, isNull);
      expect(entry.studio, isNull);
    });

    test('i numeri come stringa sono convertiti', () {
      // Postgres restituisce bigint e numeric come testo per non perdere
      // precisione nel JSON: senza conversione i filtri non funzionerebbero.
      final entry = AnimeEntry.parse({
        'external_id': '1',
        'title': 'X',
        'episodes': '12',
        'year': '2024',
        'score': '7.5',
        'scored_by': '42',
      });

      expect(entry.episodes, 12);
      expect(entry.year, 2024);
      expect(entry.score, 7.5);
      expect(entry.scoredBy, 42);
    });

    test('generi non stringa vengono scartati', () {
      final entry = AnimeEntry.parse({
        'external_id': '1',
        'title': 'X',
        'genres': ['Action', 42, null, '  ', 'Drama'],
      });

      expect(entry.genres, ['Action', 'Drama']);
    });

    test('un valore enum sconosciuto non fa crash', () {
      // Se Jikan inventa un tipo, la lista deve comunque mostrare l'anime.
      final entry = AnimeEntry.parse({
        'external_id': '1',
        'title': 'X',
        'media_type': 'Documentary',
        'season': 'monsoon',
        'status': 'hiatus',
      });

      expect(entry.mediaType, isNull);
      expect(entry.season, isNull);
      expect(entry.status, isNull);
      expect(entry.title, 'X');
    });
  });

  group('fatti derivati', () {
    test('factsLabel unisce solo i dati presenti', () {
      final completo = animeFixtureFromDomain();
      expect(completo.factsLabel, 'TV · 89 episodi · 2013');
    });

    test('factsLabel senza dati non mette separatori vuoti', () {
      final vuoto = animeFixtureFromDomain(
        mediaType: null,
        episodes: null,
        year: null,
      );
      expect(vuoto.factsLabel, isEmpty);
    });

    test('factsLabel con dati parziali non lascia virgole', () {
      // Il caso reale piu' frequente: un ONA ha 1 episodio ma l'anno manca
      // perche' Jikan non lo fornisce.
      final parziale = animeFixtureFromDomain(episodes: 1, year: null);
      expect(parziale.factsLabel, 'TV · 1 episodi');
      // Il controllo che conta e' che il separatore non resti appeso in fondo:
      // cercarlo ovunque nella stringa darebbe un falso positivo, perche'
      // "TV · 1 episodi" contiene " · " di legittimo.
      expect(parziale.factsLabel, isNot(endsWith(' ·')));
      expect(parziale.factsLabel, isNot(contains(' · · ')));
    });

    test('canRate richiede id e presenza in catalogo', () {
      expect(animeFixtureFromDomain().canRate, isTrue);
      expect(animeFixtureFromDomain(id: null).canRate, isFalse);
      expect(animeFixtureFromDomain(inCatalog: false).canRate, isFalse);
    });

    test('isRecentAt guarda la data di inizio', () {
      final vecchio = animeFixtureFromDomain(airedFrom: DateTime(2000, 1, 1));
      final recente = animeFixtureFromDomain(airedFrom: DateTime(2026, 9, 20));

      expect(vecchio.isRecentAt(DateTime(2026, 10, 1)), isFalse);
      expect(recente.isRecentAt(DateTime(2026, 10, 1)), isTrue);
    });

    test('isAiringAt: senza data di fine non si conclude che sia finito', () {
      final senzaFine = animeFixtureFromDomain(
        status: AnimeAirStatus.finished,
        airedTo: null,
      );
      final conFine = animeFixtureFromDomain(airedTo: DateTime(2020, 1, 1));

      expect(senzaFine.isAiringAt(DateTime(2026, 10, 1)), isFalse);
      expect(conFine.isAiringAt(DateTime(2026, 10, 1)), isFalse);
    });

    test('isAiringAt: una data di fine futura significa ancora in corso', () {
      final inCorso = animeFixtureFromDomain(airedTo: DateTime(2027, 1, 1));
      expect(inCorso.isAiringAt(DateTime(2026, 10, 1)), isTrue);
    });

    test('sameAs confronta l id esterno, non l interno', () {
      // Due righe con lo stesso externalId sono la stessa opera anche se hanno
      // id interni diversi: e' cio' che evita i duplicati durante lo scroll.
      final a = animeFixtureFromDomain(externalId: '16498', id: 'uuid-1');
      final b = animeFixtureFromDomain(externalId: '16498', id: 'uuid-2');
      final c = animeFixtureFromDomain(externalId: '9999');

      expect(a.sameAs(b), isTrue);
      expect(a.sameAs(c), isFalse);
    });

    test('sameAs con externalId vuoto non dice mai che sono la stessa opera', () {
      // Senza questo controllo due righe senza id esterno sembrerebbero uguali.
      final a = animeFixtureFromDomain(externalId: '');
      final b = animeFixtureFromDomain(externalId: '');
      expect(a.sameAs(b), isFalse);
    });
  });

  group('AnimeSeason.fromMonth', () {
    test('dicembre inverno, non autunno', () {
      // Le stagioni sono a cavallo d anno: e' l'errore piu' facile da fare e
      // quello che sposterebbe gli anime recenti nella stagione sbagliata.
      expect(AnimeSeason.fromMonth(12), AnimeSeason.winter);
      expect(AnimeSeason.fromMonth(1), AnimeSeason.winter);
      expect(AnimeSeason.fromMonth(2), AnimeSeason.winter);
    });

    test('le altre tre coprono tre mesi ciascuna', () {
      expect(AnimeSeason.fromMonth(3), AnimeSeason.spring);
      expect(AnimeSeason.fromMonth(5), AnimeSeason.spring);
      expect(AnimeSeason.fromMonth(6), AnimeSeason.summer);
      expect(AnimeSeason.fromMonth(8), AnimeSeason.summer);
      expect(AnimeSeason.fromMonth(9), AnimeSeason.fall);
      expect(AnimeSeason.fromMonth(11), AnimeSeason.fall);
    });

    test('un mese fuori intervallo dà null invece di fare un giro', () {
      expect(AnimeSeason.fromMonth(0), isNull);
      expect(AnimeSeason.fromMonth(13), isNull);
      expect(AnimeSeason.fromMonth(-1), isNull);
    });

    test('isCurrentAt coincide con fromMonth', () {
      expect(AnimeSeason.winter.isCurrentAt(1), isTrue);
      expect(AnimeSeason.summer.isCurrentAt(1), isFalse);
    });
  });

  group('AnimeMediaType', () {
    test('parsing tollerante al maiuscolo', () {
      expect(AnimeMediaType.fromWire('TV'), AnimeMediaType.tv);
      expect(AnimeMediaType.fromWire('movie'), AnimeMediaType.movie);
      expect(AnimeMediaType.fromWire('OVA'), AnimeMediaType.ova);
    });

    test('un tipo sconosciuto dà null', () {
      expect(AnimeMediaType.fromWire('Documentary'), isNull);
      expect(AnimeMediaType.fromWire(null), isNull);
    });

    test('i sei valori hanno etichette non vuote', () {
      for (final type in AnimeMediaType.values) {
        expect(type.label, isNotEmpty, reason: '${type.wire} senza etichetta');
      }
    });
  });

  group('AnimeAirStatus', () {
    test('parsing dei tre valori', () {
      expect(
        AnimeAirStatus.fromWire('finished_airing'),
        AnimeAirStatus.finished,
      );
      expect(
        AnimeAirStatus.fromWire('currently_airing'),
        AnimeAirStatus.airing,
      );
      expect(AnimeAirStatus.fromWire('not_yet_aired'), AnimeAirStatus.upcoming);
      expect(AnimeAirStatus.fromWire('hiatus'), isNull);
    });
  });

  group('AnimeFilters', () {
    test('nessun filtro per impostazione predefinita', () {
      expect(AnimeFilters.none.isEmpty, isTrue);
      expect(AnimeFilters.none.isActive, isFalse);
      expect(AnimeFilters.none.activeCount, 0);
    });

    test('due generi contano come un filtro solo', () {
      // Sono un criterio unico ("Action e Fantasy"), non due voci di elenco.
      const due = AnimeFilters(genres: ['Action', 'Fantasy']);
      expect(due.activeCount, 1);
    });

    test('un intervallo di anni conta come un filtro', () {
      const daSola = AnimeFilters(yearFrom: 2020);
      const aSola = AnimeFilters(yearTo: 2020);
      const entrambe = AnimeFilters(yearFrom: 2020, yearTo: 2024);

      expect(daSola.activeCount, 1);
      expect(aSola.activeCount, 1);
      expect(entrambe.activeCount, 1);
    });

    test('un intervallo di episodi conta come un filtro', () {
      expect(const AnimeFilters(minEpisodes: 10).activeCount, 1);
      expect(const AnimeFilters(maxEpisodes: 10).activeCount, 1);
      expect(
        const AnimeFilters(minEpisodes: 1, maxEpisodes: 24).activeCount,
        1,
      );
    });

    test('activeCount conta i filtri indipendenti', () {
      const tutto = AnimeFilters(
        genres: ['Action'],
        mediaType: AnimeMediaType.movie,
        season: AnimeSeason.winter,
        yearFrom: 2000,
        minScore: 7,
        minEpisodes: 12,
      );
      expect(tutto.activeCount, 6);
    });

    test('toggleGenre aggiunge e poi toglie', () {
      const vuoto = AnimeFilters.none;

      final aggiunto = vuoto.toggleGenre('Action');
      expect(aggiunto.genres, ['Action']);

      final tolto = aggiunto.toggleGenre('Action');
      expect(tolto.genres, isEmpty);
      expect(tolto.isEmpty, isTrue);
    });

    test('toggleGenre su due generi non perde il primo', () {
      const vuoto = AnimeFilters.none;
      final due = vuoto.toggleGenre('Action').toggleGenre('Fantasy');
      expect(due.genres, containsAll(['Action', 'Fantasy']));

      final uno = due.toggleGenre('Action');
      expect(uno.genres, ['Fantasy']);
    });

    test('clearYear azzera entrambi gli estremi', () {
      const conAnno = AnimeFilters(yearFrom: 2000, yearTo: 2024);
      final senza = conAnno.copyWith(clearYear: true);
      expect(senza.yearFrom, isNull);
      expect(senza.yearTo, isNull);
      expect(senza.isEmpty, isTrue);
    });

    test('clearMediaType e clearEpisodes non toccano gli altri campi', () {
      const iniziale = AnimeFilters(
        genres: ['Action'],
        mediaType: AnimeMediaType.movie,
        minEpisodes: 10,
        maxEpisodes: 24,
      );

      final senzaTipo = iniziale.copyWith(clearMediaType: true);
      expect(senzaTipo.mediaType, isNull);
      expect(senzaTipo.genres, ['Action']);
      expect(senzaTipo.minEpisodes, 10);

      final senzaEpi = iniziale.copyWith(clearEpisodes: true);
      expect(senzaEpi.minEpisodes, isNull);
      expect(senzaEpi.maxEpisodes, isNull);
      expect(senzaEpi.mediaType, AnimeMediaType.movie);
    });

    test('copyWith senza argomenti non modifica nulla', () {
      const iniziale = AnimeFilters(genres: ['Action'], minScore: 7);
      final copia = iniziale.copyWith();
      expect(copia.genres, ['Action']);
      expect(copia.minScore, 7);
    });

    test('la copia non condivide la lista dei generi con l originale', () {
      // Se condividessero la lista, un toggle successivo modificherebbe anche
      // lo stato precedente, e tornare indietro mostrerebbe filtri diversi.
      const iniziale = AnimeFilters(genres: ['Action']);
      final copia = iniziale.toggleGenre('Fantasy');

      expect(iniziale.genres, ['Action']);
      expect(copia.genres, hasLength(2));
    });
  });

  group('AnimeCatalogStats', () {
    test('il default e un catalogo vuoto', () {
      final stats = AnimeCatalogStats.empty;
      expect(stats.isEmpty, isTrue);
      expect(stats.totalAnime, 0);
      expect(stats.lastSyncedAt, isNull);
    });

    test('parse di una riga reale', () {
      final stats = AnimeCatalogStats.parse({
        'total_anime': 1250,
        'last_synced_at': '2026-10-01T12:00:00Z',
        'season': 'fall',
        'airing_now': 34,
        'newest_aired': '2026-09-28',
      });

      expect(stats.totalAnime, 1250);
      expect(stats.currentSeason, AnimeSeason.fall);
      expect(stats.airingNow, 34);
      expect(stats.isEmpty, isFalse);
    });

    test('parse di una riga quasi vuota non fallisce', () {
      final stats = AnimeCatalogStats.parse(const {});
      expect(stats.totalAnime, 0);
      expect(stats.isEmpty, isTrue);
    });
  });

  group('AnimeGenre', () {
    test('parse legge nome e conteggio', () {
      final genre = AnimeGenre.parse({'genre': 'Action', 'anime_count': '312'});
      expect(genre.name, 'Action');
      expect(genre.count, 312);
    });

    test('un genere senza nome non diventa una stringa vuota', () {
      final genre = AnimeGenre.parse(const {});
      expect(genre.name, 'Sconosciuto');
      expect(genre.count, 0);
    });
  });
}

/// Costruisce un'entry senza dipendere dagli helper dei test, per tenere questo
/// file autonomo.
AnimeEntry animeFixtureFromDomain({
  String externalId = '16498',
  String? id = 'uuid-1',
  String title = 'Attack on Titan',
  int? episodes = 89,
  int? year = 2013,
  AnimeMediaType? mediaType = AnimeMediaType.tv,
  AnimeAirStatus? status = AnimeAirStatus.finished,
  // `DateTime` non e' una costante compilata: come default di un parametro
  // nominale deve per forza essere `const`, quindi questi due valori si indicano
  // con `null` e si risolvono dentro.
  DateTime? airedFrom,
  DateTime? airedTo,
  bool inCatalog = true,
}) => AnimeEntry(
  externalId: externalId,
  id: id,
  title: title,
  episodes: episodes,
  year: year,
  mediaType: mediaType,
  status: status,
  // Le date di default sono qui dentro perche' i parametri nominali non
  // possono avere un `DateTime(...)` non costante: i test che le
  // sovrascrivono devono poter passare `null` per dire "nessuna data".
  airedFrom: airedFrom ?? DateTime(2013, 4, 7),
  airedTo: airedTo ?? DateTime(2023, 11, 4),
  inCatalog: inCatalog,
);
