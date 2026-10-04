import '../../../../core/ui/content_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/anime_thumb.dart';
import '../../../../core/ui/transitions.dart';
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
      loading: () => const _PairSkeleton(),
      error: (error, _) => ErrorState(
        message: _message(error),
        onRetry: () => ref.read(duelPairProvider(groupId).notifier).next(),
      ),
      data: (data) {
        if (data == null || !data.isPlayable) {
          return const EmptyState(
            icon: Icons.compare_arrows,
            title: 'Non ci sono anime da mettere in duello',
            message: 'I duelli funzionano fra anime che il gruppo ha gia '
                'votato: vota almeno due anime nella classifica e torna qui.',
          );
        }

        final page = ArSpace.page(context);

        // Il bottone sta in una barra fissa e non in coda alla lista: dentro
        // la `ListView` finiva sotto la piega su ogni schermo di altezza
        // normale, quindi l'utente che aveva appena scelto doveva scorrere per
        // trovare "prossima coppia" — il passo che chiude il duello. In fondo
        // resta sempre a portata di pollice, che su un telefono e' anche la
        // meta' comoda.
        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  page.left,
                  ArSpace.md,
                  page.right,
                  ArSpace.lg,
                ),
                children: [
                  Text(
                    'Scegli il preferito',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: ArSpace.xxs),
                  Text(
                    'La scelta spinge in su l anime scelto e in giu l altro. '
                    'Poi ne arriva un altro.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: ArSpace.lg),
                  _DuelCard(
                    pair: data,
                    result: _result,
                    isSaving: isSaving,
                    onPick: (animeId) => _play(data, animeId),
                  ),
                ],
              ),
            ),
            // Compare solo dopo una scelta: prima non c'e' niente da
            // rimescolare, e un bottone grigio sarebbe rumore.
            AnimatedSize(
              duration: ArMotion.base,
              curve: ArMotion.enter,
              alignment: Alignment.bottomCenter,
              child: _result == null
                  ? const SizedBox(width: double.infinity)
                  : DecoratedBox(
                      decoration: const BoxDecoration(
                        color: ArColors.bg,
                        border: Border(
                          top: BorderSide(color: ArColors.borderSoft),
                        ),
                      ),
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            page.left,
                            ArSpace.sm,
                            page.right,
                            ArSpace.sm,
                          ),
                          child: ArGradientButton(
                            label: 'Prossima coppia',
                            icon: Icons.shuffle,
                            expand: true,
                            onPressed: isSaving ? null : _next,
                          ),
                        ),
                      ),
                    ),
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

