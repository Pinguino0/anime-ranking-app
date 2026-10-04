import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/transitions.dart';
import '../../domain/episode.dart';

/// Una riga dell'elenco episodi.
///
/// La riga porta tre informazioni che l'elenco deve mostrare tutte insieme:
/// il numero, quanto si e' andati avanti, e il voto personale. Sono nella stessa
/// riga perche' e' la domanda che l'utente si fa scorrendo — "dov'ero?" — e
/// rispondere in tre schermate diverse significa farlo smettere.
class EpisodeTile extends StatelessWidget {
  const EpisodeTile({
    required this.episode,
    required this.onTap,
    this.selected = false,
    this.duration,
    super.key,
  });

  final Episode episode;
  final VoidCallback onTap;

  /// true quando e' l'episodio aperto nel player.
  ///
  /// Il player e' un'altra schermata, quindi quando si torna indietro questa
  /// riga deve dire quale era: senza, la lista riparte da capo e l'utente non
  /// sa piu' cosa sta guardando.
  final bool selected;

  /// Durata conosciuta, per calcolare la barra di progresso.
  ///
  /// `null` quando il backend non la sa: meglio nessuna barra che una barra
  /// disegnata a caso, perche' una barra sbagliata fa pensare di aver visto
  /// piu' o meno di quanto si e' davvero visto.
  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return ArPressable(
      onTap: episode.isPlayable ? onTap : null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? colors.primary.withValues(alpha: 0.12)
              : colors.surfaceContainerLow.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(ArRadii.control),
          border: Border.all(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(ArSpace.sm),
              child: Row(
                children: [
                  _Number(episode: episode),
                  const SizedBox(width: ArSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          episode.titleLabel,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: selected
                                ? colors.primary
                                : theme.textTheme.bodyLarge?.color,
                            fontWeight: selected ? FontWeight.w600 : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: ArSpace.xxs),
                        _Meta(episode: episode),
                      ],
                    ),
                  ),
                  const SizedBox(width: ArSpace.sm),
                  _Score(episode: episode),
                ],
              ),
            ),
            if (episode.started)
              _ProgressBar(fraction: episode.progressFraction(duration)),
          ],
        ),
      ),
    );
  }
}

/// Il numero dell'episodio.
///
/// Dentro un quadrato perche' e' l'unico riferimento stabile: il titolo di un
/// episodio di ricap si ripete e il numero no, e senza un numero fisso
/// l'utente non saprebbe se sta sfogliando la stagione giusta.
class _Number extends StatelessWidget {
  const _Number({required this.episode});

  final Episode episode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final done = episode.completed;

    return SizedBox(
      width: 46,
      height: 46,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: done
              ? ArColors.completed.withValues(alpha: 0.16)
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(ArRadii.chip),
          border: Border.all(
            color: done
                ? ArColors.completed.withValues(alpha: 0.4)
                : colors.outlineVariant,
          ),
        ),
        child: Center(
          child: done
              ? const Icon(
                  Icons.check_rounded,
                  size: 21,
                  color: ArColors.completed,
                )
              : Text(
                  '${episode.number}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontVariations: const [FontVariation('wght', 600)],
                  ),
                ),
        ),
      ),
    );
  }
}

/// Badge, data di messa in onda e stato di visione.
class _Meta extends StatelessWidget {
  const _Meta({required this.episode});

  final Episode episode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final parts = <String>[
      if (episode.filler) 'Filler',
      if (episode.recap) 'Riassunto',
      if (!episode.isPlayable) 'Non disponibile',
      if (episode.started) _watchedLabel(episode),
      if (episode.completed) 'Visto',
    ];

    return Row(
      children: [
        if (episode.thumbnail != null) ...[
          _Thumb(url: episode.thumbnail!),
          const SizedBox(width: ArSpace.xs),
        ],
        Expanded(
          child: Text(
            parts.isEmpty ? _airedLabel(episode) : parts.join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: episode.isPlayable
                  ? colors.onSurfaceVariant
                  : ArColors.textMid,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// "Riprendi da 12:34" invece di un conteggio di secondi.
  ///
  /// Il punto di ripresa e' l'unica cosa che l'utente cerca in questa schermata
  /// e la sola forma in cui si può confrontare con la barra qui sotto: dalla
  /// barra si vede la percentuale, dal testo si vede il punto esatto.
  static String _watchedLabel(Episode episode) {
    final total = episode.progressTime;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return 'Riprendi da $minutes:${seconds.toString().padLeft(2, '0')}';
  }

  static String _airedLabel(Episode episode) =>
      episode.airedAt == null ? 'Episodio' : _formatDate(episode.airedAt!);

  /// "4 aprile 2026".
  ///
  /// Il mese per nome e non "04/04": nella stessa lista un anno di date in
  /// numeri e' una tabella da leggere riga per riga, e questa riga serve per
  /// orientarsi, non per essere controllata.
  static String _formatDate(DateTime date) {
    const months = [
      'gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno',
      'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre',
    ];
    final month = months[date.month - 1];
    return '${date.day} $month ${date.year}';
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SizedBox(
      width: 46,
      height: 26,
      child: ClipRRect(
        // Raggio piccolo e non quello delle card: qui l'immagine e' un
        // dettaglio di ventisei pixel, e un raggio da dodici la farebbe
        // sembrare una pillola.
        borderRadius: BorderRadius.circular(ArSpace.xs),
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          placeholder: (_, _) => ColoredBox(color: colors.surfaceContainerHigh),
          errorWidget: (_, _, _) => ColoredBox(color: colors.surfaceContainerHigh),
        ),
      ),
    );
  }
}

/// Voto personale, in numeri e non in stelle.
///
/// Sull'opera il voto e' in decimi e va detto per decimi; su un episodio la
/// domanda e' piu' grossolana — "mi piace o no" — e una stella non
/// differenzia un 7 da un 8, che sono voti che l'utente ha davvero distinto
/// mentre cliccava.
class _Score extends StatelessWidget {
  const _Score({required this.episode});

  final Episode episode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = episode.myScore;

    if (score == null) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.star_rounded, size: 16, color: ArColors.gold),
        const SizedBox(width: ArSpace.xxs),
        Text(
          score.toStringAsFixed(1),
          style: theme.textTheme.titleSmall?.copyWith(color: ArColors.gold),
        ),
      ],
    );
  }
}

/// Barra di quanto si e' visto.
///
/// Spessa quattro pixel e senza etichette: e' un riferimento, non una
/// informazione da leggere. Il numero esatto e' nella riga, sopra.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.fraction});

  final double? fraction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final value = fraction;

    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 4,
        child: LinearProgressIndicator(
          value: value,
          minHeight: 4,
          backgroundColor: colors.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation<Color>(ArColors.primary),
        ),
      ),
    );
  }
}