import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../domain/user_profile.dart';
import '../profile_controller.dart';
import '../widgets/avatar.dart';

/// Schermata profilo.
///
/// Mostra i dati pubblici, permette di modificarli e porta alle impostazioni.
/// Niente "cancella account" qui dentro il form: e' un'azione distruttiva e
/// sta in una schermata separata.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final size = Breakpoints.fromContext(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profilo'),
        actions: [
          IconButton(
            tooltip: 'Impostazioni notifiche',
            onPressed: () => context.push('/profile/notifications'),
            icon: const Icon(Icons.notifications_outlined),
          ),
        ],
      ),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          message: '$error',
          onRetry: () => ref.read(profileProvider.notifier).refresh(),
        ),
        data: (data) => _Body(profile: data, wide: !size.isCompact),
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.profile, required this.wide});

  final UserProfile profile;
  final bool wide;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  final _formKey = GlobalKey<FormState>();
  late final _username = TextEditingController(text: widget.profile.username);
  late final _bio = TextEditingController(text: widget.profile.bio ?? '');

  bool _busy = false;
  String? _error;
  bool _saved = false;

  @override
  void dispose() {
    _username.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
      _saved = false;
    });

    try {
      await ref.read(profileProvider.notifier).save(
            username: _username.text,
            bio: _bio.text,
          );
      if (!mounted) return;
      setState(() => _saved = true);
    } on ProfileFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final theme = Theme.of(context);

    // Su schermo largo il form sta a sinistra e l'anteprima a destra: senza
    // questo, a 1400px l'avatar resterebbe schiacciato in alto a sinistra con
    // un campo da 1200px accanto, illeggibile.
    final form = Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            AuthErrorBanner.error(_error!),
            const SizedBox(height: 16),
          ],
          if (_saved) ...[
            AuthErrorBanner.notice('Profilo salvato.'),
            const SizedBox(height: 16),
          ],
          TextFormField(
            controller: _username,
            enabled: !_busy,
            textInputAction: TextInputAction.next,
            // inputFormatters e non solo validazione: senza, il campo puo'
            // assumere valori che il CHECK del database rifiuterebbe e
            // l'utente scoprirebbe il problema solo salvando.
            inputFormatters: [
              LengthLimitingTextInputFormatter(ProfileValidators.maxUsernameLength),
              FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9_]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Nome utente',
              helperText: '3-24 caratteri: lettere, numeri e _',
              prefixIcon: Icon(Icons.alternate_email),
            ),
            validator: ProfileValidators.usernameError,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _bio,
            enabled: !_busy,
            minLines: 3,
            maxLines: 6,
            maxLength: ProfileValidators.maxBioLength,
            decoration: const InputDecoration(
              labelText: 'Bio',
              hintText: 'Qualcosa su di te (facoltativo)',
              alignLabelWithHint: true,
            ),
            validator: ProfileValidators.bioError,
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Salva'),
          ),
        ],
      ),
    );

    final preview = Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ProfileAvatar(url: profile.avatarUrl, fallbackText: profile.initial, size: 96),
        const SizedBox(height: 16),
        Text(profile.username, style: theme.textTheme.titleLarge),
        if (profile.hasBio) ...[
          const SizedBox(height: 8),
          Text(
            profile.bio!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Membro dal ${_formatDate(profile.createdAt)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => ref.read(authStatusProvider.notifier).signOut(),
          icon: const Icon(Icons.logout),
          label: const Text('Esci'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => context.push('/profile/delete'),
          icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
          label: Text('Elimina account', style: TextStyle(color: theme.colorScheme.error)),
        ),
      ],
    );

    if (!widget.wide) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [preview, const SizedBox(height: 32), form],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 280, child: preview),
          const SizedBox(width: 32),
          Expanded(child: form),
        ],
      ),
    );
  }

  /// Data in formato italiano leggibile.
  ///
  /// `toLocalizedString` richiederebbe `intl`: per un campo solo qui non vale
  /// la pena una dipendenza e una tabella di localizzazione.
  String _formatDate(DateTime date) {
    const months = [
      'gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno',
      'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AuthErrorBanner.error(message),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onRetry, child: const Text('Riprova')),
            ],
          ),
        ),
      ),
    );
  }
}
