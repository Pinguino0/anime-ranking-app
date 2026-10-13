import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/content_row.dart';
import '../../../../core/ui/section_header.dart';
import '../../../../core/ui/transitions.dart';
import '../../domain/episode.dart';
import '../../domain/intro_markers.dart';
import '../episode_sync_controller.dart';
import '../episodes_controller.dart';
import '../widgets/episode_player.dart';
import '../widgets/episode_rating_bar.dart';
import '../widgets/episode_tile.dart';

/// Schermata di visione di un episodio.
///
/// Il player sta in alto e l'elenco a lato, non sotto. Sotto funziona solo se
/// l'elenco e' una riga sola: con venti episodi per un utente che sta
/// guardando, farlo scorrere in fondo a ogni episodio per scegliere il
/// successivo significa scrollare piu' spesso di quanto si guarda.
///
/// Su telefono l'elenco diventa un foglio che sale dal basso, che e' la
/// disposizione giusta quando lo spazio in larghezza non c'e': il player deve
/// restare grande e l'elenco, che si consulta di rado, sta sopra tutto.
class EpisodeScreen extends ConsumerStatefulWidget {
  const EpisodeScreen({
    required this.animeId,
    this.episodeId,
    this.initialEpisodeNum,
    this.animeTitle,
    super.key,
  });

  /// Id interno di `public.anime`, quello a cui `episodes.anime_id` fa
  /// riferimento.
  final String animeId;

  /// Episodio da aprire. `null` apre il primo disponibile.
  final String? episodeId;

  /// Numero dell'episodio da aprire quando non c'e' un [episodeId].
  ///
  /// Arriva dal tap di una notifica "nuovo episodio", che conosce il numero ma
  /// non l'id: la schermata apre quello, o l'ultimo disponibile se il catalogo
  /// non lo conosce ancora.
  final int? initialEpisodeNum;

  /// Nome dell'opera, per il titolo della pagina.
  final String? animeTitle;

  @override
  ConsumerState<EpisodeScreen> createState() => _EpisodeScreenState();
}

class _EpisodeScreenState extends ConsumerState<EpisodeScreen> {
  /// Scrittura del progresso.
  ///
  /// Vive nello stato e non in un provider perche' tiene il contatore interno
  /// di "quanto video e' passato dall'ultimo salvataggio", che e' una cosa di
  /// questa schermata: cambiando episodio deve ricominciare da zero, mentre
  /// un provider condiviso lo ricorderebbe e salterebbe il primo salvataggio
  /// dell'episodio successivo.
  late final WatchProgressSaver _saver;

  /// Chiave stabile del blocco player.
  ///
  /// La schermata ha due disposizioni — colonna su telefono, elenco a lato
  /// quando e' larga — e ruotando per il full screen si passa dall'una
  /// all'altra. Senza una chiave stabile Flutter smonta il player e lo ricrea:
  /// il video riparte da capo e la rotta a tutto schermo resta su un controller
  /// gia' chiuso (schermo nero). Con la chiave l'elemento viene rimontato e il
  /// player sopravvive al cambio di disposizione.
  final GlobalKey _playerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _saver = WatchProgressSaver(ref.read(episodesRepositoryProvider));

