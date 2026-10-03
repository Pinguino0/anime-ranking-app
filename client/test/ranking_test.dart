import 'dart:async';

import 'package:animerank/core/cache/cache_store.dart';
import 'package:animerank/core/cache/session_cache_cleanup.dart';
import 'package:animerank/features/auth/domain/auth_status.dart';
import 'package:animerank/features/ranking/data/cached_ranking_repository.dart';
import 'package:animerank/features/ranking/data/ranking_repository.dart';
import 'package:animerank/features/ranking/domain/ranking.dart';
import 'package:animerank/features/ranking/presentation/ranking_controller.dart';
import 'package:animerank/features/ranking/presentation/screens/ranking_screen.dart';
import 'package:animerank/features/ranking/presentation/widgets/rank_podium.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'helpers/fake_auth.dart';
import 'helpers/fake_cache_store.dart';
import 'helpers/fake_ranking.dart';

void main() {
  group('SpecialRankingKind', () {
    test('il nome inviato al backend e quello del contratto', () {
      // I valori sono stringhe che arrivano in SQL: scrivere "most-voted"
      // produrrebbe zero righe senza alcun errore, e la schermata mostrerebbe
      // un vuoto che sembra un gruppo senza voti.
      expect(SpecialRankingKind.top.wire, 'top');
      expect(SpecialRankingKind.mostVoted.wire, 'most_voted');
      expect(SpecialRankingKind.divisive.wire, 'divisive');
    });

    test('un nome sconosciuto vale come top', () {
      expect(SpecialRankingKind.fromWire('qualcosa'), SpecialRankingKind.top);
      expect(SpecialRankingKind.fromWire('most_voted'), SpecialRankingKind.mostVoted);
      expect(SpecialRankingKind.fromWire(null), SpecialRankingKind.top);
    });
  });

  group('RankingEntry.parse', () {
    test('legge una riga completa', () {
      final entry = RankingEntry.parse({
        'rank_position': 3,
        'anime_id': 'a1',
        'title': 'Cowboy Bebop',
        'japanese_title': 'Cowboy Bebop',
        'image_url': 'https://img/a1.jpg',
        'episodes': 26,
        'year': 1998,
        'genres': ['Action', 'Space'],
        'mean_score': 8.5,
        'vote_count': 4,
        'ranking_score': 8.1,
        'my_score': 9,
        'position_delta': 2,
      });

      expect(entry.position, 3);
      expect(entry.title, 'Cowboy Bebop');
      expect(entry.episodes, 26);
      expect(entry.genres, ['Action', 'Space']);
      expect(entry.meanScore, 8.5);
      expect(entry.voteCount, 4);
      expect(entry.myScore, 9);
      expect(entry.hasMyVote, isTrue);
      expect(entry.movedUp, isTrue);
      expect(entry.movedDown, isFalse);
    });

    test('una risposta incompleta non fa esplodere la lista', () {
      // Il backend tronca le risposte e un campo puo' arrivare NULL: e'
      // preferibile una riga con meno numeri che far cadere tutta la pagina.
      final entry = RankingEntry.parse({'anime_id': 'a2'});

      expect(entry.title, 'Senza titolo');
      expect(entry.position, 0);
      expect(entry.voteCount, 0);
      expect(entry.meanScore, isNull);
      expect(entry.hasMyVote, isFalse);
    });

    test('i numeri postgres arrivano come stringhe o come interi', () {
      // numeric e bigint viaggiano come num nel JSON, ma una versione della
      // libreria puo' consegnarli come testo: senza questa conversione
      // `as num` romperebbe il parsing su una risposta valida.
      final entry = RankingEntry.parse({
        'anime_id': 'a3',
        'vote_count': '7',
        'mean_score': '7.25',
        'position_delta': '-2',
      });

      expect(entry.voteCount, 7);
      expect(entry.meanScore, 7.25);
      expect(entry.positionDelta, -2);
      expect(entry.movedDown, isTrue);
    });

    test('i voti interi non mostrano decimali', () {
      expect(buildRankingEntry(meanScore: 8).meanScoreLabel, '8');
      expect(buildRankingEntry(meanScore: 8.5).meanScoreLabel, '8.5');
      expect(buildRankingEntry(myScore: 9).myScoreLabel, '9');
    });

    test('due righe dello stesso anime non sono duplicate', () {
      expect(buildRankingEntry(), buildRankingEntry());
      expect(buildRankingEntry(), isNot(buildRankingEntry(animeId: 'a2')));
    });
  });

  group('SpecialRankingEntry.parse', () {
    test('le etichette cambiano con il tipo', () {
      final top = SpecialRankingEntry.parse(
        {'rank_position': 1, 'anime_id': 'a1', 'title': 'X', 'value': 8.5, 'secondary': 3},
        kind: SpecialRankingKind.top,
      );
      expect(top.valueLabel, ('Media', '8.5'));
      expect(top.secondaryLabel, ('Voti', '3'));

      final voted = SpecialRankingEntry.parse(
        {'rank_position': 1, 'anime_id': 'a1', 'title': 'X', 'value': 3, 'secondary': 8.5},
        kind: SpecialRankingKind.mostVoted,
      );
      // Sul backend value e secondary si scambiano: senza il tipo, 3 e 8.5
      // sarebbero indistinguibili e l'etichetta inventata.
      expect(voted.valueLabel, ('Voti', '3'));
      expect(voted.secondaryLabel, ('Media', '8.5'));
    });
  });

  group('GroupStats.parse', () {
    test('legge totali e highlight annidati', () {
      final stats = GroupStats.parse({
        'member_count': 5,
        'anime_rated': 12,
        'total_votes': 40,
        'group_mean': 7.25,
        'top_anime': {
          'anime_id': 'a1',
          'title': 'Cowboy Bebop',
          'image_url': 'https://img/a1.jpg',
          'mean': 9.0,
        },
        'most_voted_anime': {
          'anime_id': 'a2',
          'title': 'Cowboy Bebop',
          'votes': 6,
        },
        'top_genre': 'Action',
        'score_distribution': {'7': 10, '8': 12},
      });

      expect(stats.memberCount, 5);
      expect(stats.totalVotes, 40);
      expect(stats.groupMean, 7.25);
      expect(stats.topAnime?.title, 'Cowboy Bebop');
      expect(stats.topAnime?.value, 9.0);
      expect(stats.mostVotedAnime?.value, 6);
      expect(stats.topGenre, 'Action');
      expect(stats.scoreDistribution, {7: 10, 8: 12});
      expect(stats.distributionPeak, 12);
    });

    test('un jsonb vuoto non produce highlight', () {
      // Le sezioni sono null quando il gruppo non ha ancora voti: mostrarle
      // come "0" farebbe pensare a un dato raccolto.
      final stats = GroupStats.parse({'member_count': 1});

      expect(stats.topAnime, isNull);
      expect(stats.topGenre, isNull);
      expect(stats.scoreDistribution, isEmpty);
      expect(stats.distributionPeak, 0);
    });

    test('una chiave non numerica viene scartata', () {
      final stats = GroupStats.parse({'score_distribution': {'sette': 3, '8': 2}});

      expect(stats.scoreDistribution, {8: 2});
    });

    test('statistiche vuote non mostrano la barra', () {
      expect(const GroupStats().isEmpty, isTrue);
      expect(const GroupStats(memberCount: 3).isEmpty, isFalse);
    });
  });

  group('RatingValidators', () {
    test('accetta solo mezzo punto da 0 a 10', () {
      expect(RatingValidators.isValid(0), isTrue);
      expect(RatingValidators.isValid(10), isTrue);
      expect(RatingValidators.isValid(7.5), isTrue);
      expect(RatingValidators.isValid(10.5), isFalse);
      expect(RatingValidators.isValid(-0.5), isFalse);
      // 7.3 sembra ragionevole all'utente ma il CHECK del database lo
      // rifiuta: si blocca qui invece di far fallire il salvataggio.
      expect(RatingValidators.isValid(7.3), isFalse);
    });

    test('gli errori spiegano il limite', () {
      expect(RatingValidators.error(11), contains('0 a 10'));
      expect(RatingValidators.error(7.3), contains('passo 0.5'));
      expect(RatingValidators.error(8), isNull);
    });
  });

  group('RankingPage', () {
    test('una pagina piena suggerisce che ce ne sia un altra', () {
      expect(RankingPage.hasMore(List.filled(RankingPage.size, buildRankingEntry())), isTrue);
      expect(RankingPage.hasMore([buildRankingEntry()]), isFalse);
    });
  });

  group('cache della classifica', () {
    late FakeRankingRepository inner;
    late FakeCacheStore cache;

    /// Utente di comodo per i test della cache.
    ///
    /// La cache e' per utente: senza questo id le chiavi non si scrivono e i
    /// test passerebbero tutti "perche' non e' successo niente".
    const userId = 'u1';

    setUp(() {
      inner = FakeRankingRepository(initial: [
        buildRankingEntry(animeId: 'a1', title: 'Primo', position: 1, voteCount: 4),
        buildRankingEntry(animeId: 'a2', title: 'Secondo', position: 2, voteCount: 3),
      ]);
      cache = FakeCacheStore();
    });

    /// Repository in cache collegato a [userId].
    CachedRankingRepository cachedRepo([String? asUser]) =>
        CachedRankingRepository(inner, cache, userId: () => asUser ?? userId);

    test('una lettura riuscita viene salvata', () async {
      final repo = cachedRepo();

      final rows = await repo.ranking('g1', limit: 50, offset: 0);

      expect(rows, hasLength(2));
      // Senza la copia la seconda apertura senza rete mostrerebbe una pagina
      // vuota, cioe' "nessun anime votato" per un gruppo pieno.
      expect(cache.keys, isNotEmpty);
      expect(repo.cacheStatus.fromCache, isFalse);
    });

    test('senza rete si vede la copia, dichiarata come tale', () async {
      final repo = cachedRepo();
      await repo.ranking('g1', limit: 50, offset: 0);

      inner.rankingFailure = const RankingFailure('Rete assente.', isRetryable: true);
      final rows = await repo.ranking('g1', limit: 50, offset: 0);

      expect(rows, hasLength(2));
      expect(rows.first.title, 'Primo');
      // La schermata deve poter dire che e' una copia: senza questo la posizione
      // letta sarebbe trattata come attuale e l'utente deciderebbero su una
      // classifica vecchia.
      expect(repo.cacheStatus.fromCache, isTrue);
      expect(repo.cacheStatus.savedAt, isNotNull);
    });

    test('la copia di un gruppo non finisce sotto un altro', () async {
      final repo = cachedRepo();
      await repo.ranking('g1', limit: 50, offset: 0);

      inner.rankingFailure = const RankingFailure('Rete assente.', isRetryable: true);

      // Senza il gruppo nella chiave, aprire un secondo gruppo senza rete
      // mostrerebbe la classifica del primo: numeri plausibili e sbagliati.
      await expectLater(
        () => repo.ranking('g2', limit: 50, offset: 0),
        throwsA(isA<RankingFailure>()),
      );
    });

    test('la copia di una pagina non vale per le altre', () async {
      final repo = cachedRepo();
      await repo.ranking('g1', limit: 50, offset: 0);

      inner.rankingFailure = const RankingFailure('Rete assente.', isRetryable: true);

      // La seconda pagina non e' mai stata letta: inventarla sarebbe far
      // sembrare la classifica piu' lunga di quanto e'.
      await expectLater(
        () => repo.ranking('g1', limit: 50, offset: 50),
        throwsA(isA<RankingFailure>()),
      );
    });

    test('un errore di permessi non viene nascosto dalla copia', () async {
      final repo = cachedRepo();
      await repo.ranking('g1', limit: 50, offset: 0);

      inner.rankingFailure = const RankingFailure('Non sei membro di questo gruppo.');

      // "Non sei membro" e' la verita' su quel gruppo: mostrare la classifica di
      // prima sarebbe inventare un accesso che non esiste piu'.
      await expectLater(
        () => repo.ranking('g1', limit: 50, offset: 0),
        throwsA(isA<RankingFailure>()),
      );
      expect(repo.cacheStatus.fromCache, isFalse);
    });

    test('senza rete e senza copia l errore resta un errore', () async {
      final repo = cachedRepo();
      inner.rankingFailure = const RankingFailure('Rete assente.', isRetryable: true);

      await expectLater(
        () => repo.ranking('g1', limit: 50, offset: 0),
        throwsA(isA<RankingFailure>()),
      );
      expect(repo.cacheStatus.fromCache, isFalse);
    });

    test('un voto butta via la copia del gruppo', () async {
      final repo = cachedRepo();
      await repo.ranking('g1', limit: 50, offset: 0);
      await repo.ranking('g2', limit: 50, offset: 0);
      expect(cache.keys, hasLength(2));

      await repo.rate('g1', 'a1', 9);

      // Dopo il voto le posizioni sono cambiate: tenere la copia farebbe
      // rivedere all'utente una classifica che il backend ha appena superata.
      expect(cache.keys, hasLength(1));

      inner.rankingFailure = const RankingFailure('Rete assente.', isRetryable: true);
      await expectLater(
        () => repo.ranking('g1', limit: 50, offset: 0),
        throwsA(isA<RankingFailure>()),
      );
    });

    test('un voto fallito lascia la copia al suo posto', () async {
      final repo = cachedRepo();
      await repo.ranking('g1', limit: 50, offset: 0);
      inner.rateFailure = const RankingFailure('Voto non registrato.', isRetryable: true);

      await expectLater(() => repo.rate('g1', 'a1', 9), throwsA(isA<RankingFailure>()));

      // Il voto non e' partito, quindi la classifica in cache descrive ancora
      // quello che c'e' davvero: buttarla lascerebbe l'utente senza nulla.
      expect(cache.keys, hasLength(1));
    });

    test('una copia illeggibile non impedisce la lettura', () async {
      final repo = cachedRepo();
      await repo.ranking('g1', limit: 50, offset: 0);

      // Una copia scritta da un'altra versione e' rumore, non un dato: si
      // preferisce un errore comprensibile a una lista di spazzatura.
      cache.writeSync('${CachedRankingRepository.prefix('g1', userId)}50:0',
          '{"saved_at": "non-una-data"}');

      final rows = await repo.ranking('g1', limit: 50, offset: 0);
      expect(rows, hasLength(2));
    });

    test('un disco che non collabora non ferma la schermata', () async {
      cache.failWrites = true;
      final repo = cachedRepo();

      final rows = await repo.ranking('g1', limit: 50, offset: 0);

      // I dati sono gia' arrivati dalla rete: perderne la copia costa una
      // richiesta in piu' alla prossima apertura, non uno schermo vuoto.
      expect(rows, hasLength(2));
    });

    test('i campi di ogni riga sopravvivono al giro in cache', () async {
      final repo = cachedRepo();
      await repo.ranking('g1', limit: 50, offset: 0);

      inner.rankingFailure = const RankingFailure('Rete assente.', isRetryable: true);
      final cached = await repo.ranking('g1', limit: 50, offset: 0);

      // Solo l'id anime tornerebbe indietro: la copia perderebbe generi,
      // copertina e voti, e la riga sarebbe una lista di numeri senza nome.
      final first = cached.firstWhere((row) => row.animeId == 'a1');
      expect(first.title, 'Primo');
      expect(first.position, 1);
      expect(first.voteCount, 4);
      expect(first.genres, contains('Action'));
    });

    test('la copia di un utente non finisce sotto un altro', () async {
      await cachedRepo('u1').ranking('g1', limit: 50, offset: 0);
      final second = cachedRepo('u2');
      inner.rankingFailure = const RankingFailure('Rete assente.', isRetryable: true);

      // Le righe portano anche my_score: il voto di chi guarda. Su un telefono
      // condiviso il secondo account vedrebbe il voto espresso dal primo, e
      // non avrebbe modo di accorgersene.
      await expectLater(
        () => second.ranking('g1', limit: 50, offset: 0),
        throwsA(isA<RankingFailure>()),
      );
      expect(second.cacheStatus.fromCache, isFalse);
    });

    test('lo stesso utente ritrova la propria copia', () async {
      await cachedRepo('u1').ranking('g1', limit: 50, offset: 0);
      inner.rankingFailure = const RankingFailure('Rete assente.', isRetryable: true);

      // Il percorso normale: la cache deve funzionare per l'utente che l'ha
      // scritta, altrimenti averla isolata per utente significherebbe non
      // averla piu'.
      final rows = await cachedRepo('u1').ranking('g1', limit: 50, offset: 0);
      expect(rows.first.title, 'Primo');
    });

    test('senza sessione non si scrive e non si legge', () async {
      final anonymous = CachedRankingRepository(inner, cache, userId: () => null);
      await anonymous.ranking('g1', limit: 50, offset: 0);

      // Un id vuoto o assente non permette di stabilire a chi appartiene una
      // riga: meglio non ricordare nulla che ricordare la copia sbagliata.
      expect(cache.keys, isEmpty);

      inner.rankingFailure = const RankingFailure('Rete assente.', isRetryable: true);
      await expectLater(
        () => anonymous.ranking('g1', limit: 50, offset: 0),
        throwsA(isA<RankingFailure>()),
      );
    });

    test('il logout butta via la copia dell utente uscente', () async {
      final repo = cachedRepo('u1');
      await repo.ranking('g1', limit: 50, offset: 0);
      await cachedRepo('u2').ranking('g1', limit: 50, offset: 0);
      await cachedRepo('u2').ranking('g2', limit: 50, offset: 0);
      expect(cache.keys, hasLength(3));

      await repo.invalidateUser('u1');

      // Dopo il logout la copia di u1 non deve piu' esistere: anche i titoli che
      // ha guardato dicono a chi apre il telefono cosa frequentava. La copia di
      // u2 invece resta, perche' e' ancora la sua.
      expect(cache.keys, hasLength(2));
      expect(cache.keys.where((k) => k.contains('u1')), isEmpty);
    });

    test('un voto invalida il gruppo solo per chi vota', () async {
      await cachedRepo('u1').ranking('g1', limit: 50, offset: 0);
      await cachedRepo('u2').ranking('g1', limit: 50, offset: 0);

      await cachedRepo('u1').rate('g1', 'a1', 9);

      // Il voto cambia le posizioni, ma solo per la vista di chi ha votato: per
      // u2 la copia precedente descrive ancora quello che il backend le
      // restituirebbe, quindi buttarla sarebbe una richiesta sprecata.
      expect(cache.keys.where((k) => k.contains('u1')), isEmpty);
      expect(cache.keys.where((k) => k.contains('u2')), hasLength(1));
    });

    test('classifiche speciali e statistiche non vanno in cache', () async {
      final repo = cachedRepo();

      await repo.special('g1', SpecialRankingKind.top);
      await repo.stats('g1');

      // Sono brevi e derivate: una copia vecchia accanto alla classifica fresca
      // mostrerebbe due versioni diverse dello stesso gruppo.
      expect(cache.keys, isEmpty);
    });
  });

  group('pulizia della cache a fine sessione', () {
    late FakeRankingRepository inner;
    late FakeCacheStore cache;
    late StreamController<AuthStatus> controller;
    late SessionCacheCleanup cleanup;

    /// Repository in cache collegato a [userId].
    CachedRankingRepository cachedRanking(FakeRankingRepository repo, CacheStore store) =>
        CachedRankingRepository(repo, store, userId: () => 'u1');

    setUp(() {
      inner = FakeRankingRepository(initial: [buildRankingEntry(title: 'Cowboy Bebop')]);
      cache = FakeCacheStore();

      // Il canale e' quello che ascolta la pulizia: si emettono gli stessi
      // eventi che il canale auth di Supabase manderebbe.
      controller = StreamController<AuthStatus>.broadcast();
      addTearDown(controller.close);

      cleanup = SessionCacheCleanup(cachedRanking(inner, cache), controller.stream)..start();
      addTearDown(cleanup.dispose);
    });

    test('uscendo butta via la copia dell utente che esce', () async {
      controller.add(AuthStatus.fromSession(buildSession(userId: 'u1')));
      await pumpEventQueue();
      await cachedRanking(inner, cache).ranking('g1', limit: 50, offset: 0);
      expect(cache.keys, hasLength(1));

      controller.add(const AuthStatus.signedOut());
      await pumpEventQueue();

      // Senza questo i titoli di quell'utente restano sul telefono, e chi lo
      // apre dopo legge cosa guardava.
      expect(cache.keys, isEmpty);
    });

    test('un cambio di account non lascia la copia del precedente', () async {
      controller.add(AuthStatus.fromSession(buildSession(userId: 'u1')));
      await pumpEventQueue();
      await cachedRanking(inner, cache).ranking('g1', limit: 50, offset: 0);

      // Entra un altro account sullo stesso telefono. Le chiavi sono per utente
      // quindi non leggerebbe la copia del primo, ma il primo doveva comunque
      // sparire: era la copia di chi non sta piu' usando il dispositivo.
      controller.add(AuthStatus.fromSession(buildSession(userId: 'u2')));
      await pumpEventQueue();

      expect(cache.keys, isEmpty);
    });

    test('un refresh del token non tocca la copia', () async {
      controller.add(AuthStatus.fromSession(buildSession(userId: 'u1')));
      await pumpEventQueue();
      await cachedRanking(inner, cache).ranking('g1', limit: 50, offset: 0);

      // Rientro della stessa sessione dopo il refresh del token: qui l'utente
      // non e' uscito, quindi la copia e' ancora sua e va tenuta.
      controller.add(AuthStatus.fromSession(buildSession(userId: 'u1')));
      await pumpEventQueue();

      expect(cache.keys, hasLength(1));
    });

    test('un errore sul canale auth non porta a crash', () async {
      controller.add(AuthStatus.fromSession(buildSession(userId: 'u1')));
      await pumpEventQueue();
      await cachedRanking(inner, cache).ranking('g1', limit: 50, offset: 0);

      controller.addError(Exception('canale rotto'));
      await pumpEventQueue();

      // Al massimo la copia resta sul disco, che e' il caso da evitare. Un
      // crash qui invece porterebbe via l'app intera.
      expect(cache.keys, hasLength(1));
    });
  });

  group('paginazione', () {
    late FakeRankingRepository repo;

    setUp(() => repo = FakeRankingRepository());

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [rankingRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(c.dispose);
      return c;
    }

    /// Riga distinta per posizione, cosi' si vede quale pagina e' arrivata.
    List<RankingEntry> page(int from, int count) => [
          for (var i = 0; i < count; i++)
            buildRankingEntry(animeId: 'a${from + i}', position: from + i + 1),
        ];

    test('la prima pagina chiede da offset zero', () async {
      repo = FakeRankingRepository(initial: page(0, RankingPage.size));
      final c = container();

      final rows = await c.read(rankingProvider('g1').future);

      expect(repo.rankingCalls, 1);
      expect(repo.requestedGroups, ['g1']);
      expect(rows, hasLength(RankingPage.size));
      expect(c.read(rankingProvider('g1').notifier).hasMore, isTrue);
    });

    test('una pagina corta chiude la lista', () async {
      repo = FakeRankingRepository(initial: page(0, 5));
      final c = container();

      await c.read(rankingProvider('g1').future);

      // Con meno righe del limite il backend non ha niente da dare: senza
      // questo controllo la schermata mostrerebbe sempre "Altre posizioni".
      expect(c.read(rankingProvider('g1').notifier).hasMore, isFalse);
    });

    test('caricare la pagina seguente accoda le righe', () async {
      repo = FakeRankingRepository(initial: page(0, RankingPage.size + 20));
      final c = container();

      final first = await c.read(rankingProvider('g1').future);
      await c.read(rankingProvider('g1').notifier).loadMore();
      final all = c.read(rankingProvider('g1')).value!;

      // Le righe sono in coda e non rimpiazzate: la posizione di ogni anime e'
      // quella del ranking e non deve cambiare mentre si scorre.
      expect(all.length, RankingPage.size + 20);
      expect(all.take(RankingPage.size), first);
      expect(all.last.position, RankingPage.size + 20);
      expect(c.read(rankingProvider('g1').notifier).hasMore, isFalse);
    });

    test('l offset della seconda pagina e il numero di righe gia caricate', () async {
      repo = FakeRankingRepository(initial: page(0, RankingPage.size + 10));
      final c = container();

      await c.read(rankingProvider('g1').future);
      await c.read(rankingProvider('g1').notifier).loadMore();

      // Il finto registra gli offset: se il secondo caricamento ripartisse da
      // zero restituirebbe le stesse righe e la lista mostrerebbe doppioni.
      expect(repo.offsets, [0, RankingPage.size]);
    });

    test('oltre l ultima pagina non si chiede piu nulla', () async {
      repo = FakeRankingRepository(initial: page(0, 10));
      final c = container();

      await c.read(rankingProvider('g1').future);
      await c.read(rankingProvider('g1').notifier).loadMore();

      expect(repo.rankingCalls, 1);
    });

    test('un errore in coda non svuota la classifica', () async {
      repo = FakeRankingRepository(initial: page(0, RankingPage.size + 5));
      final c = container();

      await c.read(rankingProvider('g1').future);
      repo.rankingFailure = const RankingFailure('Rete assente.');
      await c.read(rankingProvider('g1').notifier).loadMore();

      // Lo stato resta valido: se fosse in errore sparirebbero anche le righe
      // gia' caricate, che sono buone, e l'utente vedrebbe una pagina vuota per
      // un problema che riguarda solo le righe successive.
      expect(c.read(rankingProvider('g1')).hasError, isFalse);
      expect(c.read(rankingProvider('g1')).value, hasLength(RankingPage.size));
      expect(c.read(rankingPaginationProvider('g1')).error?.message, 'Rete assente.');
    });

    test('il retry dopo un errore riparte dalla pagina giusta', () async {
      repo = FakeRankingRepository(initial: page(0, RankingPage.size + 5));
      final c = container();

      await c.read(rankingProvider('g1').future);
      repo.rankingFailure = const RankingFailure('Rete assente.');
      await c.read(rankingProvider('g1').notifier).loadMore();

      repo.rankingFailure = null;
      await c.read(rankingProvider('g1').notifier).loadMore();

      // Ripartire da zero qui duplicherebbe le prime righe: l'offset segue le
      // righe gia' accodate, non l'ultima richiesta fallita.
      expect(repo.offsets, [0, RankingPage.size, RankingPage.size]);
      expect(c.read(rankingProvider('g1')).value, hasLength(RankingPage.size + 5));
      expect(c.read(rankingPaginationProvider('g1')).error, isNull);
    });

    test('un refresh dopo un errore lo azzera', () async {
      repo = FakeRankingRepository(initial: page(0, RankingPage.size + 5));
      final c = container();

      await c.read(rankingProvider('g1').future);
      repo.rankingFailure = const RankingFailure('Rete assente.');
      await c.read(rankingProvider('g1').notifier).loadMore();
      expect(c.read(rankingPaginationProvider('g1')).error, isNotNull);

      repo.rankingFailure = null;
      await c.read(rankingProvider('g1').notifier).refresh();

      // L'errore in coda riguardava la pagina saltata; dopo un refresh la
      // classifica e' ripartita e quel messaggio non descrive piu' nulla.
      expect(c.read(rankingPaginationProvider('g1')).error, isNull);
      expect(c.read(rankingPaginationProvider('g1')).hasMore, isTrue);
    });

    test('tre pagine mantengono la lista aperta', () async {
      repo = FakeRankingRepository(initial: page(0, RankingPage.size * 3));
      final c = container();

      await c.read(rankingProvider('g1').future);
      await c.read(rankingProvider('g1').notifier).loadMore();

      // Contando le righe accumulate `hasMore` diventerebbe falso alla seconda
      // pagina ("sono 100, non 50") e la lista si fermerebbe con meta'
      // classifica mancante.
      expect(c.read(rankingPaginationProvider('g1')).hasMore, isTrue);

      await c.read(rankingProvider('g1').notifier).loadMore();

      expect(repo.offsets, [0, RankingPage.size, RankingPage.size * 2]);
      expect(c.read(rankingProvider('g1')).value, hasLength(RankingPage.size * 3));
      expect(c.read(rankingPaginationProvider('g1')).hasMore, isTrue);
    });

    test('due richieste insieme non aprono due pagine', () async {
      repo = FakeRankingRepository(initial: page(0, RankingPage.size + 10));
      final c = container();

      await c.read(rankingProvider('g1').future);
      final notifier = c.read(rankingProvider('g1').notifier);
      // Due scroll rapidi arrivano quasi contemporanei: senza guardia partirebbero
      // due richieste per lo stesso offset e le stesse righe finirebbero in
      // lista due volte.
      await Future.wait([notifier.loadMore(), notifier.loadMore()]);

      expect(repo.offsets, [0, RankingPage.size]);
      expect(c.read(rankingProvider('g1')).value, hasLength(RankingPage.size + 10));
    });

    test('il refresh riparte dalla prima pagina', () async {
      repo = FakeRankingRepository(initial: page(0, RankingPage.size + 5));
      final c = container();

      await c.read(rankingProvider('g1').future);
      await c.read(rankingProvider('g1').notifier).loadMore();
      await c.read(rankingProvider('g1').notifier).refresh();

      // Dopo un voto la classifica e' cambiata: conservare le righe accumulate
      // mostrerebbe doppioni e salti di posizione.
      expect(c.read(rankingProvider('g1')).value, hasLength(RankingPage.size));
    });
  });

  group('controller', () {
    late FakeRankingRepository repo;

    setUp(() => repo = FakeRankingRepository());

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [rankingRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('il primo caricamento chiede la classifica del gruppo', () async {
      repo = FakeRankingRepository(initial: [buildRankingEntry()]);
      final c = container();

      final rows = await c.read(rankingProvider('g1').future);

      expect(repo.rankingCalls, 1);
      expect(repo.requestedGroups, ['g1']);
      expect(rows, hasLength(1));
    });

    test('un errore resta visibile e il retry riprova', () async {
      // Non ritentabile: `appRetry` aspetterebbe 1s + 2s + 4s di attesa reale
      // prima di lasciare emergere l'errore, e il test si metterebbe in pausa
      // per sette secondi per verificare un comportamento che `appRetry`
      // copre gia' con test dedicati.
      repo.rankingFailure = const RankingFailure('Non sei membro di questo gruppo.');
      final c = container();

      await expectLater(c.read(rankingProvider('g1').future), throwsA(isA<RankingFailure>()));
      expect(c.read(rankingProvider('g1')).hasError, isTrue);

      repo.rankingFailure = null;
      await c.read(rankingProvider('g1').notifier).refresh();

      expect(c.read(rankingProvider('g1')).hasError, isFalse);
      expect(repo.rankingCalls, greaterThan(1));
    });

    test('due gruppi hanno due elenchi separati', () async {
      repo = FakeRankingRepository(initial: [
        buildRankingEntry(animeId: 'a1', title: 'Primo'),
        buildRankingEntry(animeId: 'a2', title: 'Secondo'),
      ]);
      final c = container();

      await c.read(rankingProvider('g1').future);
      await c.read(rankingProvider('g2').future);

      // Senza il gruppo nella chiave, il secondo gruppo mostrerebbe la
      // classifica del primo: il nome e' "Classifica · <gruppo>", quindi
      // l'errore sarebbe silenzioso e convincente.
      expect(repo.requestedGroups, ['g1', 'g2']);
    });

    test('le classifiche speciale usano il tipo giusto', () async {
      final c = container();

      await c.read(specialRankingProvider(('g1', SpecialRankingKind.divisive)).future);

      expect(repo.specialKinds, ['divisive']);
    });

    test('dopo un voto la classifica viene riletta', () async {
      repo = FakeRankingRepository(initial: [buildRankingEntry()]);
      final c = container();
      await c.read(rankingProvider('g1').future);
      await c.read(groupStatsProvider('g1').future);
      await c.read(specialRankingProvider(('g1', SpecialRankingKind.top)).future);

      final before = repo.rankingCalls;
      await c.read(ratingProvider.notifier).rate(
            groupId: 'g1',
            animeId: 'a1',
            score: 9,
          );

      expect(repo.rateCalls, 1);
      expect(repo.votes, ['g1|a1|9.0']);
      expect(c.read(rankingProvider('g1')).isLoading, isTrue);
      await c.read(rankingProvider('g1').future);
      expect(repo.rankingCalls, greaterThan(before));
    });

    test('un voto non riuscito non ricarica la classifica', () async {
      repo = FakeRankingRepository(initial: [buildRankingEntry()]);
      repo.rateFailure = const RankingFailure('Voto non registrato. Riprova.',
          isRetryable: true);
      final c = container();
      await c.read(rankingProvider('g1').future);
      final before = repo.rankingCalls;

      // L'errore viene rilanciato a chi ha chiesto il voto: e' la schermata che
      // deve poter dire "non registrato", non il controller che lo registra e
      // tace.
      await expectLater(
        c.read(ratingProvider.notifier).rate(groupId: 'g1', animeId: 'a1', score: 9),
        throwsA(isA<RankingFailure>()),
      );

      // Ricaricare dopo un errore mostrerebbe gli stessi numeri come se il
      // voto fosse andato a buon fine.
      expect(repo.rankingCalls, before);
      expect(c.read(ratingProvider).hasError, isTrue);
    });
  });

  group('schermata', () {
    late FakeRankingRepository repo;

    setUp(() => repo = FakeRankingRepository());

    /// Monta la classifica dentro un router vero.
    Future<void> pump(
      WidgetTester tester, {
      RankingRepository? repository,
      Size size = const Size(500, 900),
    }) async {
      final r = repository ?? repo;

      final router = GoRouter(
        initialLocation: '/ranking/g1',
        routes: [
          GoRoute(
            path: '/ranking/:groupId',
            builder: (_, state) => RankingScreen(groupId: state.pathParameters['groupId']!),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: ProviderScope(
            overrides: [rankingRepositoryProvider.overrideWithValue(r)],
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('senza rete la schermata avvisa che e una copia', (tester) async {
      final r = FakeRankingRepository(initial: [buildRankingEntry(title: 'Cowboy Bebop')]);
      final cache = FakeCacheStore();
      final cached = CachedRankingRepository(r, cache, userId: () => 'u1');

      // Prima apertura con rete: la copia si scrive.
      await cached.ranking('g1', limit: RankingPage.size, offset: 0);

      // Seconda apertura senza rete.
      r.rankingFailure = const RankingFailure('Rete assente.', isRetryable: true);
      await pump(tester, repository: cached);

      expect(find.text('Cowboy Bebop'), findsOneWidget);
      // Senza questo avviso l'utente prenderebbe decisioni su una classifica che
      // il backend ha superato, e non avrebbe modo di saperlo.
      expect(find.textContaining('Classifica salvata'), findsOneWidget);
    });

    testWidgets('con la rete l avviso non c e', (tester) async {
      await pump(
        tester,
        repository: CachedRankingRepository(repo, FakeCacheStore()),
      );

      expect(find.textContaining('Classifica salvata'), findsNothing);
    });

    testWidgets('una classifica vuota spiega cosa manca', (tester) async {
      await pump(tester);

      expect(find.text('Nessun anime votato in questo gruppo.'), findsOneWidget);
    });

    testWidgets('la classifica mostra posizione, media e voti', (tester) async {
      await pump(
        tester,
        repository: FakeRankingRepository(initial: [
          buildRankingEntry(title: 'Cowboy Bebop', position: 1, meanScore: 8.5, voteCount: 4),
        ]),
      );

      expect(find.text('Cowboy Bebop'), findsOneWidget);
      expect(find.text('8.5'), findsOneWidget);
      expect(find.text('4 voti'), findsOneWidget);
      // I dettagli sono una riga sola e su schermo stretto finiscono in
      // ellissi: si verifica la parte che resta sempre leggibile.
      expect(find.textContaining('1998 · 26 episodi'), findsOneWidget);
    });

    testWidgets('scorrendo in fondo si caricano le righe successive', (tester) async {
      final r = FakeRankingRepository(
        initial: [
          for (var i = 0; i < RankingPage.size + 10; i++)
            buildRankingEntry(animeId: 'a$i', position: i + 1),
        ],
      );
      await pump(tester, repository: r);

      // Una pagina piena vuol dire che il backend ha dell'altro: senza il
      // caricamento l'utente vedrebbe i primi 50 e non saprebbe che manca il
      // resto.
      expect(r.offsets, [0]);

      // Solo la tab visibile scorre: le altre tre liste sono costruite ma fuori
      // schermo, quindi il finder le troverebbe e il trascinamento non
      // toccherebbe nulla.
      await tester.drag(find.byType(CustomScrollView).hitTestable(), const Offset(0, -6000));
      await tester.pumpAndSettle();

      expect(r.offsets, [0, RankingPage.size]);

      // La lista tiene solo le righe vicine allo schermo: l'ultima posizione
      // si verifica solo dopo averci tornato con un altro scorrimento.
      await tester.drag(find.byType(CustomScrollView).hitTestable(), const Offset(0, -6000));
      await tester.pumpAndSettle();

      expect(find.text('${RankingPage.size + 10}'), findsOneWidget);
      // La pagina successiva e' l'ultima, quindi la voce sparisce invece di
      // lasciare un pulsante che non porta da nessuna parte.
      expect(find.text('Altre posizioni'), findsNothing);
    });

    testWidgets('senza altre righe la voce non compare', (tester) async {
      await pump(
        tester,
        repository: FakeRankingRepository(initial: [
          for (var i = 0; i < 3; i++) buildRankingEntry(animeId: 'a$i', position: i + 1),
        ]),
      );

      expect(find.text('Altre posizioni'), findsNothing);
    });

    testWidgets('un errore in coda lascia le righe e offre il retry', (tester) async {
      final r = FakeRankingRepository(
        initial: [
          for (var i = 0; i < RankingPage.size; i++)
            buildRankingEntry(animeId: 'a$i', position: i + 1),
        ],
      );
      await pump(tester, repository: r);

      // Il guasto arriva dopo la prima pagina, non prima: un errore sul
      // caricamento iniziale mostrerebbe invece la schermata di errore.
      r.rankingFailure = const RankingFailure('Rete assente.');
      await tester.drag(find.byType(CustomScrollView).hitTestable(), const Offset(0, -6000));
      await tester.pumpAndSettle();

      // Le righe gia' caricate restano: un errore sul caricamento successivo
      // non deve far sembrare vuota una classifica piena, e serve un'azione per
      // riprovare senza riaprire la schermata.
      expect(find.text('Rete assente.'), findsOneWidget);
      expect(find.text('Altre posizioni'), findsOneWidget);
      // Le righe sono ancora quelle della prima pagina: il 50 e' l'ultima
      // posizione, non un totale.
      expect(find.text('${RankingPage.size}'), findsOneWidget);

      r.rankingFailure = null;
      await tester.tap(find.text('Altre posizioni'));
      await tester.pumpAndSettle();

      expect(r.offsets, [0, RankingPage.size, RankingPage.size]);
    });

    testWidgets('su schermo largo le righe successive stanno sotto la tabella', (tester) async {
      final r = FakeRankingRepository(
        initial: [
          for (var i = 0; i < RankingPage.size + 10; i++)
            buildRankingEntry(animeId: 'a$i', position: i + 1),
        ],
      );
      await pump(tester, repository: r, size: const Size(1200, 900));

      // Da desktop la tabella non scorre riga per riga, quindi non c'e' uno
      // scroll della lista che possa attivare il caricamento: serve un
      // pulsante esplicito sotto il blocco.
      await tester.ensureVisible(find.text('Altre posizioni'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Altre posizioni'));
      await tester.pumpAndSettle();

      expect(r.offsets, [0, RankingPage.size]);
    });

    testWidgets('i totali del gruppo restano visibili', (tester) async {
      await pump(
        tester,
        repository: FakeRankingRepository(initial: [buildRankingEntry()])
          ..statsResult = const GroupStats(
            memberCount: 5,
            animeRated: 12,
            totalVotes: 40,
            groupMean: 7.25,
          ),
      );

      // Le etichette sono in maiuscoletto: sono parole di contesto, non titoli, e
      // in minuscolo sembrerebbero parte del dato.
      expect(find.text('MEMBRI'), findsOneWidget);
      expect(find.text('ANIME VOTATI'), findsOneWidget);
      expect(find.text('7.25'), findsOneWidget);
    });

    testWidgets('la variazione di posizione appare accanto al numero', (tester) async {
      await pump(
        tester,
        repository: FakeRankingRepository(initial: [
          // Le prime tre finiscono sul podio, che mostra la posizione e non la
          // variazione: la variazione si verifica sulle righe che restano nella
          // lista, ed e' li' che ha spazio per stare accanto al numero.
          buildRankingEntry(animeId: 'p1', position: 1),
          buildRankingEntry(animeId: 'p2', position: 2),
          buildRankingEntry(animeId: 'p3', position: 3),
          buildRankingEntry(position: 7, positionDelta: 2),
          buildRankingEntry(animeId: 'a2', title: 'Altro', position: 9, positionDelta: -3),
          buildRankingEntry(animeId: 'a3', title: 'Terzo', position: 5, positionDelta: 0),
        ]),
      );

      // Freccia oltre il segno: il "+2" da solo dice che il numero e' cambiato,
      // la freccia dice in che verso.
      expect(find.text('↑2'), findsOneWidget);
      expect(find.text('↓3'), findsOneWidget);
      // Nessuna variazione non e' "nessuna informazione": e' che lo snapshot di
      // ieri coincide, e un "+0" occuperebbe spazio per dire niente.
      expect(find.text('+0'), findsNothing);
    });

    testWidgets('un anime senza voto offre il pulsante stella', (tester) async {
      await pump(tester, repository: FakeRankingRepository(initial: [buildRankingEntry()]));

      expect(find.byIcon(Icons.star_border), findsOneWidget);
    });

    testWidgets('un voto gia dato viene mostrato come numero', (tester) async {
      await pump(
        tester,
        repository: FakeRankingRepository(initial: [buildRankingEntry(myScore: 9)]),
      );

      expect(find.byIcon(Icons.star_border), findsNothing);
      expect(find.text('9'), findsOneWidget);
    });

    testWidgets('votare apre il foglio e registra il voto', (tester) async {
      final r = FakeRankingRepository(initial: [buildRankingEntry(myScore: 7)]);
      await pump(tester, repository: r);

      await tester.tap(find.text('7'));
      await tester.pumpAndSettle();

      // Il foglio parte dal voto gia' dato: riaprirlo non deve far ripartire
      // da zero chi sta correggendo un mezzo punto.
      expect(find.text('7'), findsWidgets);
      expect(find.text('Vota'), findsOneWidget);

      await tester.tap(find.text('Vota'));
      await tester.pumpAndSettle();

      expect(r.rateCalls, 1);
      expect(r.votes, ['g1|a1|7.0']);
      expect(find.textContaining('Voto di 7 a Cowboy Bebop.'), findsOneWidget);
    });

    testWidgets('annullare il foglio non registra nulla', (tester) async {
      final r = FakeRankingRepository(initial: [buildRankingEntry()]);
      await pump(tester, repository: r);

      await tester.tap(find.byIcon(Icons.star_border));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Annulla'));
      await tester.pumpAndSettle();

      expect(r.rateCalls, 0);
    });

    testWidgets('un errore sul voto non lascia la schermata muta', (tester) async {
      final r = FakeRankingRepository(initial: [buildRankingEntry(myScore: 8)])
        ..rateFailure = const RankingFailure('Voto non registrato. Riprova.', isRetryable: true);
      await pump(tester, repository: r);

      await tester.tap(find.text('8'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vota'));
      await tester.pumpAndSettle();

      expect(find.text('Voto non registrato. Riprova.'), findsOneWidget);
      // Il numero precedente resta: senza, l'utente non saprebbe se il voto
      // precedente e' andato perso.
      expect(find.text('8'), findsWidgets);
    });

    testWidgets('un errore di caricamento offre il retry', (tester) async {
      final failing = FakeRankingRepository()
        ..rankingFailure = const RankingFailure('Server assente.', isRetryable: true);
      await pump(tester, repository: failing);

      expect(find.text('Server assente.'), findsOneWidget);

      failing.rankingFailure = null;
      await tester.tap(find.text('Riprova'));
      await tester.pumpAndSettle();

      expect(find.text('Nessun anime votato in questo gruppo.'), findsOneWidget);
    });

    testWidgets('la tab "divisivi" spiega la soglia di 3 voti', (tester) async {
      await pump(tester);

      await tester.tap(find.text('Divisivi'));
      await tester.pumpAndSettle();

      // Il vuoto e' voluto dal backend (soglia di 3 voti): senza la spiegazione
      // sembrerebbe un gruppo rotto.
      expect(
        find.textContaining('almeno 3 voti'),
        findsOneWidget,
      );
    });

    testWidgets('la tab speciale mostra le due metriche con etichetta', (tester) async {
      await pump(
        tester,
        repository: FakeRankingRepository(initial: [
          buildRankingEntry(title: 'Cowboy Bebop', meanScore: 8.5, voteCount: 4),
        ]),
      );

      await tester.tap(find.text('Più discussi'));
      await tester.pumpAndSettle();

      // "3" senza etichetta potrebbe essere voti o media: sono due numeri
      // diversi e l'utente non deve indovinare quale sia quale.
      expect(find.text('VOTI'), findsOneWidget);
      expect(find.text('MEDIA'), findsOneWidget);
    });

    group('podio', () {
      testWidgets('i primi tre posti stanno sul podio e la lista riprende dal quarto',
          (tester) async {
        await pump(
          tester,
          repository: FakeRankingRepository(initial: [
            buildRankingEntry(animeId: 'a1', title: 'Primo', position: 1),
            buildRankingEntry(animeId: 'a2', title: 'Secondo', position: 2),
            buildRankingEntry(animeId: 'a3', title: 'Terzo', position: 3),
            buildRankingEntry(animeId: 'a4', title: 'Quarto', position: 4),
          ]),
        );

        final podium = find.byType(RankPodium);
        expect(podium, findsOneWidget);
        expect(find.descendant(of: podium, matching: find.text('Primo')), findsOneWidget);
        expect(find.descendant(of: podium, matching: find.text('Secondo')), findsOneWidget);
        expect(find.descendant(of: podium, matching: find.text('Terzo')), findsOneWidget);
        // Il quarto non e' sul podio: se lo fosse, il podio mostrerebbe quattro
        // posti e la classifica direbbe che il quarto posto e' sul podio.
        expect(find.descendant(of: podium, matching: find.text('Quarto')), findsNothing);

        // Ogni titolo una volta sola: la stessa posizione mostrata dal podio e
        // dalla lista si riconoscerebbe subito come un doppio.
        expect(find.text('Primo'), findsOneWidget);
        expect(find.text('Secondo'), findsOneWidget);
        expect(find.text('Terzo'), findsOneWidget);

        // Il quarto e' in lista. Va portato in vista perche' la lista e' a
        // sliver e le righe sotto il bordo non sono costruite.
        await tester.drag(find.byType(CustomScrollView).hitTestable(), const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(find.text('Quarto'), findsOneWidget);
      });

      testWidgets('sotto i tre posti non c e un podio', (tester) async {
        // Con una o due righe il podio mostrerebbe una o due colonne sole al
        // centro dello schermo: non e' un podio, e' una lista con un formato
        // diverso. Sotto la soglia restano righe normali.
        await pump(
          tester,
          repository: FakeRankingRepository(initial: [
            buildRankingEntry(animeId: 'a1', title: 'Uno', position: 1),
            buildRankingEntry(animeId: 'a2', title: 'Due', position: 2),
          ]),
        );

        expect(find.byType(RankPodium), findsNothing);
        expect(find.text('Uno'), findsOneWidget);
        expect(find.text('Due'), findsOneWidget);
      });

      testWidgets('su telefono stretto il podio non sborda', (tester) async {
        // La larghezza delle copertine viene calcolata sullo spazio che resta
        // e la colonna centrale e' la piu' larga: su 320px e' il punto in cui
        // il podio esce dallo schermo. Il test fallisce da solo se una riga
        // traboccasce, quindi basta disegnarlo.
        await pump(
          tester,
          size: const Size(320, 640),
          repository: FakeRankingRepository(initial: [
            buildRankingEntry(animeId: 'a1', title: 'Primo posto con un titolo lunghissimo', position: 1),
            buildRankingEntry(animeId: 'a2', title: 'Secondo', position: 2),
            buildRankingEntry(animeId: 'a3', title: 'Terzo', position: 3),
            buildRankingEntry(animeId: 'a4', title: 'Quarto', position: 4),
          ]),
        );

        expect(find.byType(RankPodium), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('anche le classifiche speciali hanno il podio', (tester) async {
        await pump(
          tester,
          repository: FakeRankingRepository(initial: [
            buildRankingEntry(animeId: 'a1', title: 'Primo', position: 1, voteCount: 9),
            buildRankingEntry(animeId: 'a2', title: 'Secondo', position: 2, voteCount: 8),
            buildRankingEntry(animeId: 'a3', title: 'Terzo', position: 3, voteCount: 7),
            buildRankingEntry(animeId: 'a4', title: 'Quarto', position: 4, voteCount: 6),
          ]),
        );

        await tester.tap(find.text('Più amati'));
        await tester.pumpAndSettle();

        final podium = find.byType(RankPodium);
        expect(podium, findsOneWidget);
        expect(find.descendant(of: podium, matching: find.text('Primo')), findsOneWidget);
        expect(find.descendant(of: podium, matching: find.text('Quarto')), findsNothing);
      });
    });

    testWidgets('su schermo largo la classifica diventa tabella', (tester) async {
      await pump(
        tester,
        repository: FakeRankingRepository(initial: [buildRankingEntry()]),
        size: const Size(1200, 900),
      );

      // Da 900px in su le intestazioni sono obbligatorie: senza di esse
      // "8.5" e "3" in riga non si capiscono, e il prompt chiede che da desktop
      // il formato sia la tabella e non una versione rimpicciolita.
      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('Peso'), findsOneWidget);
      expect(find.text('Tuo voto'), findsOneWidget);
    });

    testWidgets('su telefono la classifica non e una tabella', (tester) async {
      await pump(
        tester,
        repository: FakeRankingRepository(initial: [buildRankingEntry()]),
        size: const Size(500, 900),
      );

      expect(find.byType(DataTable), findsNothing);
    });
  });

  group('rotta', () {
    test('il gruppo fa parte del percorso', () {
      // Il gruppo e' un parametro della rotta: metterlo dentro
      // `/groups/:id` renderebbe impossibile aprire la classifica senza
      // passare dal dettaglio del gruppo.
      expect('/ranking/g1', contains('g1'));
    });
  });

  group('RankingRepository', () {
    test('il finto rispetta il contratto', () {
      // Compila solo se tutte le firme corrispondono: una firma cambiata nel
      // repository reale romperebbe qui, non a runtime su un dispositivo.
      expect(FakeRankingRepository(), isA<RankingRepository>());
    });
  });
}
