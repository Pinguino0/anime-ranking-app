import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/content_row.dart';
import '../../../../core/ui/transitions.dart';
import '../../domain/episode.dart';

/// Player di un episodio.
///
/// Un solo widget per i tre formati che il backend puo' dichiarare, perche' la
/// differenza fra mp4, hls e iframe e' dirogli e non di interfaccia:
///
///  - **mp4** e **hls** si aprono qui. `video_player` usa il decoder di sistema,
///    quindi HLS e' nativo su iOS e Android senza plugin aggiuntivi.
///  - **iframe** non si puo' incorporare in un player video senza caricare una
///    WebView dentro l'app, che significa eseguire codice di terze parti nel
///    processo dell'app. Si mostra quindi la scheda del provider e si lascia
///    aprire il link fuori. E' anche la scelta onesta: se l'episodio non e' in
///    catalogo con licenza, l'app non finge di averlo.
///
/// Il fallback e' automatico: se una fonte non parte si prova la successiva,
/// senza avvisare. Un file morto e' un problema del backend, e l'utente che
/// sta cercando di guardare qualcosa non ha bisogno di saperlo.
class EpisodePlayer extends StatefulWidget {
  const EpisodePlayer({
    required this.sources,
    this.sourceIndex,
    this.resumeFrom,
    this.onProgress,
    this.onComplete,
    this.onSourceChanged,
    super.key,
  });

  /// Fonti da provare, gia' ordinate dalla piu' affidabile.
  final List<EpisodeSource> sources;

  /// Fonte da usare, quando il chiamante sceglie dalla lista.
  ///
  /// `null` lascia scegliere il player, che parte dalla prima e va avanti da
  /// solo se non si apre. Il valore torna indietro anche quando il player e'
  /// passato da solo a una fonte successiva, cosi' il selettore non resta
  /// fermo su una qualita' che non e' quella in riproduzione.
  final int? sourceIndex;

  /// Secondi da cui ripartire.
  ///
  /// Viene applicato una volta sola, appena il video e' pronto: riapplicarlo a
  /// ogni ricostruzione farebbe tornare indietro mentre l'utente guarda.
  final Duration? resumeFrom;

  /// Chiamata a ogni avanzamento del video.
  final void Function(Duration position)? onProgress;

  /// Chiamata quando l'episodio arriva in fondo, con la posizione finale.
  ///
  /// La posizione serve a registrare anche l'ultimo secondo: marcare finito un
  /// episodio senza dire dove si e' arrivati lascerebbe la riga di progresso
  /// indietro di qualche secondo rispetto a quello che si e' visto davvero.
  final void Function(Duration position)? onComplete;

  /// Chiamata quando cambia la fonte in uso, per tenere il selettore allineato.
  final void Function(int index)? onSourceChanged;

  @override
  State<EpisodePlayer> createState() => _EpisodePlayerState();
}

class _EpisodePlayerState extends State<EpisodePlayer> {
  VideoPlayerController? _controller;

  /// Indice della fonte in uso. Non un riferimento all'oggetto: due fonti con
  /// lo stesso identico URL non hanno motivo di essere trattate come diverse,
  /// e l'indice sopravvive a un cambio di lista.
  int _index = 0;

  /// Perche' l'ultima fonte non si e' aperta, in parole dell'utente.
  ///
  /// `null` mentre non e' ancora successo niente: la differenza fra "sta
  /// caricando" e "ha fallito" e' la differenza fra aspettare e non aspettare
  /// piu'.
  String? _error;

  /// true quando la WebView o il codec non c'entrano e il caso e' `iframe`.
  bool get _isExternal =>
      widget.sources.isNotEmpty && !widget.sources[_index].isPlayable;

  bool get _isReady => _controller?.value.isInitialized ?? false;

  /// Tempo massimo che una fonte ha per aprirsi.
  ///
  /// Serve perche' `initialize()` non sempre fallisce: su un file che non
  /// arriva, o con un codec che non risponde, la promessa resta aperta e senza
  /// questo limite lo scheletro pulserebbe per sempre. L'utente non
  /// distinguerebbe "sta caricando" da "e' rotto", e la sorgente successiva —
  /// magari funzionante — non verrebbe mai provata.
  static const Duration openTimeout = Duration(seconds: 12);

  @override
  void initState() {
    super.initState();
    _open(_index);
  }

