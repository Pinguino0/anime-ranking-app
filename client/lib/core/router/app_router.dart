import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../ui/transitions.dart';
import '../../features/auth/domain/auth_status.dart';
import '../../features/auth/presentation/auth_controller.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/anime/domain/anime.dart';
import '../../features/anime/presentation/screens/anime_detail_screen.dart';
import '../../features/anime/presentation/screens/anime_search_screen.dart';
import '../../features/auth/presentation/screens/register_screen.dart';
import '../../features/duels/presentation/screens/duels_screen.dart';
import '../../features/episodes/presentation/screens/episode_screen.dart';
import '../../features/groups/presentation/screens/create_group_screen.dart';
import '../../features/groups/presentation/screens/group_detail_screen.dart';
import '../../features/groups/presentation/screens/group_members_screen.dart';
import '../../features/groups/presentation/screens/group_picker_screen.dart';
import '../../features/groups/presentation/screens/groups_list_screen.dart';
import '../../features/groups/presentation/screens/join_group_screen.dart';
import '../../features/profile/presentation/screens/delete_account_screen.dart';
import '../../features/profile/presentation/screens/notification_settings_screen.dart';
import '../../features/profile/presentation/screens/profile_screen.dart';
import '../../features/ranking/presentation/screens/ranking_screen.dart';
import '../../features/shell/presentation/shell_screen.dart';
import '../../features/tournaments/presentation/screens/tournament_detail_screen.dart';
import '../../features/tournaments/presentation/screens/tournaments_screen.dart';
import '../../features/watchlist/presentation/screens/watchlist_screen.dart';

/// Nomi delle rotte.
///
/// Centralizzati perche' [redirect] e le schermate devono concordare: una
/// rotta scritta a mano in due posti diverge appena una viene cambiata.
class AppRoutes {
  const AppRoutes._();

  static const String home = '/';
  static const String login = '/login';
  static const String register = '/register';

  static const String groups = '/groups';
  static const String createGroup = '/groups/create';
  static const String joinGroup = '/groups/join';

  /// Ricerca del catalogo anime.
  ///
  /// Non sta sotto `/groups` perche' il catalogo e' condiviso: e' leggibile da
  /// tutti gli autenticati e serve anche a chi non ha ancora un gruppo, per
  /// capire cosa potrebbe valutare prima di iscriversi a una lista condivisa.
  static const String animeSearch = '/anime';

  /// Selettori di gruppo delle sezioni per gruppo.
  ///
  /// Sono le rotte delle voci globali della shell, dove il gruppo non e' noto.
  /// Ogni rotta con `:groupId` sotto resta quella vera: il selettore sparisce
  /// appena l'utente sceglie.
  static const String rankingPicker = '/ranking';
  static const String watchlistPicker = '/watchlist';
  static const String duelsPicker = '/duels';
  static const String tournamentsPicker = '/tournaments';

  /// Classifica di un gruppo specifico.
  ///
  /// Fuori da [AppRoutes.groups] perche' la si raggiunge dal dettaglio di un
  /// gruppo, dove il gruppo e' gia' noto: qui e' un parametro, non parte
  /// dell'elenco dei gruppi.
  static String ranking(String groupId) => '/ranking/$groupId';

  /// Watchlist personale dentro un gruppo specifico.
  ///
  /// Sullo stesso percorso della classifica per lo stesso motivo: `watchlists`
  /// ha `group_id` fra le colonne, quindi la watchlist di un gruppo e' un
  /// insieme diverso da quello di un altro.
  static String watchlist(String groupId) => '/watchlist/$groupId';

  /// Duelli e classifica Elo di un gruppo specifico.
  ///
  /// Come la classifica e la watchlist, anche i duelli stanno per gruppo: la
  /// tabella `duels` ha `group_id`, quindi gli Elo di un gruppo non hanno
  /// senso mescolati a quelli di un altro.
  static String duels(String groupId) => '/duels/$groupId';

  /// Tornei di un gruppo e tabellone di un torneo.
  ///
  /// Il tabellone ha un parametro in piu' del gruppo (`tournamentId`) perche' il
  /// backend non ha una pagina "torneo per gruppo": ogni torneo si raggiunge
  /// dal proprio id, gia' noto dalla lista.
  static String tournaments(String groupId) => '/tournaments/$groupId';

  static String tournamentDetail(String groupId, String tournamentId) =>
      '/tournaments/$groupId/$tournamentId';

  static const String profile = '/profile';
  static const String notificationSettings = '/profile/notifications';
  static const String deleteAccount = '/profile/delete';

  /// Costruisce la rotta di un gruppo specifico.
  static String groupDetail(String id) => '/groups/$id';

  /// Costruisce la rotta dell'elenco membri di un gruppo.
  ///
  /// I membri hanno una schermata propria e non una sezione nel dettaglio: la
  /// lista puo' essere lunga, e mescolarla alle card di navigazione del gruppo
  /// costringerebbe a scorrere tutto per arrivare in fondo ai nomi.
  static String groupMembers(String id) => '/groups/members/$id';

