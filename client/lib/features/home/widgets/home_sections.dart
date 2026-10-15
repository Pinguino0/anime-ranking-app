import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_failure.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/anime_card.dart';
import '../../../core/ui/content_row.dart';
import '../../../core/ui/section_header.dart';
import '../../../core/ui/transitions.dart';
import '../../anime/domain/anime.dart';
import '../../history/domain/watch_history.dart';
import '../../watchlist/domain/watchlist.dart';
import '../../watchlist/presentation/watchlist_controller.dart';
import '../domain/friend_activity.dart';
import '../home_controller.dart';

/// Colore semantico di uno stato della watchlist.
///
/// Uno solo per tutta la home: lo stato di un anime deve avere lo stesso colore
/// nella riga "Riprendi dalla watchlist" e nel badge di una card, altrimenti
/// "In visione" sembra due cose diverse.
Color watchStatusColor(WatchStatus status) => switch (status) {
  WatchStatus.planned => ArColors.planned,
  WatchStatus.watching => ArColors.watching,
  WatchStatus.completed => ArColors.completed,
  WatchStatus.dropped => ArColors.dropped,
  WatchStatus.paused => ArColors.paused,
};

/// Colore semantico dello stato di messa in onda.
Color airStatusColor(AnimeAirStatus status) => switch (status) {
  AnimeAirStatus.airing => ArColors.success,
  AnimeAirStatus.upcoming => ArColors.warning,
  AnimeAirStatus.finished => ArColors.textLow,
};

/// Numero compatto: `987`, `12.3K`, `1.1M`.
///
/// La popolarita' del catalogo arriva a sette cifre: scritta per intero su una
/// card larga 150px andrebbe a capo o verrebbe troncata, e "1.1M" risponde alla
/// stessa domanda senza far contare gli zeri.
String compactNumber(int value) {
  if (value < 1000) return '$value';
  if (value < 1000000) return '${_trimDecimal(value / 1000)}K';
  return '${_trimDecimal(value / 1000000)}M';
}

