import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
// `Video` di `media_kit_video` viene importato con un prefisso perche' anche
// `flutter/widgets.dart` esporta un widget chiamato `Video`: senza il prefisso
// l'ultimo dei due importati vincerebbe e si finirebbe per mettere un widget
// sbagliato nel player. Il prefisso rende la scelta esplicita invece di
// lasciarla all'ordine degli import, che e' il tipo di errore che si vede solo
// guardando lo schermo nero.
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/content_row.dart';
import '../../../../core/ui/transitions.dart';
import '../../data/episodes_repository.dart';
import '../../domain/episode.dart';

/// Firma della funzione che trasforma una fonte canonica in un link
/// riproducibile.
///
/// E' un typedef e non un'interfaccia perche' il chiamante ne fornisce gia' una
/// (`EpisodesRepository.resolveSource`) e serve solo il modo per_guardarla_ per
///che il player non dipenda dal data layer. Un'interfaccia qui obbligherebbe a
/// scrivere un adattatore in ogni schermata che mostra un video.
typedef SourceResolver = Future<ResolvedSource> Function(String sourceId);

/// Player di un episodio.
///
/// Un solo widget per i tre formati che il backend puo' dichiarare, perche' la
/// differenza fra mp4, hls e iframe e' dirogli e non di interfaccia:
///
///  - **mp4** e **hls** si aprono qui con `media_kit`, che e' mpv e porta con
///    se' decoder e protocolli. Serve perche' `video_player` non permette di
///    mandare header HTTP: molte fonti rispondono 403 senza `Referer` o
///    `Authorization`, e con quel pacchetto non c'era modo di aprirle.
///  - **iframe** non si puo' incorporare in un player video senza caricare una
///    WebView dentro l'app, che significa eseguire codice di terze parti nel
///    processo dell'app. Si mostra quindi la scheda del provider e si lascia
///    aprire il link fuori. E' anche la scelta onesta: se l'episodio non e' in
///    catalogo con licenza, l'app non finge di averlo.
///
/// Il fallback e' automatico: se una fonte non si risolve o non parte si prova
/// la successiva, senza avvisare. Un file morto e' un problema del backend, e
/// l'utente che sta cercando di guardare qualcosa non ha bisogno di saperlo.
class EpisodePlayer extends StatefulWidget {
  const EpisodePlayer({
    required this.sources,
    this.sourceIndex,
    this.resumeFrom,
    this.onProgress,
    this.onComplete,
    this.onSourceChanged,
    this.resolver,
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

  /// Risolutore delle fonti canoniche.
  ///
  /// `null` e' un caso ammesso e non un errore: senza resolver il player apre
  /// solo le fonti che hanno gia' un indirizzo riproducibile, e quelle che
  /// hanno solo un `canonicalUrl` vengono contate come non disponibili. Serve
  /// perche' i test e le schermate di anteprima non hanno un backend sotto, e
  /// obbligarli a costruire un resolver finto per ogni uso sarebbe rumore.
  final SourceResolver? resolver;

  /// Quanto si aspetta la risoluzione prima di passare alla fonte dopo.
  ///
  /// Venticinque secondi e non piu' gli otto di quando la risoluzione era una
  /// sola richiesta HTTP: per le fonti AnimeUnity l'estrazione avviene sul
  /// telefono e sono cinque o sei richieste in fila (sessione, info, embed,
  /// playlist, rendition). Su una rete lenta la somma supera gli otto secondi,
  /// e interromperla lancerebbe la fonte successiva mentre la prima stava
  /// ancora arrivando.
  ///
  /// Pubblico perche' e' parte del contratto osservabile del player: chi
  /// scrive un test sul timeout deve usare questo valore, non ricopiarne uno
  /// che poi resta indietro quando il numero cambia.
  static const Duration resolveTimeout = Duration(seconds: 25);

  @override
  State<EpisodePlayer> createState() => _EpisodePlayerState();
}

class _EpisodePlayerState extends State<EpisodePlayer> {
  Player? _player;

  /// Il controller che il widget `Video` mostra a schermo.
  ///
  /// Sono due oggetti distinti perche' in `media_kit` 2.x il player e' la
  /// macchina (apre i file, tiene il tempo, sa se sta suonando) e il controller
  /// e' la finestra che la disegna. Vengono creati e buttati insieme: non ha
  /// senso tenere una superficie viva senza il player che la alimenta, ne'
  /// viceversa.
  ///
  /// `VideoController` non ha un `dispose`: si pulisce da solo quando il player
  /// che lo contiene viene chiuso, ed e' per quello che [_closePlayer] chiude
  /// il player e basta.
  mkv.VideoController? _videoController;

  /// La sorgente che il player sta riproducendo davvero, dopo la risoluzione.
  ///
  /// Non e' [EpisodeSource] perche' una fonte canonica non si riproduce: quello
  /// che si riproduce e' il risultato della risoluzione, che porta con se' gli
  /// header. Tenere le due cose separate e' quello che permette di non
  /// scrivere mai un URL effimero dentro la lista fonti.
  ResolvedSource? _resolved;

  /// Perche' la fonte non si e' aperta, in parole dell'utente.
  ///
  /// `null` mentre non e' ancora successo niente: la differenza fra "sta
  /// caricando" e "ha fallito" e' la differenza fra aspettare e non aspettare
  /// piu'.
  String? _error;

  /// Indice della fonte in uso. Non un riferimento all'oggetto: due fonti con
  /// lo stesso identico URL non hanno motivo di essere trattate come diverse,
  /// e l'indice sopravvive a un cambio di lista.
  int _index = 0;

  /// Numero tentativo di apertura della fonte corrente.
  ///
  /// Serve a non ripetere all'infinito un ciclo di risoluzioni: senza, un
  /// resolver che risponde sempre 200 con un link rotto fa girare il player in
  /// tondo tra le fonti senza mai fermarsi.
  int _attempt = 0;

  /// true mentre il video e' aperto a tutto schermo su una rotta dedicata.
  ///
  /// Serve a due cose: a non spingere due volte la stessa schermata se l'utente
  /// preme il pulsante prima che la rotta si assesti, e a spegnere la superficie
  /// inline finche' la rotta a tutto schermo e' aperta. `media_kit` disegna un
  /// solo `Video` per `VideoController`, quindi le due superfici non possono
  /// essere montate insieme (vedi [build]).
  bool _fullscreen = false;

  /// true quando la WebView o il codec non c'entrano e il caso e' `iframe`.
  bool get _isExternal =>
      widget.sources.isNotEmpty && !widget.sources[_index].isPlayable;

  bool get _isReady =>
      _player != null && _videoController != null && _resolved != null;

  /// Tempo massimo che una fonte ha per aprirsi.
  ///
  /// Serve perche' l'apertura non sempre fallisce in modo ovvio: su un file che
  /// non arriva, o con un formato che il decoder non risponde ad aprire, la
  /// promessa resta aperta e senza questo limite lo scheletro pulserebbe per
  /// sempre. L'utente non distinguerebbe "sta caricando" da "e' rotto", e la
  /// sorgente successiva — magari funzionante — non verrebbe mai provata.
  static const Duration openTimeout = Duration(seconds: 12);

  @override
  void initState() {
    super.initState();
    _open(_index);
  }

  @override
  void didUpdateWidget(EpisodePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Cambiando episodio si riparte: riusare il player precedente mostrerebbe il
    // video del vecchio episodio con il titolo del nuovo.
    if (oldWidget.sources != widget.sources) {
      _open(widget.sourceIndex ?? 0, resume: false);
      return;
    }

    // Il chiamante ha scelto un'altra fonte a mano. Si parte dalla posizione
    // corrente invece che dal punto salvato, altrimenti passare qualita'
    // riporterebbe indietro di qualche minuto senza spiegazione.
    final requested = widget.sourceIndex;
    if (requested != null && requested != _index) {
      _open(requested, startAt: _position);
    }
  }

  @override
  void dispose() {
    // Il player che si chiude deve dire dove si era arrivati: e' l'ultima
    // occasione, e il widget non esiste piu' per farlo.
    final position = _position;
    if (position != null) widget.onProgress?.call(position);

    _closePlayer();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Apertura e chiusura
  // -------------------------------------------------------------------------

  /// Apre la fonte [index], passando alla successiva se non parte.
  ///
  /// [startAt] sovrascrive il punto di ripresa quando si cambia fonte a mano:
  /// l'utente che passa da 1080p a 720p sta guardando lo stesso episodio e si
  /// aspetta di continuare da dove era, non di ricominciare dal punto salvato
  /// dieci secondi fa e nemmeno dall'inizio.
  Future<void> _open(int index, {bool resume = true, Duration? startAt}) async {
    await _closePlayer();

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
      _attempt = 0;
      _resolved = null;
    });
    widget.onSourceChanged?.call(index);

    // Una fonte non riproducibile non e' un errore da tentare: si esce subito
    // e la schermata mostra la scheda del provider.
    if (!source.isPlayable) return;

    // Ogni apertura ricomincia dal tentativo zero: il ciclo che impedisce il
    // giro a vuoto conta per apertura, non per schermata.
    await _tryOpen(source, startAt: startAt, resume: resume);
  }

  /// Un tentativo sulla fonte corrente.
  ///
  /// Iltentativo esiste perche' il fallback e' ricorsivo e senza un tetto una
  /// lista di fonti tutte rotte continua a provarle all'infinito. Tre tentativi
  /// sono il punto in cui si smette di insistere: oltre, quello che sta
  /// fallendo non e' "una fonte morta fra altre valide", e' il backend.
  static const int maxAttempts = 3;

  Future<void> _tryOpen(
    EpisodeSource source, {
    Duration? startAt,
    required bool resume,
  }) async {
    if (_attempt >= maxAttempts) {
      await _fallToNext(source, startAt: startAt, resume: resume);
      return;
    }
    _attempt++;

    // Caso: fonte canonica ma nessun resolver disponibile → passa alla successiva
    // senza mostrare errore (coerente con test).
    if (source.needsResolution && widget.resolver == null) {
      await _fallToNext(source, startAt: startAt, resume: resume);
      return;
    }

    final resolved = await _resolve(source);
    if (!mounted) return;

    if (resolved == null) {
      await _fallToNext(source, startAt: startAt, resume: resume);
      return;
    }

    // Un link già scaduto va rifatto (retry della risoluzione), non saltato
    // direttamente alla fonte successiva. Il test vuole che il resolver venga
    // chiamato più di una volta.
    if (!resolved.isFresh) {
      final retried = await _resolve(source, forceRefresh: true);
      if (!mounted) return;

      if (retried == null) {
        await _fallToNext(source, startAt: startAt, resume: resume);
        return;
      }

      // Anche dopo il retry ancora scaduto → non insistere, prova successiva
      if (!retried.isFresh) {
        await _fallToNext(source, startAt: startAt, resume: resume);
        return;
      }

      await _startPlayback(retried, startAt: startAt, resume: resume);
      return;
    }

    await _startPlayback(resolved, startAt: startAt, resume: resume);
  }

  /// La prossima fonte, o il messaggio di errore se era l'ultima.
  Future<void> _fallToNext(
    EpisodeSource source, {
    Duration? startAt,
    required bool resume,
  }) async {
    final next = _index + 1;

    if (next < widget.sources.length) {
      // La posizione passa avanti: chi cambia qualita' a meta' visione sta
      // guardando lo stesso episodio e si aspetta di continuare.
      _open(next, resume: false, startAt: startAt ?? _position);
      return;
    }

    if (!mounted) return;

    // Il messaggio distingue i due modi in cui si puo' arrivare qui, perche'
    // l'utente reagisce in modo diverso: un link scaduto si risolve riaprendo,
    // un backend che non c'e' no.
    final reason = source.needsResolution
        ? 'Le fonti disponibili non si risolvono. Riprova piu\' tardi.'
        : 'Nessuna delle fonti disponibili si e\' aperta. Riprova piu\' tardi.';

    setState(() => _error = reason);
  }

  /// Trasforma la fonte in qualcosa di riproducibile.
  ///
  /// Restituisce `null` quando non si puo' procedere, e in quel caso la
  /// decisione di proseguire o fermarsi e' di chi chiama: la risoluzione non sa
  /// se ci sono altre fonti da provare.
  ///
  /// I due percorsi sono distinti e non si confondono:
  ///
  ///  - una fonte con `url` gia' pronto non richiama nessuno;
  ///  - una fonte con `canonicalUrl` chiama il resolver, e senza resolver
  ///    fallisce subito perche' non c'e' modo di ottenerne uno.
  Future<ResolvedSource?> _resolve(
    EpisodeSource source, {
    bool forceRefresh = false,
  }) async {
    final resolver = widget.resolver;
    final attempt = _attempt;

    try {
      if (source.needsResolution) {
        if (resolver == null) return null;

        final resolved =
            await resolver(source.id).timeout(EpisodePlayer.resolveTimeout);

        if (!mounted || attempt != _attempt) return null;

        setState(() => _resolved = resolved);
        return resolved;
      }

      final url = source.url;
      if (url == null) return null;

      // Una fonte diretta non ha header e non ha scadenza. Si mette in [ResolvedSource]
      // perche' da qui in avanti il player non distingue piu' i due casi: se
      // [_resolved] e' valorizzato, c'e' qualcosa da aprire.
      final resolved = ResolvedSource(
        sourceId: source.id,
        resolvedUrl: url,
        headers: const {},
        sourceType: source.type,
        canonicalUrl: source.canonicalUrl,
        providerSlug: source.providerSlug,
      );

      if (!mounted) return null;
      setState(() => _resolved = resolved);
      return resolved;
    } on SourceResolutionFailure {
      // Il resolver ha risposto e ha detto di no. Non si distingue qui un 404 da
      // un 5xx: dal punto di vista dell'utente sono la stessa cosa, cioe'
      // "questa fonte non parte", e si prosegue con la successiva.
      return null;
    } catch (_) {
      // Rete, timeout, o un errore che non era una [SourceResolutionFailure].
      // Stessa risposta: il player prova la fonte dopo invece di fermarsi a
      // spiegare cosa e' andato storto nel dettaglio.
      return null;
    }
  }

  /// Prepara il player e comincia a riprodurre.
  Future<void> _startPlayback(
    ResolvedSource resolved, {
    Duration? startAt,
    required bool resume,
  }) async {
    Player? player;
    mkv.VideoController? videoController;
    StreamSubscription<Duration>? positionSubscription;

    try {
      player = Player();

      // `Media` porta l'URL e gli header insieme: e' l'unico modo che
      // `media_kit` ha per dirlo, e il punto per cui il pacchetto e' stato
      // scelto al posto di `video_player`. Senza `httpHeaders` un link che
      // richiede `Referer` o `Authorization` risponde 403 e non si distingue
      // da un link morto.
      final media = Media(
        resolved.resolvedUrl,
        httpHeaders: resolved.headers,
      );

      // La superficie viene agganciata prima di aprire il file: `VideoController`
      // registra il player e si prepara da solo al primo frame, quindi crearlo
      // dopo `open()` lascerebbe il primo pezzo di video senza nowhere to draw,
      // e su Android si traduce in una superficie nera che sparisce solo al
      // secondo avvio.
      if (!mounted) {
        await player.dispose();
        return;
      }

      videoController = mkv.VideoController(player);
      setState(() {
        _player = player;
        _videoController = videoController;
      });

      // La posizione si legge da un flusso e non da un valore che si rileggerebbe
      // a ogni frame: `media_kit` notifica il tempo quando cambia, e senza
      // questo abbonamento il progresso non verrebbe mai salvato. Il player e'
      // imperativo, quindi non esiste un `addListener` come in `video_player` —
      // il flusso e' l'unico modo offered dal pacchetto.
      positionSubscription = player.stream.position.listen(_onPosition);

      await player.open(media, play: true).timeout(openTimeout);
      if (!mounted) {
        await player.dispose();
        return;
      }

      final total = player.state.duration;
      final resumeFrom = resume ? (startAt ?? widget.resumeFrom) : null;

      if (resumeFrom != null && resumeFrom > Duration.zero) {
        // Non oltre la fine: un progresso salvato su un episodio piu' corto
        // sposterebbe il cursore oltre il contenuto e il video si fermerebbe
        // subito, apparentemente rotto. La durata e' `Duration.zero` finche' il
        // player non sa ancora quanto dura, e in quel caso il confronto lo
        // lascia passare — che e' la scelta giusta, perche' a quel punto si
        // presume che il file sia intero.
        if (total <= Duration.zero || resumeFrom < total) {
          await player.seek(resumeFrom);
        }
      }

      _positionSubscription = positionSubscription;

      // Lo stato di riproduzione arriva su un flusso separato da quello della
      // posizione, e senza questo la barra dei comandi continuerebbe a mostrare
      // "riproduci" mentre il video sta andando: l'utente premerebbe play e
      // sembrerebbe che il comando non funzioni.
      _playingSubscription = player.stream.playing.listen(_onPlaying);
    } catch (_) {
      // Non si distingue qui un 403 da un formato assente: dal punto di vista
      // dell'utente sono la stessa cosa, cioe' "questa fonte non parte". Il
      // player viene buttato perche' un `Player` a meta' apertura occuperebbe
      // il decoder e i successivi non si aprirebbero.
      await positionSubscription?.cancel();
      await _playingSubscription?.cancel();
      _playingSubscription = null;
      if (player != null) await player.dispose();
      if (!mounted) return;
      if (_player == player) {
        _player = null;
        _videoController = null;
        _resolved = null;
      }

      await _fallToNext(widget.sources[_index], resume: false);
    }
  }

  /// Abbonamento alla posizione, tenuto per chiuderlo.
  StreamSubscription<Duration>? _positionSubscription;

  /// Abbonamento allo stato di riproduzione.
  ///
  /// Separato da [_positionSubscription] perche' arrivano da flussi distinti e
  /// con significati distinti: la posizione serve al salvataggio del progresso,
  /// lo stato serve solo a ridisegnare play e pausa.
  StreamSubscription<bool>? _playingSubscription;

  /// Chiude il player liberando il decoder.
  ///
  /// Il tepto e' perche' chiudere un player a meta' apertura, o dopo che la
  /// schermata e' gia' stata smontata, puo' non restituire mai: aspettarlo
  /// bloccherebbe il passaggio alla fonte successiva e l'utente resterebbe a
  /// fissare uno scheletro che non finisce piu'.
  Future<void> _closePlayer() async {
    final player = _player;
    if (player == null) {
      _player = null;
      _videoController = null;
      _resolved = null;
      return;
    }

    _player = null;
    _videoController = null;
    _resolved = null;

    await _positionSubscription?.cancel();
    _positionSubscription = null;
    await _playingSubscription?.cancel();
    _playingSubscription = null;

    try {
      await player
          .dispose()
          .timeout(const Duration(seconds: 3), onTimeout: () {});
    } catch (_) {
      // Un dispose che fallisce non puo' impedire al widget di continuare: il
      // peggio che succede e' un decoder occupato, e la prossima apertura
      // risolve.
    }
  }

  // -------------------------------------------------------------------------
  // Lettura della posizione
  // -------------------------------------------------------------------------

  /// La posizione corrente, se il video e' pronto.
  Duration? get _position {
    final player = _player;
    if (player == null) return null;

    final position = player.state.position;
    return position == Duration.zero ? null : position;
  }

  /// Segue l'avanzamento a ogni notifica del decoder.
  ///
  /// `media_kit` notifica la posizione piu' volte al secondo, quindi qui non si
  /// fa niente di pesante: si avvisa chi ascolta e si controlla la fine. Il
  /// salvataggio con intervallo e' lavoro di [WatchProgressSaver], non del
  /// player — perche' scrivere a ogni tick farebbe una scrittura al secondo.
  void _onPosition(Duration position) {
    if (!mounted) return;
    if (position == Duration.zero) return;

    // Il ridisegno serve a due cose che non si aggiornano da sole: il cursore
    // della barra e l'orologio nell'angolo. Senza, l'interfaccia mostrerebbe il
    // tempo a zero per tutta la riproduzione mentre il video va avanti, e
    // l'utente non avrebbe modo di sapere a che punto e'.
    setState(() {});

    widget.onProgress?.call(position);

    // Un secondo di margine: l'ultima notifica arriva spesso qualche decimo
    // prima della durata dichiarata, e senza il margine la fine non scatterebbe
    // mai.
    final player = _player;
    if (player == null) return;

    // `completed` e' il segnale che `media_kit` dà esplicitamente, ed e' piu'
    // affidabile del confronto posizione/durata: quest'ultimo scatta anche
    // mentre il video e' in pausa a due secondi dalla fine, e segnalerebbe un
    // episodio finito che non e' finito.
    if (player.state.completed) {
      widget.onComplete?.call(position);
      return;
    }

    final total = player.state.duration;
    if (!player.state.playing &&
        total > Duration.zero &&
        position >= total - const Duration(seconds: 1)) {
      widget.onComplete?.call(position);
    }
  }

  /// Ridisegna quando la riproduzione parte o si ferma.
  ///
  /// Serve a mostrare play su pausa e viceversa: senza, il pulsante continuerebbe
  /// a dire "riproduci" mentre il video e' fermo, e premerlo sembrerebbe non
  /// fare niente.
  void _onPlaying(bool playing) {
    if (mounted) setState(() {});
  }

  void _togglePlay() {
    final player = _player;
    if (player == null || !_isReady) return;

    if (player.state.playing) {
      player.pause();
    } else {
      // Riavviare dalla posizione corrente, non dall'inizio: l'utente che
      // aveva fermato per un attimo si aspetta di continuare.
      player.play();
    }
    setState(() {});
  }

  Future<void> _seekTo(double fraction) async {
    final player = _player;
    if (player == null || !_isReady) return;

    final total = player.state.duration;
    if (total <= Duration.zero) return;

    await player.seek(
      Duration(milliseconds: (total.inMilliseconds * fraction).round()),
    );
    if (mounted) setState(() {});
  }

  /// Riapre la sorgente corrente.
  ///
  /// La risoluzione parte da zero: dopo un "Riprova" il token vecchio non ha
  /// piu' senso e va chiesto un link nuovo, ed e' anche l'unico caso in cui un
  /// errore di rete si risolve davvero da solo.
  Future<void> _retry() async {
    setState(() => _error = null);
    await _tryOpen(
      widget.sources[_index],
      resume: false,
      startAt: _position,
    );
  }

  /// Apre il video a tutto schermo, in orizzontale.
  ///
  /// Non si apre una seconda decodifica: si riusa lo stesso
  /// [mkv.VideoController] e la rotta a tutto schermo monta un `mkv.Video`
  /// sullo stesso controller. Quello che cambia e' che la superficie inline
  /// viene spenta prima di spingere la rotta: `media_kit` mostra un solo
  /// `Video` per controller e tenerne due montati insieme — quello inline sotto
  /// e quello a tutto schermo sopra — lascia nero quello visibile. Smontando la
  /// superficie sotto, la rotta a tutto schermo resta l'unica a disegnare il
  /// video.
  ///
  /// La rotazione e la barra di sistema vengono impostate prima di spingere la
  /// rotta e ripristinate quando la rotta si chiude, cosi' l'utente esce dallo
  /// schermo intero anche con il gesto indietro del telefono e non resta
  /// bloccato in orizzontale.
  Future<void> _enterFullscreen() async {
    if (_fullscreen) return;

    final player = _player;
    final controller = _videoController;
    if (player == null || controller == null) return;

    final sources = widget.sources;
    final index = _index;

    // Spegne la superficie inline prima della rotta: e' l'unico modo per non
    // avere due `Video` sullo stesso controller nello stesso momento.
    setState(() => _fullscreen = true);
    try {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

      if (!mounted) return;

      await Navigator.of(context, rootNavigator: true).push<void>(
        PageRouteBuilder<void>(
          opaque: true,
          barrierColor: Colors.black,
          transitionDuration: ArMotion.fast,
          reverseTransitionDuration: ArMotion.fast,
          pageBuilder: (_, _, _) => _FullscreenPlayer(
            player: player,
            controller: controller,
            sourceLabel: sources[index].label,
            onTogglePlay: _togglePlay,
            onSeek: _seekTo,
            onNext: _nextEpisode == null ? null : () => _nextEpisode!(),
            onToggleFullscreen: _exitFullscreen,
          ),
        ),
      );
    } finally {
      // La rotta a tutto schermo e' stata smontata (e con lei il suo `Video`):
      // ora la superficie inline puo' tornare a disegnare.
      if (mounted) setState(() => _fullscreen = false);
      await SystemChrome.setPreferredOrientations([]);
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }

  void _exitFullscreen() {
    Navigator.of(context, rootNavigator: true).maybePop();
  }

  @override
  Widget build(BuildContext context) {
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
              else if (_isExternal)
                _ExternalSourceCard(source: widget.sources[_index])
              else if (_isReady && !_fullscreen)
                _VideoSurface(
                  player: _player!,
                  controller: _videoController!,
                  sourceLabel: widget.sources[_index].label,
                  isPlaying: _player!.state.playing,
                  onTogglePlay: _togglePlay,
                  onSeek: _seekTo,
                  onNext: _nextEpisode == null
                      ? null
                      : () => _nextEpisode!(),
                  onToggleFullscreen: _isReady ? _enterFullscreen : null,
                )
              else if (_isReady)
                // A tutto schermo il video lo disegna la rotta dedicata: qui si
                // lascia solo lo sfondo. Montare anche questa superficie
                // significherebbe due `Video` sullo stesso controller, e
                // `media_kit` ne mostra uno solo lasciando nero l'altro.
                const SizedBox.expand()
              else
                const SkeletonBox(
                  height: double.infinity,
                  radius: 0,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Va alla fonte successiva, se c'e'.
  ///
  /// Il pulsante e' una promessa che l'utente si aspetta di poter onorare: se
  /// non ci sono piu' fonti il pulsante sparisce, invece di restare li' a non
  /// fare niente.
  VoidCallback? get _nextEpisode {
    final index = _index;
    if (index + 1 >= widget.sources.length) return null;
    return () => _open(index + 1, resume: false);
  }
}

/// mm:ss, e h:mm:ss solo quando serve davvero.
String _formatDuration(Duration value) {
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

/// Superficie del video con i comandi sovrapposti.
///
/// I comandi sono dell'app e non quelli del sistema perche' l'obiettivo e'
/// una sola esperienza coerente con il resto di AnimeRank: i controlli nativi
/// su Android e su iOS hanno due aspetti diversi e nessuno dei due somiglia al
/// tema della sezione episodi.
///
/// I comandi stanno *sopra* il video e non in una riga sotto. Su un telefono
/// una barra fissa ruba altezza al video anche quando non serve; sovrapposti,
/// invece, il video resta grande e i comandi compaiono solo quando li si cerca,
/// con lo stesso velo scuro dei player che l'utente conosce.
class _VideoSurface extends StatefulWidget {
  const _VideoSurface({
    required this.player,
    required this.controller,
    required this.sourceLabel,
    required this.isPlaying,
    required this.onTogglePlay,
    required this.onSeek,
    this.onNext,
    this.isFullscreen = false,
    this.onToggleFullscreen,
  });

  final Player player;
  final mkv.VideoController controller;

  /// Nome della fonte in uso, mostrato in alto quando i comandi sono visibili.
  final String sourceLabel;

  final bool isPlaying;
  final VoidCallback onTogglePlay;
  final void Function(double fraction) onSeek;
  final VoidCallback? onNext;

  /// true quando questa superficie e' dentro la rotta a tutto schermo.
  final bool isFullscreen;

  /// Passa a tutto schermo, o ne esce, se c'e' un posto dove andare.
  final VoidCallback? onToggleFullscreen;

  @override
  State<_VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<_VideoSurface> {
  /// Quanto restano a schermo i comandi prima di sparire da soli in play.
  ///
  /// Tre secondi e mezzo: sotto i tre l'utente spesso non fa in tempo a mirare
  /// un pulsante, sopra i quattro i comandi coprono il video piu' del dovuto.
  static const Duration _hideDelay = Duration(milliseconds: 3500);

  /// Di quanto salta un doppio tocco laterale, e i pulsanti ±10.
  static const Duration _skipStep = Duration(seconds: 10);

  bool _controlsVisible = true;
  Timer? _hideTimer;
  Timer? _skipTimer;
  int _skipFeedback = 0;
  int _doubleTapZone = 0;
  double _lastVolume = 100;

  @override
  void initState() {
    super.initState();
    _lastVolume = widget.player.state.volume;
    _scheduleHide();
  }

  @override
  void didUpdateWidget(_VideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      if (widget.isPlaying) {
        _scheduleHide();
      } else {
        // In pausa i comandi restano: nasconderli lascerebbe un fotogramma
        // fermo e l'utente non capirebbe se e' in pausa o bloccato.
        _hideTimer?.cancel();
        _controlsVisible = true;
      }
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _skipTimer?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!widget.isPlaying) return;
    _hideTimer = Timer(_hideDelay, () {
      if (mounted && widget.isPlaying) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _toggleControls() {
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  /// Ricorda in quale terzo dello schermo e' caduto il doppio tocco.
  ///
  /// Il doppio tocco non porta la posizione con se' al momento in cui scatta,
  /// quindi va registrata quando il dito tocca il vetro: e' l'unico modo per
  /// distinguere "avanti" da "indietro" senza chiedere all'utente di mirare.
  void _onDoubleTapDown(TapDownDetails details) {
    final width = context.size?.width ?? 1;
    final dx = details.localPosition.dx;
    if (dx < width / 3) {
      _doubleTapZone = -1;
    } else if (dx > width * 2 / 3) {
      _doubleTapZone = 1;
    } else {
      _doubleTapZone = 0;
    }
  }

  Future<void> _onDoubleTap() async {
    if (_doubleTapZone == 0) {
      widget.onTogglePlay();
      _showControls();
      return;
    }
    await _skipAndFlash(Duration(seconds: _doubleTapZone * 10));
  }

  Future<void> _skipBy(Duration delta) async {
    final player = widget.player;
    final total = player.state.duration;
    var target = player.state.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    await player.seek(target);
    if (mounted) setState(() {});
  }

  Future<void> _skipAndFlash(Duration delta) async {
    await _skipBy(delta);
    _showSkipFeedback(delta.inSeconds);
  }

  void _showSkipFeedback(int seconds) {
    _skipTimer?.cancel();
    setState(() => _skipFeedback = seconds);
    _skipTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _skipFeedback = 0);
    });
  }

  void _setVolume(double value) {
    final volume = value.clamp(0.0, 100.0);
    widget.player.setVolume(volume);
    if (volume > 0) _lastVolume = volume;
    setState(() {});
  }

  void _toggleMute() {
    final current = widget.player.state.volume;
    if (current > 0) {
      _lastVolume = current;
      widget.player.setVolume(0);
    } else {
      // Alzare da zero: si ricorda l'ultimo livello non nullo, altrimenti il
      // pulsante riporterebbe sempre al massimo e perderebbe la posizione.
      widget.player.setVolume(_lastVolume <= 0 ? 100 : _lastVolume);
    }
    setState(() {});
  }

  void _setRate(double rate) {
    widget.player.setRate(rate);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Lo stato si legge qui e non si riceve come parametro: la posizione cambia
    // piu' volte al secondo e `player.state` restituisce sempre l'ultimo valore.
    final state = widget.player.state;
    final visible = _controlsVisible || !widget.isPlaying;

    return Stack(
      fit: StackFit.expand,
      children: [
        mkv.Video(
          controller: widget.controller,
          // I comandi di `media_kit` restano spenti perche' quelli a schermo
          // sono gia' dell'app: due serie di comandi sovrapposte si contendono
          // i tocchi e l'utente preme quello che vede sotto il dito.
          controls: mkv.NoVideoControls,
          fit: BoxFit.contain,
        ),
        // Strato dei gesti: sopra il video e sotto i comandi, sempre attivo. Un
        // tocco singolo mostra o nasconde i comandi, un doppio tocco a sinistra
        // o a destra sposta di dieci secondi, al centro mette in pausa. Le aree
        // vuote dei comandi lasciano passare il tocco fin qui: e' quello che
        // rende il video un grande pulsante per nasconderli.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTapDown: _onDoubleTapDown,
            onDoubleTap: _onDoubleTap,
            child: const SizedBox.expand(),
          ),
        ),
        if (_skipFeedback != 0)
          Positioned.fill(
            child: IgnorePointer(
              child: _SkipFeedback(seconds: _skipFeedback),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: ArMotion.fast,
              child: _ControlsOverlay(
                isPlaying: widget.isPlaying,
                position: state.position,
                duration: state.duration,
                volume: state.volume,
                rate: state.rate,
                sourceLabel: widget.sourceLabel,
                isFullscreen: widget.isFullscreen,
                onTogglePlay: widget.onTogglePlay,
                onSeek: widget.onSeek,
                onSkipBack: () => _skipAndFlash(-_skipStep),
                onSkipForward: () => _skipAndFlash(_skipStep),
                onToggleMute: _toggleMute,
                onVolume: _setVolume,
                onRate: _setRate,
                onNext: widget.onNext,
                onToggleFullscreen: widget.onToggleFullscreen,
                onInteract: _showControls,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// La superficie a tutto schermo.
///
/// E' un widget a se' e non la stessa superficie spostata perche' il video e'
/// gia' decodificato: qui si monta un secondo `mkv.Video` sullo stesso
/// [mkv.VideoController], esattamente come fa `media_kit` per il proprio schermo
/// intero. Una sola decodifica, due viste: e' quello che rende il passaggio
/// istantaneo invece di riaprire il file.
class _FullscreenPlayer extends StatefulWidget {
  const _FullscreenPlayer({
    required this.player,
    required this.controller,
    required this.sourceLabel,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onToggleFullscreen,
    this.onNext,
  });

  final Player player;
  final mkv.VideoController controller;
  final String sourceLabel;
  final VoidCallback onTogglePlay;
  final void Function(double fraction) onSeek;
  final VoidCallback onToggleFullscreen;
  final VoidCallback? onNext;

  @override
  State<_FullscreenPlayer> createState() => _FullscreenPlayerState();
}

class _FullscreenPlayerState extends State<_FullscreenPlayer> {
  final _subscriptions = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    // La rotta non e' figlia del player, quindi non ne eredita i ridisegni:
    // qui ci si abbona direttamente, altrimenti tempo e play/pausa resterebbero
    // fermi al valore di quando si e' entrati.
    _subscriptions.addAll([
      widget.player.stream.playing.listen((_) {
        if (mounted) setState(() {});
      }),
      widget.player.stream.position.listen((_) {
        if (mounted) setState(() {});
      }),
    ]);
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _VideoSurface(
        player: widget.player,
        controller: widget.controller,
        sourceLabel: widget.sourceLabel,
        isPlaying: widget.player.state.playing,
        onTogglePlay: widget.onTogglePlay,
        onSeek: widget.onSeek,
        onNext: widget.onNext,
        isFullscreen: true,
        onToggleFullscreen: widget.onToggleFullscreen,
      ),
    );
  }
}

/// Pulsante grande di play e pausa, al centro del video.
///
/// Sta al centro e non in basso perche' in quel momento l'occhio e' sul centro
/// dello schermo: e' la posizione in cui si cerca il controllo principale, e
/// metterlo in basso costringerebbe a spostare lo sguardo.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.isPlaying, required this.onTap});

  final bool isPlaying;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ArPressable(
      onTap: onTap,
      scale: 0.92,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24),
        ),
        child: SizedBox(
          width: 66,
          height: 66,
          child: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 34,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// Pulsante tondo su fondo scuro, per i salti di dieci secondi.
class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      iconSize: 30,
      color: Colors.white,
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.32),
        shape: const CircleBorder(),
        padding: const EdgeInsets.all(ArSpace.sm),
      ),
    );
  }
}

/// Icona piccola dei comandi in basso, senza sfondo.
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      iconSize: 22,
      color: Colors.white,
      icon: Icon(icon),
    );
  }
}

/// Pastiglia con la velocita' in uso; apre il menu delle velocita'.
///
/// Sono le cinque velocita' che si trovano in qualunque player: sotto 0.5 il
/// parlato non si segue, sopra 2x non si capisce. Il valore corrente e' scritto
/// per esteso ("1.25x") perche' e' l'unico modo per accorgersi di aver lasciato
/// il video accelerato.
class _RateButton extends StatelessWidget {
  const _RateButton({required this.rate, required this.onRate});