/// Scheletro della coppia in gara.
///
/// Due blocchi affiancati della stessa dimensione delle carte vere: se lo
/// scheletro mostrasse un rettangolo solo, al primo arrivo dei dati le due
/// copertine comparirebbero sotto gli occhi e la pagina sembrerebbe saltare.
class _PairSkeleton extends StatelessWidget {
  const _PairSkeleton();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final page = ArSpace.page(context);
    final available = width - page.left - page.right;
    final poster = available >= 520 ? 200.0 : 132.0;

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: page.left),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SkeletonBox(width: 180, height: 20),
            const SizedBox(height: ArSpace.lg),
            DecoratedBox(
              decoration: BoxDecoration(
                color: ArColors.containerLow,
                borderRadius: BorderRadius.circular(ArRadii.card),
                border: Border.all(color: ArColors.borderSoft),
              ),
              child: Padding(
                padding: const EdgeInsets.all(ArSpace.md),
                child: Column(
                  children: [
                    Row(
                      children: [
                        for (var i = 0; i < 2; i++) ...[
                          Expanded(
                            child: Column(
                              children: [
                                SkeletonBox(
                                  height: poster * 3 / 2,
                                  radius: ArRadii.poster,
                                ),
                                const SizedBox(height: ArSpace.xs),
                                const SkeletonBox(height: 14),
                              ],
                            ),
                          ),
                          if (i == 0) const SizedBox(width: ArSpace.sm),
                        ],
                      ],
                    ),
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

/// Le due carte del duello e l'esito.
///
/// Il formato cambia con la larghezza invece di cambiare solo la dimensione:
/// sotto i 700px le due copertine sono affiancate perche' uno schermo stretto
/// non regge due poster grandi uno sotto l'altro senza costringere a
/// scorrere, sopra i 700px diventano quadretti affiancati con la copertina a
/// sinistra e il titolo accanto, cosi' la scheda resta larga ma bassa.
///
/// La terza via — la stessa identica schermata piu' grande — e' esattamente
/// il "desktop rimpicciolito" che il progetto vieta: le due carte sembrerebbero
/// le stesse di sempre, solo un po' piu' larghe.
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

  /// Larghezza oltre la quale ogni contender ha la copertina a lato.
  static const double _sideLayout = 700;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final page = ArSpace.page(context);
    final side = width >= _sideLayout;
    // La larghezza che vede la scheda: `MediaQuery` da sola racconterebbe
    // "schermo largo" anche con la sidebar aperta, e le carte risulterebbero
    // piu' strette del previsto senza che nessuno capisca perche'.
    final available = width - page.left - page.right;
    final locked = isSaving || result != null;

    return Container(
      padding: EdgeInsets.all(side ? ArSpace.lg : ArSpace.md),
      decoration: BoxDecoration(
        color: ArColors.containerLow,
        borderRadius: BorderRadius.circular(ArRadii.card),
        border: Border.all(color: ArColors.borderSoft),
        boxShadow: ArShadows.card,
      ),
      child: Column(
        children: [
          if (isSaving) ...[
            const LinearProgressIndicator(minHeight: 3),
            const SizedBox(height: ArSpace.md),
          ],

          if (side)
            //_orizzontale_: contender a sinistra, "contro" al centro, contender
            // a destra. Il testo al centro non e' decorazione: e' il modo piu'
            // rapido di dire che i due titoli sono in competizione senza
            // dover aggiungere un'icona che ripeterebbe la metafora del pugno.
            Row(
              children: [
                Expanded(
                  child: _DuelOption(
                    title: pair.titleA,
                    imageUrl: pair.imageA,
                    isWinner: result?.animeId == pair.animeAId,
                    isLoser: result != null && result!.animeId != pair.animeAId,
                    enabled: !locked,
                    coverSize: 96,
                    layout: _DuelLayout.horizontal,
                    onTap: () => onPick(pair.animeAId),
                  ),
                ),
                const _Versus(),
                Expanded(
                  child: _DuelOption(
                    title: pair.titleB,
                    imageUrl: pair.imageB,
                    isWinner: result?.animeId == pair.animeBId,
                    isLoser: result != null && result!.animeId != pair.animeBId,
                    enabled: !locked,
                    coverSize: 96,
                    layout: _DuelLayout.horizontal,
                    onTap: () => onPick(pair.animeBId),
                  ),
                ),
              ],
            )
          else
            // Su schermo stretto il "contro" sta sopra: fra le carte non c'e'
            // spazio, e metterlo in mezzo le taglierebbe a meta'.
            Column(
              children: [
                const _Versus(),
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
                        // La copertina non occupa tutta la colonna: con
                        // `AspectRatio` prenderebbe tutta la larghezza e su un
                        // tablet farebbe una locandina alta 500px col duello
                        // interamente sotto la piega.
                        coverSize: available >= 520 ? 200 : 132,
                        layout: _DuelLayout.vertical,
                        onTap: () => onPick(pair.animeAId),
                      ),
                    ),
                    const SizedBox(width: ArSpace.sm),
                    Expanded(
                      child: _DuelOption(
                        title: pair.titleB,
                        imageUrl: pair.imageB,
                        isWinner: result?.animeId == pair.animeBId,
                        isLoser: result != null && result!.animeId != pair.animeBId,
                        enabled: !locked,
                        coverSize: available >= 520 ? 200 : 132,
                        layout: _DuelLayout.vertical,
                        onTap: () => onPick(pair.animeBId),
                      ),
                    ),
                  ],
                ),
              ],
            ),

          // L'esito entra con una comparsa breve invece di apparire di colpo:
          // il cambiamento di stato appena avvenuto e' l'informazione
          // principale dello schermo, e senza animazione sembrerebbe che il
          // testo fosse sempre li' e l'utente non lo collegherebbe alla scelta.
          AnimatedSize(
            duration: ArMotion.base,
            curve: ArMotion.enter,
            alignment: Alignment.topCenter,
            child: result == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: ArSpace.lg),
                    child: _Outcome(title: result!.title),
                  ),
          ),
        ],
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

/// Il "contro" fra i due contendenti.
class _Versus extends StatelessWidget {
  const _Versus();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ArSpace.sm),
      child: Text(
        'CONTRO',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: ArColors.textLow,
              // Spaziatura larga: e' un'etichetta decorativa, e le lettere
              // accostate sembrerebbero una parola da leggere.
              letterSpacing: 3,
            ),
      ),
    );
  }
}

