import 'package:flutter/material.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../../core/theme/app_theme.dart';

/// Guscio comune alle schermate di autenticazione.
///
/// Su telefono il modulo occupa tutta la larghezza disponibile. Da [LayoutSize.medium]
/// in su si ferma a 440px e si centra: un campo da 1200px e' scomodo da leggere
/// e da scrivere, perche' l'occhio deve tornare indietro a ogni riga.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    required this.title,
    required this.subtitle,
    required this.child,
    this.footer,
    super.key,
  });

  final String title;
  final String subtitle;
  final Widget child;

  /// Link in fondo al modulo: "Non hai un account? Registrati".
  final Widget? footer;

  /// Larghezza massima del modulo.
  static const double _maxFormWidth = 440;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = Breakpoints.fromContext(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            // 24 orizzontali su telefono servono per i campi con icona.
            padding: EdgeInsets.symmetric(
              horizontal: size.isCompact ? 24 : 32,
              vertical: 32,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxFormWidth),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Wordmark(),
                  const SizedBox(height: 28),
                  Text(title, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  child,
                  if (footer != null) ...[
                    const SizedBox(height: 24),
                    footer!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Logo testuale.
///
/// Non un'immagine: cosi' non serve un asset, non c'e' uno sfondo che non
/// si adatta ai tempi, e resta leggibile a qualsiasi dimensione.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            gradient: ArColors.brand,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(
            'AR',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'AnimeRank',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

/// Banner d'errore riusabile nei moduli.
///
/// [tone] distingue l'errore bloccante dal semplice avviso, cosi' il colore
/// non e' l'unico modo di capire che qualcosa non va: anche l'icona cambia.
class AuthErrorBanner extends StatelessWidget {
  const AuthErrorBanner.error(this.message, {super.key}) : tone = AuthBannerTone.error;

  const AuthErrorBanner.notice(this.message, {super.key}) : tone = AuthBannerTone.notice;

  final String message;
  final AuthBannerTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (bg, fg, icon) = switch (tone) {
      AuthBannerTone.error => (
          theme.colorScheme.errorContainer,
          theme.colorScheme.onErrorContainer,
          Icons.error_outline,
        ),
      AuthBannerTone.notice => (
          theme.colorScheme.secondaryContainer,
          theme.colorScheme.onSecondaryContainer,
          Icons.check_circle_outline,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

enum AuthBannerTone { error, notice }