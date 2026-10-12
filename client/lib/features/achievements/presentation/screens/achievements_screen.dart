import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/content_row.dart';
import '../../../../core/ui/section_header.dart';
import '../achievements_controller.dart';
import '../../domain/achievement.dart';

/// Elenco degli obiettivi.
///
/// Mostra sia gli sbloccati sia i mancanti: un elenco dei soli traguardi
/// raggiunti sarebbe un trofeo, non un obiettivo. I bloccati restano visibili
/// proprio perche' dicono cosa fare per arrivarci.
class AchievementsScreen extends ConsumerWidget {
  const AchievementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final achievements = ref.watch(achievementsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Obiettivi')),
      body: achievements.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorState(
          message: error is AppFailure
              ? error.message
              : 'Obiettivi non disponibili. Riprova.',
          onRetry: () => ref.read(achievementsProvider.notifier).refresh(),
        ),
        data: (values) => values.isEmpty
            ? const _Empty()
            : _AchievementsList(achievements: values),
      ),
    );
  }
}

/// Caso senza obiettivi.
///
/// Con il catalogo attuale non capita, ma la schermata non deve dare per
/// scontato che il backend ne abbia sempre: se restasse vuota e muta sembrerebbe
/// rotta.
class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.workspace_premium_outlined,
      title: 'Nessun obiettivo',
      message: 'Gli obiettivi compariranno qui man mano che vengono aggiunti.',
    );
  }
}

class _AchievementsList extends StatelessWidget {
  const _AchievementsList({required this.achievements});

  final List<Achievement> achievements;

  @override
  Widget build(BuildContext context) {
    final page = ArSpace.page(context);
    final unlocked = achievements.where((a) => a.isUnlocked).length;

    return ListView(
      padding: EdgeInsets.fromLTRB(page.left, ArSpace.lg, page.right, ArSpace.xxl),
      children: [
        _Summary(unlocked: unlocked, total: achievements.length),
        const SizedBox(height: ArSpace.lg),
        const SectionHeader(
          title: 'Tutti gli obiettivi',
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: ArSpace.sm),
        for (final achievement in achievements) ...[
          _AchievementCard(achievement: achievement),
          const SizedBox(height: ArSpace.sm),
        ],
      ],
    );
  }
}

/// Riepilogo in cima: quanti sbloccati su quanti, e quanto manca.
class _Summary extends StatelessWidget {
  const _Summary({required this.unlocked, required this.total});

  final int unlocked;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: ArColors.subtle,
        borderRadius: BorderRadius.circular(ArRadii.card),
        border: Border.all(color: ArColors.borderSoft),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ArSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('$unlocked', style: theme.textTheme.displaySmall),
                Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 6),
                  child: Text(
                    '/ $total',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: ArColors.textMid),
                  ),
                ),
                const Spacer(),
                const Icon(Icons.workspace_premium, color: ArColors.gold, size: 30),
              ],
            ),
            const SizedBox(height: ArSpace.sm),
            _ProgressBar(value: total == 0 ? 0 : unlocked / total),
            const SizedBox(height: ArSpace.sm),
            Text(
              _sentence(unlocked, total),
              style: theme.textTheme.bodyMedium?.copyWith(color: ArColors.textMid),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: value.clamp(0.0, 1.0),
        minHeight: 8,
        backgroundColor: ArColors.containerHighest,
      ),
    );
  }
}

class _AchievementCard extends StatelessWidget {
  const _AchievementCard({required this.achievement});

  final Achievement achievement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unlocked = achievement.isUnlocked;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: ArColors.containerLow,
        borderRadius: BorderRadius.circular(ArRadii.card),
        border: Border.all(
          // Il bordo colorato dice lo stato senza aggiungere un'etichetta: e' la
          // stessa informazione della spunta, ma si vede prima di leggere.
          color: unlocked
              ? ArColors.primary.withValues(alpha: 0.35)
              : ArColors.borderSoft,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ArSpace.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AchievementIcon(achievement: achievement),
            const SizedBox(width: ArSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    achievement.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: unlocked ? ArColors.textHigh : ArColors.textMid,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    achievement.description,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: ArSpace.xs),
                  if (unlocked)
                    _UnlockedLabel(at: achievement.unlockedAt!)
                  else
                    _RequirementLabel(text: achievement.requirement),
                ],
              ),
            ),
            const SizedBox(width: ArSpace.sm),
            Icon(
              unlocked ? Icons.check_circle : Icons.lock_outline,
              size: 20,
              color: unlocked ? ArColors.success : ArColors.textLow,
            ),
          ],
        ),
      ),
    );
  }
}

class _AchievementIcon extends StatelessWidget {
  const _AchievementIcon({required this.achievement});

  final Achievement achievement;

  @override
  Widget build(BuildContext context) {
    final unlocked = achievement.isUnlocked;

    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: unlocked
            ? ArColors.primary.withValues(alpha: 0.15)
            : ArColors.containerHighest,
        borderRadius: BorderRadius.circular(ArRadii.control),
      ),
      child: Opacity(
        // L'emoji resta leggibile ma spenta: un lucchetto al posto dell'icona
        // nasconderebbe cosa si sta cercando di sbloccare.
        opacity: unlocked ? 1 : 0.45,
        child: Text(achievement.icon, style: const TextStyle(fontSize: 24)),
      ),
    );
  }
}

class _RequirementLabel extends StatelessWidget {
  const _RequirementLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: ArColors.containerHigh,
        borderRadius: BorderRadius.circular(ArRadii.chip),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: AppTheme.bodyFont,
          fontSize: 11.5,
          color: ArColors.textLow,
        ),
      ),
    );
  }
}

class _UnlockedLabel extends StatelessWidget {
  const _UnlockedLabel({required this.at});

  final DateTime at;

  @override
  Widget build(BuildContext context) {
    return Text(
      'Sbloccato il ${_unlockedDateFormat.format(at)}',
      style: const TextStyle(
        fontFamily: AppTheme.bodyFont,
        fontSize: 11.5,
        color: ArColors.success,
      ),
    );
  }
}

/// Costruito una volta sola: `DateFormat` non e' banale da creare e questa
/// funzione gira a ogni build.
final DateFormat _unlockedDateFormat = _italianDateFormat();

DateFormat _italianDateFormat() {
  // Senza questa inizializzazione `intl` conosce solo l'inglese e chiamare
  // `DateFormat` con una locale non caricata solleva.
  initializeDateFormatting('it');
  return DateFormat('d MMMM y', 'it');
}

/// Frase del riepilogo, con il singolare quando manca un solo obiettivo.
String _sentence(int unlocked, int total) {
  if (unlocked == total) return 'Li hai sbloccati tutti. Complimenti.';
  final missing = total - unlocked;
  if (missing == 1) return 'Ti manca un obiettivo su $total.';
  return 'Ti mancano $missing obiettivi su $total.';
}
