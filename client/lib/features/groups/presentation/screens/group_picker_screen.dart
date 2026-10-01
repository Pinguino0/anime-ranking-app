import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../domain/group.dart';
import '../groups_controller.dart';

/// Sezione dell'app che appartiene a un gruppo.
///
/// Classifica, watchlist, duelli e tornei hanno tutti `group_id` nelle tabelle:
/// due gruppi hanno quindi voti, watchlist, Elo e tabelloni diversi. Le voci
/// globali della shell non possono sapere quale gruppo sia, quindi passano da
/// [GroupPickerScreen] che fa scegliere e poi apre la sezione scelta.
enum GroupSection {
  ranking(
    label: 'Classifica',
    icon: Icons.leaderboard_outlined,
    hint: 'Scegli il gruppo di cui vedere la classifica.',
    route: _rankingRoute,
  ),
  watchlist(
    label: 'Watchlist',
    icon: Icons.bookmark_border,
    hint: 'Scegli il gruppo in cui gestire la watchlist.',
    route: _watchlistRoute,
  ),
  duels(
    label: 'Duelli',
    icon: Icons.sports_martial_arts_outlined,
    hint: 'Scegli il gruppo in cui fare i duelli.',
    route: _duelsRoute,
  ),
  tournaments(
    label: 'Tornei',
    icon: Icons.emoji_events_outlined,
    hint: 'Scegli il gruppo in cui lanciare un torneo.',
    route: _tournamentsRoute,
  );

  const GroupSection({
    required this.label,
    required this.icon,
    required this.hint,
    required this.route,
  });

  final String label;
  final IconData icon;
  final String hint;

  /// Costruisce il percorso della sezione dentro un gruppo.
  final String Function(String groupId) route;

  /// Percorso della sezione senza gruppo: quello che apre il selettore.
  String get pickerRoute => switch (this) {
        GroupSection.ranking => AppRoutes.rankingPicker,
        GroupSection.watchlist => AppRoutes.watchlistPicker,
        GroupSection.duels => AppRoutes.duelsPicker,
        GroupSection.tournaments => AppRoutes.tournamentsPicker,
      };

  static String _rankingRoute(String groupId) => AppRoutes.ranking(groupId);
  static String _watchlistRoute(String groupId) => AppRoutes.watchlist(groupId);
  static String _duelsRoute(String groupId) => AppRoutes.duels(groupId);
  static String _tournamentsRoute(String groupId) => AppRoutes.tournaments(groupId);
}

/// Scelta del gruppo per una sezione che gli appartiene.
///
/// Compare quando si entra dalla shell, dove il gruppo non e' noto. Con un solo
/// gruppo la schermata non viene mostrata: si va diretti alla sezione, che
/// sarebbe altrimenti un tocco inutile da ripetere a ogni visita.
class GroupPickerScreen extends ConsumerWidget {
  const GroupPickerScreen({required this.section, super.key});

  final GroupSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsListProvider);

    return Scaffold(
      appBar: AppBar(title: Text(section.label)),
      body: groups.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AuthErrorBanner.error('$error'),
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: () => ref.read(groupsListProvider.notifier).refresh(),
                    child: const Text('Riprova'),
                  ),
                ],
              ),
            ),
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return _NoGroups(section: section);
          }

          // Con un solo gruppo il selettore non aggiunge informazione: il nome
          // e' gia' nell'app bar della sezione che si sta per aprire.
          if (list.length == 1) {
            return _Opening(section: section, group: list.first);
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _GroupTile(
              group: list[i],
              section: section,
            ),
          );
        },
      ),
    );
  }
}

/// Scheda di un gruppo, con l'icona della sezione per non far leggere due volte
/// la stessa lista in schermate diverse.
class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.group, required this.section});

  final AnimeGroup group;
  final GroupSection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // `pushReplacement`: la scelta del gruppo sostituisce il selettore,
        // altrimenti "indietro" tornerebbe qui e l'utente dovrebbe premere
        // indietro un secondo giro per uscire dalla sezione.
        onTap: () => context.pushReplacement(
          section.route(group.id),
          extra: group.name,
        ),
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
                    Text(
                      group.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      group.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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

/// Passaggio automatico all'unico gruppo.
///
/// Senza uno spinner si vedrebbe un vuoto per una frazione di secondo e poi la
/// sezione: meglio un indicatore esplicito.
class _Opening extends StatelessWidget {
  const _Opening({required this.section, required this.group});

  final GroupSection section;
  final AnimeGroup group;

  @override
  Widget build(BuildContext context) {
    return _Redirect(
      route: section.route(group.id),
      name: group.name,
      label: 'Apro ${section.label.toLowerCase()} di ${group.name}...',
    );
  }
}

/// Nessun gruppo: la sezione non ha nulla su cui lavorare.
///
/// Non basta "non hai gruppi": senza dire come crearne uno l'utente resta
/// fermo su una pagina che non spiega nulla.
class _NoGroups extends StatelessWidget {
  const _NoGroups({required this.section});

  final GroupSection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(section.icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                '${section.label} per gruppo',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Non fai parte di nessun gruppo, quindi non c\'e niente da '
                'mostrare. Crea un gruppo o entra con un codice invito.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton(
                    onPressed: () => context.pushReplacement(AppRoutes.createGroup),
                    child: const Text('Crea un gruppo'),
                  ),
                  OutlinedButton(
                    onPressed: () => context.pushReplacement(AppRoutes.joinGroup),
                    child: const Text('Ho un codice invito'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reindirizza una volta sola, dopo il primo frame.
///
/// Il `postFrameCallback` serve perche' `pushReplacement` chiamato durante il
/// build modifica lo stato del router mentre l'albero si sta costruendo.
class _Redirect extends StatefulWidget {
  const _Redirect({required this.route, required this.name, required this.label});

  final String route;
  final String name;
  final String label;

  @override
  State<_Redirect> createState() => _RedirectState();
}

class _RedirectState extends State<_Redirect> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.pushReplacement(widget.route, extra: widget.name);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(widget.label, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}