import 'package:animerank/features/groups/domain/group.dart';
import 'package:animerank/features/home/home_controller.dart';
import 'package:animerank/features/home/widgets/home_sections.dart';
import 'package:animerank/features/history/domain/watch_history.dart';
import 'package:animerank/features/watchlist/domain/watchlist.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_anime.dart';

/// La logica pura della home.
///
/// Sono le funzioni che decidono *cosa* si vede: quale opera va nel banner, cosa
/// finisce in "Guardati di recente", quando un consiglio e' davvero personale.
/// Sono pure anche per questo: si possono fissare data e ingressi e pretendere
/// lo stesso risultato, che e' esattamente cio' che non si puo' fare guardando
/// la schermata.
void main() {
  group('primaryGroupOf', () {
    AnimeGroup group(String id, GroupRole role) => AnimeGroup(
      id: id,
      name: 'Gruppo $id',
      inviteCode: 'code-$id',
      ownerId: 'owner',
      myRole: role,
      createdAt: DateTime(2024),
    );

    test('senza gruppi non c e un gruppo di riferimento', () {
      expect(primaryGroupOf(const []), isNull);
    });

    test('preferisce quello che possiedo', () {
      final pick = primaryGroupOf([
        group('a', GroupRole.member),
        group('b', GroupRole.owner),
        group('c', GroupRole.admin),
      ]);

      expect(pick?.id, 'b');
    });

    test('senza owner ripiega su chi posso amministrare', () {
      final pick = primaryGroupOf([
        group('a', GroupRole.member),
        group('b', GroupRole.admin),
      ]);

      expect(pick?.id, 'b');
    });

    test('fra soli membri vale il primo', () {
      final pick = primaryGroupOf([
        group('a', GroupRole.member),
        group('b', GroupRole.member),
      ]);

      expect(pick?.id, 'a');
    });
  });

  group('featuredOf', () {
    test('catalogo vuoto: nessun banner', () {
      expect(featuredOf(const []), isNull);
    });

    test('la scelta non cambia fra due chiamate ravvicinate', () {
      final pool = [
        animeFixture(externalId: '1', id: 'id-1', imageUrl: 'a.jpg'),
        animeFixture(externalId: '2', id: 'id-2', imageUrl: 'b.jpg'),
        animeFixture(externalId: '3', id: 'id-3', imageUrl: 'c.jpg'),
      ];
      final at = DateTime(2026, 3, 10, 9);

      expect(featuredOf(pool, now: at)?.id, featuredOf(pool, now: at)?.id);
    });

    test('cambia quando cambia il giorno', () {
      final pool = [
        for (var i = 1; i <= 5; i++)
          animeFixture(externalId: '$i', id: 'id-$i', imageUrl: '$i.jpg'),
      ];

      final today = featuredOf(pool, now: DateTime(2026, 3, 10));
      final tomorrow = featuredOf(pool, now: DateTime(2026, 3, 11));

      expect(today?.id, isNot(tomorrow?.id));
    });

    test('preferisce le opere con copertina', () {
      final pool = [
        animeFixture(externalId: '1', id: 'id-1', imageUrl: null),
        animeFixture(externalId: '2', id: 'id-2', imageUrl: 'b.jpg'),
      ];

      // Il giorno dell'anno cade sull'indice 0, cioe' proprio l'opera senza
      // copertina: se il filtro non ci fosse, il banner resterebbe cieco.
      expect(featuredOf(pool, now: DateTime(2026, 1, 1))?.id, 'id-2');
    });

    test('se nessuna ha copertina usa comunque il catalogo', () {
      final pool = [
        animeFixture(externalId: '1', id: 'id-1', imageUrl: null),
        animeFixture(externalId: '2', id: 'id-2', imageUrl: null),
      ];

      expect(featuredOf(pool, now: DateTime(2026, 1, 1)), isNotNull);
    });
  });

  group('favouriteGenre', () {
    test('niente generi: niente segnale', () {
      expect(favouriteGenre(const []), isNull);
    });

    test('una sola occorrenza non basta a dire che e un genere preferito', () {
      expect(favouriteGenre(['Comedy', 'Action']), isNull);
    });

    test('due occorrenze bastano', () {
      expect(favouriteGenre(['Comedy', 'Action', 'Comedy']), 'Comedy');
    });

    test('a parita di conteggio vince l ordine alfabetico', () {
      final pick = favouriteGenre(['Romance', 'Action', 'Romance', 'Action']);

      expect(pick, 'Action');
    });

    test('gli spazi non creano generi diversi', () {
      expect(favouriteGenre(['  Action', 'Action  ']), 'Action');
    });

    test('le stringhe vuote si scartano', () {
      expect(favouriteGenre(['', '  ', '']), isNull);
    });
  });

  group('currentSeasonLabel', () {
    test('gennaio e inverno dello stesso anno', () {
      expect(currentSeasonLabel(DateTime(2026, 1, 15)), 'Inverno 2026');
    });

    test('aprile e primavera', () {
      expect(currentSeasonLabel(DateTime(2026, 4, 2)), 'Primavera 2026');
    });

    test('dicembre e l inverno dell anno dopo', () {
      // La stagione invernale comincia a dicembre: chiamarla 2026 a dicembre
      // manderebbe la home un anno indietro.
      expect(currentSeasonLabel(DateTime(2026, 12, 20)), 'Inverno 2027');
    });
  });

  group('compactNumber', () {
    test('sotto il migliaio resta intero', () {
      expect(compactNumber(987), '987');
      expect(compactNumber(0), '0');
    });

    test('migliaia con una cifra decimale', () {
      expect(compactNumber(12345), '12.3K');
    });

    test('il decimale a zero non si scrive', () {
      expect(compactNumber(5000), '5K');
    });

    test('milioni', () {
      // Il valore reale di Attack on Titan nel catalogo.
      expect(compactNumber(1062878), '1.1M');
    });
  });

  group('recentlyWatched', () {
    WatchHistoryItem item(String animeId, {int episode = 1}) => WatchHistoryItem(
      animeId: animeId,
      animeTitle: 'Titolo $animeId',
      episodeId: 'ep-$animeId-$episode',
      episodeNumber: episode,
      currentSeconds: 0,
      completed: true,
    );

    test('un anime una volta sola', () {
      final rows = [
        item('a', episode: 3),
        item('a', episode: 4),
        item('b'),
      ];

      final picked = recentlyWatched(rows, excludeAnimeIds: const {});

      expect(picked.map((e) => e.animeId), ['a', 'b']);
      // Vince la voce piu' recente, cioe' la prima che si incontra.
      expect(picked.first.episodeId, 'ep-a-3');
    });

    test('le opere in Continua a guardare non si ripetono', () {
      final rows = [item('a'), item('b')];

      final picked = recentlyWatched(rows, excludeAnimeIds: {'a'});

      expect(picked.map((e) => e.animeId), ['b']);
    });

    test('il limite si rispetta', () {
      final rows = [for (var i = 0; i < 10; i++) item('a$i')];

      expect(
        recentlyWatched(rows, excludeAnimeIds: const {}, limit: 3).length,
        3,
      );
    });
  });

  group('watchlistResume', () {
    WatchlistEntry entry(String animeId, WatchStatus status) => WatchlistEntry(
      id: 'w-$animeId',
      animeId: animeId,
      status: status,
    );

    test('prima quello iniziato, poi quello da iniziare', () {
      final entries = [
        entry('a', WatchStatus.planned),
        entry('b', WatchStatus.watching),
        entry('c', WatchStatus.planned),
        entry('d', WatchStatus.watching),
      ];

      final picked = watchlistResume(entries);

      expect(picked.map((e) => e.animeId), ['b', 'd', 'a', 'c']);
    });

    test('finiti e abbandonati restano fuori', () {
      final entries = [
        entry('a', WatchStatus.completed),
        entry('b', WatchStatus.dropped),
        entry('c', WatchStatus.paused),
        entry('d', WatchStatus.watching),
      ];

      final picked = watchlistResume(entries);

      expect(picked.map((e) => e.animeId), ['d']);
    });

    test('il limite si rispetta', () {
      final entries = [
        for (var i = 0; i < 8; i++) entry('a$i', WatchStatus.watching),
      ];

      expect(watchlistResume(entries, limit: 4).length, 4);
    });
  });

  group('shortSynopsis', () {
    test('una sinossi corta resta intera', () {
      expect(shortSynopsis('Breve.'), 'Breve.');
    });

    test('vuota o nulla non produce testo', () {
      expect(shortSynopsis(null), isNull);
      expect(shortSynopsis('   '), isNull);
    });

    test('si chiude sull ultimo periodo del taglio', () {
      final text = '${'a' * 200}. ${'b' * 200}';

      final short = shortSynopsis(text, limit: 220);

      expect(short, endsWith('.'));
      expect(short!.length, lessThan(text.length));
    });
  });

  group('relativeDate', () {
    final now = DateTime(2026, 5, 10, 12);

    test('adesso', () {
      expect(relativeDate(DateTime(2026, 5, 10, 11, 59, 30), now: now), 'adesso');
    });

    test('minuti', () {
      expect(relativeDate(DateTime(2026, 5, 10, 11, 45), now: now), '15 min');
    });

    test('ore', () {
      expect(relativeDate(DateTime(2026, 5, 10, 9), now: now), '3 h');
    });

    test('ieri', () {
      expect(relativeDate(DateTime(2026, 5, 9, 12), now: now), 'ieri');
    });

    test('giorni', () {
      expect(relativeDate(DateTime(2026, 5, 7, 12), now: now), '3 g');
    });

    test('oltre la settimana diventa una data', () {
      expect(relativeDate(DateTime(2026, 5, 1, 12), now: now), '01/05/2026');
    });
  });
}
