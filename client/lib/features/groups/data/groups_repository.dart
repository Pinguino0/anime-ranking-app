import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_failure.dart';
import '../domain/group.dart';

/// Operazioni disponibili su un gruppo.
///
/// Interfaccia separata dall'implementazione perche' i test non possano
/// parlare con Supabase, e perche' le schermate non dipendano dal driver.
abstract interface class GroupsRepository {
  /// Gruppi di cui l'utente collegato e membro, con il suo ruolo in ciascuno.
  Future<List<AnimeGroup>> listMine();

  /// Crea un gruppo e ne entra come owner.
  Future<AnimeGroup> create({required String name, String? description});

  /// Entra in un gruppo con il codice invito.
  ///
  /// Il codice va passato letteralmente: un utente non ancora membro non puo
  /// leggere `groups.invite_code` (la RLS lo nasconde), quindi non si puo
  /// cercare il gruppo per nome o per id e poi leggere il codice al suo posto.
  Future<AnimeGroup> join(String inviteCode);

  /// Esce dal gruppo.
  ///
  /// Fallisce se l'utente e' l'owner: in quel caso va trasferita la
  /// proprieta' o eliminato il gruppo.
  Future<void> leave(String groupId);

  /// Genera un nuovo codice invito, invalidando il precedente.
  Future<String> regenerateInviteCode(String groupId);

  /// Cambia il ruolo di un membro. Solo il owner puo' farlo.
  Future<void> setMemberRole({
    required String groupId,
    required String userId,
    required GroupRole role,
  });

  /// Espelle un membro dal gruppo. Solo un admin puo' farlo.
  Future<void> kickMember({required String groupId, required String userId});

  /// Membri del gruppo con profilo e ruolo, gia' ordinati dal backend.
  ///
  /// Serve al selettore del nuovo owner: senza i nomi l'unica alternativa
  /// sarebbe far scegliere da un campo libero un id, e un id sbagliato
  /// passerebbe il controllo di esistenza senza dire nulla all'utente.
  Future<List<GroupMember>> listMembers(String groupId);

  /// Cede la proprieta' del gruppo a un membro. Solo l'owner puo' farlo.
  ///
  /// Chi cede diventa admin e resta nel gruppo.
  Future<void> transferOwnership({required String groupId, required String newOwnerId});
}

/// Implementazione reale su Supabase.
///
/// Tutte le mutazioni passano da funzioni SECURITY DEFINER e non da scritture
/// dirette sulle tabelle: le RLS da sole non bastano (per esempio sulla
/// creazione del gruppo, dove il vincolo "owner = utente corrente" non
/// controlla il ruolo in `group_members`), e il backend mette gia' i controlli
/// giusti al posto giusto.
class SupabaseGroupsRepository implements GroupsRepository {
  SupabaseGroupsRepository(this._client);

  final SupabaseClient _client;

