import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/error/app_failure.dart';
import '../auth_controller.dart';
import '../../data/auth_repository.dart';
import '../../domain/auth_validators.dart';
import '../widgets/auth_scaffold.dart';

/// Scelta della nuova password, aperta dal link di reset.
///
/// Non ha un "indietro" verso l'app: finche' il cambio non riesce l'utente
/// resta qui. L'unica uscita e' il pulsante in fondo, che chiude la sessione di
/// recupero e riporta al login: cosi' chi ha aperto il link per sbaglio non
/// resta collegato con la password vecchia ancora valida.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // validate() ricalcola anche la conferma: se le due password non
    // coincidono l'errore compare prima di toccare la rete.
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref.read(authRepositoryProvider).updatePassword(_password.text);
      // Chiudere il recupero fa ripartire il redirect: la sessione e' valida e
      // con la password nuova, quindi il router porta l'utente nella shell.
      if (!mounted) return;
      ref.read(passwordRecoveryPendingProvider.notifier).finish();
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Esce dal recupero senza cambiare password.
  ///
  /// La sessione aperta dal link va chiusa: senza, l'utente resterebbe
  /// collegato con la password vecchia, che non e' quello che ha chiesto.
  Future<void> _giveUp() async {
    setState(() => _busy = true);
    // Il notifier va preso prima dell'await: dopo signOut la schermata puo'
    // essere smontata dal redirect e lì `ref` non sarebbe piu' utilizzabile.
    final recovery = ref.read(passwordRecoveryPendingProvider.notifier);
    await ref.read(authRepositoryProvider).signOut();
    recovery.finish();
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Scegli una nuova password',
      subtitle: 'Il link ti ha riportato qui: imposta la password che userai da adesso.',
      footer: TextButton(
        onPressed: _busy ? null : _giveUp,
        child: const Text('Non ora, torna al login'),
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              AuthErrorBanner.error(_error!),
              const SizedBox(height: 16),
            ],
            TextFormField(
              controller: _password,
              enabled: !_busy,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Nuova password',
                helperText:
                    'Almeno ${AuthValidators.minPasswordLength} caratteri, con una cifra.',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  tooltip: _obscure ? 'Mostra la password' : 'Nascondi la password',
                ),
              ),
              validator: (v) =>
                  AuthValidators.passwordError(v, isRegistration: true),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirm,
              enabled: !_busy,
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Ripeti la password',
                prefixIcon: Icon(Icons.lock_reset),
              ),
              validator: (v) {
                if (v != _password.text) return 'Le due password non coincidono.';
                return null;
              },
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Salva la nuova password'),
            ),
          ],
        ),
      ),
    );
  }
}
