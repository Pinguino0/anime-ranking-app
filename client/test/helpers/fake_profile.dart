import 'dart:typed_data';

import 'package:animerank/features/profile/data/profile_repository.dart';
import 'package:animerank/features/profile/domain/user_profile.dart';

/// Repository finto per i test del profilo.
///
/// Registra l'ordine delle operazioni in [calls]: il requisito che conta di
/// piu' qui e' che i file vengano eliminati prima della cancellazione, e un
/// semplice contatore non lo dimostrerebbe.
class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository({UserProfile? profile, NotificationPreferences? preferences})
      : profile = profile ??
            UserProfile(
              id: 'me',
              username: 'mario',
              bio: 'Sono Mario',
              createdAt: DateTime(2026, 1, 15),
            ),
        preferences = preferences ?? const NotificationPreferences();

  UserProfile profile;
  NotificationPreferences preferences;

  final List<String> calls = [];

  int loadCalls = 0;
  int updateCalls = 0;
  int updateAvatarCalls = 0;
  int loadNotificationsCalls = 0;
  int saveNotificationsCalls = 0;
  int deleteStoredFilesCalls = 0;
  int deleteAccountCalls = 0;

  /// File ancora presenti, usato da [deleteStoredFiles] per azzerarsi.
  int storedFiles = 0;

  ProfileFailure? loadFailure;
  ProfileFailure? updateFailure;
  ProfileFailure? updateAvatarFailure;
  ProfileFailure? notificationsFailure;
  ProfileFailure? saveFailure;
  ProfileFailure? deleteFilesFailure;
  ProfileFailure? deleteFailure;

  @override
  Future<UserProfile> loadMine() async {
    loadCalls++;
    final failure = loadFailure;
    if (failure != null) throw failure;
    return profile;
  }

  @override
  Future<UserProfile> updateMine({String? username, String? bio, String? avatarUrl}) async {
    updateCalls++;
    calls.add('update');
    final failure = updateFailure;
    if (failure != null) throw failure;

    profile = UserProfile(
      id: profile.id,
      username: username?.trim() ?? profile.username,
      avatarUrl: avatarUrl?.isEmpty ?? true ? avatarUrl ?? profile.avatarUrl : avatarUrl,
      bio: bio == null
          ? profile.bio
          : (bio.trim().isEmpty ? null : bio.trim()),
      createdAt: profile.createdAt,
    );
    return profile;
  }

  @override
  Future<UserProfile> updateAvatar({
    required Uint8List bytes,
    required String extension,
  }) async {
    updateAvatarCalls++;
    calls.add('updateAvatar');
    final failure = updateAvatarFailure;
    if (failure != null) throw failure;

    profile = UserProfile(
      id: profile.id,
      username: profile.username,
      bio: profile.bio,
      // Indirizzo riconoscibile: il test verifica che l'avatar a schermo venga
      // aggiornato con il risultato dell'upload.
      avatarUrl: 'https://cdn.test/avatar_${bytes.length}.$extension',
      createdAt: profile.createdAt,
    );
    return profile;
  }

  @override
  Future<NotificationPreferences> loadNotifications() async {
    loadNotificationsCalls++;
    final failure = notificationsFailure;
    if (failure != null) throw failure;
    return preferences;
  }

  @override
  Future<void> saveNotifications(NotificationPreferences next) async {
    saveNotificationsCalls++;
    calls.add('saveNotifications');
    final failure = saveFailure;
    if (failure != null) throw failure;
    preferences = next;
  }

  @override
  Future<int> countStoredFiles() async => storedFiles;

  @override
  Future<void> deleteStoredFiles() async {
    deleteStoredFilesCalls++;
    calls.add('deleteStoredFiles');
    final failure = deleteFilesFailure;
    if (failure != null) throw failure;
    storedFiles = 0;
  }

  @override
  Future<void> deleteAccount() async {
    deleteAccountCalls++;

    // Come il repository reale, che elimina i file prima di chiamare la RPC.
    // Il finto deve riprodurre il contratto, altrimenti la UI sembrerebbe
    // saltare il passaggio di pulizia.
    await deleteStoredFiles();
    calls.add('deleteAccount');

    final failure = deleteFailure;
    if (failure != null) throw failure;
  }
}

/// Profilo di comodo per i test.
UserProfile buildProfile({
  String id = 'me',
  String username = 'mario',
  String? bio = 'Sono Mario',
  String? avatarUrl,
}) =>
    UserProfile(
      id: id,
      username: username,
      bio: bio,
      avatarUrl: avatarUrl,
      createdAt: DateTime(2026, 1, 15),
    );
