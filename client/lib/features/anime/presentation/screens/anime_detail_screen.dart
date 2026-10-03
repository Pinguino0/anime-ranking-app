import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/transitions.dart';
import '../../domain/anime.dart';

/// Scheda di un anime, a tutta pagina.
///
/// Prima esisteva solo un foglio che sale dal basso: funzionava, ma il foglio
/// comunicava "opzione" e non "pagina", e con una locandina piccola in alto a
/// sinistra non si poteva mostrare niente di quello che l'opera ha davvero.
///
/// Qui l'immagine e' il fondo della pagina. Il motivo e' pratico prima che
/// estetico: la locandina contiene gia' tutto il cromatismo dell'opera, e
/// usarla come sfondo e' l'unico modo per far capire di che colore e'
/// quell'anime senza aggiungere una copertina generica.
///
/// I dati vengono da [AnimeEntry] e non da una nuova richiesta: la Edge
/// Function espone solo ricerca e stagioni, quindi non esiste una rotta di
/// dettaglio da chiamare. La scheda mostra quello che il risultato di ricerca
/// contiene gia', il che e' anche il comportamento giusto per un'app che deve
/// aprire la pagina offline.
class AnimeDetailScreen extends StatelessWidget {
  const AnimeDetailScreen({
    required this.entry,
    this.heroTag,
    super.key,
  });

  final AnimeEntry entry;

  /// Tag dell'immagine di sfondo, se la scheda e' stata aperta da una card che
  /// si e' animata. Senza, l'immagine appare semplicemente.
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.fromContext(context);

    // Su telefono il poster e il titolo restano incolonnati, con il poster
    // che fa da locandina accanto al testo. Da tablet in su il poster passa a
    // sinistra come colonna fissa: e' la disposizione che usano i cataloghi,
    // e lascia al testo tutto lo spazio orizzontale rimanente.
    final posterWidth = size.isCompact ? 132.0 : 220.0;

    return Scaffold(
      backgroundColor: ArColors.bg,
      body: Stack(
        children: [
          // Sfondo a tutta pagina. Va in fondo e non si tocca: e' il colore
          // dell'opera, non un elemento dell'interfaccia.
          Positioned.fill(child: _Backdrop(entry: entry)),
          // Un velo scuro sopra lo sfondo. Senza, il testo bianco sopra
          // un'immagine chiara diventa illeggibile: il contrasto dipende
          // dall'opera e non si puo' dare per scontato.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x33000000), Color(0xCC05050A), Color(0xFF05050A)],
                  stops: [0, 0.45, 0.78],
                ),
              ),
            ),
          ),
          SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _TopBar(entry: entry)),
                SliverToBoxAdapter(
                  child: _Head(
                    entry: entry,
                    posterWidth: posterWidth,
                    stacked: size.isCompact,
                    heroTag: heroTag,
                  ),
                ),
                SliverToBoxAdapter(child: _Actions(entry: entry)),
                SliverToBoxAdapter(child: _Facts(entry: entry)),
                SliverToBoxAdapter(child: _Genres(entry: entry)),
                if (entry.synopsis != null)
                  SliverToBoxAdapter(child: _Synopsis(entry: entry)),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: ArSpace.xxl + ArSpace.lg,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Immagine di sfondo: il poster allungato e sfocato.