    // Prima di mostrare l'elenco si chiede al provider se ha episodi nuovi.
    // Non blocca niente: la lista di prima compare subito, e se il conteggio
    // e' cambiato si ricarica da sola (senza che l'utente debba ricaricare).
    unawaited(ref.read(episodeSyncProvider).syncAnime(widget.animeId));
  }

  void _openEpisode(String id) {
    // `pushReplacement` e non `push`: ogni episodio spinto sullo stack
    // lascerebbe un player in pausa e un decoder aperto, e dopo tre episodi
    // l'utente avrebbe una pila di pagine da attraversare una alla volta per
    // tornare alla lista.
    context.pushReplacement(
      AppRoutes.episode(widget.animeId, id),
      extra: widget.animeTitle,
    );
  }

  @override
  Widget build(BuildContext context) {
    final episodes = ref.watch(episodesProvider(widget.animeId));

    return Scaffold(
      backgroundColor: ArColors.bg,
      body: episodes.when(
        loading: () => const _LoadingBody(),
        error: (error, _) => ErrorState(
          message: error is AppFailure
              ? error.message
              : 'Episodi non disponibili.',
          onRetry: () => ref.invalidate(episodesProvider(widget.animeId)),
        ),
        data: _body,
      ),
    );
  }

  Widget _body(List<Episode> episodes) {
    if (episodes.isEmpty) {
      return EmptyState(
        icon: Icons.tv_off_rounded,
        title: 'Nessun episodio',
        message: 'Questa opera non ha ancora episodi in catalogo.',
        action: ArPressable(
          onTap: () => context.pop(),
          child: Text(
            'Torna indietro',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ),
      );
    }

    final index = _resolveIndex(episodes);
    final episode = episodes[index];

    final size = Breakpoints.fromContext(context);
    final wide = !size.isCompact;

    final player = _PlayerBlock(
      episode: episode,
      animeId: widget.animeId,
      saver: _saver,
      playerKey: _playerKey,
    );

    final details = _Details(episode: episode, animeId: widget.animeId);

    final onPrevious =
        index > 0 ? () => _openEpisode(episodes[index - 1].id) : null;
    final onNext = index < episodes.length - 1
        ? () => _openEpisode(episodes[index + 1].id)
        : null;

    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: size.isExpanded ? ArSpace.lg : ArSpace.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _TopBar(title: widget.animeTitle),
                    player,
                    details,
                    const SizedBox(height: ArSpace.xl),
                  ],
                ),
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          SizedBox(
            width: 340,
            child: _SideList(
              episodes: episodes,
              current: index,
              onPick: _openEpisode,
            ),
          ),
        ],
      );
    }

    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 72),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TopBar(title: widget.animeTitle),
              player,
              details,
              const SizedBox(height: ArSpace.xl),
            ],
          ),
        ),
        // Barra in basso solo su telefono: l'elenco e' dentro un foglio, e
        // senza un punto fisso per aprirlo l'utente dovrebbe indovinare che
        // sotto al player c'e' qualcosa da aprire.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _MobileBar(
            episode: episode,
            onPrevious: onPrevious,
            onNext: onNext,
            onOpenList: () => _openSheet(episodes, index),
          ),
        ),
      ],
    );
  }

  /// Indice dell'episodio da mostrare.
  ///
  /// Se l'id richiesto non c'e' piu' — l'episodio e' stato rimosso, o il link
  /// e' vecchio — si cade sul primo disponibile invece di mostrare una pagina
  /// vuota: la lista e' comunque li', e il vuoto sembrerebbe un bug.
  int _resolveIndex(List<Episode> episodes) {
    final wanted = widget.episodeId;
    if (wanted != null) {
      final index = episodes.indexWhere((e) => e.id == wanted);
      if (index >= 0) return index;
    }

    // Numero da notifica: la lista e' ordinata crescente, quindi si cerca
    // l'episodio con quel numero; se il catalogo non lo conosce ancora si
    // prende l'ultimo disponibile, che e' comunque la novita' piu' recente.
    final number = widget.initialEpisodeNum;
    if (number != null) {
      final exact = episodes.indexWhere((e) => e.number == number);
      return exact >= 0 ? exact : episodes.length - 1;
    }

    return 0;
  }

  void _openSheet(List<Episode> episodes, int current) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ArColors.surfaceHigh,
      isScrollControlled: true,
      builder: (sheetContext) => _EpisodeSheet(
        episodes: episodes,
        current: current,
        onPick: (id) {
          Navigator.of(sheetContext).pop();
          _openEpisode(id);
        },
      ),
    );
  }
}

/// Player e selettore della fonte.
///
/// Lo stato del player — posizione, riproduzione — resta tutto dentro
/// [EpisodePlayer]. Qui c'e' solo l'indice della fonte, che e' l'unica cosa che
/// il selettore e il player devono condividere.
class _PlayerBlock extends ConsumerWidget {
  const _PlayerBlock({
    required this.episode,
    required this.animeId,
    required this.saver,
    required this.playerKey,
  });

  final Episode episode;

  /// Anime dell'episodio: serve solo a cercare la finestra della sigla, che il
  /// catalogo tiene per anime e non per episodio.
  final String animeId;

