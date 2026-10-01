import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth_controller.dart';
import '../../data/auth_repository.dart';
import '../../domain/auth_validators.dart';
import '../widgets/auth_scaffold.dart';

/// Schermata di accesso.
///
/// Non chiama le API direttamente: passa da [authRepositoryProvider], cosi' il
/// test puo' iniettare un repository finto e verificare che il pulsante si
/// disattivi, che l'errore compaia e che il campo sbagliato venga evidenziato.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // validate() riesegue i validator su ogni campo, quindi gli errori del
    // tentativo precedente vengono ricalcolati: non serve cancellarli a mano,
    // e i campi corretti nell'ultimo giro smettono di essere rossi.
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref.read(authRepositoryProvider).signIn(
            email: _email.text,
            password: _password.text,
          );
      // Nessun routing manuale: appena Supabase emette la nuova sessione,
      // AuthController aggiorna lo stato e il redirect del router porta da
      // solo alla schermata principale.
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Bentornato',
      subtitle: 'Accedi per rivedere i tuoi gruppi e le tue classifiche.',
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Non hai un account?',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          TextButton(
            onPressed: _busy ? null : () => context.go('/register'),
            child: const Text('Registrati'),
          ),
        ],
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
              controller: _email,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.alternate_email),
              ),
              validator: AuthValidators.emailError,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              enabled: !_busy,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  tooltip: _obscure ? 'Mostra la password' : 'Nascondi la password',
                ),
              ),
              // In accesso la password non viene pretenduta "forte": l'utente potrebbe
              // avere un account creato con una password debole e deve poter
              // rientrare. isRegistration: false e' il motivo per cui il
              // requisito della cifra esiste solo in registrazione.
              validator: (v) => AuthValidators.passwordError(v, isRegistration: false),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : () => _forgotPassword(context),
                child: const Text('Password dimenticata?'),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Accedi'),
            ),
          ],
        ),
      ),
    );
  }

  /// Avvia il recupero password e conferma sempre la stessa cosa.
  ///
  /// Rispondere "email inesistente" solo per qualche indirizzo permetterebbe
  /// di scoprire chi ha un account su AnimeRank.
  Future<void> _forgotPassword(BuildContext context) async {
    final email = _email.text.trim();
    final emailError = AuthValidators.emailError(email);

    final messenger = ScaffoldMessenger.of(context);

    if (emailError != null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Inserisci prima la tua email: $emailError')),
      );
      return;
    }

    try {
      await ref.read(authRepositoryProvider).sendPasswordReset(email);
    } on AuthFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }

    messenger.showSnackBar(
      const SnackBar(
        content: Text('Se l indirizzo e registrato, riceverai un email.'),
      ),
    );
  }
}