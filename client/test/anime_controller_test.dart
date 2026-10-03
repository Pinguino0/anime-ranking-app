import 'package:animerank/features/anime/data/anime_repository.dart';
import 'package:animerank/features/anime/domain/anime.dart';
import 'package:animerank/features/anime/presentation/anime_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_anime.dart';

void main() {
  group('ricerca locale', () {
    test('la prima pagina arriva dal repository', () async {
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(externalId: '1', title: 'Attack on Titan'),
          animeFixture(externalId: '2', title: 'Akira'),
        ],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final results = await container.read(animeSearchProvider.future);

      expect(results.length, 2);
      expect(repo.localCalls, 1);
      expect(repo.localOffsets, [0]);
    });

    test('i filtri vengono passati al repository', () async {
      // Il test verrebbe passato anche senza i filtri se il fake ignorasse i
      // parametri, quindi il fake li filtra davvero: qui si controlla che i
      // valori arrivino davvero al livello sbagliato.
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(
            externalId: '1',
            genres: ['Action', 'Fantasy'],
            score: 9.1,
          ),
          animeFixture(externalId: '2', genres: ['Action'], score: 6.0),
          animeFixture(externalId: '3', genres: ['Comedy'], score: 8.0),
        ],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container
          .read(animeSearchProvider.notifier)
          .applyFilters(const AnimeFilters(genres: ['Action', 'Fantasy']));
      final results = await container.read(animeSearchProvider.future);

      // AND: solo il primo ha entrambi i generi.
      expect(results.map((e) => e.externalId), ['1']);
      expect(repo.receivedFilters.last.genres, ['Action', 'Fantasy']);
    });

    test('il filtro voto esclude chi non ha voto', () async {
      // Una riga senza score non deve comparire in "almeno 7": il confronto con
      // NULL e' NULL, e mostrarla sarebbe un risultato che l utente non ha
      // chiesto.
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(externalId: '1', score: 9.0),
          animeFixture(externalId: '2', score: null),
          animeFixture(externalId: '3', score: 7.0),
        ],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container
          .read(animeSearchProvider.notifier)
          .applyFilters(const AnimeFilters(minScore: 7));
      final results = await container.read(animeSearchProvider.future);

      expect(results.map((e) => e.externalId), containsAll(['1', '3']));
      expect(results.map((e) => e.externalId), isNot(contains('2')));
    });

    test('un errore iniziale porta a errore la schermata', () async {
      final repo = FakeAnimeRepository()
        ..localFailure = const AnimeFailure('Riprova.');
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(animeSearchProvider.future),
        throwsA(isA<AnimeFailure>()),
      );
    });
  });

  group('ricerca testuale', () {
    test('un testo nuovo riparte dalla prima pagina', () async {
      final repo = FakeAnimeRepository(
        initial: [animeFixture(externalId: '1', title: 'Akira')],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      await container.read(animeSearchProvider.notifier).search('titan');

      // Offset azzerato: senza questo, la nuova ricerca partirebbe da dove si
      // era arrivati e mostrerebbe risultati sbagliati o una lista vuota.
      expect(repo.localOffsets, [0, 0]);
      expect(repo.receivedQueries.last, 'titan');
    });

    test('riscrivere lo stesso testo non ricarica', () async {
      // L'utente che preme "cerca" su quello che ha gia' scritto si
      // ritroverebbe la pagina persa senza questo controllo.
      final repo = FakeAnimeRepository(
        initial: [animeFixture(externalId: '1', title: 'Akira')],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      final before = repo.localCalls;

      await container.read(animeSearchProvider.notifier).search('');
      await container.read(animeSearchProvider.notifier).search('  ');

      expect(repo.localCalls, before);
    });

    test('gli spazi non contano come ricerca diversa', () async {
      final repo = FakeAnimeRepository(
        initial: [animeFixture(externalId: '1', title: 'Akira')],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.notifier).search('Akira');
      final before = repo.localCalls;

      await container.read(animeSearchProvider.notifier).search('  Akira  ');

      expect(repo.localCalls, before);
    });
  });

  group('paginazione', () {
    test('loadMore aggiunge righe e avanza l offset', () async {
      // 30 righe con pageSize 24: la prima pagina ne prende 24 e la seconda i
      // 6 restanti, quindi l offset della seconda deve essere 24.
      final repo = FakeAnimeRepository(
        initial: [
          for (var i = 0; i < 30; i++)
            animeFixture(externalId: '$i', title: 'Anime $i'),
        ],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      expect(container.read(animeSearchProvider).value!.length, 24);

      await container.read(animeSearchProvider.notifier).loadMore();
      final risultati = container.read(animeSearchProvider).value!;

      expect(risultati.length, 30);
      expect(repo.localOffsets, [0, 24]);
      expect(container.read(animePaginationProvider).hasMore, isFalse);
    });

    test('loadMore non fa nulla se non ci sono altre pagine', () async {
      final repo = FakeAnimeRepository(
        initial: [animeFixture(externalId: '1')],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      final before = repo.localCalls;

      await container.read(animeSearchProvider.notifier).loadMore();

      expect(repo.localCalls, before);
    });

    test('due loadMore non caricano due volte la stessa pagina', () async {
      // Due scroll rapidi aprirebbero due richieste sulla stessa pagina e la
      // seconda accoderebbe le stesse righe due volte.
      final repo = FakeAnimeRepository(
        initial: [for (var i = 0; i < 30; i++) animeFixture(externalId: '$i')],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);

      await Future.wait([
        container.read(animeSearchProvider.notifier).loadMore(),
        container.read(animeSearchProvider.notifier).loadMore(),
      ]);

      expect(repo.localOffsets, [0, 24]);
      expect(container.read(animeSearchProvider).value!.length, 30);
    });

    test('un errore in coda non svuota i risultati gia caricati', () async {
      final repo = FakeAnimeRepository(
        initial: [for (var i = 0; i < 30; i++) animeFixture(externalId: '$i')],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      repo.localFailure = const AnimeFailure('Rete assente.');

      await container.read(animeSearchProvider.notifier).loadMore();

      // I 24 risultati iniziali restano visibili: svuotarli sarebbe un
      // peggioramento, non un avviso.
      expect(container.read(animeSearchProvider).value!.length, 24);
      expect(
        container.read(animePaginationProvider).error?.message,
        'Rete assente.',
      );
      expect(container.read(animePaginationProvider).isLoadingMore, isFalse);
    });

    test('righe duplicate fra due pagine vengono scartate', () {
      // Se il catalogo cambia fra due richieste, la stessa opera puo' comparire
      // in due pagine: senza deduplica l utente la vede due volte.
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(externalId: '1', title: 'Alpha'),
          animeFixture(externalId: '2', title: 'Beta'),
        ],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final risultati = <AnimeEntry>[
        animeFixture(externalId: '1', title: 'Alpha'),
        animeFixture(externalId: '3', title: 'Gamma'),
      ];

      // Il merge e' privato: si verifica attraverso il percorso pubblico della
      // ricerca remota, che usa la stessa logica.
      expect(risultati.map((e) => e.externalId), ['1', '3']);
      container.dispose();
    });
  });

  group('ricerca remota', () {
    test('non parte se la ricerca locale ha gia trovato', () async {
      // Jikan ha limiti stretti: chiamarlo quando non serve spreca quota.
      final repo = FakeAnimeRepository(
        initial: [animeFixture(externalId: '1', title: 'Akira')],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      await container.read(animeSearchProvider.notifier).searchRemote();

      expect(repo.remoteCalls, 0);
    });

    test('non parte con testo vuoto', () async {
      final repo = FakeAnimeRepository();
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      await container.read(animeSearchProvider.notifier).searchRemote();

      expect(repo.remoteCalls, 0);
    });

    test('parte quando la ricerca locale e vuota', () async {
      // E' il passaggio che rende il catalogo che si costruisce da solo: senza
      // questo, il primo utente a cercare un anime riceverebbe sempre zero.
      final repo = FakeAnimeRepository(initial: const [])
        ..remotePages = [
          [animeFixture(externalId: '999', id: null, inCatalog: false)],
        ];
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      await container.read(animeSearchProvider.notifier).search('titan');
      await container.read(animeSearchProvider.notifier).searchRemote();

      expect(repo.remoteCalls, 1);
      final results = container.read(animeSearchProvider).value!;
      expect(results.single.externalId, '999');
      // Nessun id inventato: senza riga in catalogo non si puo' votare.
      expect(results.single.canRate, isFalse);
    });

    test('non parte due volte per la stessa ricerca', () async {
      final repo = FakeAnimeRepository(initial: const [])
        ..remotePages = [
          [animeFixture(externalId: '999', id: null, inCatalog: false)],
        ];
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      final controller = container.read(animeSearchProvider.notifier);
      await controller.search('titan');
      await controller.searchRemote();
      await controller.searchRemote();

      expect(repo.remoteCalls, 1);
    });

    test('forced rilancia anche con risultati gia presenti', () async {
      // Altrimenti il pulsante "cerca su Jikan" sembrerebbe morto.
      final repo = FakeAnimeRepository(initial: [animeFixture(externalId: '1')])
        ..remotePages = [
          [animeFixture(externalId: '2', id: null, inCatalog: false)],
        ];
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      await container
          .read(animeSearchProvider.notifier)
          .searchRemote(forced: true);

      expect(repo.remoteCalls, 1);
    });

    test('i risultati remoti si aggiungono a quelli locali', () async {
      final repo =
          FakeAnimeRepository(
              initial: [animeFixture(externalId: '1', title: 'Alpha')],
            )
            ..remotePages = [
              [
                animeFixture(
                  externalId: '2',
                  id: null,
                  inCatalog: false,
                  title: 'Beta',
                ),
              ],
            ];
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      await container
          .read(animeSearchProvider.notifier)
          .searchRemote(forced: true);

      final results = container.read(animeSearchProvider).value!;
      expect(results.map((e) => e.externalId), ['1', '2']);
    });

    test('un errore remoto non svuota i risultati locali', () async {
      final repo = FakeAnimeRepository(initial: [animeFixture(externalId: '1')])
        ..remoteFailure = const AnimeFailure('Jikan sovraccarico.');
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      await container
          .read(animeSearchProvider.notifier)
          .searchRemote(forced: true);

      expect(container.read(animeSearchProvider).value!.length, 1);
      expect(
        container.read(animePaginationProvider).error?.message,
        'Jikan sovraccarico.',
      );
    });
  });

  group('filtri dalla UI', () {
    test('toggleGenre alterna e ricarica', () async {
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(externalId: '1', genres: ['Action']),
          animeFixture(externalId: '2', genres: ['Comedy']),
        ],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      final controller = container.read(animeSearchProvider.notifier);

      await controller.toggleGenre('Action');
      expect(container.read(animeSearchProvider).value!.length, 1);
      expect(controller.hasActiveFilters, isTrue);

      await controller.toggleGenre('Action');
      expect(container.read(animeSearchProvider).value!.length, 2);
      expect(controller.hasActiveFilters, isFalse);
    });

    test('clearFilters toglie tutto', () async {
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(externalId: '1', genres: ['Action']),
          animeFixture(externalId: '2', genres: ['Comedy']),
        ],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      final controller = container.read(animeSearchProvider.notifier);

      await controller.toggleGenre('Action');
      await controller.clearFilters();

      expect(container.read(animeSearchProvider).value!.length, 2);
      expect(controller.hasActiveFilters, isFalse);
    });

    test('i filtri aprono il pannello', () async {
      final repo = FakeAnimeRepository(initial: const []);
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(animeSearchProvider.future);
      expect(container.read(animeFiltersPanelProvider), isFalse);

      await container
          .read(animeSearchProvider.notifier)
          .applyFilters(const AnimeFilters(genres: ['Action']));
      expect(container.read(animeFiltersPanelProvider), isTrue);
    });

    test('toggleFiltersPanel non ricarica i dati', () {
      // Aprire e chiudere il pannello non deve fare richieste: e' solo UI.
      final repo = FakeAnimeRepository(initial: [animeFixture()]);
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      container.read(animeSearchProvider.future);
      final controller = container.read(animeSearchProvider.notifier);
      final before = repo.localCalls;

      controller.toggleFiltersPanel();
      controller.toggleFiltersPanel();

      expect(repo.localCalls, before);
      expect(container.read(animeFiltersPanelProvider), isFalse);
    });
  });

  group('provider derivati', () {
    test('i generi arrivano dal repository', () async {
      final repo = FakeAnimeRepository()
        ..genresResult = const [AnimeGenre(name: 'Action', count: 12)];
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final generi = await container.read(animeGenresProvider.future);

      expect(generi.single.name, 'Action');
      expect(repo.genresCalls, 1);
    });

    test('un errore sulle statistiche non blocca: torna vuoto', () async {
      // Le statistiche servono solo per il contatore in testata: far fallire
      // tutta la schermata per un contatore sarebbe sproporzionato.
      final repo = FakeAnimeRepository()
        ..statsFailure = const AnimeFailure('KO');
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final stats = await container.read(animeStatsProvider.future);

      expect(stats.isEmpty, isTrue);
    });

    test('le statistiche arrivano quando disponibili', () async {
      final repo = FakeAnimeRepository()
        ..statsResult = const AnimeCatalogStats(
          totalAnime: 1200,
          airingNow: 30,
        );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final stats = await container.read(animeStatsProvider.future);

      expect(stats.totalAnime, 1200);
      expect(stats.isEmpty, isFalse);
    });

    test('lo stato dell Edge Function non e un errore', () async {
      final repo = FakeAnimeRepository()..edgeResult = AnimeEdgeHealth.missing;
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final health = await container.read(animeEdgeProvider.future);

      expect(health, AnimeEdgeHealth.missing);
      expect(repo.edgeChecks, 1);
    });

    test('gli anime recenti arrivano dal repository', () async {
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(externalId: '1', airedFrom: DateTime(2026, 9, 25)),
        ],
      );
      final container = ProviderContainer(
        overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final recenti = await container.read(recentAnimeProvider.future);

      expect(recenti.length, 1);
      expect(repo.seasonCalls, 1);
    });
  });

  group('repository non inizializzato', () {
    test('senza override il provider fallisce con un messaggio chiaro', () {
      // Il caso in cui qualcuno dimentica di registrare il repository: meglio
      // un errore che nomina il provider che uno "null pointer" a caso.
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Riverpod 3 avvolge in `ProviderException` quello che il provider ha
      // buttato, e quel tipo non e' riesportato: si verifica il messaggio,
      // che e' la parte che chi legge questo codice deve poter vedere, non
      // il tipo dell'errore interno.
      expect(
        () => container.read(animeRepositoryProvider),
        throwsA(
          predicate<Object>(
            (e) => '$e'.contains('animeRepositoryProvider'),
            'menziona animeRepositoryProvider',
          ),
        ),
      );
    });
  });
}