  final WatchProgressSaver saver;

  /// Chiave stabile del player, passata dal genitore.
  ///
  /// Serve perche' ruotando cambia la disposizione della schermata: con una
  /// chiave stabile il player viene rimontato invece che ricreato, e il video
  /// non riparte da capo nel passaggio al full screen.
  final Key playerKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(episodeSourcesProvider(episode.id));

    return sources.when(
      loading: () => const _PlayerSkeleton(),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(ArSpace.lg),
        child: ErrorState(
          message: error is AppFailure ? error.message : 'Fonti non disponibili.',
          onRetry: () => ref.invalidate(episodeSourcesProvider(episode.id)),
        ),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(ArSpace.lg),
            child: EmptyState(
              icon: Icons.videocam_off_rounded,
              title: 'Nessuna fonte attiva',
              message: 'Questo episodio non ha ancora una sorgente in catalogo.',
            ),
          );
        }
        return _Playable(
          key: playerKey,
          sources: list,
          episode: episode,
          // `value` e non `when`: la sigla e' un di piu', non una cosa da
          // mostrare. Finche' arriva — o se la lettura fallisce — non c'e'
          // pulsante, e il player funziona lo stesso. La finestra va chiesta
          // per episodio: la sigla cambia da puntata a puntata.
          intro: ref
              .watch(animeIntroProvider((animeId: animeId, episode: episode.number)))
              .value,
          saver: saver,
          // Il resolver viene preso dal provider e non passato dal chiamante:
          // e' la stessa operazione che ha caricato le fonti, quindi deve
          // attraversare lo stesso client gia' collegato. Senza questo, una
          // schermata che apre un episodio da una notifica — e che non ha ancora
          // costruito il blocco fonti — si troverebbe un player senza resolver e
          // tutte le fonti canoniche sembrerebbero rotte.
          resolve: ref.read(episodesRepositoryProvider).resolveSource,
        );
      },
    );
  }
}

/// Player vero e proprio piu' il selettore delle fonti.
class _Playable extends StatefulWidget {
  const _Playable({
    required this.sources,
    required this.episode,
    required this.saver,
    required this.resolve,
    this.intro,
    super.key,
  });

  final List<EpisodeSource> sources;
  final Episode episode;
  final WatchProgressSaver saver;

  /// Finestra della sigla, se il catalogo la conosce. `null` = nessun pulsante
  /// "Salta intro".
  final IntroMarkers? intro;

  /// Risolutore passato al player per le fonti che hanno solo l'indirizzo
  /// canonico.
  final SourceResolver resolve;

  @override
  State<_Playable> createState() => _PlayableState();
}

class _PlayableState extends State<_Playable> {
  int _index = 0;

