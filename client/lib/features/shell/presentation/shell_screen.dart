import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/breakpoints.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/section_accent.dart';
import '../../../core/ui/ar_badge.dart';
import '../../../core/ui/transitions.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../groups/presentation/groups_controller.dart';
import '../../home/screens/home_screen.dart';
import 'widgets/shell_chrome.dart';

/// Scheletro dell'app per l'utente collegato.
///
/// E' la pagina da cui si parte: offre la sidebar da desktop e la barra in
/// basso da telefono. Le sezioni non ancora scritte restano visibili ma
/// dichiarano di non essere disponibili, cosi' l'utente capisce che mancano e
/// non crede che l'app sia rotta.
class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({this.child, this.location, super.key});

  /// La schermata corrente, quando la shell fa da cornice alle rotte
  /// dell'app (vedi la `ShellRoute` nel router). Se manca, la shell mostra la
  /// home: e' il caso dei test che la montano da sola.
  final Widget? child;

  /// Percorso attivo, passato dalla `ShellRoute`.
  ///
  /// Serve a sapere quale voce evidenziare mentre si apre un gruppo o una sua
  /// sezione: senza, la barra resterebbe ferma sull'ultima voce toccata e
  /// sembrerebbe che la navigazione non sia avvenuta.
  final String? location;

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
      accent: ArAccent.anime,
    ),
    _NavSection(
      'Gruppi',
      Icons.groups_outlined,
      Icons.groups,
      AppRoutes.groups,
      accent: ArAccent.groups,
    ),
    // Le quattro sezioni restano per gruppo, quindi la voce globale porta al
    // selettore e non alla sezione: `/ranking` da sola non saprebbe quale
    // gruppo mostrare. Il nome del gruppo viaggia in `extra` una volta scelto.
    _NavSection(
      'Classifica',
      Icons.leaderboard_outlined,
      Icons.leaderboard,
      AppRoutes.rankingPicker,
      accent: ArAccent.ranking,
    ),
    // La lista personale e' una sola anche se la watchlist e' per gruppo:
    // "La mia lista" unisce le voci di tutti i gruppi in un unico posto, quindi
    // non passa dal selettore. La watchlist di un gruppo resta nel dettaglio
    // del gruppo.
    _NavSection(
      'La mia lista',
      Icons.bookmark_outline,
      Icons.bookmark,
      AppRoutes.myList,
      accent: ArAccent.watchlist,
    ),
    // Come le due precedenti, anche i duelli sono per gruppo: la tabella `duels`
    // ha `group_id` e gli Elo sono calcolati dentro un solo gruppo.
    _NavSection(
      'Duelli',
      Icons.sports_martial_arts_outlined,
      Icons.sports_martial_arts,
      AppRoutes.duelsPicker,
      accent: ArAccent.duels,
      description: 'Un confronto testa a testa: scegli il titolo che preferisci.',
    ),
    // Come le precedenti, i tornei sono per gruppo: `tournaments` ha `group_id`
    // e il bracket si genera dentro un solo gruppo.
    _NavSection(
      'Tornei',
      Icons.emoji_events_outlined,
      Icons.emoji_events,
      AppRoutes.tournamentsPicker,
      accent: ArAccent.tournaments,
      description: 'Un tabellone a eliminazione dentro il gruppo.',
    ),
    // Il profilo sta fra le sezioni anche se non e' un gruppo: sulla barra da
    // telefono e' l'ultima voce raggiungibile senza aprire un menu, e sulla
    // sidebar evita che resti incastonato in fondo alla lista.
    _NavSection(
      'Profilo',
      Icons.person_outline,
      Icons.person,
      AppRoutes.profile,
      accent: ArAccent.profile,
      description: 'Il tuo account, le notifiche e le impostazioni.',
    ),
  ];

  /// Quante sezioni stanno nella barra in basso, prima della voce "Altro".
  ///
  /// Su uno schermo stretto sette voci diventano etichette illeggibili e
  /// bersagli minuscoli: la barra tiene le quattro sezioni piu' usate e
  /// raccoglie le altre in un foglio "Altro". Meglio cosi' che comprimere tutto
  /// o togliere delle sezioni dal telefono, dove il profilo serve di piu'.
  static const int _barSectionCount = 4;

  /// Ultima voce toccata, cosi' la barra e la sidebar concordano.
  ///
  /// Serve solo alla modalita' senza shell (test): la' la pagina aperta copre
  /// la barra e la sezione non e' deducibile dalla location, che non cambia.
  String? _lastRoute;

  /// Apre una sezione.
  ///
  /// Dentro la shell la pagina non copre piu' la barra: si cambia sezione
  /// restando nella cornice, quindi `go` (sostituisce) e non `push`. Cosi' il
  /// tasto "indietro" del sistema non accumula una pila di schermate.
  void _openSection(_NavSection section) {
    if (widget.location != null) {
      context.go(section.route);
      return;
    }

    // Senza shell (test o fallback) la pagina aperta copre tutto: `push` e non
    // `go`, cosi' la si chiude con "indietro" tornando da dove si e' partiti.
    setState(() => _lastRoute = section.route);
    context.push(section.route);
  }

  /// Tocco su una voce della barra in basso.
  ///
  /// Le prime [_barSectionCount] voci aprono la sezione corrispondente; l'ultima
  /// apre il foglio "Altro" con le sezioni rimanenti.
  void _onBarSelect(int index) {
    if (index < _barSectionCount) {
      _openSection(_sections[index]);
      return;
    }
    _openMore();
  }

  /// Indice della barra per la sezione aperta.
  ///
  /// Le sezioni oltre [_barSectionCount] non hanno una voce propria: fanno capo
  /// ad "Altro", che e' quindi l'unica cosa da evidenziare dentro Duelli, Tornei
  /// o Profilo. Il risultato resta sempre dentro la lista della barra, quindi
  /// niente indici fuori range.
  int _barIndexFor(int sectionIndex) {
    return sectionIndex < _barSectionCount ? sectionIndex : _barSectionCount;
  }

  /// Apre il foglio "Altro" e naviga alla sezione scelta.
  Future<void> _openMore() async {
    final chosen = await showModalBottomSheet<_NavSection>(
      context: context,
      backgroundColor: ArColors.containerHigh,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(ArRadii.sheet),
        ),
      ),
      builder: (_) => _MoreSheet(
        sections: _sections.sublist(_barSectionCount),
        selectedRoute: _currentSectionRoute(),
      ),
    );

    if (chosen == null || !mounted) return;
    _openSection(chosen);
  }

  /// Rotta della sezione aperta, per evidenziarla nella barra e nel foglio.
  String? _currentSectionRoute() {
    if (widget.location != null) {
      return _sectionRouteFor(_sections, widget.location!);
    }
    return _lastRoute;
  }

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.fromContext(context);
    final route = _currentSectionRoute();
    final selected = _indexOfRoute(_sections, route);
    // L'accento della sezione scende da qui a tutto cio' che la pagina disegna:
    // intestazioni, pastiglie, decorazioni. Sta sulla shell e non sulle singole
    // schermate perche' la sezione aperta la conosce solo la shell, e perche'
    // cosi' una pagina profonda (la classifica di un gruppo) eredita la tinta
    // giusta senza doverla dichiarare. Fuori da una sezione — la home — resta
    // l'accento del marchio.
    final body = SectionAccentScope(
      accent: route == null ? ArAccent.home : _sections[selected].accent,
      child: widget.child ??
          ShellHomeBody(email: ref.watch(authStatusProvider).user?.email),
    );

    if (size.usesSidebar) {
      return Scaffold(
        body: Row(
          children: [
            ArNavRail(
              destinations: _destinationsOf(_sections),
              selectedIndex: selected,
              onSelect: (i) => _openSection(_sections[i]),
            ),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: ArBottomBar(
        selectedIndex: _barIndexFor(selected),
        onSelect: _onBarSelect,
        destinations: [
          // Le sezioni con voce propria, poi "Altro" per le rimanenti: la
          // barra ha cosi' sempre [_barSectionCount] + 1 voci, un numero che
          // sta anche sugli schermi stretti.
          ..._destinationsOf(_sections.take(_barSectionCount).toList()),
          const ArDestination(
            label: 'Altro',
            icon: Icons.more_horiz,
            selectedIcon: Icons.more_horiz,
          ),
        ],
      ),
    );
  }

  /// Le sezioni nella forma che la barra o la colonna laterale capiscono.
  ///
  /// La conversione sta qui e non nei due widget: se ognuno ricavasse le
  /// icone dai propri campi, la barra laterale e quella in basso potrebbero
  /// finire con icone diverse per la stessa sezione.
  static List<ArDestination> _destinationsOf(List<_NavSection> sections) {
    return [
      for (final s in sections)
        ArDestination(
          label: s.label,
          icon: s.icon,
          selectedIcon: s.selectedIcon,
          accent: s.accent,
        ),
    ];
  }
}

class _NavSection {
  const _NavSection(
    this.label,
    this.icon,
    this.selectedIcon,
    this.route, {
    this.description = '',
    this.accent = ArAccent.home,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Rotta della sezione.
  ///
  /// Non puo' mancare: le sezioni senza schermata non hanno una voce nella
  /// barra, altrimenti l'utente toccherebbe una destinazione inesistente.
  final String route;

  /// Una riga che spiega cosa si trova nella sezione.
  ///
  /// Serve nel foglio "Altro": le voci ammassate senza una spiegazione sono
  /// indistinguibili per chi non conosce gia' l'app, e il foglio e' il posto
  /// giusto per dire in una riga cosa fa ognuna.
  final String description;

  /// Accento della sezione, portato fino alla barra e alla colonna laterale.
  final ArAccent accent;
}

/// Foglio "Altro" della barra in basso.
///
/// Raccoglie le sezioni che non stanno nella barra (Duelli, Tornei, Profilo).
/// Ogni voce ha una riga di spiegazione: chi arriva qui di solito non conosce
/// gia' l'app, e un elenco di sole etichette non direbbe a cosa servono.
class _MoreSheet extends StatelessWidget {
  const _MoreSheet({required this.sections, required this.selectedRoute});

  final List<_NavSection> sections;
  final String? selectedRoute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ArSpace.lg,
          0,
          ArSpace.lg,
          ArSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Altre sezioni',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: ArSpace.xs),
            Text(
              'Duelli, tornei e profilo: quello che non sta nella barra in basso.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: ArColors.textMid,
              ),
            ),
            const SizedBox(height: ArSpace.md),
            for (final section in sections)
              Padding(
                padding: const EdgeInsets.only(bottom: ArSpace.xs),
                child: _MoreSheetItem(
                  section: section,
                  selected: section.route == selectedRoute,
                  onTap: () => Navigator.of(context).pop(section),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Voce del foglio "Altro": icona, titolo e una riga di spiegazione.
class _MoreSheetItem extends StatelessWidget {
  const _MoreSheetItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final _NavSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = section.accent;

    return Material(
      color: selected ? accent.soft : ArColors.container,
      borderRadius: BorderRadius.circular(ArRadii.control),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ArRadii.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ArSpace.sm,
            vertical: ArSpace.xs,
          ),
          child: Row(
            children: [
              // Il segno della sezione porta la sua tinta gia' qui: nel foglio
              // "Altro" le voci sono accostate e il colore e' l'unico modo di
              // distinguerle a colpo d'occhio prima di leggerle.
              ArBadge(icon: section.selectedIcon, color: accent.base, size: 38),
              const SizedBox(width: ArSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: selected ? accent.base : ArColors.textHigh,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (section.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        section.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: ArColors.textMid,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: selected ? accent.base : ArColors.textLow,
              ),
            ],
          ),
        ),
      ),
    );
  }
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

/// Sezione di appartenenza di una location, se c'e'.
///
/// Il confronto e' per prefisso perche' aprendo un gruppo o una sua sezione la
/// location diventa piu' profonda (`/ranking/<id>`) ma la voce evidenziata deve
/// restare quella della sezione. La watchlist di gruppo non ha una voce sua e
/// ricade su "La mia lista", l'unica sezione che parla di titoli salvati.
String? _sectionRouteFor(List<_NavSection> sections, String location) {
  if (location.startsWith(AppRoutes.watchlistPicker)) return AppRoutes.myList;

  for (final section in sections) {
    if (location == section.route || location.startsWith('${section.route}/')) {
      return section.route;
    }
  }
  return null;
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
class ShellHomeBody extends ConsumerWidget {
  const ShellHomeBody({this.email, super.key});

  final String? email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `orElse: () => true` e' deliberato: mentre l'elenco gruppi non e'
    // ancora arrivato si mostra la home. Il dubbio ("avrà un gruppo?") non
    // merita di costringere l'utente ad aspettare, e se la lista arriva vuota
    // la schermata di benvenuto corregge la rotta.
    final hasGroups = ref
        .watch(groupsListProvider)
        .maybeWhen(
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
      padding: const EdgeInsets.all(ArSpace.md),
      decoration: BoxDecoration(
        color: ArColors.containerLow,
        borderRadius: BorderRadius.circular(ArRadii.card),
        border: Border.all(color: ArColors.borderSoft),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: ArColors.primary),
          const SizedBox(width: ArSpace.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: ArColors.textMid,
                height: 1.45,
              ),
            ),
          ),
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
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          padding: const EdgeInsets.all(ArSpace.lg),
          children: [
            // Il segno al posto del titolo: dice il nome dell'app dove la si
            // cerca, e stavolta non e' una riga di testo che compete con
            // "Benvenuto" per la stessa importanza.
            const Align(
              alignment: Alignment.centerLeft,
              child: BrandMark(size: 26),
            ),
            const SizedBox(height: ArSpace.md),
            Text('Benvenuto', style: theme.textTheme.headlineMedium),
            const SizedBox(height: ArSpace.xs),
            ConstrainedBox(
              // La riga non oltrepassa una certa larghezza: a tutta pagina su un
              // monitor grande il testo arriva a 120 caratteri per riga e
              // l'occhio perde il punto di fine frasea.
              constraints: const BoxConstraints(maxWidth: 400),
              child: Text(
                'Voti, watchlist, Elo e tornei si calcolano dentro un gruppo. '
                'Creane uno e invita chi ti pare: le classifiche sono per '
                'gruppo, non globali.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: ArColors.textMid,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: ArSpace.xl),
            ArGradientButton(
              label: 'Crea un gruppo',
              icon: Icons.group_add_outlined,
              expand: true,
              onPressed: () => context.push(AppRoutes.createGroup),
            ),
            const SizedBox(height: ArSpace.sm),
            OutlinedButton.icon(
              onPressed: () => context.push(AppRoutes.joinGroup),
              icon: const Icon(Icons.login, size: 19),
              label: const Text('Unisciti con un codice'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
            ),
            const SizedBox(height: ArSpace.xl),
            const _HintCard(
              icon: Icons.search,
              text:
                  'Nel frattempo puoi cercare anime: quello che trovi viene '
                  'salvato in catalogo e resta disponibile anche offline.',
            ),
          ],
        ),
      ),
    );
  }
}