/// L'esito del duello.
class _Outcome extends StatelessWidget {
  const _Outcome({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.trending_up_rounded, size: 18, color: ArColors.success),
            const SizedBox(width: ArSpace.xxs),
            Flexible(
              child: Text(
                // La frase intera e non il solo titolo: "Hai scelto" dice che
                // la scelta e' stata registrata, e senza l'utente potrebbe
                // leggere il titolo come il nome della prossima coppia.
                'Hai scelto $title',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(color: ArColors.success),
              ),
            ),
          ],
        ),
        const SizedBox(height: ArSpace.xxs),
        Text(
          _DuelCard._eloHint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Come il contender e' disposito dentro la scheda.
enum _DuelLayout { vertical, horizontal }

/// Una delle due carte in gara.
///
/// Stateful solo per l'hover: su desktop il contender si illumina al passaggio
/// del mouse, che e' l'unico segnale che dice "questa si puo' scegliere".
/// Senza, le due carte sarebbero immagini che l'utente deve provare a toccare.
class _DuelOption extends StatefulWidget {
  const _DuelOption({
    required this.title,
    required this.imageUrl,
    required this.isWinner,
    required this.isLoser,
    required this.enabled,
    required this.coverSize,
    required this.layout,
    required this.onTap,
  });

  final String title;
  final String? imageUrl;
  final bool isWinner;
  final bool isLoser;
  final bool enabled;
  final double coverSize;
  final _DuelLayout layout;
  final VoidCallback onTap;

  @override
  State<_DuelOption> createState() => _DuelOptionState();
}

class _DuelOptionState extends State<_DuelOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hovered = _hovered;
    final picked = widget.isWinner;
    // Il perdente si spegne, ma solo dopo che c'e' un risultato: durante la
    // scelta le due carte devono avere lo stesso peso, altrimenti l'utente
    // sceglierebbe sempre l'unica che non e' spenta.
    final dimmed = widget.isLoser;
    final enabled = widget.enabled;

    final cover = AnimatedContainer(
      duration: ArMotion.base,
      curve: ArMotion.enter,
      width: widget.coverSize,
      height: widget.coverSize * 3 / 2,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ArRadii.poster),
        border: Border.all(
          color: picked
              ? ArColors.success
              : enabled && hovered
                  ? ArColors.primary.withValues(alpha: 0.7)
                  : Colors.transparent,
          width: picked ? 2.5 : 1.5,
        ),
        boxShadow: picked
            ? ArShadows.glow(ArColors.success, strength: 0.28)
            : enabled && hovered
                ? ArShadows.glow(ArColors.primary, strength: 0.20)
                : null,
      ),
      // Il ritaglio e' su un widget separato dal bordo: metterli insieme
      // farebbe ritagliare anche il bordo del vincente, che sparirebbe dentro
      // l'angolo arrotondato proprio quando deve dire "ha vinto".
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ArRadii.poster - 2),
        child: ColorFiltered(
          // Lo spegnimento e' una desaturazione, non un'opacita': una
          // locandina mezza trasparente su fondo scuro diventa quasi nera e
          // sembrerebbe un'immagine non caricata.
          colorFilter: dimmed
              ? const ColorFilter.matrix(<double>[
                  0.4, 0.4, 0.2, 0, 0,
                  0.4, 0.4, 0.2, 0, 0,
                  0.4, 0.4, 0.2, 0, 0,
                  0, 0, 0, 1, 0,
                ])
              : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
          child: (widget.imageUrl == null || widget.imageUrl!.isEmpty)
              ? _CoverFallback(title: widget.title)
              : Image.network(
                  widget.imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _CoverFallback(title: widget.title),
                ),
        ),
      ),
    );

    final label = Text(
      widget.title,
      maxLines: widget.layout == _DuelLayout.vertical ? 2 : 1,
      textAlign: widget.layout == _DuelLayout.vertical
          ? TextAlign.center
          : TextAlign.start,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleSmall?.copyWith(
        color: picked
            ? ArColors.textHigh
            : dimmed
                ? ArColors.textLow
                : ArColors.textHigh,
        fontVariations: [
          FontVariation('wght', picked ? 700 : 500),
        ],
      ),
    );

    final badge = picked
        ? Container(
            margin: const EdgeInsets.only(top: ArSpace.xxs),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: ArColors.success.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(ArRadii.chip),
              border: Border.all(color: ArColors.success.withValues(alpha: 0.5)),
            ),
            child: Text(
              'Scelto',
              style: theme.textTheme.labelSmall?.copyWith(
                color: ArColors.success,
                letterSpacing: 0.6,
              ),
            ),
          )
        : null;

    final content = widget.layout == _DuelLayout.vertical
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              cover,
              const SizedBox(height: ArSpace.xs),
              label,
              ?badge,
            ],
          )
        : Row(
            children: [
              cover,
              const SizedBox(width: ArSpace.sm),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [label, ?badge],
                ),
              ),
            ],
          );

    return MouseRegion(
      onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
      onExit: enabled ? (_) => setState(() => _hovered = false) : null,
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: ArPressable(
        onTap: enabled ? widget.onTap : null,
        child: content,
      ),
    );
  }
}

