import 'package:animerank/core/error/app_failure.dart';
import 'package:animerank/features/groups/data/groups_repository.dart';
import 'package:animerank/features/groups/domain/group.dart';

/// Data fissa per i membri di comodo.
///
/// Costante e non `DateTime(2026, ...)`: `DateTime` non e' una costante in Dart,
/// quindi un `const GroupMember` con dentro un `DateTime` non compilerebbe.
final DateTime _epoch = DateTime(2026, 1, 1);

/// Repository finto per i test.
///
/// Tiene i dati in memoria e conta le chiamate, cosi' i test possono
/// verificare che la UI chieda davvero al repository e non solo disegni
/// schermate plausibili.
class FakeGroupsRepository implements GroupsRepository {
  FakeGroupsRepository({List<AnimeGroup>? initial}) : _groups = [...?initial];

  final List<AnimeGroup> _groups;

  int listCalls = 0;
  int createCalls = 0;
  int joinCalls = 0;
  int leaveCalls = 0;
  int regenerateCalls = 0;
  int setRoleCalls = 0;
  int kickCalls = 0;
  int membersCalls = 0;
  int transferCalls = 0;

  List<String> joinedCodes = [];

  /// Membri restituiti da [listMembers].
  ///
  /// Se resta vuoto il finto ne crea uno solo: un gruppo appena creato ha
  /// esattamente l'owner dentro, e un elenco vuoto in tutti i test renderebbe
  /// il selettore irraggiungibile.
  List<GroupMember> members = [
    GroupMember(
      userId: 'u2',
      username: 'asuka',
      role: GroupRole.member,
      joinedAt: _epoch,
    ),
  ];

  /// Trasferimenti richiesti, come "groupId|newOwnerId".
  List<String> transfers = [];

  /// Errore da sollevare alla prossima chiamata di [listMembers].
  GroupsFailure? membersFailure;

  /// Errore da sollevare alla prossima chiamata di [transferOwnership].
  GroupsFailure? transferFailure;

  /// Errore da sollevare alla prossima chiamata di [listMine].
  GroupsFailure? listFailure;

  /// Errore da sollevare alla prossima chiamata di [create].
  GroupsFailure? createFailure;

  /// Errore da sollevare alla prossima chiamata di [join].
  GroupsFailure? joinFailure;

  /// Errore da sollevare alla prossima chiamata di [leave].
  GroupsFailure? leaveFailure;

  int _seq = 0;

  @override
  Future<List<AnimeGroup>> listMine() async {
    listCalls++;
    final failure = listFailure;
    if (failure != null) throw failure;
    return List.unmodifiable(_groups);
  }

  @override
  Future<AnimeGroup> create({required String name, String? description}) async {
    createCalls++;
    final failure = createFailure;
    if (failure != null) throw failure;

    final created = AnimeGroup(
      id: 'g${++_seq}',
      name: name.trim(),
      description: (description?.trim().isEmpty ?? true) ? null : description!.trim(),
      inviteCode: 'ANIME-${_seq.toString().padLeft(6, '0')}',
      ownerId: 'me',
      myRole: GroupRole.owner,
      createdAt: DateTime(2026, 1, 1 + _seq),
    );
    _groups.add(created);
    return created;
  }

  @override
  Future<AnimeGroup> join(String inviteCode) async {
    joinCalls++;
    joinedCodes.add(inviteCode);
    final failure = joinFailure;
    if (failure != null) throw failure;

    final joined = AnimeGroup(
      id: 'g${++_seq}',
      name: 'Gruppo $_seq',
      inviteCode: inviteCode,
      ownerId: 'altro',
      myRole: GroupRole.member,
      createdAt: DateTime(2026, 2, 1 + _seq),
    );
    _groups.add(joined);
    return joined;
  }

  @override
  Future<void> leave(String groupId) async {
    leaveCalls++;
    final failure = leaveFailure;
    if (failure != null) throw failure;
    _groups.removeWhere((g) => g.id == groupId);
  }

  @override
  Future<String> regenerateInviteCode(String groupId) async {
    regenerateCalls++;
    final index = _groups.indexWhere((g) => g.id == groupId);
    if (index == -1) throw const GroupsFailure('Gruppo non trovato.');
    final code = 'ANIME-R$regenerateCalls';
    _groups[index] = _groups[index].copyWith(inviteCode: code);
    return code;
  }

  @override
  Future<void> setMemberRole({
    required String groupId,
    required String userId,
    required GroupRole role,
  }) async {
    setRoleCalls++;
  }

  @override
  Future<void> kickMember({required String groupId, required String userId}) async {
    kickCalls++;
  }

  @override
  Future<List<GroupMember>> listMembers(String groupId) async {
    membersCalls++;
    final failure = membersFailure;
    if (failure != null) throw failure;
    return List.unmodifiable(members);
  }

  @override
  Future<void> transferOwnership({
    required String groupId,
    required String newOwnerId,
  }) async {
    transferCalls++;
    transfers.add('$groupId|$newOwnerId');
    final failure = transferFailure;
    if (failure != null) throw failure;

    final index = _groups.indexWhere((g) => g.id == groupId);
    if (index != -1) _groups[index] = _groups[index].copyWithOwner(newOwnerId);
  }
}

/// Gruppo di comodo per i test.
///
/// [role] permette di coprire i tre casi della UI senza ripetere la costruzione.
AnimeGroup buildGroup({
  String id = 'g1',
  String name = 'Sala pausa',
  String description = 'Si pausa insieme',
  String inviteCode = 'ANIME-000001',
  GroupRole role = GroupRole.owner,
}) =>
    AnimeGroup(
      id: id,
      name: name,
      description: description,
      inviteCode: inviteCode,
      ownerId: 'owner-1',
      myRole: role,
      createdAt: DateTime(2026, 1, 1),
    );