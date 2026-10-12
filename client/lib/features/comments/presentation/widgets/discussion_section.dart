import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/section_header.dart';
import '../../../groups/domain/group.dart';
import '../../../groups/presentation/groups_controller.dart';
import '../../../profile/presentation/widgets/avatar.dart';
import '../../domain/comment.dart';
import '../comments_controller.dart';

/// Sezione "Discussione" del dettaglio anime.
///
/// I commenti sono legati a un gruppo, non all'anime in assoluto: la stessa
/// scheda mostra conversazioni diverse a seconda di dove si e' membro. Se i
/// gruppi sono piu' d'uno, il selettore in cima sceglie quale si sta leggendo.
///
/// Senza gruppi la sezione non sparisce: spiega che serve un gruppo. Una
/// sezione vuota e muta sembrerebbe rotta, e l'utente non saprebbe che il
/// commento e' legato a un gruppo.
class DiscussionSection extends ConsumerStatefulWidget {
  const DiscussionSection({required this.animeId, super.key});

  final String animeId;

  @override
  ConsumerState<DiscussionSection> createState() => _DiscussionSectionState();
}

class _DiscussionSectionState extends ConsumerState<DiscussionSection> {
  final TextEditingController _field = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// Gruppo scelto a mano. Nullo finche' non si tocca il selettore: il primo
  /// gruppo e' il predefinito, calcolato a ogni build senza scrivere stato.
  String? _groupId;

  bool _spoiler = false;
  String? _replyToId;
  String? _replyToName;
  bool _sending = false;
  String? _error;

