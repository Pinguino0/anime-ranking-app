import 'package:flutter/material.dart';

/// Avatar con fallback su iniziale.
///
/// L'immagine viene rimpiazzata dall'iniziale se manca o se non si carica: un
/// riquadro grigio o l'icona di errore di [Image.network] non dicono nulla,
/// mentre l'iniziale identifica comunque la persona.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    required this.fallbackText,
    required this.size,
    this.url,
    super.key,
  });

  final String? url;
  final String fallbackText;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatar = url?.isNotEmpty == true
        ? Image.network(
            url!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stack) =>
                _Initials(theme: theme, fallbackText: fallbackText),
          )
        : _Initials(theme: theme, fallbackText: fallbackText);

    return ClipOval(
      child: SizedBox.square(dimension: size, child: avatar),
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.theme, required this.fallbackText});

  final ThemeData theme;
  final String fallbackText;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: theme.colorScheme.primaryContainer,
      child: Center(
        child: Text(
          fallbackText,
          style: theme.textTheme.headlineMedium?.copyWith(
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