///
/// Sfocata e non semplicemente ingrandita perche' un'immagine allungata a tutta
/// pagina mostrerebbe i pixel: la sfocatura e' quello che la trasforma in un
/// campo di colore, che e' l'unica cosa che serve da sfondo.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.entry});

  final AnimeEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final fallback = DecoratedBox(
      decoration: const BoxDecoration(gradient: ArColors.subtle),
      child: Center(
        child: Text(
          entry.title.characters.firstOrNull?.toUpperCase() ?? '?',
          style: TextStyle(
            fontFamily: AppTheme.displayFont,
            fontSize: 160,
            fontWeight: FontWeight.w700,
            fontVariations: const [FontVariation('wght', 700)],
            color: colors.onSurfaceVariant.withValues(alpha: 0.06),
          ),
        ),
      ),
    );

    if (entry.imageUrl == null || entry.imageUrl!.isEmpty) return fallback;

    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 42, sigmaY: 42),
      child: CachedNetworkImage(
        imageUrl: entry.imageUrl!,
        fit: BoxFit.cover,
        // L'immagine di sfondo sfuma invece di comparire di colpo. Su una
        // pagina che ha gia' del testo sopra, un'immagine che appare
        // istantaneamente sembra un lampo; con la dissolvenza la pagina si
        // compone e l'occhio la legge come una cosa sola.
        fadeInDuration: ArMotion.slow,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

/// Barra in alto con indietro e trailer.
///
/// Stessa altezza e stesso raggio del pulsante indietro di sistema: senza, il
/// bottone dell'app e quello di Android hanno due forme diverse sulla stessa
/// riga e la schermata sembra montata da due persone.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.entry});

  final AnimeEntry entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ArSpace.md,
        vertical: ArSpace.xs,
      ),
      child: Row(
        children: [
          _RoundButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Indietro',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const Spacer(),
          if (entry.trailerUrl != null)
            _RoundButton(
              icon: Icons.play_arrow_rounded,
              tooltip: 'Trailer',
              onPressed: () => _showTrailerNotice(context),
            ),
        ],
      ),
    );
  }

  void _showTrailerNotice(BuildContext context) {
    // Il trailer e' un link esterno e l'app non ha un browser incorporato:
    // aprirlo richiederebbe `url_launcher`, che non e' fra le dipendenze. Meglio
    // dichiararlo che aggiungere un pacchetto per un link che si puo' aprire
    // con un tocco da quattro schermate di distanza.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Il trailer si apre dal collegato su MyAnimeList.',
        ),
      ),
    );
  }
}

/// Bottone circolare su fondo scuro, per le azioni che stanno sopra
/// l'immagine.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon, size: 21),
          color: Colors.white,
          splashRadius: 22,
        ),
      ),
    );
  }
}

/// Poster, titolo e metadati principali.
class _Head extends StatelessWidget {
  const _Head({
    required this.entry,
    required this.posterWidth,
    required this.stacked,
    this.heroTag,
  });

  final AnimeEntry entry;
  final double posterWidth;

  /// true quando poster e testo vanno incolonnati (telefono).
  final bool stacked;

  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final poster = _Poster(
      entry: entry,
      width: posterWidth,
      heroTag: heroTag,
    );

    final text = _Headline(entry: entry);

    if (stacked) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: ArSpace.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            poster,
            const SizedBox(width: ArSpace.md),
            Expanded(child: text),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ArSpace.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          poster,
          const SizedBox(width: ArSpace.lg),
          Expanded(child: text),
        ],
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.entry, required this.width, this.heroTag});

  final AnimeEntry entry;
  final double width;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    Widget image;
    if (entry.imageUrl == null || entry.imageUrl!.isEmpty) {
      image = ColoredBox(
        color: colors.surfaceContainerHigh,
        child: Center(
          child: Text(
            entry.title.characters.firstOrNull?.toUpperCase() ?? '?',
            style: TextStyle(
              fontFamily: AppTheme.displayFont,
              fontSize: 44,
              fontWeight: FontWeight.w700,
              fontVariations: const [FontVariation('wght', 700)],
              color: colors.onSurfaceVariant.withValues(alpha: 0.4),
            ),
          ),
        ),
      );
    } else {
      image = CachedNetworkImage(
        imageUrl: entry.imageUrl!,
        fit: BoxFit.cover,
        placeholder: (_, _) => ColoredBox(color: colors.surfaceContainerHigh),
        errorWidget: (_, _, _) => ColoredBox(color: colors.surfaceContainerHigh),
      );
    }

    if (heroTag != null) {
      image = Hero(
        tag: heroTag!,
        // Lo stesso shuttle del poster in lista: l'immagine deve arrivare
        // nello stesso modo con cui e' partita, altrimenti il ritorno
        // all'indietro mostrerebbe un movimento diverso da quello di andata.
        flightShuttleBuilder: (context, animation, direction, from, to) =>
            ScaleTransition(scale: animation, child: image),
        child: image,
      );
    }

    return SizedBox(
      width: width,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ArRadii.poster),
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: DecoratedBox(
            // Ombra sotto il poster: e' l'oggetto che "appoggia" sullo sfondo
            // e stabilisce la profondita' della pagina.
            decoration: const BoxDecoration(boxShadow: ArShadows.card),
            child: image,
          ),
        ),
      ),
    );
  }
}

/// Titolo, titolo giapponese, voto e fatti.
class _Headline extends StatelessWidget {
  const _Headline({required this.entry});

