import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../groups/domain/group.dart';
import '../watchlist_controller.dart';

/// Foglio "Consiglia": a chi e con quale messaggio.
///
/// Il gruppo e' gia' stato scelto (la scheda anime lo chiede prima): qui resta
/// la decisione che riguarda il consiglio, cioe' il destinatario e il testo.
/// "A tutti" e' la scelta iniziale perche' e' quella che non richiede di
/// conoscere gli altri membri.
class RecommendSheet extends ConsumerStatefulWidget {
  const RecommendSheet({
    required this.groupId,
    required this.animeId,
    required this.animeTitle,
    required this.members,
    super.key,
  });

  final String groupId;
  final String animeId;
  final String animeTitle;

  /// Membri tra cui scegliere il destinatario, gia' senza l'utente collegato.
  final List<GroupMember> members;

  @override
  ConsumerState<RecommendSheet> createState() => _RecommendSheetState();
}

class _RecommendSheetState extends ConsumerState<RecommendSheet> {
  final _message = TextEditingController();

  /// Destinatario scelto; `null` = a tutto il gruppo.
  String? _toUserId;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saving = ref.watch(watchlistActionProvider).isLoading;
    final members = widget.members;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: ArSpace.lg,
          right: ArSpace.lg,
          top: ArSpace.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + ArSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Consiglia "${widget.animeTitle}"',
              style: theme.textTheme.titleMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: ArSpace.md),
            if (members.isEmpty)
              Text(
                'Consiglierai a tutto il gruppo.',
                style: theme.textTheme.bodySmall?.copyWith(color: ArColors.textMid),
              )
            else
              DropdownButtonFormField<String?>(
                initialValue: _toUserId,
                decoration: const InputDecoration(
                  labelText: 'Destinatario',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Tutto il gruppo'),
                  ),
                  for (final member in members)
                    DropdownMenuItem<String?>(
                      value: member.userId,
                      child: Text(member.label),
                    ),
                ],
                onChanged: saving
                    ? null
                    : (value) => setState(() => _toUserId = value),
              ),
            const SizedBox(height: ArSpace.md),
            TextField(
              controller: _message,
              enabled: !saving,
              maxLines: 3,
              maxLength: 500,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Messaggio (facoltativo)',
                hintText: 'Perche\' lo consigli?',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: ArSpace.sm),
            FilledButton.icon(
              onPressed: saving ? null : _submit,
              icon: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.recommend_outlined),
              label: const Text('Consiglia'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final toUserId = _toUserId;

    try {
      await ref.read(watchlistActionProvider.notifier).recommend(
            groupId: widget.groupId,
            animeId: widget.animeId,
            toUserId: toUserId,
            message: _message.text,
          );

      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            toUserId == null
                ? 'Consiglio inviato al gruppo.'
                : 'Consiglio inviato.',
          ),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}
