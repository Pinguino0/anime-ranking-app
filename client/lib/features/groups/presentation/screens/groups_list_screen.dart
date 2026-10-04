import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/content_row.dart';
import '../../../../core/ui/status_pill.dart';
import '../../../../core/ui/transitions.dart';
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
          const SizedBox(width: ArSpace.sm),
          FloatingActionButton.extended(
            heroTag: 'create',
            onPressed: () => context.push('/groups/create'),
            icon: const Icon(Icons.add),
            label: const Text('Nuovo'),
          ),
        ],
      ),
      body: groups.when(
        loading: () => const _ListSkeleton(),
        error: (error, _) => ErrorState(
          message: '$error',
          onRetry: () => ref.read(groupsListProvider.notifier).refresh(),
        ),
        data: (list) {
          if (list.isEmpty) {
            // Lo stato vuuto e' il caso normale di un account nuovo, non un
            // errore: dice cosa fare e mette l'azione subito, invece di una
            // pagina bianca che costringe a cercare il pulsante da soli.
            return EmptyState(
              icon: Icons.groups_outlined,
              title: 'Non fai parte di nessun gruppo',
              message:
                  'Crea il tuo primo gruppo per iniziare a votare gli anime, '
                  'oppure entra in uno con il codice invito.',
              action: Wrap(
                spacing: ArSpace.sm,
                runSpacing: ArSpace.sm,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () => context.push('/groups/create'),
                    icon: const Icon(Icons.add, size: 19),
                    label: const Text('Crea un gruppo'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => context.push('/groups/join'),
                    icon: const Icon(Icons.person_add_alt, size: 19),
                    label: const Text('Ho un codice invito'),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () => ref.read(groupsListProvider.notifier).refresh(),
            child: Breakpoints.gridColumns(
                  MediaQuery.sizeOf(context).width,
                  min: 1,
                  max: 3,
                ) >
                    1
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

/// Scheletro della lista.
///
/// Stessa forma della scheda reale: senza, all'arrivo dei dati le schede
/// sbatterebbero fuori dal vuoto e la pagina sembrerebbe montarsi sotto gli
/// occhi dell'utente.
class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: ArSpace.page(context).copyWith(
        top: ArSpace.md,
        bottom: ArSpace.xxl * 2,
      ),
      itemCount: 4,
      separatorBuilder: (_, _) => const SizedBox(height: ArSpace.sm),
      itemBuilder: (_, _) =>
          const SkeletonBox(height: GroupCard.extent, radius: ArRadii.card),
    );
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
      padding: ArSpace.page(context).copyWith(
        top: ArSpace.md,
        bottom: ArSpace.xxl * 2,
      ),
      itemCount: groups.length,
      separatorBuilder: (_, _) => const SizedBox(height: ArSpace.sm),
      itemBuilder: (context, i) => ArReveal(
        // Il ritardo cresce con la posizione e si ferma: oltre il limite le
        // schede in fondo arriverebbero cosi' tardi che l'utente le cercherebbe
        // gia' come se mancassero.
        delayMs: (i * 45).clamp(0, 300),
        child: GroupCard(group: groups[i]),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.groups});

  final List<AnimeGroup> groups;

  @override
  Widget build(BuildContext context) {
    final columns = Breakpoints.gridColumns(
      MediaQuery.sizeOf(context).width,
      min: 1,
      max: 3,
    );

    return GridView.builder(
      padding: ArSpace.page(context).copyWith(
        top: ArSpace.md,
        bottom: ArSpace.xxl * 2,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: ArSpace.sm,
        crossAxisSpacing: ArSpace.sm,
        // Altezza fissata per aspetto: se si lascia `mainAxisExtent` a zero la
        // griglia calcola l'altezza dal contenuto e le schede con descrizioni
        // di lunghezza diversa risultano di altezze diverse.
        mainAxisExtent: GroupCard.extent,
      ),
      itemCount: groups.length,
      itemBuilder: (context, i) => ArReveal(
        delayMs: (i * 45).clamp(0, 300),
        child: GroupCard(group: groups[i]),
      ),
    );
  }
}

/// Scheda di un gruppo.
///
/// Il corpo e' una colonna che occupa solo lo spazio del testo e il ruolo sta
/// in fondo: dentro una griglia ad altezza fissa un `Expanded` con uno `Spacer`
/// non ha niente su cui espandersi quando il testo e' corto, e finisce in
/// overflow quando e' lungo. Qui la colonna si chiude da sola e la griglia fa
/// il resto.
class GroupCard extends StatelessWidget {
  const GroupCard({required this.group, super.key});

  final AnimeGroup group;

  /// Altezza della fascia con l'immagine.
  static const double _headerHeight = 84;

  /// Altezza della parte di testo: padding (12+12) + titolo (~21) + stacco (4)
  /// + due righe di sottotitolo (~38) + stacco (8) + pastiglia (~22), con un
  /// margine perche' le altezze dei font variano di qualche pixel fra una
  /// piattaforma e l'altra.
  static const double _bodyHeight = 120;

  /// Altezza totale della scheda.
  ///
  /// Esposta perche' la griglia deve ripetere esattamente questa altezza: se le
  /// due copie divergessero, la griglia mostrerebbe schede tagliate o spazi
  /// vuoti. Il valore conta anche i pezzi elencati sopra, quindi allungare un
  /// titolo o aggiungere un metadata vuol dire correggere questo numero e non
  /// lasciare che sia il layout a decidere a runtime.
  static const double extent = _headerHeight + _bodyHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final card = Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(group: group),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ArSpace.md,
              ArSpace.sm,
              ArSpace.md,
              ArSpace.sm,
            ),
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
                const SizedBox(height: ArSpace.xxs),
                Text(
                  group.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: ArSpace.xs),
                GroupRoleBadge(role: group.myRole),
              ],
            ),
          ),
        ],
      ),
    );

    // Il tocco e' affidato ad `ArPressable` e non a un `InkWell`: quello
    // affossa la card, che su fondo scuro si legge come una vera pressione,
    // mentre lo spruzzo d'inchiostro sopra un'immagine arbitraria sparisce e
    // lascia solo un rettangolo colorato senza significato.
    return ArPressable(
      onTap: () => context.push('/groups/${group.id}'),
      child: card,
    );
  }
}

