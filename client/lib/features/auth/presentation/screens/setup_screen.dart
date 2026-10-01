import 'package:flutter/material.dart';

import '../../../../core/env/app_config.dart';

/// Schermata mostrata quando mancano le credenziali Supabase.
///
/// Un crash con stack trace su schermo nero non dice nulla a chi apre l'app
/// per la prima volta. Qui si spiega cosa non torna e si mostra il comando
/// esatto da eseguire, cosi' il problema si risolve senza aprire un issue.
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.settings_ethernet,
                    size: 40,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 20),
                  Text('Configurazione incompleta',
                      style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text(
                    AppConfig.configurationError,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _Command(
                    'flutter run\n'
                    '  --dart-define=SUPABASE_URL=https://<tuo-progetto>.supabase.co\n'
                    '  --dart-define=SUPABASE_ANON_KEY=<publishable key>',
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'La chiave si trova in Supabase, in Project Settings -> API Keys. '
                    'Serve la publishable key (sb_publishable_...), non la secret key: '
                    'la secret darebbe a chiunque apra il pacchetto lettura completa '
                    'del database.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Blocco monospaziato con il comando da eseguire.
///
/// Blocchi con sfondo arrotondato e spaziatura fissa, perche' il comando
/// contiene righe spezzate: renderizzato come testo normale i a capo andrebbero
/// persi e diventerebbe un blocco unico illeggibile.
class _Command extends StatelessWidget {
  const _Command(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: SelectableText(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
          height: 1.5,
        ),
      ),
    );
  }
}