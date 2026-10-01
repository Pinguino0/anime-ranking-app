import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../../ranking/presentation/screens/ranking_screen.dart';
import '../../domain/duels.dart';
import '../duels_controller.dart';

/// Duelli di un gruppo: la coppia da scegliere e la classifica Elo.
///
/// Due schede e non una pagina sola perche' sono due cose diverse: il duello e'
/// un'azione singola da fare e poi finisce, la classifica e' una lista da
/// consultare. Infilarle nello stesso scorrimento metterebbe la classifica
/// sotto la piega esattamente quando l'utente ha appena finito di votare.
class DuelsScreen extends ConsumerStatefulWidget {
  const DuelsScreen({required this.groupId, this.groupName, super.key});

  final String groupId;
  final String? groupName;

  @override
  ConsumerState<DuelsScreen> createState() => _DuelsScreenState();
}

class _DuelsScreenState extends ConsumerState<DuelsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groupId = widget.groupId;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.groupName == null ? 'Duelli' : 'Duelli · ${widget.groupName}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Ricarica',
            icon: const Icon(Icons.refresh),
            onPressed: () => _refresh(context, ref),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Sfida'),
            Tab(text: 'Elo'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _DuelTab(groupId: groupId),
          _EloTab(groupId: groupId),
        ],
      ),
    );
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final groupId = widget.groupId;

    ref.invalidate(duelPairProvider(groupId));
    ref.invalidate(duelStandingsProvider(groupId));

    // Entrambe le richieste, non solo quella visibile: invalidare la classifica
    // senza aspettarla lascerebbe i numeri vecchi quando l'utente apre la
    // seconda scheda, che e' parte della stessa pagina.
    await ref.read(duelPairProvider(groupId).future);
    await ref.read(duelStandingsProvider(groupId).future);
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('Duelli aggiornati.')));
  }
}

/// Tab del duello: due anime, un tocco.
///
/// Stateful perche' la scelta va tenuta qui: dopo aver votato la coppia resta
/// sullo schermo con il risultato, e quel risultato non torna dal backend
/// (`play` non restituisce nulla e non esiste una RPC "ultimo duello"), quindi
/// se vive in un provider o in un campo del padre verrebbe perso al primo
/// rebuild.
class _DuelTab extends ConsumerStatefulWidget {
  const _DuelTab({required this.groupId});

  final String groupId;

  @override
  ConsumerState<_DuelTab> createState() => _DuelTabState();
}

class _DuelTabState extends ConsumerState<_DuelTab> {
  DuelResult? _result;

