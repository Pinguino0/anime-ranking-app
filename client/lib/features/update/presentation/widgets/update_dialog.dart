import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/app_release.dart';
import '../app_update_controller.dart';

/// Schermata di aggiornamento.
///
/// Bloccante per scelta: e' l'unica schermata del progetto senza via d'uscita.
/// Il motivo e' che versioni diverse dell'app parlano con schemi diversi, e un
/// utente che rimanda finisce per restare indietro con dati che il backend non
/// capisce piu'. Costa, ma costa a chi sceglie di rimandare, non a chi aggiorna.
///
/// Non e' una rotta e non ha bisogno di PopScope: la chiude [UpdateGate],
/// restituendo il figlio com'era appena lo stato torna non bloccante.
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({required this.state, required this.onInstall, super.key});

  final UpdateState state;

  /// Chiamata quando l'utente preme Aggiorna o Riprova.
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final release = state.release;

    return AlertDialog(
      title: const Text('Aggiornamento disponibile'),
      content: _content(context, theme, release),
      actions: [_action(theme)],
    );
  }

  Widget _content(
    BuildContext context,
    ThemeData theme,
    AppRelease? release,
  ) {
    switch (state.stage) {
      case UpdateStage.downloading:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sto scaricando l\'aggiornamento.',
              style: theme.textTheme.bodyMedium,
            ),
            SizedBox(height: ArSpace.md),
            // Il valore del progress e' l'unica cosa che cambia e cambia
            // spesso: senza chiare, ricostruirebbe tutta la colonna a ogni
            // percentuale e si vedrebbe il testo lampeggiare.
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: state.progress <= 0 ? null : state.progress,
                minHeight: 6,
                backgroundColor: ArColors.surfaceTop,
              ),
            ),
            SizedBox(height: ArSpace.xs),
            Text(
              '${(state.progress * 100).round()}%',
              style: theme.textTheme.bodySmall?.copyWith(
                color: ArColors.textMid,
              ),
            ),
          ],
        );

      case UpdateStage.installing:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: ArSpace.sm),
                Expanded(
                  child: Text(
                    'Aggiornamento pronto. Si sta installando...',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            SizedBox(height: ArSpace.sm),
            Text(
              'Quando Android chiude, riapri l\'app.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: ArColors.textMid,
              ),
            ),
          ],
        );

      case UpdateStage.failed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, color: ArColors.danger),
                SizedBox(width: ArSpace.sm),
                Expanded(
                  child: Text(
                    state.message ?? 'Aggiornamento non riuscito.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            if (release != null) ...[
              SizedBox(height: ArSpace.md),
              _versionLine(context, theme, release),
            ],
          ],
        );

      default:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (release != null) _versionLine(context, theme, release),
            if (state.needsInstallPermission) ...[
              SizedBox(height: ArSpace.md),
              const Icon(Icons.toggle_off, color: ArColors.warning),
              SizedBox(height: ArSpace.xs),
              Text(
                'Android non permette ancora a questa app di installare '
                'aggiornamenti. Nei passi appena aperti, abilita '
                '"Consenti installazione di app sconosciute" per AnimeRank '
                'e poi torna qui e premi di nuovo Aggiorna.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: ArColors.textMid,
                ),
              ),
            ],
            if (release != null && release.notes.isNotEmpty) ...[
              SizedBox(height: ArSpace.md),
              // Le note possono essere lunghe e la scelta che spiega il
              // rilascio e' quella che l'utente sta per saltare: se non
              // scorrono, la parte finale non la legge mai.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  child: Text(
                    release.notes,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: ArColors.textMid,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
    }
  }

  /// "1.0.1 → 1.0.2", o solo la nuova versione se quella installata non si
  /// conosce.
  Widget _versionLine(BuildContext context, ThemeData theme, AppRelease r) {
    final from = state.installedVersionName;
    final label = from == null || from.isEmpty
        ? 'Versione ${r.versionName}'
        : 'Da $from a ${r.versionName}';

    return Row(
      children: [
        const Icon(Icons.system_update_alt, size: 18, color: ArColors.primary),
        SizedBox(width: ArSpace.xs),
        Text(label, style: theme.textTheme.bodyMedium),
      ],
    );
  }

  Widget _action(ThemeData theme) {
    // Durante il download e l'installazione non c'e' un'azione possibile: il
    // bottone sparisce invece di restare li premibile, perche' premuto non
    // farebbe niente e sembrerebbe un'app rotta.
    if (state.stage == UpdateStage.downloading ||
        state.stage == UpdateStage.installing) {
      return const SizedBox.shrink();
    }

    final label = state.stage == UpdateStage.failed ? 'Riprova' : 'Aggiorna';

    return FilledButton(
      onPressed: onInstall,
      style: FilledButton.styleFrom(
        backgroundColor: ArColors.primary,
        foregroundColor: ArColors.bg,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: ArSpace.lg),
      ),
      child: Text(label),
    );
  }
}