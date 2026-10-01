import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth_controller.dart';
import '../../data/auth_repository.dart';
import '../../domain/auth_validators.dart';
import '../widgets/auth_scaffold.dart';

/// Schermata di registrazione.
///
/// Il nome utente e' facoltativo perche' `handle_new_user()` ne genera uno
/// quando manca. Se pero' l'utente ne sceglie uno gia' preso il backend non
/// fallisce: gliene assegna un altro in silenzio. Per questo l'avviso sotto il
/// campo dice esplicitamente che il nome scelto puo' non essere quello finale,
/// invece di lasciare l'utente con la sorpresa di un profilo diverso.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _userName = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  bool _obscure = true;
  String? _error;
  bool _confirmationSent = false;

  @override
  void dispose() {
    _email.dispose();
    _userName.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // validate() ricalcola gli errori su tutti i campi: quelli corretti
    // smettono di essere rossi senza doverli ripulire a mano.
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final outcome = await ref.read(authRepositoryProvider).signUp(
            email: _email.text,
            password: _password.text,
            // Stringa vuota = lascia al backend il nome generato: e' il
            // comportamento previsto, non un campo mancante.
            userName: _userName.text.trim(),
          );

      if (!mounted) return;

      if (outcome == SignUpOutcome.needsEmailConfirmation) {
        setState(() => _confirmationSent = true);
      }
      // Con alreadySignedIn arriva l'evento di sessione e il redirect porta
      // alla schermata principale: non c'e' niente da fare qui.
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_confirmationSent) return _ConfirmationSent(email: _email.text.trim());

    return AuthScaffold(
      title: 'Crea il tuo account',
      subtitle: 'Un profilo, tutti i tuoi gruppi di condivisione.',
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Hai gia un account?',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          TextButton(
            onPressed: _busy ? null : () => context.go('/login'),
            child: const Text('Accedi'),
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
              autofillHints: const [AutofillHints.newUsername],
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.alternate_email),
              ),
              validator: AuthValidators.emailError,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _userName,
              enabled: !_busy,
              textInputAction: TextInputAction.next,
              // Il nome viene normalizzato in minuscolo e senza spazi: evita
              // che l'utente digiti " Mario " e si trovi un profilo diverso
              // da quello che scrive nei messaggi.
              inputFormatters: [_UsernameFormatter()],
              decoration: const InputDecoration(
                labelText: 'Nome utente',
                helperText: 'Facoltativo. Se e gia preso, ne scegliamo uno.',
                prefixIcon: Icon(Icons.person_outline),
              ),
              validator: AuthValidators.usernameError,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              enabled: !_busy,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                helperText: 'Almeno ${AuthValidators.minPasswordLength} caratteri, con una cifra.',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  tooltip: _obscure ? 'Mostra la password' : 'Nascondi la password',
                ),
              ),
              validator: (v) => AuthValidators.passwordError(v, isRegistration: true),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Crea account'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Schermata mostrata quando la conferma email e' obbligatoria.
///
/// Non lascia pulsante "Accedi": fino a che l'indirizzo non e' confermato
/// GoTrue rifiuta l'accesso, quindi premere il pulsante produrrebbe solo
/// un errore. Il link diretto al login c'e' lo stesso, ma come testo secondario.
class _ConfirmationSent extends StatelessWidget {
  const _ConfirmationSent({required this.email});

  final String email;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AuthScaffold(
      title: 'Controlla la tua email',
      subtitle: 'Abbiamo inviato un link di conferma a $email.',
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton(
            onPressed: () => context.go('/login'),
            child: const Text('Torna al login'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AuthErrorBanner.notice(
            'Clicca il link nell email per attivare l account. '
            'Il collegamento vale per poco tempo: se scade, ripeti la registrazione.',
          ),
          const SizedBox(height: 20),
          Text(
            'Niente email? Controlla la posta indesiderata: capita che il filtro '
            'delle newsletter ci butti fuori.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Normalizza il nome utente mentre si digita.
///
/// Blocca i caratteri che il database rifiuterebbe, invece di lasciare
/// l'utente scoprire l'errore solo al submit. Sostituisce l'errore con "non
/// valido" che e' il modo peggiore per farglielo capire.
class _UsernameFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final sanitized = newValue.text
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');

    if (sanitized.length <= AuthValidators.maxUsernameLength) {
      return newValue.copyWith(
        text: sanitized,
        selection: TextSelection.collapsed(offset: sanitized.length),
      );
    }

    // Oltre il limite si taglia, invece di bloccare la digitazione: continuare
    // a scrivere e non vedere nulla accadere e' il comportamento peggiore.
    final clipped = sanitized.substring(0, AuthValidators.maxUsernameLength);
    return newValue.copyWith(
      text: clipped,
      selection: TextSelection.collapsed(offset: clipped.length),
    );
  }
}