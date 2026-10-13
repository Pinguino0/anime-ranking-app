import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/transitions.dart';
import '../../domain/watch_history.dart';

/// Card della riga "Continua da guardare".
///
/// Diversa da [AnimeCard] perche' racconta un'altra cosa: non "ecco un'opera", ma
/// "ecco dove eri arrivato". Per questo il tocco riprende l'episodio invece di
/// aprire la scheda, e sulla card c'e' l'episodio col minuto — il dato che
/// risponde alla domanda "a che punto ero".
///
/// Non c'e' una barra di avanzamento: il database sa quanti secondi sono stati
/// guardati ma non quanto dura l'episodio, e una barra senza il totale sarebbe
/// una percentuale inventata. Il minuto scritto sotto e' l'informazione vera.
class ContinueWatchingCard extends StatelessWidget {
  const ContinueWatchingCard({super.key, required this.item, this.onTap});

  final ContinueWatchingItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ArPressable(
      onTap: onTap,
      scale: 0.96,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ArRadii.card),
          border: Border.all(color: ArColors.borderSoft),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Poster(url: item.imageUrl, title: item.animeTitle),
            const DecoratedBox(
              decoration: BoxDecoration(gradient: ArColors.posterScrim),
            ),
            const Center(child: _PlayBadge()),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.animeTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      shadows: const [
                        Shadow(color: Colors.black87, blurRadius: 6),
                      ],
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Icon(
                        Icons.play_arrow_rounded,
                        size: 14,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(
                          'E${item.episodeNumber} · '
                          '${formatClock(item.currentSeconds)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.78),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pastiglia di riproduzione al centro.
class _PlayBadge extends StatelessWidget {
  const _PlayBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
      ),
      child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
    );
  }
}

/// Locandina con segnaposto, come [AnimeCard]: una cella grigia vuota sembra
/// un'immagine rotta, l'iniziale dice subito di che opera si tratta.
class _Poster extends StatelessWidget {
  const _Poster({required this.url, required this.title});

  final String? url;
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.surfaceContainerHigh, colors.surfaceContainerLow],
        ),
      ),
      child: Center(
        child: Text(
          title.isEmpty ? '?' : title.characters.first.toUpperCase(),
          style: TextStyle(
            fontFamily: AppTheme.displayFont,
            fontSize: 34,
            fontWeight: FontWeight.w700,
            fontVariations: const [FontVariation('wght', 700)],
            color: colors.onSurfaceVariant.withValues(alpha: 0.35),
          ),
        ),
      ),
    );

    if (url == null || url!.isEmpty) return placeholder;

    return CachedNetworkImage(
      imageUrl: url!,
      fit: BoxFit.cover,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }
}