/// Un decimale, senza lo `.0` finale.
String _trimDecimal(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// La cronologia come riga della home: un anime per card, i piu' recenti prima.
///
/// Due regole, entrambe per non ripetere quello che c'e' gia' sopra:
///  - [excludeAnimeIds] toglie le opere che sono in "Continua a guardare": la
///    stessa locandina due righe di distanza sembra un errore di caricamento.
///  - una voce per anime: la cronologia ha una riga per episodio, ma "Guardati
///    di recente" parla di opere, e la E3 e la E4 dello stesso titolo viste una
///    dopo l'altra non sono due scoperte diverse.
List<WatchHistoryItem> recentlyWatched(
  List<WatchHistoryItem> rows, {
  required Set<String> excludeAnimeIds,
  int limit = homeRowSize,
}) {
  final seen = <String>{};
  final picked = <WatchHistoryItem>[];

  for (final row in rows) {
    if (excludeAnimeIds.contains(row.animeId)) continue;
    if (!seen.add(row.animeId)) continue;
    picked.add(row);
    if (picked.length >= limit) break;
  }

  return picked;
}

/// Cosa far riprendere dalla watchlist: prima quello che e' gia' iniziato, poi
/// quello che si era solo segnato da vedere.
///
/// Le opere finite e abbandonate restano fuori: comparire in "Riprendi" un
/// titolo che l'utente ha dichiarato concluso sarebbe un invito sbagliato.
List<WatchlistEntry> watchlistResume(
  List<WatchlistEntry> entries, {
  int limit = homeRowSize,
}) {
  final watching = <WatchlistEntry>[];
  final planned = <WatchlistEntry>[];

  for (final entry in entries) {
    switch (entry.status) {
      case WatchStatus.watching:
        watching.add(entry);
      case WatchStatus.planned:
        planned.add(entry);
      case WatchStatus.completed:
      case WatchStatus.dropped:
      case WatchStatus.paused:
        break;
    }
  }

  return [...watching, ...planned].take(limit).toList();
}

/// Prima frase della sinossi, limitata a [limit] caratteri.
///
/// Non un troncamento con i puntini: la sinossi del catalogo esterno finisce
/// spesso a meta' frase, e i "..." su un periodo interrotto fanno pensare a un
/// testo corrotto. Si chiude sull'ultimo punto fermo che si trova nella meta'
/// finale del taglio, cosi' la frase resta tutta.
String? shortSynopsis(String? text, {int limit = 220}) {
  if (text == null || text.trim().isEmpty) return null;

  final clean = text.trim();
  if (clean.length <= limit) return clean;

  final cut = clean.substring(0, limit);
  final stop = cut.lastIndexOf(RegExp(r'[.!?]'));
  return stop > limit ~/ 2 ? cut.substring(0, stop + 1) : '$cut...';
}

/// Data in forma breve: "adesso", "12 min", "3 h", "ieri", "4 g", "05/03/2026".
///
/// La stessa forma usata dai commenti: una data assoluta su un'attivita' di
/// poche ore fa obbliga a fare il conto a mente, mentre "2 h" risponde subito
/// alla domanda "quanto e' recente".
String relativeDate(DateTime at, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(at);
  if (diff.inMinutes < 1) return 'adesso';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min';
  if (diff.inHours < 24) return '${diff.inHours} h';
  if (diff.inDays == 1) return 'ieri';
  if (diff.inDays < 7) return '${diff.inDays} g';
  final day = at.day.toString().padLeft(2, '0');
  final month = at.month.toString().padLeft(2, '0');
  return '$day/$month/${at.year}';
}

/// Pastiglia leggibile sopra una locandina.
///
/// Non riusa [StatusPill] perche' quella e' pensata per una superficie: sopra
/// un'immagine arbitraria serve un fondo scuro, altrimenti un bordo colorato su
/// una foto chiara sparisce.
class HomeBadge extends StatelessWidget {
  const HomeBadge({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ArColors.bg.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(ArRadii.chip),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                height: 1.1,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sezione della home con i suoi tre stati.
///
/// Una sezione non e' mai "o dati o niente": mentre carica mostra uno scheletro
/// e se fallisce mostra l'errore **solo lei**, con il suo "Riprova". Cosi' un
/// guasto del feed social non porta via anche il catalogo, e la home non
/// diventa una pagina di errore per una riga sola.
///
/// Quando l'elenco e' vuoto la sezione sparisce del tutto: uno spazio con la
/// scritta "nessun contenuto" e' peggio di una sezione in meno.
class HomeSection<T> extends StatelessWidget {
  const HomeSection({
    super.key,
    required this.title,
    this.subtitle,
    this.onSeeAll,
    required this.value,
    required this.itemBuilder,
    this.onRetry,
    this.itemWidth,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onSeeAll;

  final AsyncValue<List<T>> value;

  /// Costruisce una card. La larghezza la decide [ContentRow].
  final Widget Function(BuildContext context, T item) itemBuilder;

  final VoidCallback? onRetry;
  final double? itemWidth;

  @override
  Widget build(BuildContext context) {
    // `hasValue` resta vero anche durante un aggiornamento: mentre la sezione
    // si rinfresca si continua a mostrare quello che c'era, invece di
    // sostituirlo con uno scheletro e far "saltare" la pagina.
    if (!value.hasValue) {
      if (value.hasError) {
        return HomeSectionError(
          title: title,
          subtitle: subtitle,
          message: _messageOf(value.error),
          onRetry: onRetry,
        );
      }
      return HomeSectionSkeleton(title: title);
    }

    final items = value.requireValue;
    if (items.isEmpty) return const SizedBox.shrink();

    return ContentRow(
      title: title,
      subtitle: subtitle,
      onSeeAll: onSeeAll,
      itemWidth: itemWidth,
      itemCount: items.length,
      itemBuilder: (context, index) => itemBuilder(context, items[index]),
    );
  }

  static String _messageOf(Object? error) {
    if (error is AppFailure) return error.message;
    return 'Non si è riusciti a caricare questa sezione.';
  }
}

/// Scheletro di una sezione: intestazione vera, poster finti.
///
/// Il titolo e' quello reale perche' la pagina mantenga la sua struttura
/// mentre arriva il contenuto, invece di crescere a scatti man mano.
class HomeSectionSkeleton extends StatelessWidget {
  const HomeSectionSkeleton({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final horizontal = ArSpace.page(context).left;
    final available = MediaQuery.sizeOf(context).width - horizontal * 2;
    final count = switch (available) {
      < 320 => 2,
      < 520 => 3,
      < 760 => 4,
      < 1040 => 5,
      _ => 6,
    };
    // Stessa formula di `ContentRow`, senza aggiustamenti: lo scheletro deve
    // avere le stesse misure della riga vera, altrimenti la pagina si assesta
    // di scatto quando i dati arrivano.
    final cardWidth = (available - ArSpace.sm * (count - 1)) / count;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ArSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // L'intestazione si posiziona da sola: aggiungere un altro padding
          // l'allontanerebbe dal titolo delle righe vere e la pagina
          // sembrerebbe scossa.
          SectionHeader(title: title),
          const SizedBox(height: ArSpace.sm),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontal),
            child: Row(
              children: [
                for (var i = 0; i < count; i++) ...[
                  SkeletonBox(
                    width: cardWidth,
                    height: cardWidth * 3 / 2,
                    radius: ArRadii.card,
                  ),
                  if (i < count - 1) const SizedBox(width: ArSpace.sm),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Errore di una singola sezione, compatto.
///
/// Diverso da [ErrorState], che occupa una pagina intera: qui l'errore sta
/// dentro una home che per il resto funziona, quindi non deve prendersi lo
/// schermo. Mostra titolo, motivo e un "Riprova" solo se la sezione sa
/// ricaricarsi.
class HomeSectionError extends StatelessWidget {
  const HomeSectionError({
    super.key,
    required this.title,
    this.subtitle,
    required this.message,
    this.onRetry,
  });

  final String title;
  final String? subtitle;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final horizontal = ArSpace.page(context).left;

    return Padding(
      // Solo verticale: l'orizzontale lo aggiungono i singoli blocchi, che
      // sanno dove deve iniziare ciascuno.
      padding: const EdgeInsets.symmetric(vertical: ArSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Si posiziona da sola col suo padding: un wrapping in piu'
          // sposterebbe il titolo di errore dal titolo delle righe a fianco.
          SectionHeader(title: title, subtitle: subtitle),
          const SizedBox(height: ArSpace.sm),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontal),
            child: Container(
              padding: const EdgeInsets.all(ArSpace.md),
              decoration: BoxDecoration(
                color: ArColors.containerLow,
                borderRadius: BorderRadius.circular(ArRadii.card),
                border: Border.all(color: ArColors.borderSoft),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.cloud_off,
                    size: 20,
                    color: ArColors.textLow,
                  ),
                  const SizedBox(width: ArSpace.sm),
                  Expanded(
                    child: Text(
                      message,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: ArColors.textMid,
                      ),
                    ),
                  ),
                  if (onRetry != null)
                    TextButton(onPressed: onRetry, child: const Text('Riprova')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Locandina con testo in basso, per le sezioni che raccontano uno stato.
///
/// [AnimeCard] spiega "ecco un'opera" e mostra i generi; questa card spiega
/// "ecco dove sei arrivato" e mostra stato e progresso. Sono due domande
/// diverse e con una card sola o l'una o l'altra resterebbe senza risposta.
class HomePosterCard extends StatelessWidget {
  const HomePosterCard({
    super.key,
    required this.title,
    required this.imageUrl,
    this.subtitle,
    this.badge,
    this.progress,
    this.onTap,
  });

  final String title;
  final String? imageUrl;
  final String? subtitle;

  /// Pastiglia gia' pronta, in alto a sinistra.
  final Widget? badge;

  /// Avanzamento da 0 a 1. Se manca, nessuna barra: un progresso senza il
  /// totale sarebbe una percentuale inventata.
  final double? progress;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ArPressable(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ArRadii.card),
          child: Stack(
            fit: StackFit.expand,
            children: [
              HomePosterImage(url: imageUrl, title: title),
              const DecoratedBox(
                decoration: BoxDecoration(gradient: ArColors.posterScrim),
              ),
              if (badge != null) Positioned(top: 8, left: 8, child: badge!),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        shadows: const [
                          Shadow(color: Colors.black87, blurRadius: 6),
                        ],
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: ArColors.textMid,
                          shadows: const [
                            Shadow(color: Colors.black87, blurRadius: 6),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (progress != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LinearProgressIndicator(
                    value: progress!.clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: Colors.white24,
                    color: ArColors.accent,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Card di un'attivita' di un membro del gruppo.
///
/// Mostra la locandina dell'anime, chi ha agito e cosa ha fatto, col voto se
/// l'azione lo porta. L'avatar sta sull'angolo perche' l'ordine di lettura deve
/// essere "chi" prima di "cosa", come in un feed.
class FriendActivityCard extends StatelessWidget {
  const FriendActivityCard({super.key, required this.activity, this.onTap});

  final FriendActivity activity;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = activity.detailLabel;

    return ArPressable(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ArRadii.card),
          child: Stack(
            fit: StackFit.expand,
            children: [
              HomePosterImage(url: activity.imageUrl, title: activity.animeTitle),
              const DecoratedBox(
                decoration: BoxDecoration(gradient: ArColors.posterScrim),
              ),
              Positioned(
                top: 8,
                left: 8,
                child: _Avatar(
                  name: activity.userName,
                  url: activity.avatarUrl,
                ),
              ),
              if (activity.score != null)
                Positioned(
                  top: 8,
                  right: 8,
                  child: ScoreBadge(score: activity.score!),
                ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${activity.userName} ${activity.kind.actionLabel}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: ArColors.textHigh,
                        shadows: const [
                          Shadow(color: Colors.black87, blurRadius: 6),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      activity.animeDisplayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: ArColors.textMid,
                        shadows: const [
                          Shadow(color: Colors.black87, blurRadius: 6),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [?detail, relativeDate(activity.createdAt)].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: ArColors.textLow,
                        shadows: const [
                          Shadow(color: Colors.black87, blurRadius: 6),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Copertina con un segnaposto elegante.
///
/// Non una cella grigia vuota: una locandina mancante e' normale nel catalogo
/// esterno, ma un rettangolo grigio sembra un'immagine rotta. L'icona dice
/// "qui ci sarebbe la copertina" senza allarmare.
class HomePosterImage extends StatelessWidget {
  const HomePosterImage({super.key, required this.url, required this.title});

  final String? url;
  final String title;

  @override
  Widget build(BuildContext context) {
    final fallback = DecoratedBox(
      decoration: const BoxDecoration(gradient: ArColors.subtle),
      child: Center(
        child: Icon(Icons.movie_outlined, size: 28, color: ArColors.textLow),
      ),
    );

    return Semantics(
      image: true,
      label: title,
      child: (url == null || url!.isEmpty)
          ? fallback
          : CachedNetworkImage(
              imageUrl: url!,
              fit: BoxFit.cover,
              fadeInDuration: ArMotion.slow,
              placeholder: (_, _) => const DecoratedBox(
                decoration: BoxDecoration(gradient: ArColors.subtle),
              ),
              errorWidget: (_, _, _) => fallback,
            ),
    );
  }
}

/// Avatar tondo con l'iniziale come fallback.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, this.url});

  final String name;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ArColors.containerHigh,
        border: Border.all(color: ArColors.bg.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: (url == null || url!.isEmpty)
          ? Center(
              child: Text(
                initial,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: ArColors.textHigh,
                ),
              ),
            )
          : CachedNetworkImage(
              imageUrl: url!,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: ArColors.textHigh,
                  ),
                ),
              ),
            ),
    );
  }
}

/// Pulsante "Watchlist": aggiunge o toglie l'opera dalla lista personale.
///
/// Personale e non di gruppo: la home non ha un gruppo selezionato, e scrivere
/// nella lista di un gruppo scelto a caso sarebbe una decisione presa al posto
/// dell'utente. Lo stato arriva da "La mia lista", quindi il pulsante sa se
/// l'opera e' gia' salvata e cambia etichetta di conseguenza.
class HomeWatchlistButton extends ConsumerStatefulWidget {
  const HomeWatchlistButton({
    super.key,
    required this.animeId,
    this.onSurface = false,
  });

  final String animeId;

  /// true quando il pulsante sta su una superficie piena invece che sopra
  /// un'immagine: cambia il fondo, non il comportamento.
  final bool onSurface;

  @override
  ConsumerState<HomeWatchlistButton> createState() =>
      _HomeWatchlistButtonState();
}

class _HomeWatchlistButtonState extends ConsumerState<HomeWatchlistButton> {
  bool _busy = false;

  Future<void> _toggle(bool saved) async {
    setState(() => _busy = true);
    try {
      final actions = ref.read(watchlistActionProvider.notifier);
      if (saved) {
        await actions.remove(animeId: widget.animeId);
      } else {
        await actions.setStatus(
          animeId: widget.animeId,
          status: WatchStatus.planned,
        );
      }
      if (!mounted) return;
      _message(saved ? 'Rimosso da La mia lista' : 'Aggiunto a La mia lista');
    } on AppFailure catch (e) {
      if (!mounted) return;
      _message(e.message);
    } catch (_) {
      if (!mounted) return;
      _message('Non si è potuto aggiornare la lista. Riprova.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final saved =
        ref
            .watch(myListProvider)
            .asData?.value
            .any((entry) => entry.animeId == widget.animeId) ??
        false;

    final label = saved ? 'Nella lista' : 'Watchlist';
    final icon = saved ? Icons.check_rounded : Icons.add_rounded;

    final background = widget.onSurface
        ? ArColors.containerHigh
        : Colors.white.withValues(alpha: 0.14);
    final border = widget.onSurface
        ? ArColors.borderSoft
        : Colors.white.withValues(alpha: 0.28);
    final foreground = widget.onSurface ? ArColors.textHigh : Colors.white;

    return Semantics(
      button: true,
      label: saved ? 'Rimuovi dalla watchlist' : 'Aggiungi alla watchlist',
      child: Opacity(
        opacity: _busy ? 0.6 : 1,
        child: ArPressable(
          onTap: _busy ? null : () => _toggle(saved),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(ArRadii.control),
              border: Border.all(color: border),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 19, color: foreground),
                  const SizedBox(width: ArSpace.sm),
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: AppTheme.bodyFont,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      fontVariations: const [FontVariation('wght', 700)],
                      color: foreground,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
