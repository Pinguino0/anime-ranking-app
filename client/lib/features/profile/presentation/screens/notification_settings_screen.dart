import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../domain/user_profile.dart';
import '../profile_controller.dart';

/// Preferenze di notifica.
///
/// Ogni riga e' un interruttore indipendente: accorparle in una categoria con
/// una spunta sola sembra piu' ordinato, ma l'utente che vuole silenziare i
/// tornei e ricevere le votazioni deve poterlo dire.
class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(notificationPreferencesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Notifiche')),
      body: prefs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AuthErrorBanner.error('$error'),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () => ref.invalidate(notificationPreferencesProvider),
                  child: const Text('Riprova'),
                ),
              ],
            ),
          ),
        ),
        data: (data) => _List(prefs: data),
      ),
    );
  }
}

class _List extends ConsumerStatefulWidget {
  const _List({required this.prefs});

  final NotificationPreferences prefs;

  @override
  ConsumerState<_List> createState() => _ListState();
}

class _ListState extends ConsumerState<_List> {
  String? _error;

  /// Salvataggio di un interruttore.
  ///
  /// L'errore viene riportato qui invece che far fallire il provider: se
  /// l'errore finisse nello stato, l'interruttore tornerebbe indietro da solo
  /// senza spiegare perche'.
  Future<void> _set({bool? push, bool? votes, bool? friends,
      bool? tournaments, bool? rankChanges}) async {
    setState(() => _error = null);

    try {
      await ref.read(notificationPreferencesProvider.notifier).set(
            push: push,
            votes: votes,
            friends: friends,
            tournaments: tournaments,
            rankChanges: rankChanges,
          );
    } on ProfileFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = widget.prefs;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: AuthErrorBanner.error(_error!),
          ),

        SwitchListTile(
          title: const Text('Notifiche push'),
          subtitle: const Text('Avvisi sul dispositivo.'),
          value: prefs.push,
          onChanged: (v) => _set(push: v),
        ),
        const Divider(height: 1),
        SwitchListTile(
          title: const Text('Nuove votazioni'),
          subtitle: const Text('Quando qualcuno vota un anime che guardi.'),
          value: prefs.votes,
          onChanged: (v) => _set(votes: v),
        ),
        const Divider(height: 1),
        SwitchListTile(
          title: const Text('Amici'),
          subtitle: const Text('Richieste e attivita dei contatti.'),
          value: prefs.friends,
          onChanged: (v) => _set(friends: v),
        ),
        const Divider(height: 1),
        SwitchListTile(
          title: const Text('Tornei'),
          subtitle: const Text('Inizio, fasi e risultati.'),
          value: prefs.tournaments,
          onChanged: (v) => _set(tournaments: v),
        ),
        const Divider(height: 1),
        SwitchListTile(
          title: const Text('Cambiamenti di classifica'),
          subtitle: const Text('Quando la posizione di un anime si muove.'),
          value: prefs.rankChanges,
          onChanged: (v) => _set(rankChanges: v),
        ),

        if (prefs.allOff) ...[
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.notifications_off_outlined,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Tutte le notifiche sono spente.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// La scelta del tema (colonna `profiles.theme`) e' volutamente fuori da qui:
// richiede di scrivere il tema scelto su Supabase e di applicarlo al
// MaterialApp, quindi tocca `app.dart`. Viene aggiunta con il resto del
// materiale di profilo, non con un interruttore finto.