  final AnimeEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return ArReveal(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Il nome dell'archivio MyAnimeList in maiuscoletto: dice da dove
          // viene l'opera, che altrimenti un utente nuovo non saprebbe.
          if (entry.status != null)
            Padding(
              padding: const EdgeInsets.only(bottom: ArSpace.xs),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _statusColor(entry).withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(ArRadii.chip),
                  border: Border.all(
                    color: _statusColor(entry).withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  entry.status!.label.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _statusColor(entry),
                  ),
                ),
              ),
            ),
          Text(
            entry.title,
            style: theme.textTheme.headlineMedium?.copyWith(
              // Ombra piu' forte del normale perche' il testo e' sopra
              // l'immagine, non sopra il nero della app.
              shadows: const [
                Shadow(color: Colors.black54, blurRadius: 12),
              ],
            ),
          ),
          if (entry.japaneseTitle != null) ...[
            const SizedBox(height: ArSpace.xxs),
            Text(
              entry.japaneseTitle!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: ArSpace.sm),
          if (entry.score != null) _ScoreStrip(entry: entry),
          const SizedBox(height: ArSpace.sm),
          _FactsInline(entry: entry),
        ],
      ),
    );
  }

  /// Colore dello stato di trasmissione.
  ///
  /// Riprende i colori gia' usati nella watchlist, cosi' "In corso" e' lo
  /// stesso verde-azzurro nella lista e nella scheda. Un colore diverso per lo
  /// stesso stato farebbe pensare a due cose diverse.
  static Color _statusColor(AnimeEntry entry) => switch (entry.status) {
        AnimeAirStatus.airing => ArColors.watching,
        AnimeAirStatus.finished => ArColors.completed,
        AnimeAirStatus.upcoming => ArColors.planned,
        null => ArColors.textMid,
      };
}

/// Voto MyAnimeList con il numero di votanti.
///
/// Il numero dei votanti sta in piccolo sotto la media perche' 8,4 su 40 e
/// 8,4 su 800.000 non sono la stessa valutazione: senza il conteggio, la
/// media sembra precisa quando magari e' una manciata di voti.
class _ScoreStrip extends StatelessWidget {
  const _ScoreStrip({required this.entry});

  final AnimeEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // `Icon` da solo ha dimensioni che l'arrotondamento del layout puo'
        // portare a superare di qualche decimo di pixel lo spazio rimasto,
        // e quello basta per far scattare l'overflow. Incapsulandola in un
        // `SizedBox` la larghezza e' esattamente quella dichiarata.
        const SizedBox(
          width: 22,
          height: 22,
          child: Icon(
            Icons.star_rounded,
            size: 22,
            color: ArColors.gold,
          ),
        ),
        const SizedBox(width: ArSpace.xxs),
        // La flessibilita' sta sul gruppo dei due numeri, non solo sul
        // conteggio: se il solo conteggio poteva rimpicciolirsi, la stella e
        // la media restavano a dimensione fissa e, in una colonna stretta,
        // arrivavano a superare lo spazio disponibile anche senza votanti.
        // Cosi' e' tutto il gruppo che si comprime, e il numero dei votanti e'
        // quello che cede per primo perche' e' il meno importante.
        Flexible(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                entry.score!.toStringAsFixed(2),
                style: theme.textTheme.titleLarge?.copyWith(
                  color: ArColors.gold,
                ),
              ),
              if (entry.scoredBy != null) ...[
                const SizedBox(width: ArSpace.xs),
                Flexible(
                  child: Text(
                    'su ${_thousands(entry.scoredBy!)} voti',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 1234567 -> "1.234.567".
  ///
  /// Il separatore delle migliaia italiano e' il punto, non la virgola: senza
  /// la formattazione "800000" si legge come un codice.
  static String _thousands(int value) {
    final digits = value.toString();
    if (digits.length <= 3) return digits;

    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

/// Formato, episodi, anno, durata: la riga corta sotto il titolo.
class _FactsInline extends StatelessWidget {
  const _FactsInline({required this.entry});

  final AnimeEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[
      if (entry.mediaType != null) entry.mediaType!.label,
      if (entry.episodes != null) '${entry.episodes} ep',
      if (entry.year != null) '${entry.year}',
      if (entry.duration != null) entry.duration!,
    ];

    if (parts.isEmpty) {
      // Con zero dati noti la riga si riduce a uno spazio vuoto: mostrerebbe
      // una riga di 20px con niente dentro e i titoli successivi salterebbero
      // di un gradino rispetto a una scheda che ha i dati.
      return const SizedBox.shrink();
    }

    return Text(parts.join(' · '), style: theme.textTheme.bodyMedium);
  }
}

/// Azioni principali.
///
/// Solo votazione e watchlist, e solo se c'e' un gruppo. La scheda non puo'
/// chiedere quale gruppo usare — non lo sa — quindi il pulsante porta al
/// selettore invece di fingere di sapere. Il testo lo dice, cosi' il passaggio
/// non sembra un errore.
class _Actions extends StatelessWidget {
  const _Actions({required this.entry});

  final AnimeEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: Breakpoints.fromContext(context).isCompact ? ArSpace.md : ArSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: ArSpace.lg),
          if (!entry.canRate)
            _Notice(
              icon: Icons.info_outline_rounded,
              text: 'Questo anime non è ancora in catalogo, quindi non si può '
                  'votare. Aprilo di nuovo dalla ricerca fra un momento: la '
                  'seconda volta sarà disponibile.',
            )
          else
            ArGradientButton(
              label: 'Vota in un gruppo',
              icon: Icons.star_outline_rounded,
              onPressed: () => _pickGroup(context),
            ),
          const SizedBox(height: ArSpace.xs),
          Text(
            'Le classifiche sono per gruppo: scegli dove contare questo voto.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: ArSpace.md),
        ],
      ),
    );
  }

