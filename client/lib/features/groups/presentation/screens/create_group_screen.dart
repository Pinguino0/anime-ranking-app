import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/error/app_failure.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../data/groups_repository.dart';
import '../groups_controller.dart';

/// Creazione di un gruppo.
///
/// Aperto come schermata a se' e non come dialog: il modulo e' lungo (nome,
/// descrizione) e su schermi piccoli un dialog finisce tagliato. Inoltre la
/// schermata e' raggiungibile dalla lista vuota e dal pulsante, quindi ha
/// senso che l'utente possa tornare indietro.
class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final created = await ref.read(groupsListProvider.notifier).create(
            name: _name.text,
            description: _description.text,
          );
      if (!mounted) return;
      // replace e non go: dopo aver creato il gruppo non ha senso tornare al
      // modulo gia' compilato, quindi la schermata non deve restare nella
      // cronologia.
      context.go('/groups/${created.id}');
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
      title: 'Nuovo gruppo',
      subtitle: 'Crei il gruppo: ne diventi owner e ricevi subito un codice invito.',
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
              controller: _name,
              enabled: !_busy,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Nome del gruppo',
                helperText: 'Fino a 60 caratteri.',
                prefixIcon: Icon(Icons.group_outlined),
              ),
              validator: GroupValidators.nameError,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _description,
              enabled: !_busy,
              minLines: 3,
              maxLines: 5,
              maxLength: GroupValidators.maxDescriptionLength,
              decoration: const InputDecoration(
                labelText: 'Descrizione',
                hintText: 'Facoltativa: di cosa parla il gruppo?',
                alignLabelWithHint: true,
              ),
              validator: GroupValidators.descriptionError,
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Crea il gruppo'),
            ),
          ],
        ),
      ),
    );
  }
}