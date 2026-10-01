import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/error/app_failure.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../groups_controller.dart';

/// Ingresso in un gruppo con il codice invito.
///
/// Il codice viene normalizzato in maiuscolo mentre si digita, perche' il
/// backend genera i codici in maiuscolo (`ANIME-XXXXXX`): digitare minuscole
/// non deve sembrare un errore dell'utente quando il problema e' l'assenza
/// della lettera maiuscola.
class JoinGroupScreen extends ConsumerStatefulWidget {
  const JoinGroupScreen({super.key});

  @override
  ConsumerState<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends ConsumerState<JoinGroupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final joined = await ref.read(groupsListProvider.notifier).join(_code.text);
      if (!mounted) return;
      context.go('/groups/${joined.id}');
    } on GroupsFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Entra in un gruppo',
      subtitle: 'Chiedi a un admin il codice invito del gruppo.',
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
              controller: _code,
              enabled: !_busy,
              autofocus: true,
              // autoCapitalize: dato che il codice e fatto di lettere maiuscole,
              // la tastiera mostra i caratteri giusti da subito.
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              enableSuggestions: false,
              // InputFormatter e non solo normalizzazione: blocca lo spazio, che
              // spesso finisce per incollamento di un link condiviso.
              inputFormatters: [
                LengthLimitingTextInputFormatter(24),
                FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9-]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Codice invito',
                hintText: 'ANIME-XXXXXX',
                prefixIcon: Icon(Icons.vpn_key_outlined),
              ),
              onChanged: (v) => _code.text = v.toUpperCase(),
              validator: (v) {
                final value = v?.trim() ?? '';
                if (value.isEmpty) return 'Inserisci il codice invito.';
                // Il backend risponde "Codice invito non valido" anche per un
                // codice inesistente: controllare il formato qui dà un riscontro
                // immediato senza aspettare la rete.
                if (value.length < 6) return 'Il codice sembra troppo corto.';
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
                  : const Text('Entra'),
            ),
          ],
        ),
      ),
    );
  }
}