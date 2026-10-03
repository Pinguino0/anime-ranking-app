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
  String get subtitle =>
      description?.isNotEmpty == true ? description! : myRole.label;

  AnimeGroup copyWith({
    String? name,
    String? description,
    String? inviteCode,
  }) => AnimeGroup(
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
      final List list when list.isNotEmpty => GroupRole.fromName(
        list.first['role'] as String?,
      ),
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
      createdAt:
          DateTime.tryParse('${json['created_at']}')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  bool operator ==(Object other) => other is AnimeGroup && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Un invito a entrare in un gruppo, con scadenza e uso tracciati.
///
/// Diversamente dal codice del gruppo, che vale per sempre e si rigenera
/// invalidando il precedente, l'invito singolo vale per uno solo ingresso e per
/// un tempo limitato.
class GroupInvite {
  const GroupInvite({
    required this.id,
    required this.code,
    required this.createdBy,
    required this.expiresAt,
    required this.createdAt,
    this.usedBy,
    this.usedAt,
    this.revokedAt,
    this.pending,
  });

  final String id;
  final String code;
  final String createdBy;
  final DateTime expiresAt;
  final DateTime createdAt;

  /// Chi ha usato l'invito, se qualcuno l'ha usato.
  final String? usedBy;
  final DateTime? usedAt;
  final DateTime? revokedAt;

  /// true se l'invito si puo' ancora usare, false se e' finito, null se e'
  /// scaduto da piu' di una settimana e il backend non sa piu' nulla.
  ///
  /// Il terzo stato esiste perche' il backend smette di riportare gli inviti
  /// vecchi: senza un caso per "non lo so", la lista mostrerebbe come
  /// revocati degli inviti semplicemente spariti.
  final bool? pending;

  /// true se l'invito e' ancora spendibile.
  ///
  /// [pending] null vale come false: senza questo la UI offrirebbe di copiare
  /// un codice che il backend non accetterebbe piu'.
  bool get isActive => pending == true;

  /// true se l'invito e' stato annullato prima di essere usato.
  bool get isRevoked => revokedAt != null;

  /// true se l'invito e' scaduto senza essere stato usato.
  bool get isExpired => pending == false && usedAt == null && revokedAt == null;

  /// Stato mostrato all'utente.
  String get statusLabel {
    if (usedAt != null) return 'Usato';
    if (revokedAt != null) return 'Revocato';
    if (pending == false) return 'Scaduto';
    if (pending == null) return 'Non piu\' valido';
    return 'Valido fino al ${_day(expiresAt)}';
  }

  /// Data in formato breve, senza l'anno quando non serve.
  String _day(DateTime when) {
    final local = when.toLocal();
    final now = DateTime.now();
    return local.year == now.year
        ? '${local.day}/${local.month}'
        : '${local.day}/${local.month}/${local.year}';
  }

  factory GroupInvite.parse(Map<String, dynamic> json) => GroupInvite(
    id: '${json['id']}',
    code: json['code'] as String? ?? '',
    createdBy: '${json['created_by']}',
    usedBy: json['used_by'] as String?,
    usedAt: _date(json['used_at']),
    revokedAt: _date(json['revoked_at']),
    expiresAt:
        _date(json['expires_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    createdAt:
        _date(json['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    // `pending` arriva come bool dal backend, ma una risposta senza il
    // campo non deve diventare "valido": il default e' null, che la UI
    // tratta come non valido.
    pending: json['pending'] as bool?,
  );

  /// Legge una data tollerante.
  ///
  /// Le date del backend sono timestamptz in ISO 8601. Una riga senza la data
  /// non deve far cadere tutta la lista, quindi si ripiega sull'epoca: il
  /// fallback e' inaccettabile per l'utente ma preferibile a un crash, e la
  /// schermata mostra la data per intero cosi' l'errore resta evidente.
  static DateTime? _date(Object? raw) {
    if (raw == null) return null;
    return DateTime.tryParse('$raw')?.toLocal();
  }

  @override
  bool operator ==(Object other) => other is GroupInvite && other.id == id;

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
    joinedAt:
        DateTime.tryParse('${json['joined_at']}')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  @override
  bool operator ==(Object other) =>
      other is GroupMember && other.userId == userId;

  @override
  int get hashCode => userId.hashCode;
}
