import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_retry.dart';
import '../data/comments_repository.dart';
import '../domain/comment.dart';

/// Repository dei commenti.
final commentsRepositoryProvider = Provider<CommentsRepository>((ref) {
  throw StateError('commentsRepositoryProvider non e stato inizializzato.');
});

/// Chiave di una discussione: un anime dentro un gruppo.
///
/// Un record e non una classe: l'uguaglianza strutturale di Dart e' esattamente
/// quella che serve al `family` per capire se due richieste sono la stessa.
typedef CommentsKey = ({String groupId, String animeId});

/// Commenti di un anime in un gruppo.
class CommentsController extends AsyncNotifier<List<Comment>> {
  CommentsController(this.key);

  final CommentsKey key;

  CommentsRepository get _repository => ref.read(commentsRepositoryProvider);

  @override
  Future<List<Comment>> build() => ref
      .watch(commentsRepositoryProvider)
      .load(groupId: key.groupId, animeId: key.animeId);

  /// Pubblica e rilegge.
  ///
  /// Si ricarica invece di aggiungere in locale perche' il commento arriva con
  /// nome e avatar dell'autore risolti dal server, che sono l'unica parte che
  /// il client non puo' comporre da solo.
  Future<void> post({
    required String content,
    required bool spoiler,
    String? parentId,
  }) async {
    await _repository.add(
      groupId: key.groupId,
      animeId: key.animeId,
      content: content,
      spoiler: spoiler,
      parentId: parentId,
    );
    ref.invalidateSelf();
    await future;
  }

  Future<void> remove(String commentId) async {
    await _repository.delete(commentId);
    ref.invalidateSelf();
    await future;
  }
}

final commentsProvider = AsyncNotifierProvider.family<CommentsController,
    List<Comment>, CommentsKey>(
  CommentsController.new,
  retry: appRetry,
);