  @override
  void didUpdateWidget(_Playable oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Cambiando episodio il selettore torna alla prima fonte. Senza questo lo
    // schermo mostrerebbe la voce tre della lista mentre riproduce la prima,
    // che e' la coppia sbagliata peggiore: sembra che il player sia rotto.
    if (oldWidget.episode.id != widget.episode.id) {
      _index = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Le fonti sottotitolate vengono prima: l'ordine del backend non ha un
    // criterio, e un player che parte dalla traccia doppiata quando esiste
    // quella sottotitolata decide una preferenza al posto dell'utente. Cosi'
    // la prima fonte e la scelta di chi non ha ancora scelto, e le due
    // pastiglie restano comunque entrambe a un tocco di distanza.
    final sources = _subtitledFirst(widget.sources);
    final safeIndex = _index.clamp(0, sources.length - 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(ArRadii.card),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: EpisodePlayer(
              // La chiave comprende l'episodio: senza, il player conserva il
              // controller del precedente e per un frame mostra il video
              // vecchio sotto il titolo del nuovo.
              key: ValueKey('player-${widget.episode.id}'),
              sources: sources,
              sourceIndex: safeIndex,
              intro: widget.intro,
              resumeFrom: Duration(seconds: widget.episode.progressTime),
              // Il resolver arriva a ogni ricostruzione perche' la schermata
              // puo' cambiare provider mentre e' aperta — dopo un ricollegamento
              // dell'utente, per esempio — e il player deve parlare con quello
              // nuovo. Il player non lo chiama da solo perche' potrebbe, ma
              // tenerlo in mano e' la cosa che gli permette di accorgersi che e'
              // cambiato.
              resolver: widget.resolve,
              onSourceChanged: (index) {
                if (index == _index || !mounted) return;
                setState(() => _index = index);
              },
              onProgress: (position) =>
                  widget.saver.maybeSave(widget.episode.id, position),
              onComplete: (position) =>
                  widget.saver.markCompleted(widget.episode.id, position),
            ),
          ),
        ),
        const SizedBox(height: ArSpace.sm),
        _SourceSelector(
          sources: sources,
          selected: safeIndex,
          onSelect: (index) => setState(() => _index = index),
        ),
        const SizedBox(height: ArSpace.xxs),
        // L'URL non si mostra per intero: serve solo a distinguere le fonti
        // quando hanno la stessa etichetta, e una riga di indirizzi lunghi
        // spingerebbe il resto della pagina sotto.
        Text(
          'Formato ${sources[safeIndex].type.label.toLowerCase()}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// Fonti con le sottotitolate davanti, a parita' di ordine stabile.
  ///
  /// Un `sort` sul solo `isSubtitled` non e' stabile in Dart e mescolerebbe le
  /// fonti che condividono l'ordine: qui si costruiscono due liste e si
  /// concatena, cosi' l'ordine relativo del backend resta.
  ///
  /// Se l'ordine e' gia' quello giusto si restituisce la lista originale per
  /// identita'. Ricrearla a ogni build faceva credere al player che le fonti
  /// fossero cambiate e lo faceva ripartire da capo; nella schermata a tutto
  /// schermo, dove la rotazione ricostruisce tutto, era il bug del 12/10/2026
  /// (vedi `_sameSources` in `episode_player.dart`).
  static List<EpisodeSource> _subtitledFirst(List<EpisodeSource> sources) {
    var ordered = true;
    var seenDubbed = false;

    for (final source in sources) {
      if (source.isSubtitled) {
        if (seenDubbed) {
          ordered = false;
          break;
        }
      } else {
        seenDubbed = true;
      }
    }

    if (ordered) return sources;

    final subtitled = <EpisodeSource>[];
    final dubbed = <EpisodeSource>[];

    for (final source in sources) {
      (source.isSubtitled ? subtitled : dubbed).add(source);
    }

    return [...subtitled, ...dubbed];
  }
}

/// Pastiglie con le fonti disponibili.
///
/// Pastiglie e non menu a tendina: le fonti sono poche e l'utente le confronta
/// prima di scegliere — 1080p contro 720p, SUB contro DUB — e un menu che si
/// apre e si chiude nasconde esattamente il confronto che serve a decidere.
class _SourceSelector extends StatelessWidget {
  const _SourceSelector({
    required this.sources,
    required this.selected,
    required this.onSelect,
  });

  final List<EpisodeSource> sources;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (sources.length == 1) {
      return Text(
        'Fonte: ${sources.first.label}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    // Il numero distingue solo le sorgenti che si somigliano. Numerarle
    // tutte costerebbe una pastiglia con dentro "(2)" accanto a una che dice
    // gia' "720p DUB": l'utente leggerebbe un numero come se fosse una
    // priorita', mentre non lo e'.
    final duplicati = <String, int>{};
    for (final source in sources) {
      duplicati[source.label] = (duplicati[source.label] ?? 0) + 1;
    }
    final numerate = duplicati.values.any((n) => n > 1);

    return Wrap(
      spacing: ArSpace.xs,
      runSpacing: ArSpace.xs,
      children: [
        for (var i = 0; i < sources.length; i++)
          ArChip(
            label: numerate ? sources[i].labelledAt(i + 1) : sources[i].label,
            selected: i == selected,
            icon: sources[i].isPlayable ? null : Icons.open_in_new_rounded,
            onTap: () => onSelect(i),
          ),
      ],
    );
  }
}

/// Titolo, voto della community e votazione personale.
class _Details extends StatelessWidget {
  const _Details({required this.episode, required this.animeId});

  final Episode episode;
  final String animeId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ArSpace.md,
        vertical: ArSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(episode.titleLabel, style: theme.textTheme.headlineSmall),
          const SizedBox(height: ArSpace.xxs),
          if (episode.communityAverage != null)
            Row(
              children: [
                const Icon(Icons.star_rounded, size: 16, color: ArColors.gold),
                const SizedBox(width: ArSpace.xxs),
                Text(
                  episode.communityAverage!.toStringAsFixed(1),
                  style: theme.textTheme.bodySmall?.copyWith(color: ArColors.gold),
                ),
                const SizedBox(width: ArSpace.xs),
                Flexible(
                  child: Text(
                    'da ${episode.communityCount} '
                    '${episode.communityCount == 1 ? 'utente' : 'utenti'}',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )
          else
            Text('Nessun voto su questo episodio.', style: theme.textTheme.bodySmall),
          const SizedBox(height: ArSpace.lg),
          const SectionHeader(title: 'Il tuo voto'),
          const SizedBox(height: ArSpace.sm),
          _RatingBlock(episodeId: episode.id, animeId: animeId),
        ],
      ),
    );
  }
}

/// Voto con gestione della scrittura e dell'errore.
///
/// Rilegge l'episodio dal provider invece di fidarsi di [episode]: dopo il
/// voto la lista cambia e la riga deve mostrare il numero nuovo senza che
/// nessuno debba ricordarsi di aggiornarlo a mano.
class _RatingBlock extends ConsumerStatefulWidget {
  const _RatingBlock({required this.episodeId, required this.animeId});

  final String episodeId;
  final String animeId;

  @override
  ConsumerState<_RatingBlock> createState() => _RatingBlockState();
}

class _RatingBlockState extends ConsumerState<_RatingBlock> {
  bool _saving = false;

  Future<void> _save(double? score) async {
    // Il blocco sul primo ritorno e' quello che conta: due tap ravvicinati
    // scriverebbero due voti e la lista mostrerebbe il primo mentre la riga
    // mostra il secondo.
    if (_saving) return;
    setState(() => _saving = true);

    try {
      final current = _current;
      if (current == null) return;

      final updated = await ref.read(episodeRaterProvider).save(
            episode: current,
            score: score,
          );

      // La lista e' l'unica copia che sopravvive a questa schermata: senza
      // il patch, tornando indietro la riga mostrerebbe ancora il voto vecchio.
      ref.read(episodesProvider(widget.animeId).notifier).patch(updated);
    } on AppFailure catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Episode? get _current => ref
      .read(episodesProvider(widget.animeId))
      .asData
      ?.value
      .where((e) => e.id == widget.episodeId)
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final episode = _current;

    return EpisodeRatingBar(
      value: episode?.myScore,
      enabled: episode != null,
      saving: _saving,
      onSave: _save,
      onClear: () => _save(null),
    );
  }
}

/// Riga in alto: indietro e nome dell'opera.
class _TopBar extends StatelessWidget {
  const _TopBar({this.title});

  final String? title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ArSpace.xs,
        ArSpace.xs,
        ArSpace.md,
        ArSpace.sm,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () {
              // Un tap su una notifica apre questa pagina con `go`, quindi la
              // pila puo' essere vuota: senza il controllo il pulsante
              // solleverebbe invece di riportare da qualche parte.
              if (context.canPop()) {
                context.pop();
              } else {
                context.go(AppRoutes.home);
              }
            },
            icon: const Icon(Icons.arrow_back_rounded),
            color: theme.colorScheme.onSurface,
            tooltip: 'Indietro',
          ),
          const SizedBox(width: ArSpace.xxs),
          Expanded(
            child: Text(
              title ?? 'Episodi',
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Elenco laterale su schermo largo.
///
/// Sta in una colonna fissa e non scorre con la pagina: e' l'elenco di
/// navigazione, e scrollarlo insieme al contenuto significherebbe perderlo
/// esattamente quando serve scegliere l'episodio successivo.
class _SideList extends StatelessWidget {
  const _SideList({
    required this.episodes,
    required this.current,
    required this.onPick,
  });

  final List<Episode> episodes;
  final int current;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ListView.builder(
        padding: const EdgeInsets.all(ArSpace.md),
        itemCount: episodes.length,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(bottom: ArSpace.xs),
          child: EpisodeTile(
            episode: episodes[i],
            selected: i == current,
            onTap: () => onPick(episodes[i].id),
          ),
        ),
      ),
    );
  }
}

/// Barra di navigazione in fondo, su telefono.
class _MobileBar extends StatelessWidget {
  const _MobileBar({
    required this.episode,
    required this.onPrevious,
    required this.onNext,
    required this.onOpenList,
  });