  /// Scheda di un anime.
  ///
  /// Fuori da [animeSearch] come rotta a se': e' una pagina, non un filtro, e
  /// merita un indirizzo proprio perche' si raggiunge anche da un deep link.
  ///
  /// Il nome dell'opera viaggia in `extra` e non nel percorso: la Edge Function
  /// non espone una rotta di dettaglio, quindi l'unica fonte dei dati e' il
  /// risultato di ricerca che ha gia' l'opera in mano. Un id nel percorso
  /// suggerirebbe che la pagina si possa ricaricare da sola, e non si puo'.
  static const String animeDetail = '/anime/detail';

  /// Visione di un episodio.
  ///
  /// Sotto [animeSearch] e non sotto [animeDetail]: gli episodi sono legati
  /// all'opera dal catalogo, non alla scheda, e perche' la lista si apra dal
  /// pulsante "Guarda" della scheda senza passare da lei.
  ///
  /// L'id dell'opera e' nel percorso e non in `extra` perche' serve a ricaricare
  /// l'elenco degli episodi: senza, la pagina si aprirebbe vuota e andrebbe a
  /// testa indietro appena si cambia episodio. Il nome dell'opera invece
  /// viaggia in `extra` — e' solo il titolo in alto, e deve poter mancare.
  static String episode(String animeId, String episodeId) =>
      '$animeSearch/$animeId/episode/$episodeId';

  /// Visione dell'opera con il primo episodio, dalla scheda anime.
  static String firstEpisode(String animeId) =>
      '$animeSearch/$animeId/episode';

  /// Rotte raggiungibili senza sessione.
  static const Set<String> public = {login, register};
}

