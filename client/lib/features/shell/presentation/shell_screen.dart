import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/breakpoints.dart';
import '../../../core/router/app_router.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../groups/presentation/groups_controller.dart';
import '../../home/screens/home_screen.dart';

/// Scheletro dell'app per l'utente collegato.
///
/// E' la pagina da cui si parte: offre la sidebar da desktop e la barra in
/// basso da telefono. Le sezioni non ancora scritte restano visibili ma
/// dichiarano di non essere disponibili, cosi' l'utente capisce che mancano e
/// non crede che l'app sia rotta.
class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({super.key});

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen> {
  static const _sections = <_NavSection>[
    // Il catalogo sta per primo: e' la prima cosa che serve a un utente che
    // ha appena creato un gruppo e non ha ancora votato niente. Se fosse in
    // fondo, le sezioni piu' usate della barra starebbero nell'ordine inverso
    // rispetto a come si ragiona.
    _NavSection(
      'Anime',
      Icons.search_outlined,
      Icons.search,
      AppRoutes.animeSearch,
    ),
    _NavSection(
      'Gruppi',
      Icons.groups_outlined,
      Icons.groups,
      AppRoutes.groups,
    ),
    // Le quattro sezioni restano per gruppo, quindi la voce globale porta al
    // selettore e non alla sezione: `/ranking` da sola non saprebbe quale
    // gruppo mostrare. Il nome del gruppo viaggia in `extra` una volta scelto.
    _NavSection(
      'Classifica',
      Icons.leaderboard_outlined,
      Icons.leaderboard,
      AppRoutes.rankingPicker,
    ),
    // Come la classifica, anche la watchlist e' per gruppo: `watchlists` ha
    // `group_id` fra le colonne, quindi due gruppi hanno due watchlist diverse.
    _NavSection(
      'Watchlist',
      Icons.bookmark_border,
      Icons.bookmark,
      AppRoutes.watchlistPicker,
    ),
    // Come le due precedenti, anche i duelli sono per gruppo: la tabella `duels`
    // ha `group_id` e gli Elo sono calcolati dentro un solo gruppo.
    _NavSection(
      'Duelli',
      Icons.sports_martial_arts_outlined,
      Icons.sports_martial_arts,
      AppRoutes.duelsPicker,
    ),
    // Come le precedenti, i tornei sono per gruppo: `tournaments` ha `group_id`
    // e il bracket si genera dentro un solo gruppo.
    _NavSection(
      'Tornei',
      Icons.emoji_events_outlined,
      Icons.emoji_events,
      AppRoutes.tournamentsPicker,
    ),
    // Il profilo sta fra le sezioni anche se non e' un gruppo: sulla barra da
    // telefono e' l'ultima voce raggiungibile senza aprire un menu, e sulla
    // sidebar evita che resti incastonato in fondo alla lista.
    _NavSection(
      'Profilo',
      Icons.person_outline,
      Icons.person,
      AppRoutes.profile,
    ),
  ];

  /// Su telefono la barra mostra quattro sezioni piu' il profilo.
  ///
  /// Cinque sezioni piu' il profilo su uno schermo stretto diventano
  /// etichette illeggibili: si mostra la quarta sezione piu' usata e il resto
  /// resta raggiungibile dalla schermata di partenza.
  static const int _mobileSectionCount = 4;

  /// Ultima voce toccata, cosi' la barra e la sidebar concordano.
  ///
  /// Segue l'ultima sezione aperta invece di tenere un indice fisso: senza, dopo
  /// un tocco su "Duelli" la barra ripartirebbe da "Gruppi" e sembrerebbe che
  /// il tocco non sia andato a buon fine.
  String? _lastRoute;

  /// Ultima voce della barra del telefono che esiste davvero.
  ///
  /// Duelli e Tornei sono sezioni senza voce nella barra (vedi
  /// [_mobileSectionCount]) ma si aprono dalla schermata di partenza. La
  /// `NavigationBar` pretende comunque un indice dentro la lista, e passarle
  /// l'indice di sezione (5 o 6 su una lista di 5 voci) faceva scattare
  /// "0 <= selectedIndex < destinations.length" e chiudeva l'app. Qui si tiene
  /// l'ultima voce reale invece di puntare fuori range.
  int _lastMobileIndex = 0;

  void _select(int index, {required bool sidebar}) {
    final section = _sections[_indexFor(index, sidebar: sidebar)];

    // `push` e non `go`: la pagina aperta deve poter essere chiusa con
    // "indietro", tornando comodo alla schermata da cui si e' partiti. Con
    // `go` la schermata verrebbe sostituita e il back resterebbe la home,
    // che e' gia' la schermata corrente: l'utente sembrerebbe non tornare mai.
    setState(() => _lastRoute = section.route);
    context.push(section.route);
  }

  /// Traduce l'indice della barra in indice di sezione.
  ///
  /// La barra ha [_mobileSectionCount] sezioni piu' il profilo: per le prime
  /// l'indice coincide, per l'ultima voce il bersaglio e' la sezione profilo,
  /// che e' l'ultima di [_sections].
  int _indexFor(int index, {required bool sidebar}) {
    if (sidebar || index < _mobileSectionCount) return index;
    return _sections.length - 1;
  }

  /// Indice di sezione -> indice valido per la barra del telefono.
  ///
  /// Le prime [_mobileSectionCount] sezioni coincidono con le voci della barra,
  /// il profilo e' l'ultima voce. Duelli e Tornei non hanno voce: si lascia
  /// evidenziata l'ultima che c'era, che e' l'unica cosa che la `NavigationBar`
  /// accetta senza andare in assert.
  int _mobileIndexFor(int sectionIndex) {
    if (sectionIndex < _mobileSectionCount) return sectionIndex;
    if (sectionIndex == _sections.length - 1) return _mobileSectionCount;
    return _lastMobileIndex;
  }

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.fromContext(context);
    final selected = _indexOfRoute(_sections, _lastRoute);
    final body = _Body(email: ref.watch(authStatusProvider).user?.email);

    if (size.usesSidebar) {
      return Scaffold(
        body: Row(
          children: [
            _Sidebar(
              sections: _sections,
              selected: selected,
              onSelect: (i) => _select(i, sidebar: true),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }

    final mobileIndex = _mobileIndexFor(selected);
    // Cache, non stato: non provoca ricostruzione e serve solo al fallback
    // quando la sezione aperta non ha voce nella barra.
    _lastMobileIndex = mobileIndex;

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: mobileIndex,
        onDestinationSelected: (i) => _select(i, sidebar: false),
        destinations: [
          // La quinta sezione non c'e' nella barra, quindi il profilo viene
          // aggiunto a mano: altrimenti la barra mostrerebbe quattro voci e
          // il proflio sparirebbe dal telefono, che e' dove serve di piu'.
          for (final s in _sections.take(_mobileSectionCount))
            NavigationDestination(icon: Icon(s.icon), label: s.label),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: 'Profilo',
          ),
        ],
      ),
    );
  }
}

