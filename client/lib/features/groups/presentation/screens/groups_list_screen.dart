import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../domain/group.dart';
import '../groups_controller.dart';

/// Elenco dei gruppi dell'utente.
///
/// Su telefono e' una lista a schede; da [LayoutSize.expanded] in su le schede
/// passano a griglia con piu' colonne, perche' a quella larghezza una sola
/// colonna lascerebbe il piu' dello schermo vuoto.
class GroupsListScreen extends ConsumerWidget {
  const GroupsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('I miei gruppi'),
        actions: [
          IconButton(
            onPressed: () => _refresh(context, ref),
            icon: const Icon(Icons.refresh),
            tooltip: 'Ricarica',
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'join',
            onPressed: () => context.push('/groups/join'),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Entra'),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            heroTag: 'create',
            onPressed: () => context.push('/groups/create'),
            icon: const Icon(Icons.add),
            label: const Text('Nuovo'),
          ),
        ],
      ),
      body: groups.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          message: '$error',
          onRetry: () => ref.read(groupsListProvider.notifier).refresh(),
        ),
        data: (list) {
          if (list.isEmpty) return const _EmptyState();
          return RefreshIndicator(
            onRefresh: () => ref.read(groupsListProvider.notifier).refresh(),
            child: Breakpoints.gridColumns(MediaQuery.sizeOf(context).width, min: 1, max: 3) > 1
                ? _Grid(groups: list)
                : _List(groups: list),
          );
        },
      ),
    );
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(groupsListProvider.notifier).refresh();
    messenger.showSnackBar(const SnackBar(content: Text('Elenco aggiornato.')));
  }
}

class _List extends StatelessWidget {
  const _List({required this.groups});

  final List<AnimeGroup> groups;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      // Padding in fondo perche' i pulsanti galleggianti coprirebbero l'ultima
      // scheda: senza, l'ultimo gruppo resta coperto e non si puo' aprire.
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: groups.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) => GroupCard(group: groups[i]),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.groups});

  final List<AnimeGroup> groups;

  @override
  Widget build(BuildContext context) {
    final columns = Breakpoints.gridColumns(MediaQuery.sizeOf(context).width, min: 1, max: 3);

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        // Altezza fissata per aspecto: se si lascia mainAxisExtent a zero
        // Gridextensione calcola l'altezza dal contenuto e le schede con
        // descrizioni di lunghezza diversa risultano di altezze diverse.
        mainAxisExtent: 168,
      ),
      itemCount: groups.length,
      itemBuilder: (context, i) => GroupCard(group: groups[i]),
    );
  }
}

/// Scheda di un gruppo.
class GroupCard extends StatelessWidget {
  const GroupCard({required this.group, super.key});

  final AnimeGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      // Material con ink: senza, il tocco non lascia nessun segno e la
      // scheda sembra non cliccabile.
      child: InkWell(
        onTap: () => context.push('/groups/${group.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(group: group),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      group.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    _RoleBadge(role: group.myRole),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fascia con l'iniziale del gruppo.
///
/// Immagine reale solo se c'e': il campo `image_url` e opzionale e la maggior
/// parte dei gruppi non ne ha uno, quindi l'iniziale e' il caso normale e non
/// un ripiego raro da nascondere.
class _Header extends StatelessWidget {
  const _Header({required this.group});

  final AnimeGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = group.imageUrl;

    return SizedBox(
      height: 64,
      width: double.infinity,
      child: url == null || url.isEmpty
          ? ColoredBox(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Center(
                child: Text(
                  group.name.trim().isEmpty ? '?' : group.name.trim()[0].toUpperCase(),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : Image.network(
              url,
              fit: BoxFit.cover,
              // Senza gestione dell'errore un URL rotto mostrerebbe il
              // riquadro grigio di Image.network senza dire nulla.
              errorBuilder: (context, error, stack) => ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Center(
                  child: Text(
                    group.name.trim()[0].toUpperCase(),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});

  final GroupRole role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (role) {
      GroupRole.owner => theme.colorScheme.primary,
      GroupRole.admin => theme.colorScheme.tertiary,
      GroupRole.member => theme.colorScheme.outline,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        role.label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// Nessun gruppo: il caso normale di un account nuovo.
///
/// Dice cosa fare e offre l'azione subito, invece di una pagina vuota che
/// costringe a cercare il pulsante da soli.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.groups_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text('Non fai parte di nessun gruppo',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Crea il tuo primo gruppo per iniziare a votare gli anime, '
                'oppure entra in uno con il codice invito.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton(
                    onPressed: () => context.push('/groups/create'),
                    child: const Text('Crea un gruppo'),
                  ),
                  OutlinedButton(
                    onPressed: () => context.push('/groups/join'),
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

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AuthErrorBanner.error(message),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onRetry,
                child: const Text('Riprova'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}