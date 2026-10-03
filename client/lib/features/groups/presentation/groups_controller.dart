import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_retry.dart';
import '../data/groups_repository.dart';
import '../domain/group.dart';

/// Repository dei gruppi.
///
/// Esposto come provider perche' i test iniettino un finto con
/// `overrideWithValue` e le schermate restino indipendenti da Supabase.
final groupsRepositoryProvider = Provider<GroupsRepository>((ref) {
  throw StateError('groupsRepositoryProvider non e stato inizializzato.');
});

/// Elenco dei gruppi dell'utente.
///
/// Un [AsyncNotifier] perche' il caricamento e asincrono e l'errore deve
/// restare visibile: schermare il fallimento e distinguere "ancora carico" da
/// "non c'e' niente" e "ha sbagliato".
class GroupsListController extends AsyncNotifier<List<AnimeGroup>> {
  @override
  Future<List<AnimeGroup>> build() =>
      ref.watch(groupsRepositoryProvider).listMine();

  /// Ricarica la lista.
  ///
  /// Esposta perche' dopo una join o una creazione la lista va riletta dal
  /// server: la RLS e le regole di ruolo stanno li', e la copia locale
  /// sbaglierebbe.
  Future<void> refresh() async {
    // `invalidateSelf` e non `AsyncValue.guard`: guard imposta uno stato
    // `AsyncLoading` e Riverpod riesegue `build`, quindi `listMine` verrebbe
    // chiamata due volte per un solo retry. Con `invalidate` il Future viene
    // ricalcolato una volta sola e l'attesa qui e' sul risultato vero.
    ref.invalidateSelf();
    await future;
  }

  /// Crea un gruppo e lo aggiunge in cima alla lista.
  Future<AnimeGroup> create({required String name, String? description}) async {
    final created = await ref
        .read(groupsRepositoryProvider)
        .create(name: name, description: description);

    // Inserimento locale invece di un reload: il gruppo appena creato si vede
    // subito e senza una seconda richiesta. Se il reload fallisse l'utente
    // vedrebbe comparire il gruppo e poi sparire, che e' peggio di aspettare.
    final current = state.value ?? const <AnimeGroup>[];
    state = AsyncData([created, ...current]);
    return created;
  }

  /// Entra in un gruppo e lo aggiunge in cima alla lista.
  Future<AnimeGroup> join(String inviteCode) async {
    final joined = await ref.read(groupsRepositoryProvider).join(inviteCode);

    // Se l'utente era gia' membro, il backend non crea una seconda riga: qui si
    // evita comunque di duplicare la voce, perche' una lista con lo stesso
    // gruppo due volte sembra un bug.
    final current = state.value ?? const <AnimeGroup>[];
    state = AsyncData([joined, ...current.where((g) => g.id != joined.id)]);
    return joined;
  }

  /// Esce da un gruppo e lo toglie dalla lista.
  Future<void> leave(String groupId) async {
    await ref.read(groupsRepositoryProvider).leave(groupId);

    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.where((g) => g.id != groupId).toList());
  }

  /// Cede la proprieta' a un membro e aggiorna i ruoli in lista.
  ///
  /// L'aggiornamento e' locale perche' dopo la cessione l'utente non e' piu'
  /// owner e la schermata gli direbbe ancora "Sei l owner" fino al prossimo
  /// ricaricamento: premeva di nuovo lo stesso pulsante e il backend rispondeva
  /// "solo l'owner puo'".
  Future<void> transferOwnership({
    required String groupId,
    required String newOwnerId,
  }) async {
    await ref
        .read(groupsRepositoryProvider)
        .transferOwnership(groupId: groupId, newOwnerId: newOwnerId);

    final current = state.value;
    if (current == null) return;

    final updated = [
      for (final g in current)
        if (g.id == groupId)
          AnimeGroup(
            id: g.id,
            name: g.name,
            description: g.description,
            imageUrl: g.imageUrl,
            inviteCode: g.inviteCode,
            ownerId: newOwnerId,
            // Chi cede resta nel gruppo come admin, quindi perde la proprieta'
            // ma non l'accesso: senza questo il pulsante "Esci" comparirebbe
            // di colpo sotto i suoi occhi.
            myRole: g.myRole == GroupRole.owner ? GroupRole.admin : g.myRole,
            createdAt: g.createdAt,
          )
        else
          g,
    ];

    state = AsyncData(updated);
    ref.invalidate(groupMembersProvider(groupId));
  }

  /// Rigenera il codice invito e aggiorna il gruppo in lista.
  ///
  /// Il codice nuovo torna subito nello stato locale: e' il dato che l'utente
  /// sta per condividere, non puo' aspettare un ricaricamento.
  Future<String> regenerateInviteCode(String groupId) async {
    final code = await ref
        .read(groupsRepositoryProvider)
        .regenerateInviteCode(groupId);

    final current = state.value;
    if (current == null) return code;
    state = AsyncData([
      for (final g in current)
        g.id == groupId ? g.copyWith(inviteCode: code) : g,
    ]);
    return code;
  }
}

/// Elenco dei gruppi dell'utente.
final groupsListProvider =
    AsyncNotifierProvider<GroupsListController, List<AnimeGroup>>(
      GroupsListController.new,
      // Senza questo, Riverpod ritenta con backoff anche gli errori che il backend
      // ha gia' dichiarato non risolvibili e l'utente vede uno spinner al posto
      // del messaggio.
      retry: appRetry,
    );

/// Membri di un gruppo.
///
/// Controller a parte dalla lista gruppi perche' si carica solo quando si apre
/// il selettore: sono dati che servono a una schermata sola e non devono
/// viaggiare con ogni apertura del dettaglio gruppo.
class GroupMembersController extends AsyncNotifier<List<GroupMember>> {
  GroupMembersController(this.groupId);