  @override
  Widget build(BuildContext context) {
    final groupId = widget.groupId;
    final pair = ref.watch(duelPairProvider(groupId));
    final isSaving = ref.watch(duelActionProvider).isLoading;

    return pair.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _ErrorState(
        message: _message(error),
        onRetry: () => ref.read(duelPairProvider(groupId).notifier).next(),
      ),
      data: (data) {
        if (data == null || !data.isPlayable) {
          return const _EmptyState(
            icon: Icons.compare_arrows,
            message: 'Non ci sono anime da mettere in duello',
            hint: 'I duelli funzionano fra anime che il gruppo ha gia votato: '
                'vota almeno due anime nella classifica e torna qui.',
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Text('Scegli il preferito', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'La scelta spinge in su l anime scelto e in giu l altro. '
              'Poi ne arriva un altro.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            _DuelCard(
              pair: data,
              result: _result,
              isSaving: isSaving,
              onPick: (animeId) => _play(data, animeId),
            ),
            const SizedBox(height: 20),
            if (_result != null)
              FilledButton.tonalIcon(
                onPressed: isSaving ? null : _next,
                icon: const Icon(Icons.shuffle),
                label: const Text('Prossima coppia'),
              ),
          ],
        );
      },
    );
  }

  /// Registra la scelta e mostra il risultato solo se il backend l'ha accettata.
  Future<void> _play(DuelPair pair, String animeId) async {
    final messenger = ScaffoldMessenger.of(context);
    final groupId = widget.groupId;

    try {
      await ref.read(duelActionProvider.notifier).play(
            groupId: groupId,
            pair: pair,
            selectedAnimeId: animeId,
          );
      if (!mounted) return;
      setState(() => _result = DuelResult(animeId: animeId, title: pair.titleOf(animeId)));
    } on DuelsFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _next() async {
    final messenger = ScaffoldMessenger.of(context);

    // Il risultato viene azzerato solo dopo la nuova coppia: senza questo, il
    // banner mostrerebbe un anime che non e' piu' in gara mentre le due carte
    // ne mostrano gia' un'altra.
    try {
      final notifier = ref.read(duelPairProvider(widget.groupId).notifier);
      setState(() => _result = null);
      await notifier.next();
    } on DuelsFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// Le due carte del duello e il esito.
class _DuelCard extends StatelessWidget {
  const _DuelCard({
    required this.pair,
    required this.result,
    required this.isSaving,
    required this.onPick,
  });

  final DuelPair pair;
  final DuelResult? result;
  final bool isSaving;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = Breakpoints.fromContext(context);
    final locked = isSaving || result != null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isSaving) const LinearProgressIndicator(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _DuelOption(
                    title: pair.titleA,
                    imageUrl: pair.imageA,
                    isWinner: result?.animeId == pair.animeAId,
                    isLoser: result != null && result!.animeId != pair.animeAId,
                    enabled: !locked,
                    coverSize: size.isCompact ? 140 : 200,
                    onTap: () => onPick(pair.animeAId),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _DuelOption(
                    title: pair.titleB,
                    imageUrl: pair.imageB,
                    isWinner: result?.animeId == pair.animeBId,
                    isLoser: result != null && result!.animeId != pair.animeBId,
                    enabled: !locked,
                    coverSize: size.isCompact ? 140 : 200,
                    onTap: () => onPick(pair.animeBId),
                  ),
                ),
              ],
            ),
            if (result != null) ...[
              const SizedBox(height: 16),
              Text(
                'Hai scelto ${result!.title}',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
              ),
              const SizedBox(height: 4),
              Text(
                _eloHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Testo sul risultato.
  ///
  /// Non mostra la variazione esatta di punti: per ottenerla servirebbe un
  /// ritorno del backend, e dichiarare qui "+32" o "-32" sarebbe inventare un
  /// numero che potrebbe non essere quello giusto (l'Elo si muove di meno
  /// quando i due contendenti hanno punteggi vicini).
  static const _eloHint = 'Elo aggiornato in tabella.';
}

/// Una delle due carte in gara.
class _DuelOption extends StatelessWidget {
  const _DuelOption({
    required this.title,
    required this.imageUrl,
    required this.isWinner,
    required this.isLoser,
    required this.enabled,
    required this.coverSize,
    required this.onTap,
  });

  final String title;
  final String? imageUrl;
  final bool isWinner;
  final bool isLoser;
  final bool enabled;
  final double coverSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = isWinner
        ? theme.colorScheme.primary
        : isLoser
            ? theme.colorScheme.outlineVariant
            : theme.colorScheme.outlineVariant;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Opacity(
        // La carta non scelta resta visibile ma spenta: toglierla del tutto
        // cambierebbe larghezze e altezza durante la scelta, e la coppia
        // sembrerebbe cambiare sotto il dito dell'utente.
        opacity: enabled ? 1 : 0.55,
        child: Column(
          children: [
            Center(
              // Dimensioni fisse e non `AspectRatio`: quest'ultimo occupa
              // tutta la larghezza della colonna e su schermi larghi farebbe
              // una copertina alta 800px, con il duello sotto la piega e niente
              // da leggere li' sotto.
              child: SizedBox(
                width: coverSize,
                height: coverSize * 3 / 2,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: borderColor,
                      width: isWinner ? 3 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: (imageUrl == null || imageUrl!.isEmpty)
                      ? _CoverFallback(title: title)
                      : Image.network(
                          imageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _CoverFallback(title: title),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 3,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Text(
          title.trim().isEmpty ? '?' : title.trim()[0].toUpperCase(),
          style: theme.textTheme.headlineSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Tab della classifica Elo.
///
/// `duel_elo` restituisce al massimo 100 righe gia' ordinate: la posizione e'
/// quindi l'indice ricevuto, e la tabella non ripiega nulla su se stessa.
class _EloTab extends ConsumerWidget {
  const _EloTab({required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final standings = ref.watch(duelStandingsProvider(groupId));
    final isExpanded = Breakpoints.fromContext(context).isExpanded;

    return standings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _ErrorState(
        message: _message(error),
        onRetry: () => ref.read(duelStandingsProvider(groupId).notifier).refresh(),
      ),
      data: (rows) {
        if (rows.isEmpty) {
          return const _EmptyState(
            icon: Icons.emoji_events_outlined,
            message: 'Classifica Elo vuota',
            hint: 'Gli anime entrano in classifica quando i membri del gruppo '
                'li mettono in duello.',
          );
        }

        return isExpanded
            ? _EloTable(rows: rows)
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: rows.length,
                itemBuilder: (context, i) => _EloTile(row: rows[i]),
              );
      },
    );
  }
}

class _EloTable extends StatelessWidget {
  const _EloTable({required this.rows});

  final List<DuelStanding> rows;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          // Contenitore largo con tabella: su schermi enormi la tabella si
          // allargerebbe fino a far schizzare via i titoli, e su schermi
          // stretti finirebbe con colonne schiacciate.
          constraints: const BoxConstraints(maxWidth: 900),
          child: DataTable(
            columnSpacing: 28,
            columns: const [
              DataColumn(label: Text('#')),
              DataColumn(label: Text('Anime')),
              DataColumn(label: Text('Elo'), numeric: true),
              DataColumn(label: Text('Duelli'), numeric: true),
            ],
            rows: [
              for (final row in rows)
                DataRow(
                  cells: [
                    DataCell(Text('${row.position}')),
                    DataCell(
                      Row(
                        children: [
                          AnimeThumb(url: row.imageUrl, title: row.title, size: 32),
                          const SizedBox(width: 10),
                          Expanded(child: Text(row.title, overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    ),
                    DataCell(Text('${row.elo}')),
                    DataCell(Text('${row.duelCount}')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EloTile extends StatelessWidget {
  const _EloTile({required this.row});

  final DuelStanding row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delta = row.eloDelta;

    return ListTile(
      leading: SizedBox(width: 28, child: Text('${row.position}', style: theme.textTheme.titleSmall)),
      title: Row(
        children: [
          AnimeThumb(url: row.imageUrl, title: row.title, size: 32),
          const SizedBox(width: 10),
          Expanded(child: Text(row.title, maxLines: 2, overflow: TextOverflow.ellipsis)),
        ],
      ),
      subtitle: Text(_duelCountLabel(row.duelCount)),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('${row.elo}', style: theme.textTheme.titleMedium),
          if (delta != 0)
            Text(
              delta > 0 ? '+$delta' : '$delta',
              style: theme.textTheme.bodySmall?.copyWith(
                color: delta > 0 ? Colors.green : theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// Testo d'errore, con il fallback sui messaggi tecnici.
///
/// Gli errori che passano dal backend hanno gia' un messaggio in italiano; per
/// quelli non previsti (rete, JSON) non si mostra il dettaglio grezzo.
String _message(Object error) => switch (error) {
      final DuelsFailure e => e.message,
      _ => 'Duelli non disponibili. Riprova.',
    };

/// "1 duello", "7 duelli".
///
/// `duel_count` e' un intero che l'utente legge per capire quanto e' stato
/// usato un anime: scrivere sempre "duelli" anche per uno solo suona come un
/// errore di conteggio.
String _duelCountLabel(int count) => count == 1 ? '1 duello' : '$count duelli';

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message, required this.hint});

  final IconData icon;
  final String message;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(message, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
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
              FilledButton.tonal(onPressed: onRetry, child: const Text('Riprova')),
            ],
          ),
        ),
      ),
    );
  }
}
