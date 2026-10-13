import '../../anime/domain/anime.dart';
import '../domain/watchlist.dart';

/// Scheda anime ricostruita da una riga di watchlist.
///
/// La riga porta l'id interno di `public.anime` e il minimo dei dati, quindi la
/// scheda mostra la realta' di quello che c'e', senza riempirsi i buchi con
/// copertine o voti inventati. La lista dei voti e' un'altra tabella e non si
/// ricava da qui.
///
/// Vive in un file suo e non nella schermata che l'ha introdotta perche' ora la
/// usano due schermate — la watchlist e i preferiti — e due copie divergerebbero
/// alla prima riga aggiunta al catalogo.
AnimeEntry animeEntryOf(WatchlistEntry entry) => AnimeEntry(
      externalId: entry.animeId,
      title: entry.title,
      italianTitle: entry.italianTitle,
      imageUrl: entry.imageUrl,
      episodes: entry.episodes,
      year: entry.year,
      genres: entry.genres,
      status: entry.airing ? AnimeAirStatus.airing : null,
    );