  final double rate;
  final void Function(double rate) onRate;

  static const List<double> _rates = [0.5, 0.75, 1, 1.25, 1.5, 2];

  static String _label(double rate) => '${_compact(rate)}x';

  static String _compact(double rate) => rate
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      initialValue: rate,
      onSelected: onRate,
      tooltip: 'Velocita\' di riproduzione',
      color: ArColors.containerHigh,
      itemBuilder: (context) => [
        for (final value in _rates)
          PopupMenuItem<double>(
            value: value,
            child: Text(
              value == rate ? '${_label(value)}  \u2713' : _label(value),
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ArSpace.xs,
          vertical: ArSpace.xs,
        ),
        child: Text(
          _label(rate),
          style: const TextStyle(
            fontFamily: AppTheme.bodyFont,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            fontVariations: [FontVariation('wght', 700)],
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// I comandi sovrapposti al video.
///
/// E' un solo widget per la superficie normale e per quella a tutto schermo,
/// cosi' i due stati non possono divergere: cambiare un pulsante da una parte
/// non lascia l'altra indietro.
class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.volume,
    required this.rate,
    required this.sourceLabel,
    required this.isFullscreen,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onSkipBack,
    required this.onSkipForward,
    required this.onToggleMute,
    required this.onVolume,
    required this.onRate,
    required this.onInteract,
    this.onNext,
    this.onToggleFullscreen,
  });

  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final double volume;
  final double rate;
  final String sourceLabel;
  final bool isFullscreen;
  final VoidCallback onTogglePlay;
  final void Function(double fraction) onSeek;
  final VoidCallback onSkipBack;
  final VoidCallback onSkipForward;
  final VoidCallback onToggleMute;
  final void Function(double volume) onVolume;
  final void Function(double rate) onRate;
  final VoidCallback onInteract;
  final VoidCallback? onNext;
  final VoidCallback? onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds;
    final value = totalMs <= 0
        ? 0.0
        : (position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final muted = volume <= 0;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Velo: in alto per leggere la fonte, in basso per far staccare i
        // comandi dal video. Al centro resta trasparente, perche' e' li' che si
        // guarda. Sta dentro un `IgnorePointer` perche' e' solo colore: se
        // assorbisse i tocchi, il tocco sul video per nascondere i comandi non
        // arriverebbe mai.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x8C000000),
                  Color(0x00000000),
                  Color(0x00000000),
                  Color(0xB3000000),
                ],
                stops: [0, 0.28, 0.6, 1],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(ArSpace.sm),
                child: Row(
                  children: [
                    _SourceBadge(label: sourceLabel),
                    const Spacer(),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _RoundControl(
                      icon: Icons.replay_10_rounded,
                      tooltip: 'Indietro di 10 secondi',
                      onTap: () {
                        onInteract();
                        onSkipBack();
                      },
                    ),
                    const SizedBox(width: ArSpace.lg),
                    _PlayPauseButton(
                      isPlaying: isPlaying,
                      onTap: () {
                        onInteract();
                        onTogglePlay();
                      },
                    ),
                    const SizedBox(width: ArSpace.lg),
                    _RoundControl(
                      icon: Icons.forward_10_rounded,
                      tooltip: 'Avanti di 10 secondi',
                      onTap: () {
                        onInteract();
                        onSkipForward();
                      },
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ArSpace.sm,
                  0,
                  ArSpace.sm,
                  ArSpace.xs,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(_formatTime(position), style: _timeStyle),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              activeTrackColor: ArColors.primary,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: ArColors.primary,
                              overlayColor:
                                  ArColors.primary.withValues(alpha: 0.18),
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                            ),
                            child: Slider(
                              value: value,
                              onChangeStart: (_) => onInteract(),
                              onChanged: (v) {
                                onInteract();
                                onSeek(v);
                              },
                              onChangeEnd: (_) => onInteract(),
                            ),
                          ),
                        ),
                        Text(_formatTime(duration), style: _timeStyle),
                      ],
                    ),
                    Row(
                      children: [
                        _RoundIconButton(
                          icon: muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          tooltip: muted ? 'Riattiva l\'audio' : 'Silenzia',
                          onTap: () {
                            onInteract();
                            onToggleMute();
                          },
                        ),
                        SizedBox(
                          width: 84,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2,
                              activeTrackColor: Colors.white,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: Colors.white,
                              overlayColor: Colors.white24,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 5,
                              ),
                            ),
                            child: Slider(
                              value: (volume / 100).clamp(0.0, 1.0),
                              onChanged: (v) {
                                onInteract();
                                onVolume(v * 100);
                              },
                            ),
                          ),
                        ),
                        const Spacer(),
                        _RateButton(
                          rate: rate,
                          onRate: (value) {
                            onInteract();
                            onRate(value);
                          },
                        ),
                        if (onToggleFullscreen != null)
                          _RoundIconButton(
                            icon: isFullscreen
                                ? Icons.fullscreen_exit_rounded
                                : Icons.fullscreen_rounded,
                            tooltip: isFullscreen
                                ? 'Esci dallo schermo intero'
                                : 'Schermo intero',
                            onTap: () {
                              onInteract();
                              onToggleFullscreen!();
                            },
                          ),
                        if (onNext != null)
                          _RoundIconButton(
                            icon: Icons.skip_next_rounded,
                            tooltip: 'Prova la fonte successiva',
                            onTap: () {
                              onInteract();
                              onNext!();
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const TextStyle _timeStyle = TextStyle(
    fontFamily: AppTheme.bodyFont,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    fontVariations: [FontVariation('wght', 600)],
    color: Colors.white,
  );

  static String _formatTime(Duration value) => _formatDuration(value);
}

/// Velo laterale che conferma un salto di dieci secondi.
///
/// Compare dal lato verso cui si e' saltato: senza, un doppio tocco non
/// lascerebbe traccia e sembrerebbe che non sia successo niente.
class _SkipFeedback extends StatelessWidget {
  const _SkipFeedback({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    final forward = seconds > 0;
    return Align(
      alignment: forward ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: 0.42,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.28),
            borderRadius: BorderRadius.circular(ArRadii.card),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                forward
                    ? Icons.fast_forward_rounded
                    : Icons.fast_rewind_rounded,
                color: Colors.white,
                size: 26,
              ),
              const SizedBox(height: ArSpace.xxs),
              Text(
                '${forward ? '+' : '-'}${seconds.abs()}s',
                style: const TextStyle(
                  fontFamily: AppTheme.bodyFont,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontVariations: [FontVariation('wght', 700)],
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pastiglia con la qualita' della fonte in uso.
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.label});

  final String label;

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
        label,
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

    // La scheda apre l'indirizzo riproducibile se c'e', altrimenti il canonico.
    // Su una fonte `iframe` i due non coincidono: il canonico e' la pagina del
    // provider, ed e' quella che si deve aprire al di fuori dell'app.
    final target = source.playbackAddress;
    final uri = target == null ? null : Uri.tryParse(target);

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
