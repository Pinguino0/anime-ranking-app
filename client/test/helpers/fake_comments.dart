import 'package:animerank/features/comments/data/comments_repository.dart';
import 'package:animerank/features/comments/domain/comment.dart';

/// Repository finto dei commenti.
///
/// Tiene le righe in memoria e conta le chiamate: i test possono verificare che
/// la UI chieda davvero al repository e non disegni solo schermate plausibili.
class FakeCommentsRepository implements CommentsRepository {
  FakeCommentsRepository({
    this.currentUserId = 'me',
    List<Comment>? comments,
  }) : comments = [...?comments];

  @override
  final String? currentUserId;

  /// Tutti i commenti, di ogni discussione. [load] filtra per gruppo e anime.
  final List<Comment> comments;

  CommentsFailure? loadFailure;
  CommentsFailure? addFailure;
  CommentsFailure? deleteFailure;

  int loadCalls = 0;
  int addCalls = 0;
  int deleteCalls = 0;

  /// Dettaglio dell'ultima pubblicazione, per le verifiche.
  ({String groupId, String animeId, String content, bool spoiler, String? parentId})?
      lastAdd;

  int _seq = 0;

  @override
  Future<List<Comment>> load({
    required String groupId,
    required String animeId,
  }) async {
    loadCalls++;
    final failure = loadFailure;
    if (failure != null) throw failure;
    return List.unmodifiable(
      comments.where((c) => c.groupId == groupId && c.animeId == animeId),
    );
  }

  @override
  Future<Comment> add({
    required String groupId,
    required String animeId,
    required String content,
    required bool spoiler,
    String? parentId,
  }) async {
    addCalls++;
    lastAdd = (
      groupId: groupId,
      animeId: animeId,
      content: content,
      spoiler: spoiler,
      parentId: parentId,
    );
    final failure = addFailure;
    if (failure != null) throw failure;

    final created = Comment(
      id: 'c${++_seq}',
      groupId: groupId,
      animeId: animeId,
      userId: currentUserId ?? 'me',
      parentId: parentId,
      content: content.trim(),
      isSpoiler: spoiler,
      createdAt: DateTime(2026, 5, 1, 10, _seq),
      authorName: 'me',
    );
    comments.add(created);
    return created;
  }

  @override
  Future<void> delete(String commentId) async {
    deleteCalls++;
    final failure = deleteFailure;
    if (failure != null) throw failure;

    comments.removeWhere((c) => c.id == commentId);
    // Cascata come il vincolo ON DELETE CASCADE: le risposte seguono la radice.
    comments.removeWhere((c) => c.parentId == commentId);
  }
}

/// Commento di comodo per i test.
Comment buildComment({
  String id = 'c1',
  String groupId = 'g1',
  String animeId = 'a1',
  String userId = 'other',
  String? parentId,
  String content = 'Bello!',
  bool isSpoiler = false,
  DateTime? createdAt,
  DateTime? updatedAt,
  String authorName = 'asuka',
  String? authorAvatarUrl,
}) =>
    Comment(
      id: id,
      groupId: groupId,
      animeId: animeId,
      userId: userId,
      parentId: parentId,
      content: content,
      isSpoiler: isSpoiler,
      createdAt: createdAt ?? DateTime(2026, 5, 1, 10),
      updatedAt: updatedAt,
      authorName: authorName,
      authorAvatarUrl: authorAvatarUrl,
    );