/// Router dell'app.
///
/// Il `redirect` e' l'unico punto che decide dove l'utente può andare. Le
/// schermate non chiamano `context.go` per spostarsi dopo il login: quando la
/// sessione arriva, il router ri-valuta da solo e porta alla schermata giusta.
/// Se invece fosse una schermata a decidere, si aprirebbe la porta a schermate
/// raggiungibili "per sbaglio" mentre la sessione non e' ancora valida.
final appRouterProvider = Provider<GoRouter>((ref) {
  // GoRouter non si ricostruisce a ogni cambio di stato, quindi va avvisato
  // esplicitamente. Un ValueNotifier minimale basta: il router non guarda il
  // valore, gli interessa solo la notifica.
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen<AuthStatus>(authStatusProvider, (_, _) => refresh.value++);

  return GoRouter(
    initialLocation: AppRoutes.home,
    refreshListenable: refresh,
    routes: [
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const ShellScreen(),
      ),
      // Sotto-gruppo dei gruppi: il percorso condivide il prefisso, quindi
      // ogni schermata di gruppo eredita la protezione dichiarata sotto.
      GoRoute(
        path: AppRoutes.groups,
        builder: (context, state) => const GroupsListScreen(),
        routes: [
          GoRoute(
            path: 'create',
            builder: (context, state) => const CreateGroupScreen(),
          ),
          GoRoute(
            path: 'join',
            builder: (context, state) => const JoinGroupScreen(),
          ),
          GoRoute(
            path: ':id',
            builder: (context, state) =>
                GroupDetailScreen(groupId: state.pathParameters['id']!),
          ),
          // Rotta sorella e non figlia di `:id`: metterla dentro avrebbe
          // costretto `:id` a dichiarare una child vuota per continuare a
          // rispondere da solo, e `/groups/members/xyz` si sarebbe potuto
          // confondere con un id di gruppo.
          GoRoute(
            path: 'members/:id',
            builder: (context, state) =>
                GroupMembersScreen(groupId: state.pathParameters['id']!),
          ),
        ],
      ),
      // Le quattro sezioni per gruppo hanno una rotta senza `groupId`, che fa
      // scegliere il gruppo, e una con `groupId`, che e' la sezione vera.
      // Sono rotte distinte e non una con parametro opzionale: un parametro
      // che puo' mancare farebbe dipendere il comportamento dal posto da cui
      // si arriva, mentre qui la scelta e' sempre esplicita e resta nella
      // cronologia.
      GoRoute(
        path: AppRoutes.rankingPicker,
        builder: (_, _) =>
            const GroupPickerScreen(section: GroupSection.ranking),
      ),
      GoRoute(
        path: AppRoutes.watchlistPicker,
        builder: (_, _) =>
            const GroupPickerScreen(section: GroupSection.watchlist),
      ),
      GoRoute(
        path: AppRoutes.duelsPicker,
        builder: (_, _) => const GroupPickerScreen(section: GroupSection.duels),
      ),
      GoRoute(
        path: AppRoutes.tournamentsPicker,
        builder: (_, _) =>
            const GroupPickerScreen(section: GroupSection.tournaments),
      ),
      // La classifica sta su un percorso proprio: dentro `/groups/:id`
      // sostituirebbe il dettaglio del gruppo, che resta la schermata da cui si
      // parte, e servirebbe un terzo parametro sulla stessa rotta.
      GoRoute(
        path: '/ranking/:groupId',
        builder: (context, state) => RankingScreen(
          groupId: state.pathParameters['groupId']!,
          // Il nome del gruppo viaggia in `extra`, non nel percorso: serve solo
          // al titolo e deve poter mancare (rotta aperta a mano, deep link), e
          // un parametro di percorso che si puo' omettere romperebbe la
          // navigazione indietro.
          groupName: state.extra as String?,
        ),
      ),
      GoRoute(
        path: '/watchlist/:groupId',
        builder: (context, state) => WatchlistScreen(
          groupId: state.pathParameters['groupId']!,
          groupName: state.extra as String?,
        ),
      ),
      GoRoute(
        path: '/duels/:groupId',
        builder: (context, state) => DuelsScreen(
          groupId: state.pathParameters['groupId']!,
          groupName: state.extra as String?,
        ),
      ),
      GoRoute(
        path: '/tournaments/:groupId',
        builder: (context, state) => TournamentsScreen(
          groupId: state.pathParameters['groupId']!,
          groupName: state.extra as String?,
        ),
        routes: [
          GoRoute(
            path: ':tournamentId',
            builder: (context, state) => TournamentDetailScreen(
              tournamentId: state.pathParameters['tournamentId']!,
              groupId: state.pathParameters['groupId']!,
              // `canDelete` e' deciso dal ruolo nel gruppo, che il router non
              // conosce: viaggia in `extra` come il nome del gruppo. Se manca
              // (deep link) il menu non compare, che e' il comportamento
              // corretto per un ruolo sconosciuto.
              canDelete: state.extra as bool? ?? false,
            ),
          ),
        ],
      ),
      // Sotto-gruppo del profilo: le schermate di impostazioni e cancellazione
      // sono raggiungibili solo da un utente collegato, quindi stanno sotto
      // `/profile` che non e' in AppRoutes.public.
      // Il catalogo e' una sezione di primo livello, non una schermata che si
      // raggiunge da un gruppo: e' la prima cosa che un utente nuovo cerca,
      // perche' senza anime votati non c'e' niente da fare in nessuna sezione.
      GoRoute(
        path: AppRoutes.animeSearch,
        builder: (context, state) => const AnimeSearchScreen(),
        routes: [
          GoRoute(
            path: 'detail',
            // `pageBuilder` e non `builder`: e' l'unico modo per dire a
            // GoRouter di usare una transizione invece del salto istantaneo
            // di default. Con `builder` l'animazione si perde e la scheda
            // apparirebbe di colpo, senza il volo dell'immagine.
            pageBuilder: (context, state) {
              // `extra` porta l'opera. Se manca — rotta aperta a mano, deep
              // link, ripristino dopo un crash — non si puo' mostrare nulla di
              // utile, quindi si torna alla ricerca invece di disegnare una
              // pagina vuota che sembrerebbe un errore.
              final entry = state.extra as AnimeEntry?;

              if (entry == null) {
                return MaterialPage<void>(
                  name: AppRoutes.animeDetail,
                  child: const AnimeSearchScreen(),
                );
              }

              return arDetailRoute<void>(
                name: AppRoutes.animeDetail,
                child: AnimeDetailScreen(
                  entry: entry,
                  heroTag: entry.heroTag,
                ),
              );
            },
          ),
          GoRoute(
            path: ':animeId/episode/:episodeId',
            builder: (context, state) => EpisodeScreen(
              animeId: state.pathParameters['animeId']!,
              episodeId: state.pathParameters['episodeId']!,
              animeTitle: state.extra as String?,
            ),
          ),
          // Stessa pagina senza episodio scelto: e' la porta d'ingresso dalla
          // scheda dell'opera, dove l'utente ha premuto "Guarda" senza sapere
          // quale episodio esiste. La schermata allora apre il primo
          // disponibile, che di solito e' quello che voleva.
          GoRoute(
            path: ':animeId/episode',
            builder: (context, state) => EpisodeScreen(
              animeId: state.pathParameters['animeId']!,
              animeTitle: state.extra as String?,
            ),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.profile,
        builder: (context, state) => const ProfileScreen(),
        routes: [
          GoRoute(
            path: 'notifications',
            builder: (context, state) => const NotificationSettingsScreen(),
          ),
          GoRoute(
            path: 'delete',
            builder: (context, state) => const DeleteAccountScreen(),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.register,
        builder: (context, state) => const RegisterScreen(),
      ),
    ],
    redirect: (context, state) {
      final isPublic = AppRoutes.public.contains(state.matchedLocation);

      return switch (ref.read(authStatusProvider)) {
        // Collegato: la schermata di login o registrazione non ha senso, si
        // torna alla home. Il nome della rotta (/login) verrebbe sostituito
        // da go() che pila la cronologia: replace() non lascia un "indietro"
        // che rimanderebbe al login dopo il logout.
        AuthSignedIn() when isPublic => AppRoutes.home,
        // Scollegato: qualsiasi rotta privata rimanda al login, cosi' non si
        // resta su una pagina che mostrerebbe dati vuoti o un errore.
        AuthSignedOut() when !isPublic => AppRoutes.login,
        _ => null,
      };
    },
  );
});