  final Episode episode;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onOpenList;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ArColors.surfaceHigh,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ArSpace.sm,
            vertical: ArSpace.xs,
          ),
          child: Row(
            children: [
              _NavButton(
                icon: Icons.chevron_left_rounded,
                label: 'Prec.',
                enabled: onPrevious != null,
                onTap: onPrevious,
              ),
              const SizedBox(width: ArSpace.xs),
              Expanded(child: _ListButton(onTap: onOpenList, label: episode.titleLabel)),
              const SizedBox(width: ArSpace.xs),
              _NavButton(
                icon: Icons.chevron_right_rounded,
                label: 'Succ.',
                enabled: onNext != null,
                onTap: onNext,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottone che apre l'elenco degli episodi.
class _ListButton extends StatelessWidget {
  const _ListButton({required this.onTap, required this.label});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ArPressable(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(ArRadii.control),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: ArSpace.sm),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.format_list_numbered_rounded, size: 18),
              const SizedBox(width: ArSpace.xs),
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pulsante di salto all'episodio precedente o successivo.
class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.label,
    required this.enabled,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ArPressable(
      onTap: enabled ? onTap : null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: enabled
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(ArRadii.control),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ArSpace.sm,
            vertical: ArSpace.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: ArSpace.xxs),
              Text(label, style: theme.textTheme.labelLarge),
            ],
          ),
        ),
      ),
    );
  }
}

