import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../domain/user_profile.dart';
import '../profile_controller.dart';

/// Cancellazione dell'account.
///
/// Schermata separata dal profilo e senza azioni secondarie: e' irreversibile
/// e l'utente non deve poterci arrivare con un tocco distratto.
///
/// Il pulsante di conferma resta disabilitato finche' il testo digitato non
/// corrisponde: e' l'unico controllo che distingue davvero un utente
/// intenzionale da uno che ha aperto la schermata e ha premuto " Continua".
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  static const String _confirmation = 'ELIMINA';

  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;
  int _remainingFiles = 0;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  /// Il pulsante si abilita solo con la parola esatta.
  ///
  /// Il confronto e' case-sensitive per scelta: digitare `elimina` vuol dire
  /// che l'utente ha letto e puo' ripetere, mentre copia-incolla del maiuscolo
  /// e' il gesto deliberato che conferma la lettura dell'avviso.
  bool get _canDelete => _confirm.text.trim() == _confirmation;

  Future<void> _delete() async {
    if (!_canDelete || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref.read(profileProvider.notifier).deleteAccount();
      if (!mounted) return;

      // `go` e non `push`: l'account non esiste piu', quindi non deve
      // restare nella cronologia una schermata che riproverebbe a cancellare
      // un utente inesistente.
      context.go('/login');
    } on AccountDeletionFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _remainingFiles = e.remainingFiles;
      });
    } on ProfileFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Elimina account')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'L operazione e definitiva. Votazioni, watchlist, commenti, '
                    'duelli e notifiche collegati al tuo profilo vengono '
                    'eliminati insieme all account.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          // Cosa resta nei gruppi: le attivita passate spariscono, ma
          // l'utente deve sapere che gli altri membri perderanno quei
          // contributi, perche' e' una scelta che non riguarda solo lui.
          Text(
            'Le attivita che hai generato nei gruppi verranno rimosse '
            'dai loro feed. I gruppi di cui sei owner restano, ma senza owner.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 24),
            AuthErrorBanner.error(_error!),
          ],

          if (_remainingFiles > 0) ...[
            const SizedBox(height: 12),
            Text(
              'Rimuovi prima i $_remainingFiles file caricati: la '
              'cancellazione si ferma finche esistono.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
          ],

          const SizedBox(height: 24),
          Text('Scrivi $_confirmation per confermare', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          TextField(
            controller: _confirm,
            enabled: !_busy,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: _confirmation,
              border: OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: _busy ? null : (_canDelete ? _delete : null),
            child: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Elimina definitivamente'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : () => context.pop(),
            child: const Text('Annulla'),
          ),
        ],
      ),
    );
  }
}
