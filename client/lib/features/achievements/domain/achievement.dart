import '../../../core/error/app_failure.dart';

/// Errore nel caricamento degli obiettivi.
class AchievementsFailure extends AppFailure {
  const AchievementsFailure(super.message, {super.isRetryable});
}

/// Un obiettivo del catalogo, con lo stato per l'utente collegato.
///
/// [unlockedAt] nullo significa "non ancora sbloccato": e' la condizione normale
/// della maggior parte dell'elenco, non un errore.
class Achievement {
  const Achievement({
    required this.id,
    required this.code,
    required this.name,
    required this.description,
    required this.icon,
    required this.requirement,
    this.hidden = false,
    this.unlockedAt,
  });

  /// Chiave primaria del catalogo, usata per incrociare gli sblocchi.
  final String id;

  /// Codice stabile (es. `first_vote`), quello citato dalle notifiche.
  final String code;

  final String name;
  final String description;

  /// Emoji del catalogo.
  final String icon;

  /// Regola in chiaro ("Vota 10 anime").
  final String requirement;

  /// Obiettivo nascosto: non compare finche' non e' sbloccato.
  final bool hidden;

  final DateTime? unlockedAt;

  bool get isUnlocked => unlockedAt != null;

  /// Vero se va mostrato: un obiettivo nascosto appare solo una volta
  /// sbloccato, altrimenti l'elenco rivelerebbe cosa c'e' da scoprire.
  bool get isVisible => !hidden || isUnlocked;

  /// Copia con la data di sblocco risolta.
  Achievement withUnlock(DateTime? at) => Achievement(
        id: id,
        code: code,
        name: name,
        description: description,
        icon: icon,
        requirement: requirement,
        hidden: hidden,
        unlockedAt: at,
      );

  factory Achievement.parse(Map<String, dynamic> json) => Achievement(
        id: '${json['id']}',
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? 'Obiettivo',
        description: json['description'] as String? ?? '',
        icon: json['icon'] as String? ?? '🏆',
        requirement: json['requirement'] as String? ?? '',
        hidden: json['hidden'] as bool? ?? false,
      );
}
