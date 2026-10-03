import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/cache/hive_cache_store.dart';
import 'core/cache/session_cache_cleanup.dart';
import 'core/env/app_config.dart';
import 'core/supabase/supabase_provider.dart';
import 'features/anime/data/anime_repository.dart';
import 'features/anime/presentation/anime_controller.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/duels/data/duels_repository.dart';
import 'features/duels/presentation/duels_controller.dart';
import 'features/groups/data/groups_repository.dart';
import 'features/groups/presentation/groups_controller.dart';
import 'features/profile/data/profile_repository.dart';
import 'features/profile/presentation/profile_controller.dart';
import 'features/ranking/data/cached_ranking_repository.dart';
import 'features/ranking/data/ranking_repository.dart';
import 'features/ranking/presentation/ranking_controller.dart';
import 'features/tournaments/data/tournaments_repository.dart';
import 'features/tournaments/presentation/tournaments_controller.dart';
import 'features/watchlist/data/watchlist_repository.dart';
import 'features/watchlist/presentation/watchlist_controller.dart';

/// Punto d'ingresso.
///
/// Inizializza Supabase una volta sola e poi passa il client gia' costruito
/// dentro il [ProviderScope], invece di far leggere `Supabase.instance` ai
/// provider. Il motivo e' la testabilita': i test non devono simulare il
/// bootstrap globale, basta sovrascrivere [supabaseProvider] e
/// [authRepositoryProvider] con dei finti.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!AppConfig.isConfigured) {
    // Senza credenziali non si costruisce nessun client: l'app mostra le
    // istruzioni invece di aprire schermate che esploderebbero al primo tocco.
    runApp(const SetupApp());
    return;
  }

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    // publishableKey, non anonKey: quest'ultimo e deprecato in supabase_flutter
    // 2.18. La chiave da usare resta in ogni caso quella pubblica.
    publishableKey: AppConfig.supabaseAnonKey,
  );

  final client = Supabase.instance.client;

  // La cache si apre una volta sola e prima di `runApp`: se il disco non
  // collabora, [HiveCacheStore.open] restituisce una cache vuota e l'app parte
  // lo stesso, solo con una richiesta di rete in piu'.
  final cache = await HiveCacheStore.open();

  final cachedRanking = CachedRankingRepository(
    SupabaseRankingRepository(client),
    cache,
    // Letto a ogni accesso, non qui: al logout l'utente cambia e le chiavi
    // devono smettere di essere quelle del vecchio account.
    userId: () => client.auth.currentUser?.id,
  );

  // La copia su disco dell'utente che esce va buttata via, e va fatto qui perche'
  // e' l'unico posto dove la cache e il canale auth si incontrano.
  SessionCacheCleanup(
    cachedRanking,
    SupabaseAuthRepository(client).watch(),
  ).start();

  runApp(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(client),
        authRepositoryProvider.overrideWithValue(
          SupabaseAuthRepository(client),
        ),
        // Il repository gruppi riceve lo stesso client: nessuna nuova
        // connessione, nessuna seconda istanza di Supabase da tenere viva.
        groupsRepositoryProvider.overrideWithValue(
          SupabaseGroupsRepository(client),
        ),
        profileRepositoryProvider.overrideWithValue(
          SupabaseProfileRepository(client),
        ),
        // Il catalogo non va in cache: cambia di continuo, e mostrare una
        // copia vecchia su una ricerca ripeterebbe l'effetto scomodo che la
        // cache della classifica evita solo perche' li' i dati cambiano poco.
        animeRepositoryProvider.overrideWithValue(
          SupabaseAnimeRepository(client),
        ),
        // Solo la classifica va in cache: e' l'unica schermata che si
        // riapre spesso e che un utente stanco di aspettare accetta di vedere
        // anche copiata, con un avviso che lo dice.
        rankingRepositoryProvider.overrideWithValue(cachedRanking),
        watchlistRepositoryProvider.overrideWithValue(
          SupabaseWatchlistRepository(client),
        ),
        duelsRepositoryProvider.overrideWithValue(
          SupabaseDuelsRepository(client),
        ),
        tournamentsRepositoryProvider.overrideWithValue(
          SupabaseTournamentsRepository(client),
        ),
      ],
      child: const AnimeRankApp(),
    ),
  );
}