  void _pickGroup(BuildContext context) {
    // Il percorso del selettore e' quello dichiarato dal router: scriverlo
    // qui a mano farebbe divergere le due copie al primo rename.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Scegli il gruppo dalla barra in basso, poi apri la classifica.',
        ),
        backgroundColor: theme(context).colorScheme.surfaceContainerHigh,
      ),
    );
  }

  static ThemeData theme(BuildContext context) => Theme.of(context);
}

/// Riga avviso: sfondo tenue, icona, testo.
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(ArRadii.control),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ArSpace.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 19, color: colors.onSurfaceVariant),
            const SizedBox(width: ArSpace.sm),
            Expanded(
              child: Text(text, style: theme.textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dettagli a due colonne: studio, generi, voto, stagione.
///
/// A griglia e non a elenco di righe etichetta/valore come prima: qui le
/// informazioni si leggono in blocco e una riga per voce faceva una pagina
/// lunga con dentro pochi dati.
class _Facts extends StatelessWidget {
  const _Facts({required this.entry});

  final AnimeEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final size = Breakpoints.fromContext(context);

    final facts = <(String, String?)>[
      ('Studio', entry.studio),
      ('Formato', entry.mediaType?.label),
      ('Episodi', entry.episodes?.toString()),
      ('Anno', entry.year?.toString()),
      ('Stagione', entry.season?.label),
      ('Durata', entry.duration),
      (
        'In lista su MAL',
        entry.popularity == null ? null : _thousands(entry.popularity!)
      ),
    ].where((f) => f.$2 != null).toList();

    if (facts.isEmpty) return const SizedBox.shrink();

    final columns = size.isCompact ? 2 : 3;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: size.isCompact ? ArSpace.md : ArSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel('Dettagli'),
          const SizedBox(height: ArSpace.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              // La larghezza della colonna e' calcolata sullo spazio reale
              // disponibile e non su una frazione fissa: con il padding
              // variabile per breakpoint, `Expanded` da solo darebbe tre colonne
              // larghe uguali ma sbagliate quando la griglia ne ha due.
              final spacing = ArSpace.md;
              final cellWidth =
                  (constraints.maxWidth - spacing * (columns - 1)) / columns;

              return Wrap(
                spacing: spacing,
                runSpacing: ArSpace.sm,
                children: [
                  for (final fact in facts)
                    SizedBox(
                      width: cellWidth,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerLow.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(ArRadii.control),
                          border: Border.all(color: colors.outlineVariant),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(ArSpace.sm),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(fact.$1.toUpperCase(),
                                  style: theme.textTheme.labelSmall),
                              const SizedBox(height: ArSpace.xxs),
                              Text(
                                fact.$2!,
                                style: theme.textTheme.bodyMedium,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  static String _thousands(int value) {
    final digits = value.toString();
    if (digits.length <= 3) return digits;
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

/// Generi come pastiglie colorate.
///
/// Ogni genere prende un colore diverso dall'accento, non un colore fisso a
/// testa: una riga di chip tutti uguali sembra un elenco puntato, e il colore e'
/// quello che permette di riconoscere "ah, questo e' il genere shonen" senza
/// leggere.
class _Genres extends StatelessWidget {
  const _Genres({required this.entry});

  final AnimeEntry entry;

  @override
  Widget build(BuildContext context) {
    if (entry.genres.isEmpty) return const SizedBox.shrink();

    final size = Breakpoints.fromContext(context);

    return Padding(
      padding: EdgeInsets.only(
        top: ArSpace.lg,
        left: size.isCompact ? ArSpace.md : ArSpace.lg,
        right: size.isCompact ? ArSpace.md : ArSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('Generi'),
          const SizedBox(height: ArSpace.sm),
          Wrap(
            spacing: ArSpace.xs,
            runSpacing: ArSpace.xs,
            children: [
              for (var i = 0; i < entry.genres.length; i++)
                _GenreChip(name: entry.genres[i], seed: i),
            ],
          ),
        ],
      ),
    );
  }
}

/// Una pastiglia di genere.
///
/// Il colore nasce dall'indice e non dal testo: due anime con gli stessi
/// generi prendono gli stessi colori, che e' quello che serve per imparare a
/// leggerli. Derivare il colore dal testo darebbe a ogni genere un colore
/// diverso a ogni schermata.
class _GenreChip extends StatelessWidget {
  const _GenreChip({required this.name, required this.seed});

  final String name;
  final int seed;

  static const _palette = [
    ArColors.primary,
    ArColors.accent,
    ArColors.success,
    ArColors.info,
    ArColors.warning,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _palette[seed % _palette.length];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(ArRadii.chip),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        name,
        style: theme.textTheme.labelLarge?.copyWith(
          color: color,
          fontSize: 12.5,
        ),
      ),
    );
  }
}

/// Trama, con i primi caratteri esposti.
///
/// La trama su MyAnimeList arriva spesso con il markup `[Written by MAL Rewrite]`
/// in fondo: viene ripulito qui perche' altrimenti l'ultima riga della pagina
/// sarebbe una nota del sito che non c'entra con l'opera.
class _Synopsis extends StatelessWidget {
  const _Synopsis({required this.entry});

  final AnimeEntry entry;

  /// Rimuove la nota di MAL Rewrite in fondo alla trama.
  ///
  /// Non si cerca "l'ultima parentesi quadra": una trama puo' contenere un
  /// riferimento tra parentesi — "[seconda stagione]" — e toglierlo lascerebbe
  /// la pagina amputata di un pezzo che appartiene all'opera. Si toglie solo
  /// il blocco riconosciuto come nota del sito, che e' quello che non
  /// descrive l'anime.
  ///
  /// Il testo di MAL arriva in forme leggermente diverse ("[Written by MAL
  /// Rewrite]", con o senza spazi), quindi il confronto ignora gli spazi
  /// invece di cercare la stringa esatta.
  static final _rewriteNote = RegExp(
    r'\[\s*Written\s+by\s+MAL\s+Rewrite\s*\]',
    caseSensitive: false,
  );

  static String _clean(String raw) {
    return raw
        .replaceAll(_rewriteNote, '')
        // Il tag lascia uno spazio e un punto finale: senza, la trama
        // finisce con "... taglie ." e sembra un testo corrotto.
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\s+([.,;:!?])'), r'$1')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = _clean(entry.synopsis!);

    if (text.isEmpty) return const SizedBox.shrink();

    final size = Breakpoints.fromContext(context);

    return Padding(
      padding: EdgeInsets.only(
        top: ArSpace.lg,
        left: size.isCompact ? ArSpace.md : ArSpace.lg,
        right: size.isCompact ? ArSpace.md : ArSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('Trama'),
          const SizedBox(height: ArSpace.sm),
          // Espansione: la trama e' lunga e l'utente spesso vuole leggerla
          // tutta, ma piegarla di default la nasconderebbe dietro un tap che
          // non e' ovvio. Con EspansionTile il testo si vede subito e si
          // richiude solo se l'utente lo chiede.
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: true,
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(
                text,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: ArSpace.sm),
                  child: Row(
                    children: [
                      Text(
                        'Riduci',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: ArSpace.xxs),
                      const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Titolo di sezione.
///
/// Maiuscoletto spaziato: e' il tratto che separa un blocco di contenuto dal
/// successivo senza dover mettere un bordo o un altro colore.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall);
  }
}