  /// Id dei commenti spoiler che l'utente ha deciso di scoprire. Vive solo in
  /// questa schermata: riaprire la scheda torna a nasconderli.
  final Set<String> _revealed = {};

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(groupsListProvider);
    final page = ArSpace.page(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(page.left, ArSpace.lg, page.right, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(title: 'Discussione', padding: EdgeInsets.zero),
          const SizedBox(height: ArSpace.sm),
          groups.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: ArSpace.lg),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, _) => const _Notice(
              text: 'I commenti non sono disponibili adesso.',
            ),
            data: (list) => list.isEmpty
                ? const _Notice(
                    text: 'Entra in un gruppo per leggere e scrivere i commenti '
                        'su questo anime.',
                  )
                : _discussion(list),
          ),
        ],
      ),
    );
  }

  Widget _discussion(List<AnimeGroup> groups) {
    final selected =
        groups.firstWhere((g) => g.id == _groupId, orElse: () => groups.first);
    final key = (groupId: selected.id, animeId: widget.animeId);
    final comments = ref.watch(commentsProvider(key));
    final myId = ref.watch(commentsRepositoryProvider).currentUserId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (groups.length > 1) ...[
          _GroupSelector(
            groups: groups,
            selectedId: selected.id,
            onSelected: (id) => setState(() {
              _groupId = id;
              // La bozza resta: e' lo stesso commento, solo in un'altra
              // conversazione. La risposta aperta invece appartiene all'altro
              // gruppo e va annullata.
              _replyToId = null;
              _replyToName = null;
            }),
          ),
          const SizedBox(height: ArSpace.sm),
        ],
        comments.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: ArSpace.lg),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => _Notice(
            text: error is AppFailure
                ? error.message
                : 'Commenti non disponibili. Riprova.',
            action: TextButton(
              onPressed: () => ref.invalidate(commentsProvider(key)),
              child: const Text('Riprova'),
            ),
          ),
          data: (list) => _thread(selected.id, list, myId),
        ),
      ],
    );
  }

  Widget _thread(String groupId, List<Comment> comments, String? myId) {
    final roots = comments.where((c) => c.isRoot).toList();
    final replies = <String, List<Comment>>{};
    for (final comment in comments) {
      final parent = comment.parentId;
      if (parent != null) replies.putIfAbsent(parent, () => []).add(comment);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _composer(groupId),
        const SizedBox(height: ArSpace.md),
        if (roots.isEmpty)
          const _EmptyThread()
        else
          for (final root in roots) ...[
            _CommentTile(
              comment: root,
              revealed: _revealed.contains(root.id),
              canDelete: root.userId == myId,
              onReveal: () => setState(() => _revealed.add(root.id)),
              onReply: () => _startReply(root),
              onDelete: () => _confirmDelete(groupId, root),
              replies: [
                for (final reply in replies[root.id] ?? const <Comment>[])
                  _CommentTile(
                    comment: reply,
                    revealed: _revealed.contains(reply.id),
                    canDelete: reply.userId == myId,
                    onReveal: () => setState(() => _revealed.add(reply.id)),
                    onDelete: () => _confirmDelete(groupId, reply),
                  ),
              ],
            ),
            const SizedBox(height: ArSpace.sm),
          ],
      ],
    );
  }

  Widget _composer(String groupId) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(ArSpace.sm),
      decoration: BoxDecoration(
        color: ArColors.containerLow,
        borderRadius: BorderRadius.circular(ArRadii.card),
        border: Border.all(color: ArColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_replyToId != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Rispondi a ${_replyToName ?? 'Utente'}',
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: ArColors.primary),
                  ),
                ),
                IconButton(
                  onPressed: _sending
                      ? null
                      : () => setState(() {
                            _replyToId = null;
                            _replyToName = null;
                          }),
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Annulla risposta',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          TextField(
            controller: _field,
            focusNode: _focus,
            minLines: 2,
            maxLines: 6,
            maxLength: CommentValidators.maxLength,
            textCapitalization: TextCapitalization.sentences,
            style: theme.textTheme.bodyMedium,
            decoration: InputDecoration(
              hintText: 'Scrivi un commento...',
              // Il contatore di default occupa una riga intera per un limite
              // che l'utente raggiunge di rado: si mostra solo se serve, sotto.
              counterText: '',
              filled: true,
              fillColor: ArColors.container,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(ArRadii.control),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: ArSpace.xs),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(color: ArColors.danger),
            ),
          ],
          const SizedBox(height: ArSpace.xs),
          Row(
            children: [
              _SpoilerToggle(
                value: _spoiler,
                onChanged: _sending
                    ? null
                    : (value) => setState(() => _spoiler = value),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _sending ? null : () => _submit(groupId),
                icon: _sending
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded, size: 18),
                label: const Text('Pubblica'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _startReply(Comment comment) {
    setState(() {
      _replyToId = comment.id;
      _replyToName = comment.authorLabel;
    });
    _focus.requestFocus();
  }

  Future<void> _submit(String groupId) async {
    final error = CommentValidators.contentError(_field.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });

    final key = (groupId: groupId, animeId: widget.animeId);
    try {
      await ref.read(commentsProvider(key).notifier).post(
            content: _field.text,
            spoiler: _spoiler,
            parentId: _replyToId,
          );
      if (!mounted) return;
      _field.clear();
      setState(() {
        _spoiler = false;
        _replyToId = null;
        _replyToName = null;
      });
    } on CommentsFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _confirmDelete(String groupId, Comment comment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminare il commento?'),
        content: Text(
          comment.isRoot
              ? 'Spariranno anche le risposte. L operazione non si puo annullare.'
              : 'L operazione non si puo annullare.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final key = (groupId: groupId, animeId: widget.animeId);
    try {
      await ref.read(commentsProvider(key).notifier).remove(comment.id);
    } on CommentsFailure catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// Un commento o una risposta, con le risposte annidate sotto.
class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.revealed,
    required this.canDelete,
    required this.onReveal,
    required this.onDelete,
    this.onReply,
    this.replies = const [],
  });

  final Comment comment;
  final bool revealed;
  final bool canDelete;
  final VoidCallback onReveal;

  /// Presente solo alle radici: il database non permette di rispondere a una
  /// risposta, e offrirlo sarebbe un pulsante che il server rifiuta.
  final VoidCallback? onReply;

  final VoidCallback onDelete;
  final List<Widget> replies;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProfileAvatar(
              url: comment.authorAvatarUrl,
              fallbackText: avatarInitial(comment.authorLabel),
              size: 34,
            ),
            const SizedBox(width: ArSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          comment.authorLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(color: ArColors.textHigh),
                        ),
                      ),
                      const SizedBox(width: ArSpace.xs),
                      Text(
                        _relative(comment.createdAt),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: ArColors.textLow),
                      ),
                      if (comment.isEdited) ...[
                        const SizedBox(width: ArSpace.xxs),
                        Text(
                          '(modificato)',
                          style: TextStyle(
                            fontFamily: AppTheme.bodyFont,
                            fontSize: 11,
                            color: ArColors.textLow,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: ArSpace.xxs),
                  _body(context),
                  const SizedBox(height: ArSpace.xxs),
                  Row(
                    children: [
                      if (comment.isRoot)
                        _TileAction(
                          icon: Icons.reply_rounded,
                          label: 'Rispondi',
                          onTap: onReply!,
                        ),
                      if (canDelete)
                        _TileAction(
                          icon: Icons.delete_outline,
                          label: 'Elimina',
                          onTap: onDelete,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (replies.isNotEmpty)
          // Il rientro e il filetto verticale distinguono una risposta dal
          // commento a cui appartiene: senza, la lista sembrerebbe piatta e
          // non si capirebbe a cosa si sta rispondendo.
          Padding(
            padding: const EdgeInsets.only(left: 46, top: ArSpace.xs),
            child: Container(
              padding: const EdgeInsets.only(left: ArSpace.sm),
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: ArColors.border, width: 2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final reply in replies) ...[
                    reply,
                    const SizedBox(height: ArSpace.xs),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);

    if (!comment.isSpoiler) {
      return Text(comment.content, style: theme.textTheme.bodyMedium);
    }

    if (!revealed) {
      return InkWell(
        onTap: onReveal,
        borderRadius: BorderRadius.circular(ArRadii.chip),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: ArSpace.sm,
            vertical: ArSpace.xs,
          ),
          decoration: BoxDecoration(
            color: ArColors.containerHigh,
            borderRadius: BorderRadius.circular(ArRadii.chip),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.visibility_off_outlined,
                  size: 16, color: ArColors.textLow),
              const SizedBox(width: ArSpace.xs),
              Text(
                'Mostra spoiler',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: ArColors.textMid),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.only(left: ArSpace.sm),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: ArColors.danger.withValues(alpha: 0.5),
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SPOILER',
            style: theme.textTheme.labelSmall?.copyWith(
              color: ArColors.danger,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: ArSpace.xxs),
          Text(comment.content, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// Azione testuale compatta sotto un commento.
class _TileAction extends StatelessWidget {
  const _TileAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 15),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: ArColors.textMid,
        padding: const EdgeInsets.symmetric(horizontal: ArSpace.xs),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontFamily: AppTheme.bodyFont, fontSize: 12.5),
      ),
    );
  }
}

/// Interruttore "spoiler" del modulo.
class _SpoilerToggle extends StatelessWidget {
  const _SpoilerToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      borderRadius: BorderRadius.circular(ArRadii.chip),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: ArSpace.sm,
          vertical: ArSpace.xs,
        ),
        decoration: BoxDecoration(
          color: value
              ? ArColors.danger.withValues(alpha: 0.14)
              : ArColors.containerHigh,
          borderRadius: BorderRadius.circular(ArRadii.chip),
          border: Border.all(
            color: value ? ArColors.danger.withValues(alpha: 0.4) : ArColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.visibility_off : Icons.visibility_outlined,
              size: 16,
              color: value ? ArColors.danger : ArColors.textMid,
            ),
            const SizedBox(width: ArSpace.xs),
            Text(
              'Spoiler',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: value ? ArColors.danger : ArColors.textMid,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Selettore del gruppo di cui si legge la discussione.
class _GroupSelector extends StatelessWidget {
  const _GroupSelector({
    required this.groups,
    required this.selectedId,
    required this.onSelected,
  });

  final List<AnimeGroup> groups;
  final String selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: ArSpace.xs,
      runSpacing: ArSpace.xs,
      children: [
        for (final group in groups)
          _GroupPill(
            label: group.name,
            selected: group.id == selectedId,
            onTap: () => onSelected(group.id),
          ),
      ],
    );
  }
}

class _GroupPill extends StatelessWidget {
  const _GroupPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ArRadii.chip),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: ArSpace.sm,
          vertical: ArSpace.xs,
        ),
        decoration: BoxDecoration(
          color: selected ? ArColors.primary.withValues(alpha: 0.16) : null,
          borderRadius: BorderRadius.circular(ArRadii.chip),
          border: Border.all(
            color: selected
                ? ArColors.primary.withValues(alpha: 0.5)
                : ArColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: AppTheme.bodyFont,
            fontSize: 13,
            color: selected ? ArColors.textHigh : ArColors.textMid,
          ),
        ),
      ),
    );
  }
}

