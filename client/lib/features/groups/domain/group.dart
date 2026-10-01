/// Ruolo di un utente dentro un gruppo.
///
/// Gli ordini non sono alfabetici ma per potere: [owner] vale piu' di
/// [admin], che vale piu' di [member]. Il numero del ruolo permette confronti
/// diretti (`myRank >= GroupRole.admin.rank`) senza dover scrivere la catena
/// di `==` a ogni controllo.
enum GroupRole {
  owner(2, 'Owner'),
  admin(1, 'Admin'),
  member(0, 'Membro');

  const GroupRole(this.rank, this.label);

  /// Potere crescente: 0 membro, 1 admin, 2 owner.
  final int rank;

  /// Etichetta mostrata all'utente.
  final String label;

  /// true se questo ruolo puo amministrare il gruppo.
  bool get canManage => rank >= GroupRole.admin.rank;

  /// true se questo ruolo puo cambiare i ruoli altrui.
  ///
  /// Il backend lo limita al solo owner (`set_member_role`), quindi la UI non
  /// offre il controllo agli admin: offrire un'azione che il server rifiuta
  /// e' peggio che non offrirla.
  bool get canAssignRoles => this == GroupRole.owner;

  /// true se questo ruolo puo vedere il codice invito.
  ///
  /// Il dato e' leggibile da tutti i membri (la RLS lo permette), ma sono
  /// gli admin a poterlo usare per far entrare gente. Non mostrarlo ai membri
  /// semplici evita di far scoprire il gruppo a chi non deve.
  bool get canSeeInviteCode => rank >= GroupRole.admin.rank;

  /// Parsing tollerante: un ruolo sconosciuto dal server vale come membro.
  ///
  /// Meglio mostrare il gruppo con permessi minimi che far crashare la lista.
  static GroupRole fromName(String? raw) => switch (raw) {
        'owner' => GroupRole.owner,
        'admin' => GroupRole.admin,
        _ => GroupRole.member,
      };
}

/// Un gruppo di condivisione, visto dal punto di vista dell'utente collegato.
class AnimeGroup {
  const AnimeGroup({
    required this.id,
    required this.name,
    required this.inviteCode,
    required this.ownerId,
    required this.myRole,
    required this.createdAt,
    this.description,
    this.imageUrl,
  });

  final String id;
  final String name;
  final String? description;
  final String? imageUrl;
  final String inviteCode;
  final String ownerId;

  /// Ruolo dell'utente collegato, non il ruolo "del gruppo".
  final GroupRole myRole;

  final DateTime createdAt;

  bool get canManage => myRole.canManage;
  bool get isOwner => myRole == GroupRole.owner;
  bool get canSeeInviteCode => myRole.canSeeInviteCode;

  /// Nome mostrato in lista: la descrizione se c'e', altrimenti il ruolo.
  ///
  /// La lista e' stretta e non mostra sempre due righe: quando la descrizione
  /// manca, il ruolo riempie il vuoto invece di lasciare uno spazio vuoto.
  String get subtitle => description?.isNotEmpty == true ? description! : myRole.label;

  AnimeGroup copyWith({String? name, String? description, String? inviteCode}) => AnimeGroup(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        imageUrl: imageUrl,
        inviteCode: inviteCode ?? this.inviteCode,
        ownerId: ownerId,
        myRole: myRole,
        createdAt: createdAt,
      );

  /// Copia con un owner diverso.
  ///
  /// A parte da [copyWith] perche' il campo non e' l'aggiornamento di un dato
  /// mostrato in schermata: e' la semantica della cessione, e mescolarla ai
  /// campi cosmetici renderebbe facile chiamarla per sbaglio.
  AnimeGroup copyWithOwner(String newOwnerId) => AnimeGroup(
        id: id,
        name: name,
        description: description,
        imageUrl: imageUrl,
        inviteCode: inviteCode,
        ownerId: newOwnerId,
        myRole: myRole,
        createdAt: createdAt,
      );

  /// Costruisce il modello dalla riga restituita da PostgREST.
  ///
  /// La query dei gruppi usa una join interna su `group_members`, quindi il
  /// ruolo arriva dentro una lista: [parse] la legge dal primo elemento.
  ///
  /// Ogni campo ha un fallback perche' una risposta incompleta non deve
  /// far esplodere la lista: e' sempre meglio mostrare una riga in meno
  /// informazioni che far cadere l'intera schermata.
  factory AnimeGroup.parse(Map<String, dynamic> json) {
    final members = json['group_members'];
    final myRole = switch (members) {
      final List list when list.isNotEmpty => GroupRole.fromName(list.first['role'] as String?),
      final Map map => GroupRole.fromName(map['role'] as String?),
      _ => GroupRole.member,
    };

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

  @override
  bool operator ==(Object other) => other is AnimeGroup && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Un membro del gruppo, visto dall'owner che sta scegliendo a chi cedere la
/// proprieta'.
class GroupMember {
  const GroupMember({
    required this.userId,
    required this.username,
    required this.role,
    required this.joinedAt,
    this.avatarUrl,
  });

  final String userId;
  final String username;
  final String? avatarUrl;
  final GroupRole role;
  final DateTime joinedAt;

  /// true se questo membro puo' ricevere la proprieta'.
  ///
  /// Ogni membro puo': il backend non distingue admin da membro per il
  /// trasferimento. Il controllo resta qui per non proporre l'owner stesso,
  /// che il backend rifiuterebbe con un errore lessicale.
  bool get canReceiveOwnership => role != GroupRole.owner;

  /// Nome mostrato: l'username come arriva.
  ///
  /// Nessun fallback elaborato: se il server non manda un username il
  /// selettore mostra l'id, che e' comunque sufficiente per non scegliere a
  /// caso, e segnala che qualcosa non torna.
  String get label => username.isEmpty ? userId : username;

  factory GroupMember.parse(Map<String, dynamic> json) => GroupMember(
        userId: '${json['user_id']}',
        username: json['username'] as String? ?? '',
        avatarUrl: json['avatar_url'] as String?,
        role: GroupRole.fromName(json['role'] as String?),
        joinedAt: DateTime.tryParse('${json['joined_at']}')?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  @override
  bool operator ==(Object other) => other is GroupMember && other.userId == userId;

  @override
  int get hashCode => userId.hashCode;
}