/// Foglio con l'elenco degli episodi, su telefono.
class _EpisodeSheet extends StatelessWidget {
  const _EpisodeSheet({
    required this.episodes,
    required this.current,
    required this.onPick,
  });

  final List<Episode> episodes;
  final int current;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: ConstrainedBox(
        // Non occupa tutta l'altezza: il foglio serve per scegliere un
        // episodio, e se copre lo schermo intero sembra una schermata nuova
        // invece di una lista che si richiude.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(ArSpace.md),
              child: SectionHeader(title: 'Episodi'),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.all(ArSpace.md),
                itemCount: episodes.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: ArSpace.xs),
                  child: EpisodeTile(
                    episode: episodes[i],
                    selected: i == current,
                    onTap: () => onPick(episodes[i].id),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(ArSpace.md),
              child: ArPressable(
                onTap: () => Navigator.of(context).pop(),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(ArRadii.control),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: ArSpace.sm),
                    child: Center(
                      child: Text('Chiudi', style: theme.textTheme.labelLarge),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Segnaposto durante il caricamento dell'elenco.
///
/// Non uno spinner: la forma dell'attesa e' gia' nota — un rettangolo largo e
/// una lista di righe — e disegnarla evita che la pagina cambi forma quando
/// arrivano i dati.
///
/// Dentro uno scorrimento e non direttamente nel corpo: il rettangolo 16:9 su
/// uno schermo basso e stretto e' piu' alto della pagina, e senza uno
/// scorrimento il segnaposto sborderebbe — un'attesa che trabocca sembra un
/// errore, ed e' l'unica cosa che questa schermata non sta facendo.
class _LoadingBody extends StatelessWidget {
  const _LoadingBody();

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      padding: EdgeInsets.all(ArSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(width: 180, height: 24),
          SizedBox(height: ArSpace.lg),
          AspectRatio(aspectRatio: 16 / 9, child: _PlayerSkeleton()),
          SizedBox(height: ArSpace.lg),
          SkeletonBox(height: 68),
          SizedBox(height: ArSpace.sm),
          SkeletonBox(height: 68),
          SizedBox(height: ArSpace.sm),
          SkeletonBox(height: 68),
        ],
      ),
    );
  }
}

class _PlayerSkeleton extends StatelessWidget {
  const _PlayerSkeleton();

  @override
  Widget build(BuildContext context) {
    return const SkeletonBox(height: 220, radius: ArRadii.card);
  }
}