/// Riquadro informativo o di errore della sezione.
class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(ArSpace.md),
      decoration: BoxDecoration(
        color: ArColors.containerLow,
        borderRadius: BorderRadius.circular(ArRadii.card),
        border: Border.all(color: ArColors.borderSoft),
      ),
      child: Row(
        children: [
          const Icon(Icons.forum_outlined, size: 20, color: ArColors.textLow),
          const SizedBox(width: ArSpace.sm),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Discussione ancora vuota.
class _EmptyThread extends StatelessWidget {
  const _EmptyThread();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ArSpace.lg),
      child: Column(
        children: [
          const Icon(Icons.forum_outlined, size: 28, color: ArColors.textLow),
          const SizedBox(height: ArSpace.xs),
          Text(
            'Ancora nessun commento. Inizia tu.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Tempo trascorso in forma breve.
///
/// Relativo e non una data: in una conversazione "2 h" dice subito se il
/// messaggio e' fresco, mentre "12/10/2026" costringe a fare il conto.
String _relative(DateTime at) {
  final diff = DateTime.now().difference(at);
  if (diff.inMinutes < 1) return 'adesso';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min';
  if (diff.inHours < 24) return '${diff.inHours} h';
  if (diff.inDays == 1) return 'ieri';
  if (diff.inDays < 7) return '${diff.inDays} g';
  final day = at.day.toString().padLeft(2, '0');
  final month = at.month.toString().padLeft(2, '0');
  return '$day/$month/${at.year}';
}