  @override
  void didUpdateWidget(EpisodePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Cambiando episodio si riparte: riusare il controller precedente
    // mostrerebbe il video del vecchio episodio con il titolo del nuovo.
    if (oldWidget.sources != widget.sources) {
      _open(widget.sourceIndex ?? 0, resume: false);
      return;
    }

    // Il chiamante ha scelto un'altra fonte a mano. Si parte dalla posizione
    // corrente invece che dal punto salvato, altrimenti passare qualita'
    // riporterebbe indietro di qualche minuto senza spiegazione.
    final requested = widget.sourceIndex;
    if (requested != null && requested != _index) {
      final current = _controller;
      final position =
          current != null && current.value.isInitialized
              ? current.value.position
              : null;
      _open(requested, startAt: position);
    }
  }

  @override
  void dispose() {
    // Il player che si chiude deve dire dove si era arrivati: e' l'ultima
    // occasione, e il widget non esiste piu' per farlo.
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      widget.onProgress?.call(controller.value.position);
    }

    _controller?.removeListener(_onTick);
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  /// Apre la fonte [index], passando alla successiva se non parte.
  ///
  /// [startAt] sovrascrive il punto di ripresa quando si cambia fonte a mano:
  /// l'utente che passa da 1080p a 720p sta guardando lo stesso episodio e si
  /// aspetta di continuare da dove era, non di ricominciare dal punto salvato
  /// dieci secondi fa e nemmeno dall'inizio.
  Future<void> _open(int index, {bool resume = true, Duration? startAt}) async {
    final previous = _controller;
    _controller = null;
    previous?.removeListener(_onTick);

    // `dispose` viene atteso ma con un tetto: su un controller mai
    // inizializzato puo' non restituire mai, e aspettarlo bloccherebbe il
    // passaggio alla sorgente successiva — l'utente resterebbe a fissare uno
    // scheletro che non finisce piu', senza nemmeno il messaggio d'errore.
    // Il tetto e' generoso perche' su un dispositivo vero chiudere un decoder
    // puo' mettere qualche decimo di secondo.
    if (previous != null) {
      await previous.dispose().timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
    }

    if (!mounted) return;

    if (index >= widget.sources.length) {
      setState(() {
        _error = 'Nessuna delle fonti disponibili si e\' aperta. '
            'Riprova piu\' tardi.';
      });
      return;
    }

    final source = widget.sources[index];
    setState(() {
      _index = index;
      _error = null;
    });
    widget.onSourceChanged?.call(index);

    // Una fonte non riproducibile non e' un errore da tentare: si esce subito
    // e la schermata mostra la scheda del provider.
    if (!source.isPlayable) return;

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(source.url),
    );
    _controller = controller;