class _NavSection {
  const _NavSection(this.label, this.icon, this.selectedIcon, this.route);

  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Rotta della sezione.
  ///
  /// Non puo' mancare: le sezioni senza schermata non hanno una voce nella
  /// barra, altrimenti l'utente toccherebbe una destinazione inesistente.
  final String route;
}

/// Indice della sezione con questa rotta, -1 se non c'e'.
///
/// La barra e la sidebar partono da [_lastRoute] invece che dall'indice: se no'
/// riaprendo l'app sulla stessa sezione la barra mostrerebbe "Gruppi" come
/// attiva mentre l'utente e' su "Duelli".
int _indexOfRoute(List<_NavSection> sections, String? route) {
  if (route == null) return 0;
  final index = sections.indexWhere((s) => s.route == route);
  return index < 0 ? 0 : index;
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.sections,
    required this.selected,
    required this.onSelect,
  });

  final List<_NavSection> sections;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return NavigationRail(
      selectedIndex: selected,
      labelType: NavigationRailLabelType.all,
      onDestinationSelected: onSelect,
      leading: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'AnimeRank',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      destinations: [
        for (final s in sections)
          NavigationRailDestination(
            icon: Icon(s.icon),
            selectedIcon: Icon(s.selectedIcon),
            label: Text(s.label),
          ),
      ],
    );
  }
}

/// Contenuto centrale.
///
/// Non e' piu' una pagina di benvenuto che elenca le sezioni: e' la home con i
/// caroselli. Le sezioni per gruppo restano raggiungibili dalla barra e dalla
/// sidebar, quindi elencarle di nuovo qui era solo un doppione.
///
/// La riga di benvenuto pero' resta, perche' serve a un caso preciso: un
/// account nuovo non ha gruppi, quindi tutte le sezioni rimanderebbero al
/// selettore vuoto. Una riga che dice cosa fare vale piu' di una griglia di
/// locandine che non spiega ancora niente.
class _Body extends ConsumerWidget {
  const _Body({this.email});

  final String? email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `orElse: () => true` e' deliberato: mentre l'elenco gruppi non e'
    // ancora arrivato si mostra la home. Il dubbio ("avrà un gruppo?") non
    // merita di costringere l'utente ad aspettare, e se la lista arriva vuota
    // la schermata di benvenuto corregge la rotta.
    final hasGroups = ref.watch(groupsListProvider).maybeWhen(
          data: (list) => list.isNotEmpty,
          loading: () => false,
          orElse: () => false,
        );

    if (hasGroups) return const HomeScreen();

    return const _FirstRunWelcome();
  }
}

/// Riga informativa: icona e testo su uno sfondo appena piu' chiaro.
///
/// Solo per spiegazioni, non per azioni: un'azione dentro questa riga sembrerebbe
/// parte del testo e l'utente non la cliccherebbe.
class _HintCard extends StatelessWidget {
  const _HintCard({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Schermata del primo avvio.
///
/// Non e' un errore ne' uno stato vuoto: e' l'invito a creare il primo gruppo,
/// con il link alla ricerca anime perche' anche senza gruppo si puo' gia' cercare
/// un titolo da votare poi.
class _FirstRunWelcome extends StatelessWidget {
  const _FirstRunWelcome();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Accesso effettuato', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('Benvenuto', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(
              "Voti, watchlist, Elo e tornei sono calcolati dentro un gruppo. "
              "Creane uno e invita chi ti pare: le classifiche sono per gruppo, "
              "non globali.",
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => context.push(AppRoutes.createGroup),
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('Crea un gruppo'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => context.push(AppRoutes.joinGroup),
              icon: const Icon(Icons.login),
              label: const Text('Unisciti con un codice'),
            ),
            const SizedBox(height: 24),
            const _HintCard(
              icon: Icons.search,
              text: 'Nel frattempo puoi cercare anime: quello che trovi viene '
                  'salvato in catalogo e resta disponibile anche offline.',
            ),
          ],
        ),
      ),
    );
  }
}