  final String groupId;

  @override
  Future<List<GroupMember>> build() =>
      ref.watch(groupsRepositoryProvider).listMembers(groupId);

  /// Ricarica l'elenco.
  ///
  /// Esposta perche' dopo un cambio ruolo o un'espulsione la lista va riletta
  /// dal server: la copia locale sbaglierebbe, e il backend e' l'unico che
  /// sa quale ruolo e' stato applicato davvero.
  Future<void> refresh() async {
    // `invalidateSelf` e non `AsyncValue.guard`: guard rimetterebbe lo stato in
    // caricamento e Riverpod rieseguirebbe `build`, quindi `listMembers`
    // verrebbe chiamata due volte per un solo retry.
    ref.invalidateSelf();
    await future;
  }

  /// Cambia il ruolo di un membro e aggiorna la lista.
  ///
  /// L'aggiornamento e' locale perche' il ruolo e' esattamente il dato che
  /// l'utente sta guardando: dopo aver scelto "Admin" deve vedere subito
  /// l'etichetta nuova, non attendere un ricaricamento che lascerebbe per un
  /// istante il vecchio ruolo accanto al pulsante appena premuto.
  Future<void> setRole({
    required String userId,
    required GroupRole role,
  }) async {
    await ref
        .read(groupsRepositoryProvider)
        .setMemberRole(groupId: groupId, userId: userId, role: role);

    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final m in current) m.userId == userId ? _copyWithRole(m, role) : m,
    ]);
  }

  /// Espelle un membro e lo toglie dalla lista.
  ///
  /// Come per il ruolo la lista si aggiorna da sola: l'utente ha visto la
  /// conferma, quindi la sparizione del nome e' la conseguenza attesa. Se il
  /// backend lo rifiuta la lista resta com'era e l'errore viene mostrato.
  Future<void> kick(String userId) async {
    await ref
        .read(groupsRepositoryProvider)
        .kickMember(groupId: groupId, userId: userId);

    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.where((m) => m.userId != userId).toList());
  }

  /// Copia di [GroupMember] con un ruolo diverso.
  ///
  /// Il modello non ha `copyWith`: [GroupMember] non e' mutabile e le sue
  /// istanze sono condivise fra piu' schermate, quindi il ruolo non viene
  /// cambiato sul posto.
  GroupMember _copyWithRole(GroupMember member, GroupRole role) => GroupMember(
    userId: member.userId,
    username: member.username,
    avatarUrl: member.avatarUrl,
    role: role,
    joinedAt: member.joinedAt,
  );
}

final groupMembersProvider =
    AsyncNotifierProvider.family<
      GroupMembersController,
      List<GroupMember>,
      String
    >(GroupMembersController.new, retry: appRetry);

/// Inviti singoli di un gruppo.
///
/// Controller separato dai membri perche' gli inviti si vedono solo dagli admin
/// e si caricano solo quando la sezione si apre: caricarli con il gruppo
/// costerebbe una richiesta che per un membro semplice finisce sempre in
/// "permessi insufficienti".
class GroupInvitesController extends AsyncNotifier<List<GroupInvite>> {
  GroupInvitesController(this.groupId);

  final String groupId;

  @override
  Future<List<GroupInvite>> build() =>
      ref.watch(groupsRepositoryProvider).listInvites(groupId);

  /// Ricarica l'elenco degli inviti.
  ///
  /// Serve dopo ogni revoca e dopo una creazione: il backend decide la
  /// scadenza e chi ha usato cosa, quindi la lista deve tornare dal server per
  /// non mostrare uno stato che il database non condivide.
  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }

  /// Crea un invito e lo mette in cima alla lista.
  ///
  /// L'inserimento locale e' quello che l'utente aspetta subito, ma il reload
  /// non viene saltato: quello successivo rimette la lista esattamente come la
  /// vede il server, senza aspettare che qualcun altro prema "Aggiorna".
  Future<GroupInvite> createInvite({int? daysValid}) async {
    final created = await ref
        .read(groupsRepositoryProvider)
        .createInvite(groupId: groupId, daysValid: daysValid);

    final current = state.value;
    if (current != null) state = AsyncData([created, ...current]);
    return created;
  }

  /// Revoca un invito e lo segna come annullato nella lista.
  ///
  /// La riga resta con la data invece di sparire: l'utente deve vedere che
  /// l'invito e' stato revocato e non pensare che sia sparito da solo.
  Future<void> revokeInvite(GroupInvite invite) async {
    await ref.read(groupsRepositoryProvider).revokeInvite(invite.id);

    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final i in current)
        if (i.id == invite.id) _asRevoked(i) else i,
    ]);
  }

  /// Copia di [GroupInvite] con la revoca registrata adesso.
  ///
  /// La data e' quella del client e non quella del server: la lista viene
  /// riletta subito dopo, e un orologio sballato di qualche minuto non
  /// cambierebbe nulla, mentre far sparire la riga non lascerebbe traccia.
  GroupInvite _asRevoked(GroupInvite invite) => GroupInvite(
    id: invite.id,
    code: invite.code,
    createdBy: invite.createdBy,
    expiresAt: invite.expiresAt,
    createdAt: invite.createdAt,
    usedBy: invite.usedBy,
    usedAt: invite.usedAt,
    revokedAt: DateTime.now(),
    pending: false,
  );
}

final groupInvitesProvider =
    AsyncNotifierProvider.family<
      GroupInvitesController,
      List<GroupInvite>,
      String
    >(GroupInvitesController.new, retry: appRetry);
