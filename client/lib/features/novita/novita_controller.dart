import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../anime/domain/anime.dart';
import '../anime/presentation/anime_controller.dart';

/// Gli anime "in uscita": quelli della stagione corrente.
///
/// Stessa sorgente della riga "In uscita ora" della home, ma con un contenitore
/// suo: la pagina "Novita'" e' una pagina a se' e non deve dipendere dallo stato
/// della home per esistere.
final upcomingAnimeProvider = FutureProvider<List<AnimeEntry>>((ref) async {
  return ref.watch(animeRepositoryProvider).currentSeason(limit: 20);
});

/// Gli anime con le ultime puntate aggiunte.
///
/// Alimenta la riga "Nuovi episodi" leggendo `recent_episodes`: gli anime
/// ordinati per data dell'ultimo episodio. Un anime compare una volta sola, con
/// la sua puntata piu' recente, invece di riempire la riga con lo stesso titolo
/// ripetuto per ogni episodio.
final recentEpisodesProvider = FutureProvider<List<AnimeEntry>>((ref) async {
  return ref.watch(animeRepositoryProvider).recentEpisodes(limit: 20);
});
