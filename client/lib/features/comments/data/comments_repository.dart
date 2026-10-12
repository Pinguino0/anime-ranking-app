import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/comment.dart';

/// Accesso ai commenti di un anime dentro un gruppo.
///
/// Ogni operazione e' vincolata a una coppia gruppo+anime: la tabella non ha
/// un id globale di discussione, e le policy RLS lasciano leggere e scrivere
/// solo nei gruppi di cui si e' membro.
abstract interface class CommentsRepository {
  /// Id dell'utente collegato, o null se la sessione non c'e'.
  ///
  /// Esposto perche' la UI deve sapere quali righe puo' eliminare: mostrarne
  /// una che il server rifiuterebbe e' peggio che non mostrarla.
  String? get currentUserId;

  Future<List<Comment>> load({
    required String groupId,
    required String animeId,
  });

  /// Pubblica un commento (radice se [parentId] e' nullo) e lo restituisce.
  Future<Comment> add({
    required String groupId,
    required String animeId,
    required String content,
    required bool spoiler,
    String? parentId,
  });

  /// Elimina un commento: le risposte seguono per ON DELETE CASCADE.
  Future<void> delete(String commentId);
}

class SupabaseCommentsRepository implements CommentsRepository {
  SupabaseCommentsRepository(this._client);

  final SupabaseClient _client;

  /// Colonne lette dal client, con il profilo dell'autore incastonato.
  ///
  /// L'embed si chiama `profiles` perche' `comments.user_id` punta a quella
  /// tabella: PostgREST lo risolve da solo e non serve un alias da tenere
  /// allineato a mano.
  static const String _columns =
      'id, group_id, anime_id, user_id, parent_id, content, is_spoiler, '
      'created_at, updated_at, profiles(username, avatar_url)';

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  String get _uid {
    final id = currentUserId;
    if (id == null) {
      throw const CommentsFailure('Devi essere collegato.');
    }
    return id;
  }

  @override
  Future<List<Comment>> load({
    required String groupId,
    required String animeId,
  }) async {
    try {
      final rows = await _client
          .from('comments')
          .select(_columns)
          .eq('group_id', groupId)
          .eq('anime_id', animeId)
          // Dal piu' vecchio: e' l'ordine in cui si legge una conversazione. Il
          // raggruppamento radice/risposte lo fa la UI, che sa gia' l'albero.
          .order('created_at', ascending: true);

      return rows.map(Comment.parse).toList();
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is CommentsFailure) rethrow;
      throw const CommentsFailure(
        'Commenti non disponibili. Riprova.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<Comment> add({
    required String groupId,
    required String animeId,
    required String content,
    required bool spoiler,
    String? parentId,
  }) async {
    // Stesso vincolo del CHECK: fallire qui evita una richiesta che il server
    // rifiuterebbe comunque, e l'errore arriva subito.
    final error = CommentValidators.contentError(content);
    if (error != null) throw CommentsFailure(error);

    try {
      final row = await _client
          .from('comments')
          .insert({
            'group_id': groupId,
            'anime_id': animeId,
            'user_id': _uid,
            'parent_id': parentId,
            'content': content.trim(),
            'is_spoiler': spoiler,
          })
          // `select` sulla insert: serve la riga con il profilo incastonato,
          // perche' il client non conosce da solo nome e avatar dell'autore.
          .select(_columns)
          .single();

      return Comment.parse(Map<String, dynamic>.from(row));
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is CommentsFailure) rethrow;
      throw const CommentsFailure(
        'Commento non pubblicato. Riprova.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<void> delete(String commentId) async {
    try {
      await _client.from('comments').delete().eq('id', commentId);
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is CommentsFailure) rethrow;
      throw const CommentsFailure(
        'Commento non eliminato. Riprova.',
        isRetryable: true,
      );
    }
  }

  /// Traduce l'errore Postgres in un messaggio per l'utente.
  ///
  /// Alcuni codici hanno un messaggio utile scritto dal database (trigger di
  /// coerenza, vincoli): quelli si lasciano passare. Il resto diventa un testo
  /// generico, perche' "row-level security" o "network error" non dicono
  /// niente a chi legge.
  CommentsFailure _translate(PostgrestException e) {
    const passthrough = {
      '22023', // validazione input (risposta a una risposta)
      '42501', // permessi
      '28000', // autenticazione
      '23503', // riferimento non valido
    };

    if (passthrough.contains(e.code) && e.message.trim().isNotEmpty) {
      return CommentsFailure(e.message.trim());
    }

    if (e.code == null && e.message.contains('row-level security')) {
      return const CommentsFailure('Non puoi commentare in questo gruppo.');
    }

    return const CommentsFailure(
      'Operazione non riuscita. Riprova.',
      isRetryable: true,
    );
  }
}