/// Fascia con l'iniziale del gruppo.
///
/// Immagine reale solo se c'e': il campo `image_url` e' opzionale e la maggior
/// parte dei gruppi non ne ha uno, quindi l'iniziale e' il caso normale e non
/// un ripiego raro da nascondere.
class _Header extends StatelessWidget {
  const _Header({required this.group});

  final AnimeGroup group;

  @override
  Widget build(BuildContext context) {
    final url = group.imageUrl;
    // Con un nome vuoto `group.name.trim()[0]` lancerebbe: l'iniziale si
    // calcola una volta sola e da li' in poi e' un dato.
    final name = group.name.trim();
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();

    return SizedBox(
      height: GroupCard._headerHeight,
      width: double.infinity,
      child: url == null || url.isEmpty
          ? _Fallback(initial: initial)
          : Image.network(
              url,
              fit: BoxFit.cover,
              // Senza gestione dell'errore un URL rotto mostrerebbe il
              // riquadro grigio di Image.network senza dire nulla.
              errorBuilder: (context, error, stack) =>
                  _Fallback(initial: initial),
            ),
    );
  }
}

/// Iniziale del gruppo sulla superficie del tema.
///
/// Il gradiente serve a non lasciare il riquadro piatto: la fascia e' la
/// parte piu' grande della scheda e un campo di colore unico sembrerebbe un
///'immagine non caricata.
class _Fallback extends StatelessWidget {
  const _Fallback({required this.initial});

  final String initial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
        const DecoratedBox(decoration: BoxDecoration(gradient: ArColors.subtle)),
        Center(
          child: Text(
            initial,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Pastiglia del ruolo.
///
/// Il disegno e' quello di [StatusPill]: e' la stessa idea di "etichetta di
/// stato" che si trova anche sui tornei e nella watchlist, e due
/// implementazioni della stessa pastiglia finiscono sempre per divergere di
/// qualche pixel.
///
/// Il colore del ruolo e' il tema e non una scelta qui: proprietario in viola,
/// admin in blu (l'altro accento, quindi la coppia del gradiente), membro in
/// grigio neutro perche' non deve sembrare una promozione.
class GroupRoleBadge extends StatelessWidget {
  const GroupRoleBadge({required this.role, super.key});

  final GroupRole role;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (role) {
      GroupRole.owner => scheme.primary,
      GroupRole.admin => scheme.tertiary,
      GroupRole.member => scheme.outline,
    };

    return StatusPill(label: role.label, color: color);
  }
}