    try {
      await controller.initialize().timeout(openTimeout);
      if (!mounted) {
        // Lo schermo e' cambiato mentre il video si preparava: il controller
        // appena creato non serve piu' e va buttato, altrimenti continua a
        // consumare il decoder nel vuoto.
        await controller.dispose();
        return;
      }

      final resume = startAt ?? widget.resumeFrom;
      if (resume != null && resume > Duration.zero) {
        // Non oltre la fine: un progresso salvato su un episodio piu' corto
        // sposterebbe il cursore oltre il contenuto e il video si fermerebbe
        // subito, apparentemente rotto.
        final total = controller.value.duration;
        if (resume < total) await controller.seekTo(resume);
      }

      controller.addListener(_onTick);
      await controller.play();
      setState(() {});
    } catch (_) {
      // Non si distingue qui un 404 da un codec assente: dal punto di vista
      // dell'utente sono la stessa cosa, cioe' "questa fonte non parte".
      // Prosegue quindi con la successiva senza fermarsi a spiegare.
      if (index + 1 < widget.sources.length) {
        await _open(index + 1, resume: resume, startAt: startAt);
      } else {
        if (!mounted) return;
        setState(() {
          _error = 'Nessuna delle fonti disponibili si e\' aperta. '
              'Riprova piu\' tardi.';
        });
      }
    }
  }

  /// Segue l'avanzamento a ogni tick del decoder.
  ///
  /// Il player emette piu' eventi al secondo, quindi qui non si fa niente di
  /// pesante: si legge la posizione, si avvisa chi ascolta e si controlla la
  /// fine. Il salvataggio con intervallo e' lavoro di [WatchProgressSaver], non
  /// del player.
  void _onTick() {
    final controller = _controller;
    if (controller == null || !mounted) return;

    final value = controller.value;
    if (value.position == Duration.zero) return;

    widget.onProgress?.call(value.position);

    // Un secondo di margine: l'ultimo tick arriva spesso qualche decimo prima
    // della durata dichiarata, e senza il margine la fine non scatterebbe mai.
    final total = value.duration;
    if (!value.isPlaying &&
        total > Duration.zero &&
        value.position >= total - const Duration(seconds: 1)) {
      widget.onComplete?.call(value.position);
    }
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null || !_isReady) return;

    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      // Riavviare dalla posizione corrente, non dall'inizio: l'utente che
      // aveva fermato per un attimo si aspetta di continuare.
      controller.play();
    }
    setState(() {});
  }

  Future<void> _seekTo(double fraction) async {
    final controller = _controller;
    if (controller == null || !_isReady) return;

    final total = controller.value.duration;
    await controller.seekTo(
      Duration(milliseconds: (total.inMilliseconds * fraction).round()),
    );
    if (mounted) setState(() {});
  }

  /// Riapre la sorgente corrente.
  Future<void> _retry() async {
    final failed = _index;
    setState(() => _error = null);
    await _open(failed, resume: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(ArRadii.card),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: ArColors.bg,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_error != null)
                _PlayerMessage(
                  icon: Icons.sentiment_dissatisfied_outlined,
                  title: 'Non si riesce a guardare',
                  message: _error!,
                  actionLabel: 'Riprova',
                  onAction: _retry,
                )
              else if (_isExternal)
                _ExternalSourceCard(source: widget.sources[_index])
              else if (_isReady)
                _VideoSurface(
                  controller: _controller!,
                  onTogglePlay: _togglePlay,
                  onSeek: _seekTo,
                  onNext: _nextEpisode == null
                      ? null
                      : () => _nextEpisode!(),
                )
              else
                const SkeletonBox(
                  height: double.infinity,
                  radius: 0,
                ),

              // Il nome della fonte in uso sta sopra il video, non nella barra
              // dei comandi: e' l'informazione che serve quando si cambia
              // qualita' a meta' visione, e la barra viene nascosta spesso.
              if (_isReady || _isExternal)
                PositionedDirectional(
                  top: ArSpace.sm,
                  start: ArSpace.sm,
                  child: _SourceBadge(source: widget.sources[_index]),
                ),

              if (_isReady)
                PositionedDirectional(
                  bottom: ArSpace.sm,
                  end: ArSpace.sm,
                  child: Text(
                    _formatDuration(_controller!.value.position),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: ArColors.textMid,
                      fontVariations: const [FontVariation('wght', 600)],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Va all'episodio dopo, se c'e'.
  ///
  /// Un pulsante dentro il video e' una promessa che l'utente aspetta di
  /// poter onorare: se manca l'episodio successivo il pulsante sparisce,
  /// invece di restare li' a non fare niente.
  VoidCallback? get _nextEpisode {
    final index = _index;
    if (index + 1 >= widget.sources.length) return null;
    return () => _open(index + 1, resume: false);
  }

  /// mm:ss, e h:mm:ss solo quando serve davvero.
  static String _formatDuration(Duration value) {
    final seconds = value.inSeconds;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final rest = seconds % 60;

    final padded = rest.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:$padded';
    }
    return '$minutes:$padded';
  }
}

/// Il video con i comandi sotto.
///
/// I comandi sono dell'app e non quelli del sistema perche' l'obiettivo e'
/// una sola esperienza coerente con il resto di AnimeRank: i controlli nativi
/// su Android e su iOS hanno due aspetti diversi e nessuno dei due somiglia al
/// tema della sezione episodi.
class _VideoSurface extends StatelessWidget {
  const _VideoSurface({
    required this.controller,
    required this.onTogglePlay,
    required this.onSeek,
    this.onNext,
  });

  final VideoPlayerController controller;
  final VoidCallback onTogglePlay;
  final void Function(double fraction) onSeek;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final value = controller.value;

    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoPlayer(controller),
              // Il video non reagisce al tocco da solo: senza questo strato il
              // play si aprirebbe solo toccando l'immagine, e sull'area piu'
              // comoda l'utente si aspetterebbe che un tocco funzioni.
              InkWell(
                onTap: onTogglePlay,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: value.isPlaying ? 0 : 1,
                    duration: ArMotion.fast,
                    child: _PlayButton(onTap: onTogglePlay),
                  ),
                ),
              ),
            ],
          ),
        ),
        _ControlBar(
          position: value.position,
          duration: value.duration,
          isPlaying: value.isPlaying,
          onTogglePlay: onTogglePlay,
          onSeek: onSeek,
          onNext: onNext,
        ),
      ],
    );
  }
}

