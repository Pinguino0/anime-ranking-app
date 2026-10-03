import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/error/app_failure.dart';
import '../../domain/group.dart';
import '../groups_controller.dart';

/// Inviti singoli del gruppo: creare, copiare e revocare.
///
/// La sezione e' separata dalla card del codice gruppo perche' i due hanno
/// regole diverse. Il codice e' un accesso permanente e si rigenera; un invito
/// vale per una persona sola, scade, e siPuo' revocare. Mescolarli in una
/// scheda unica farebbe sembrare le due cose uguali, che e' esattamente
/// l'errore che porta a condividere il link del gruppo al posto di un invito.
class GroupInvitesSection extends ConsumerStatefulWidget {
  const GroupInvitesSection({required this.groupId, super.key});

  final String groupId;

  @override
  ConsumerState<GroupInvitesSection> createState() =>
      _GroupInvitesSectionState();
}

class _GroupInvitesSectionState extends ConsumerState<GroupInvitesSection> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final invites = ref.watch(groupInvitesProvider(widget.groupId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Inviti singoli', style: theme.textTheme.titleSmall),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Crea'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Ogni invito vale per una persona sola e scade. Serve per far entrare '
          'qualcuno senza chiudere il codice del gruppo.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        invites.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _Message(
            text: error is GroupsFailure
                ? error.message
                : 'Inviti non disponibili.',
            action: OutlinedButton(
              onPressed: () =>
                  ref.invalidate(groupInvitesProvider(widget.groupId)),
              child: const Text('Riprova'),
            ),
          ),
          data: (rows) {
            if (rows.isEmpty) {
              return const _Message(text: 'Nessun invito attivo.');
            }

            return Column(
              children: [
                for (final invite in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _InviteRow(
                      invite: invite,
                      busy: _busy,
                      onRevoke: () => _revoke(invite),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// Crea un invito con la validita' proposta.
  Future<void> _create() async {
    final messenger = ScaffoldMessenger.of(context);

    final days = await showDialog<int>(
      context: context,
      builder: (context) => _DaysDialog(),
    );
    if (days == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final notifier = ref.read(groupInvitesProvider(widget.groupId).notifier);
      final created = await notifier.createInvite(daysValid: days);
      await notifier.refresh();

      messenger.showSnackBar(
        SnackBar(content: Text('Invito creato: ${created.code}')),
      );
    } on GroupsFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Revoca un invito dopo conferma.
  Future<void> _revoke(GroupInvite invite) async {
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revocare l\'invito?'),
        content: Text(
          'Il codice ${invite.code} smettera\' di funzionare. Se qualcuno lo '
          'aveva gia\' ricevuto dovrà chiedere un altro invito.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revoca'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final notifier = ref.read(groupInvitesProvider(widget.groupId).notifier);
      await notifier.revokeInvite(invite);
      await notifier.refresh();

      messenger.showSnackBar(const SnackBar(content: Text('Invito revocato.')));
    } on GroupsFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Scelta della validita' dell'invito.
///
/// Le opzioni sono limitate a cio' che il backend accetta (da 1 a 30 giorni).
/// Mostrare un campo libero lascerebbe scoprire il limite solo dopo aver premuto
/// "Crea", con un errore che sembrerebbe un problema dell'app.
class _DaysDialog extends StatefulWidget {
  @override
  State<_DaysDialog> createState() => _DaysDialogState();
}

class _DaysDialogState extends State<_DaysDialog> {
  int _days = 7;

  static const _options = [1, 3, 7, 14, 30];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Validita\' dell\'invito'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Scade fra $_days ${_days == 1 ? 'giorno' : 'giorni'}.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final d in _options)
                ChoiceChip(
                  label: Text('$d g'),
                  selected: _days == d,
                  onSelected: (_) => setState(() => _days = d),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_days),
          child: const Text('Crea'),
        ),
      ],
    );
  }
}

/// Riga di un invito con il suo stato e le azioni disponibili.
class _InviteRow extends StatelessWidget {
  const _InviteRow({
    required this.invite,
    required this.busy,
    required this.onRevoke,
  });

  final GroupInvite invite;
  final bool busy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    invite.code,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontFamily: 'monospace',
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    invite.statusLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Copia',
              onPressed: () => _copy(context),
              icon: const Icon(Icons.copy, size: 18),
            ),
            // La revoca sparisce su un invito gia' usato o gia' revocato perche'
            // il backend la rifiuterebbe: un pulsante che porta sempre a un
            // errore sembra un difetto dell'app.
            if (invite.isActive)
              IconButton(
                tooltip: 'Revoca',
                onPressed: busy ? null : onRevoke,
                icon: const Icon(Icons.block, size: 18),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: invite.code));
    messenger.showSnackBar(const SnackBar(content: Text('Codice copiato.')));
  }
}

/// Riga di avviso, usata sia per gli errori sia per le liste vuote.
class _Message extends StatelessWidget {
  const _Message({required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 8), action!],
        ],
      ),
    );
  }
}
