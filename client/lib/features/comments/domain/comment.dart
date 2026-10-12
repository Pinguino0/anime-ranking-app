import '../../../core/error/app_failure.dart';

/// Errore sulle operazioni dei commenti.
class CommentsFailure extends AppFailure {
  const CommentsFailure(super.message, {super.isRetryable});
}

/// Limiti del commento, allineati ai vincoli della tabella `comments`.
class CommentValidators {
  const CommentValidators._();

  /// Stesso tetto del CHECK `comments_content_check`.
  static const int maxLength = 4000;

  /// Errore sul testo, o null se il commento si puo' pubblicare.
  ///
  /// Il controllo gira sia qui sia nel repository, cosi' un modulo che
  /// dimenticasse di chiamarlo non manderebbe comunque una riga che il server
  /// rifiuterebbe.
  static String? contentError(String value) {
    final text = value.trim();
    if (text.isEmpty) return 'Scrivi qualcosa prima di pubblicare.';
    if (text.length > maxLength) {
      return 'Testo troppo lungo: massimo $maxLength caratteri.';
    }
    return null;
  }
}

/// Un commento o una risposta.
///
/// [parentId] nullo identifica un commento radice; valorizzato, una risposta.
/// Le risposte sono righe della stessa tabella con `parent_id`, non una tabella
/// separata: un solo tipo, una sola policy da tenere allineata.
class Comment {
  const Comment({
    required this.id,
    required this.groupId,
    required this.animeId,
    required this.userId,
    required this.content,
    required this.createdAt,
    this.parentId,
    this.isSpoiler = false,
    this.updatedAt,
    this.authorName = '',
    this.authorAvatarUrl,
  });

  final String id;
  final String groupId;
  final String animeId;

  /// Autore: serve anche a decidere se mostrare "Elimina".
  final String userId;

  /// Commento a cui questa riga risponde, se e' una risposta.
  final String? parentId;

  final String content;

  /// Testo segnato come spoiler: va nascosto finche' non lo si scopre.
  final bool isSpoiler;

  final DateTime createdAt;
  final DateTime? updatedAt;

  /// Nome utente risolto dal profilo incastonato nella query.
  final String authorName;
  final String? authorAvatarUrl;

  bool get isRoot => parentId == null;

  /// Nome mostrato: come [GroupMember.label], un testo vuoto darebbe un avatar
  /// senza iniziale.
  String get authorLabel => authorName.trim().isEmpty ? 'Utente' : authorName;

  /// Vero se il commento e' stato modificato dopo la pubblicazione.
  ///
  /// La tolleranza di un secondo assorbe la differenza fra `created_at` e
  /// `updated_at`, che nascono da due `now()` distinti nella stessa scrittura:
  /// senza, ogni commento appena inserito sembrerebbe modificato.
  bool get isEdited =>
      updatedAt != null &&
      updatedAt!.difference(createdAt).inSeconds.abs() > 1;

  factory Comment.parse(Map<String, dynamic> json) {
    // PostgREST incastra il profilo dell'autore dentro `profiles`. Se per un
    // profilo mancante l'oggetto non arriva, si resta con i campi vuoti invece
    // di far fallire tutta la lista per una riga.
    final profile = json['profiles'];
    final author = profile is Map
        ? Map<String, dynamic>.from(profile)
        : const <String, dynamic>{};

    return Comment(
      id: '${json['id']}',
      groupId: '${json['group_id']}',
      animeId: '${json['anime_id']}',
      userId: '${json['user_id']}',
      parentId: json['parent_id'] as String?,
      content: json['content'] as String? ?? '',
      isSpoiler: json['is_spoiler'] as bool? ?? false,
      createdAt:
          DateTime.tryParse('${json['created_at']}')?.toLocal() ?? DateTime.now(),
      updatedAt: DateTime.tryParse('${json['updated_at']}')?.toLocal(),
      authorName: author['username'] as String? ?? '',
      authorAvatarUrl: author['avatar_url'] as String?,
    );
  }
}