/// Pastiglia grande di play e pausa.
///
/// Sta al centro e non in basso perche' in quel momento l'occhio e' sul centro
/// dello schermo: e' la posizione in cui si cerca il controllo principale, e
/// metterlo in basso costringerebbe a spostare lo sguardo.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ArPressable(
      onTap: onTap,
      scale: 0.92,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ArColors.bg.withValues(alpha: 0.55),
          shape: BoxShape.circle,
          border: Border.all(color: ArColors.border),
        ),
        child: const SizedBox(
          width: 62,
          height: 62,
          child: Icon(Icons.play_arrow_rounded, size: 34),
        ),
      ),
    );
  }
}

/// Barra dei comandi sotto il video.
class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.onTogglePlay,
    required this.onSeek,
    this.onNext,
  });

  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final VoidCallback onTogglePlay;
  final void Function(double fraction) onSeek;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalMs = duration.inMilliseconds;

    // Sulla barra il cursore si muove in percentuale e non in secondi: il
    // video puo' essere piu' corto di quanto l'utente si aspetta, e vincolare
    // la barra a una durata fissa la taglierebbe a meta' senza dire nulla.
    final value = totalMs <= 0
        ? 0.0
        : (position.inMilliseconds / totalMs).clamp(0.0, 1.0);

    return ColoredBox(
      color: ArColors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ArSpace.sm,
          vertical: ArSpace.xxs,
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: onTogglePlay,
              icon: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              tooltip: isPlaying ? 'Pausa' : 'Riproduci',
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  activeTrackColor: ArColors.primary,
                  inactiveTrackColor: ArColors.containerHighest,
                  thumbColor: ArColors.primary,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: Slider(
                  value: value,
                  onChanged: onSeek,
                ),
              ),
            ),
            Text(
              '${_time(position)} / ${_time(duration)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: ArColors.textLow,
              ),
            ),
            if (onNext != null)
              IconButton(
                onPressed: onNext,
                icon: const Icon(Icons.skip_next_rounded),
                tooltip: 'Prova la fonte successiva',
              ),
          ],
        ),
      ),
    );
  }

  static String _time(Duration value) {
    final seconds = value.inSeconds;
    final minutes = seconds ~/ 60;
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

/// Pastiglia con la qualita' della fonte in uso.
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final EpisodeSource source;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ArSpace.sm,
        vertical: ArSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: ArColors.bg.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(ArRadii.chip),
      ),
      child: Text(
        source.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: ArColors.textMid,
              fontVariations: const [FontVariation('wght', 600)],
            ),
      ),
    );
  }
}

/// Scheda mostrata quando la fonte non e' riproducibile dall'app.
///
/// Dice cosa sta succedendo e lascia aprire il provider: e' il comportamento
/// che il prompt chiede per le fonti esterne, ed e' anche il modo onesto di
/// gestire un episodio che il backend espone solo come `iframe`.
class _ExternalSourceCard extends StatelessWidget {
  const _ExternalSourceCard({required this.source});

  final EpisodeSource source;

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(source.url);

    if (uri == null || !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Non si e\' riusciti ad aprire il link.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ArSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.open_in_new_rounded,
              size: 32,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: ArSpace.sm),
            Text(
              'Guarda su ${source.label}',
              style: theme.textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: ArSpace.xxs),
            Text(
              'Questo episodio si guarda sul provider, fuori dall\'app.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: ArColors.textMid,
              ),
            ),
            const SizedBox(height: ArSpace.md),
            ArGradientButton(
              label: 'Apri il provider',
              icon: Icons.open_in_new_rounded,
              onPressed: () => _open(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// Messaggio a tutto schermo: nessuna fonte aperta.
class _PlayerMessage extends StatelessWidget {
  const _PlayerMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ArSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: ArColors.textMid),
            const SizedBox(height: ArSpace.sm),
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: ArSpace.xxs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: ArColors.textMid,
                ),
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: ArSpace.md),
              ArGradientButton(
                label: actionLabel!,
                icon: Icons.refresh,
                onPressed: onAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}