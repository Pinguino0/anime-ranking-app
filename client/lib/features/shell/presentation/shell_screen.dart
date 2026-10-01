import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/breakpoints.dart';
import '../../../core/router/app_router.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../groups/presentation/screens/group_picker_screen.dart';

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
    _NavSection('Gruppi', Icons.groups_outlined, Icons.groups, AppRoutes.groups),
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
    _NavSection('Watchlist', Icons.bookmark_border, Icons.bookmark, AppRoutes.watchlistPicker),
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
    _NavSection('Profilo', Icons.person_outline, Icons.person, AppRoutes.profile),
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

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _indexFor(selected, sidebar: false),
        onDestinationSelected: (i) => _select(i, sidebar: false),
        destinations: [
          // La quinta sezione non c'e' nella barra, quindi il profilo viene
          // aggiunto a mano: altrimenti la barra mostrerebbe quattro voci e
          // il proflio sparirebbe dal telefono, che e' dove serve di piu'.
          for (final s in _sections.take(_mobileSectionCount))
            NavigationDestination(icon: Icon(s.icon), label: s.label),
          const NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profilo'),
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
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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
/// Elenca le sezioni con il gruppo su cui agiscono, invece di restare una pagina
/// che conferma solo il login: e' il punto in cui si sceglie da dove partire.
class _Body extends StatelessWidget {
  const _Body({this.email});

  final String? email;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Accesso effettuato',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text(
              email ?? 'sessione attiva',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Text('Scegli da dove partire', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            // Le sezioni per gruppo portano al selettore: da qui non si sa
            // quale gruppo sia, quindi la scelta va fatta qui ogni volta.
            for (final section in GroupSection.values) ...[
              _SectionCard(section: section),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 12),
            _HintCard(
              icon: Icons.groups_outlined,
              text: 'Ogni sezione appartiene a un gruppo: voti, watchlist, Elo e '
                  'tornei sono calcolati dentro un solo gruppo.',
            ),
          ],
        ),
      ),
    );
  }
}

/// Riga che apre una sezione dalla schermata iniziale.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section});

  final GroupSection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(section.pickerRoute),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(section.icon, color: theme.colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(section.label, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      section.hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

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
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
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