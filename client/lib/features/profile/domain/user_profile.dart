import '../../../core/error/app_failure.dart';

/// Errore sulle operazioni del profilo.
class ProfileFailure extends AppFailure {
  const ProfileFailure(super.message, {super.isRetryable});
}

/// Errore durante la cancellazione dell'account.
///
/// Ha un tipo dedicato perche' la schermata deve poter distinguere due
/// situazioni che sembrano uguali ma non lo sono: un errore qualsiasi (che si
/// risolve riprovando) e l'account che non e' stato cancellato (che chiede
/// all'utente un intervento, e non ha senso riprovare da soli).
class AccountDeletionFailure extends ProfileFailure {
  const AccountDeletionFailure(super.message, {super.isRetryable, this.remainingFiles = 0})
      : super();

  /// File rimasti da eliminare, se l'errore e' quello della Storage API.
  ///
  /// Il backend conta i file e comunica quanti sono: senza questo numero
  /// l'utente riceverebbe solo "cancella prima i file" e non saprebbe quanto
  /// manca.
  final int remainingFiles;

  bool get hasRemainingFiles => remainingFiles > 0;
}

/// Profilo pubblico dell'utente.
class UserProfile {
  const UserProfile({
    required this.id,
    required this.username,
    required this.createdAt,
    this.avatarUrl,
    this.bio,
  });

  final String id;
  final String username;
  final String? avatarUrl;
  final String? bio;
  final DateTime createdAt;

  /// true se non c'e' nessuna bio: la UI non deve mostrare "Nessuna bio
  /// descritta", che sembra un dato mancante invece di una scelta.
  bool get hasBio => bio?.trim().isNotEmpty ?? false;

  /// Iniziale per l'avatar di fallback.
  ///
  /// Il CHECK sul database garantisce almeno 3 caratteri, quindi `substring`
  /// non va oltre i limiti, ma il fallback resta necessario perche' la lista
  /// puo' essere costruita con dati parziali nei test.
  String get initial => username.isEmpty ? '?' : username[0].toUpperCase();

  factory UserProfile.parse(Map<String, dynamic> json) => UserProfile(
        id: '${json['id']}',
        username: json['username'] as String? ?? 'Utente',
        avatarUrl: json['avatar_url'] as String?,
        bio: json['bio'] as String?,
        createdAt: DateTime.tryParse('${json['created_at']}')?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  @override
  bool operator ==(Object other) => other is UserProfile && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Preferenze di notifica.
///
/// Un tipo dedicato invece di una mappa bool-per-chiave: con una mappa ogni
/// lettura sarebbe `prefs['notify_votes']` e un errore di refactoring
/// passerebbe inosservato, restituendo null e facendo cadere l'interruttore.
class NotificationPreferences {
  const NotificationPreferences({
    this.push = true,
    this.votes = true,
    this.friends = true,
    this.tournaments = true,
    this.rankChanges = true,
  });

  final bool push;
  final bool votes;
  final bool friends;
  final bool tournaments;
  final bool rankChanges;

  /// true se e' tutto spento: permette di dire "non disturbare piu'" con un
  /// solo interruttore invece di cinque.
  bool get allOff => !push && !votes && !friends && !tournaments && !rankChanges;

  NotificationPreferences copyWith({
    bool? push,
    bool? votes,
    bool? friends,
    bool? tournaments,
    bool? rankChanges,
  }) =>
      NotificationPreferences(
        // `?? this.x` invece di un default fisso: `copyWith()` senza argomenti
        // deve restituire lo stesso oggetto, non uno con tutto acceso.
        push: push ?? this.push,
        votes: votes ?? this.votes,
        friends: friends ?? this.friends,
        tournaments: tournaments ?? this.tournaments,
        rankChanges: rankChanges ?? this.rankChanges,
      );

  factory NotificationPreferences.parse(Map<String, dynamic> json) =>
      NotificationPreferences(
        push: json['notify_push'] as bool? ?? true,
        votes: json['notify_votes'] as bool? ?? true,
        friends: json['notify_friends'] as bool? ?? true,
        tournaments: json['notify_tournaments'] as bool? ?? true,
        rankChanges: json['notify_rank_changes'] as bool? ?? true,
      );

  /// Chiavi delle colonne, per non ripetere i nomi a mano in due punti.
  static const String pushColumn = 'notify_push';
  static const String votesColumn = 'notify_votes';
  static const String friendsColumn = 'notify_friends';
  static const String tournamentsColumn = 'notify_tournaments';
  static const String rankChangesColumn = 'notify_rank_changes';
}

/// Regole sui campi del profilo.
///
/// I limiti replicano i CHECK del database: verificarli qui da un feedback
/// immediato, senza aspettare il server che risponderebbe comunque con lo
/// stesso errore.
/// * `profiles_username_format`: 3-24 caratteri alfanumerici o underscore.
/// * `profiles_bio_length`: massimo 280 caratteri.
class ProfileValidators {
  const ProfileValidators._();

  static const int minUsernameLength = 3;
  static const int maxUsernameLength = 24;
  static const int maxBioLength = 280;

  static final RegExp _usernamePattern = RegExp(r'^[A-Za-z0-9_]+$');

  static String? usernameError(String? value) {
    final v = value?.trim() ?? '';

    if (v.isEmpty) return 'Scegli un nome utente.';
    if (v.length < minUsernameLength) return 'Almeno $minUsernameLength caratteri.';
    if (v.length > maxUsernameLength) return 'Massimo $maxUsernameLength caratteri.';

    // La regex viene controllata prima del CHECK del database: mostrare qui
    // il carattere non ammesso evita un viaggio di rete per un accento o uno
    // spazio che il server rifiuterebbe comunque.
    if (!_usernamePattern.hasMatch(v)) {
      return 'Solo lettere, numeri e _ (senza spazi).';
    }

    return null;
  }

  static String? bioError(String? value) {
    final v = value?.trim() ?? '';
    if (v.length > maxBioLength) return 'Massimo $maxBioLength caratteri.';
    return null;
  }
}