/// Copertina di riserva con l'iniziale del titolo.
///
/// Stessa idea del fallback di [AnimeThumb]: un riquadro vuoto in un duello
/// sembrerebbe un'immagine rotta, mentre l'iniziale dice subito di quale dei
/// due contendenti si tratta.
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
      loading: () => const _EloSkeleton(),
      error: (error, _) => ErrorState(
        message: _message(error),
        onRetry: () => ref.read(duelStandingsProvider(groupId).notifier).refresh(),
      ),
      data: (rows) {
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.emoji_events_outlined,
            title: 'Classifica Elo vuota',
            message: 'Gli anime entrano in classifica quando i membri del '
                'gruppo li mettono in duello.',
          );
        }

        return isExpanded
            ? _EloTable(rows: rows)
            : ListView.builder(
                padding: EdgeInsets.symmetric(vertical: ArSpace.xs),
                itemCount: rows.length,
                itemBuilder: (context, i) => ArReveal(
                  // Ritardo minimo e non crescente per posizione: la classifica
                  // si legge dall'alto, e le righe in fondo arriverebbero dopo
                  // che l'utente ha gia' finito di leggerle.
                  delayMs: i < 8 ? i * 30 : 240,
                  child: _EloTile(row: rows[i]),
                ),
              );
      },
    );
  }
}

/// Scheletro della classifica.
///
/// Le stesse righe della versione vera, alla stessa altezza: un segnaposto piu'
/// basso del contenuto che sostituisce farebbe salire tutta la lista al primo
/// arrivo dei dati, e l'occhio perderebbe la riga che stava leggendo.
class _EloSkeleton extends StatelessWidget {
  const _EloSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: ArSpace.xs),
      itemCount: 8,
      itemBuilder: (context, i) => const Padding(
        padding: EdgeInsets.symmetric(
          horizontal: ArSpace.md,
          vertical: ArSpace.xxs,
        ),
        child: Row(
          children: [
            SkeletonBox(width: 28, height: 16),
            SizedBox(width: ArSpace.sm),
            SkeletonBox(width: 32, height: 32, radius: ArRadii.chip),
            SizedBox(width: ArSpace.sm),
            Expanded(child: SkeletonBox(height: 14)),
            SizedBox(width: ArSpace.md),
            SkeletonBox(width: 40, height: 16),
          ],
        ),
      ),
    );
  }
}

class _EloTable extends StatelessWidget {
  const _EloTable({required this.rows});

  final List<DuelStanding> rows;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(ArSpace.page(context).left),
      child: Center(
        child: ConstrainedBox(
          // Contenitore largo con tabella: su schermi enormi la tabella si
          // allargerebbe fino a far schizzare via i titoli, e su schermi
          // stretti finirebbe con colonne schiacciate.
          constraints: const BoxConstraints(maxWidth: 900),
          child: DataTable(
            columnSpacing: ArSpace.xl,
            headingRowColor: WidgetStatePropertyAll(ArColors.containerHigh),
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
                    DataCell(_EloPosition(position: row.position)),
                    DataCell(
                      Row(
                        children: [
                          AnimeThumb(url: row.imageUrl, title: row.title, size: 32),
                          const SizedBox(width: ArSpace.sm),
                          Expanded(
                            child: Text(
                              row.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    DataCell(
                      Text(
                        '${row.elo}',
                        style: const TextStyle(
                          fontFamily: AppTheme.displayFont,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
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

/// Posizione in classifica, colorata come le medaglie.
///
/// Il colore viene da [ArColors.rank] cosi' la posizione ha lo stesso significato
/// nella classifica, nel podio e nella lista: l'oro del primo posto non
/// ricomincia a ogni schermata.
class _EloPosition extends StatelessWidget {
  const _EloPosition({required this.position});

  final int position;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$position',
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: position <= 3 ? ArColors.rank(position) : ArColors.textMid,
            fontVariations: const [FontVariation('wght', 700)],
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

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ArSpace.md,
        vertical: ArSpace.xxs,
      ),
      child: Row(
        children: [
          // Larghezza fissa per la posizione: se prendesse quella del numero,
          // "1" e "10" sposterebbero le copertine della lista a ogni nuovo
          // arrivo e la colonna sembrerebbe vibrare.
          SizedBox(
            width: 28,
            child: _EloPosition(position: row.position),
          ),
          AnimeThumb(url: row.imageUrl, title: row.title, size: 40),
          const SizedBox(width: ArSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  row.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  _duelCountLabel(row.duelCount),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: ArSpace.sm),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${row.elo}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontVariations: const [FontVariation('wght', 700)],
                ),
              ),
              if (delta != 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      delta > 0
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 11,
                      color: delta > 0 ? ArColors.success : ArColors.danger,
                    ),
                    Text(
                      '${delta.abs()}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: delta > 0 ? ArColors.success : ArColors.danger,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
            ],
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