  /// Tiene l'id dell'utente collegato, letto una volta sola.
  ///
  /// La lista gruppi ha bisogno dell'id per filtrare la join: rileggerlo a ogni
  /// richiesta costerebbe una chiamata auth inutile, e se l'utente non e'
  /// collegato non ha senso interrogare il database.
  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) {
      throw const GroupsFailure('Devi essere collegato.', isRetryable: false);
    }
    return id;
  }

  @override
  Future<List<AnimeGroup>> listMine() async {
    try {
      // `group_members!inner` trasforma la join in un filtro: PostgREST tiene
      // solo i gruppi che hanno almeno una riga in group_members, e il filtro
      // `user_id` restringe a quella dell'utente collegato. Con una query sola
      // si ottengono gruppo e ruolo insieme: due richieste separate
      // (prima gli id dei gruppi, poi i gruppi) sarebbero il doppio del
      // traffico e potrebbero vedere dati diversi se un join arriva nel
      // frattempo.
      final rows = await _client
          .from('groups')
          .select('id, name, description, image_url, invite_code, owner_id, created_at, '
              'group_members!inner(role, user_id)')
          .eq('group_members.user_id', _uid);

      if (rows.isEmpty) return const [];

      final groups = rows.map(AnimeGroup.parse).toList();
      groups.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return groups;
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const GroupsFailure('Gruppi non disponibili. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<AnimeGroup> create({required String name, String? description}) async {
    final trimmed = name.trim();
    final invalid = GroupValidators.nameError(trimmed);
    if (invalid != null) throw GroupsFailure(invalid);

    try {
      final row = await _client.rpc(
        'create_group',
        params: {
          '_name': trimmed,
          // Il backend distingue esplicitamente "nessuna descrizione" da
          // descrizione vuota, quindi una stringa vuota non va inviata:
          // passerebbe come testo scelto dall'utente.
          '_description': (description?.isEmpty ?? true) ? null : description,
        },
      );
      return _groupFromRpc(row, myRole: GroupRole.owner);
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const GroupsFailure('Gruppo non creato. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<AnimeGroup> join(String inviteCode) async {
    final code = inviteCode.trim().toUpperCase();
    if (code.isEmpty) {
      throw const GroupsFailure('Inserisci il codice invito.');
    }

    try {
      final row = await _client.rpc('join_group', params: {'_code': code});
      return _groupFromRpc(row, myRole: GroupRole.member);
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const GroupsFailure('Ingresso non riuscito. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<void> leave(String groupId) => _callVoid(
        'leave_group',
        params: {'_group_id': groupId},
        onFailure: 'Uscita non riuscita. Riprova.',
      );

  @override
  Future<String> regenerateInviteCode(String groupId) async {
    try {
      final code = await _client.rpc(
        'regenerate_invite_code',
        params: {'_group_id': groupId},
      );
      return '$code';
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const GroupsFailure('Codice non rigenerato. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<void> setMemberRole({
    required String groupId,
    required String userId,
    required GroupRole role,
  }) =>
      _callVoid(
        'set_member_role',
        params: {'_group_id': groupId, '_user_id': userId, '_role': role.name},
        onFailure: 'Ruolo non cambiato. Riprova.',
      );

  @override
  Future<void> kickMember({required String groupId, required String userId}) => _callVoid(
        'kick_member',
        params: {'_group_id': groupId, '_user_id': userId},
        onFailure: 'Espulsione non riuscita. Riprova.',
      );

  @override
  Future<List<GroupMember>> listMembers(String groupId) async {
    try {
      final rows = await _client.rpc('group_members_list', params: {'_group_id': groupId});

      if (rows is! List) {
        throw const GroupsFailure('Elenco membri non riconosciuto.');
      }

      return [for (final row in rows) GroupMember.parse(_asMap(row))];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is GroupsFailure) rethrow;
      throw const GroupsFailure('Membri non disponibili. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<void> transferOwnership({
    required String groupId,
    required String newOwnerId,
  }) =>
      _callVoid(
        'transfer_group_ownership',
        params: {'_group_id': groupId, '_new_owner_id': newOwnerId},
        onFailure: 'Proprieta non trasferita. Riprova.',
      );

  Map<String, dynamic> _asMap(Object? row) =>
      row is Map ? Map<String, dynamic>.from(row) : const {};

  /// Invoca una funzione che non restituisce nulla.
  Future<void> _callVoid(
    String fn, {
    required Map<String, dynamic> params,
    required String onFailure,
  }) async {
    try {
      await _client.rpc(fn, params: params);
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw GroupsFailure(onFailure, isRetryable: true);
    }
  }

  /// Converte la risposta di `create_group`/`join_group` in [AnimeGroup].
  ///
  /// Le due funzioni restituiscono una riga di `public.groups`, che PostgREST
  /// consegna come oggetto. Il ruolo pero' non fa parte di quella tabella:
  /// dopo una creazione l'utente e' owner per costruzione, dopo un ingresso e'
  /// membro, quindi lo si deduce dal contesto invece di fare una seconda
  /// richiesta per rileggerlo.
  AnimeGroup _groupFromRpc(Object? row, {required GroupRole myRole}) {
    if (row is! Map) {
      throw const GroupsFailure('Risposta dal server non riconosciuta.');
    }
    final json = Map<String, dynamic>.from(row);
    return AnimeGroup(
      id: '${json['id']}',
      name: json['name'] as String? ?? 'Senza nome',
      description: json['description'] as String?,
      imageUrl: json['image_url'] as String?,
      inviteCode: json['invite_code'] as String? ?? '',
      ownerId: '${json['owner_id']}',
      myRole: myRole,
      createdAt: DateTime.tryParse('${json['created_at']}')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// Traduce un errore di PostgREST in un errore di dominio.
  ///
  /// Le funzioni del backend sollevano gia' messaggi in italiano leggibili
  /// ("Nome gruppo non valido", "Il owner non puo lasciare il gruppo"), quindi
  /// per i codici noti il messaggio del server viene riutilizzato: riscriverlo
  /// qui duplicherebbe le stringhe e le farebbe divergere.
  ///
  /// Un codice sconosciuto non viene passato attraverso: potrebbe contenere
  /// dettagli interni, e comunque l'utente non può agire su un errore che non
  /// conosce.
  GroupsFailure _translate(PostgrestException e) {
    const passthrough = {
      '22023', // validazione input
      '42501', // permessi
      '28000', // autenticazione
      'P0002', // non trovato
    };

    if (passthrough.contains(e.code) && e.message.trim().isNotEmpty) {
      return GroupsFailure(e.message.trim());
    }

    // Le RLS del PostgREST arrivano come errori con codice vuoto e messaggio
    // fisso: non sono leggibili dall'utente, quindi si traduce in "permessi".
    if (e.code == null && e.message.contains('row-level security')) {
      return const GroupsFailure('Permessi insufficienti.');
    }

    return const GroupsFailure('Operazione non riuscita. Riprova.', isRetryable: true);
  }
}

/// Regole sui campi di un gruppo.
///
/// [GroupValidators.nameError] replica il controllo del backend
/// ("Nome gruppo non valido (1-60 caratteri)").
class GroupValidators {
  const GroupValidators._();

  static const int minNameLength = 1;
  static const int maxNameLength = 60;
  static const int maxDescriptionLength = 280;

  static String? nameError(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Dai un nome al gruppo.';
    if (v.length < minNameLength) return 'Il nome e troppo corto.';
    if (v.length > maxNameLength) return 'Massimo $maxNameLength caratteri.';
    return null;
  }

  static String? descriptionError(String? value) {
    final v = value?.trim() ?? '';
    if (v.length > maxDescriptionLength) return 'Massimo $maxDescriptionLength caratteri.';
    return null;
  }
}