import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/user_profile.dart';

/// Operazioni sul profilo dell'utente collegato.
///
/// Interfaccia separata dal driver come per i gruppi: i test non devono
/// parlare con Supabase e la UI non deve sapere come sono fatti i salvataggi.
abstract interface class ProfileRepository {
  Future<UserProfile> loadMine();

  /// Salva i campi indicati e restituisce il profilo aggiornato.
  Future<UserProfile> updateMine({String? username, String? bio, String? avatarUrl});

  /// Elimina l'account dopo aver rimosso i file caricati.
  ///
  /// [ProfileController.deleteAccount] chiama questo metodo e non
  /// [deleteStoredFiles] separatamente: l'ordine dei due passi e' un requisito
  /// del backend e va garantito in un punto solo.
  Future<void> deleteAccount();

  Future<NotificationPreferences> loadNotifications();

  Future<void> saveNotifications(NotificationPreferences preferences);

  /// File caricati dall'utente che ancora esistono.
  Future<int> countStoredFiles();

  /// Elimina tutti i file caricati dall'utente.
  ///
  /// Esposta perche' i test verificano che [deleteAccount] la chiami prima
  /// della RPC: e' il requisito che il backend non puo' controllare da solo.
  Future<void> deleteStoredFiles();
}

/// Implementazione reale su Supabase.
class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(this._client);

  final SupabaseClient _client;

  /// Bucket in cui l'app lascia i file degli utenti.
  ///
  /// Sono gli stessi due del backend (015). Devono restare allineati: un
  /// bucket qui che il backend non conosce non verrebbe mai controllato prima
  /// della cancellazione dell'account.
  static const List<String> buckets = ['avatars', 'group-images'];

  /// Sessione del collegato, o un errore che lo dice.
  ///
  /// La domanda va posta alla SESSIONE e non a `currentUser`. Sono due cose
  /// diverse: `currentUser` puo' sopravvivere qualche istante a una sessione
  /// scaduta o non ancora rinnovata. In quel momento la richiesta parte senza
  /// il token, PostgREST la legge come richiesta anonima, e la RLS nasconde
  /// tutte le righe rispondendo `[]`: `maybeSingle()` su una lista vuota
  /// restituisce `null`, e il profilo risultava "non trovato" nel database
  /// mentre era semplicemente invisibile. Il pulsante Riprova non poteva
  /// funzionare perche' il problema non era il profilo.
  Session get _session {
    final session = _client.auth.currentSession;
    if (session == null) {
      throw const ProfileFailure('Sessione scaduta. Accedi di nuovo.');
    }
    return session;
  }

  String get _uid => _session.user.id;

  /// Fetch di una riga di `profiles` per l'utente collegato.
  ///
  /// [single] fallisce se la riga non c'e', e con `.maybeSingle()` si
  /// distingue "non c'e'" da "c'e'": il caso senza profilo non deve
  /// sembrare un errore di rete.
  Future<Map<String, dynamic>?> _fetchRow({Set<String>? columns}) async {
    final query = _client.from('profiles').select(columns?.join(',') ?? '*').eq('id', _uid);
    return query.maybeSingle();
  }

  @override
  Future<UserProfile> loadMine() async {
    try {
      final row = await _fetchRow();

      // Qui la sessione c'e' davvero: `_session` ha gia' escluso il caso in cui
      // la riga fosse invisibile perche' la richiesta partiva anonima. Quindi
      // l'assenza e' reale, e la sua causa e' il trigger su auth.users che non
      // ha girato. Fallire e' corretto — inventare un profilo porterebbe a
      // salvare dati su una riga inesistente — ma il messaggio non deve
      // mandare a ricaricare una pagina che non cambierebbe niente.
      if (row == null) {
        throw const ProfileFailure('Profilo non trovato. Ricaricare non basta.');
      }

      return UserProfile.parse(row);
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is ProfileFailure) rethrow;
      throw const ProfileFailure('Profilo non disponibile. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<UserProfile> updateMine({String? username, String? bio, String? avatarUrl}) async {
    final payload = <String, dynamic>{};

    if (username != null) payload['username'] = username.trim();
    // Bio vuota e bio assente sono dati diversi per il database: `bio = ''`
    // mostrerebbe una riga vuota nella scheda profilo.
    if (bio != null) payload['bio'] = bio.trim().isEmpty ? null : bio.trim();
    if (avatarUrl != null) payload['avatar_url'] = avatarUrl.isEmpty ? null : avatarUrl;

    if (payload.isEmpty) return loadMine();

    try {
      // Aggiornamento per chiave primaria filtrata su id: la RLS vieta gia'
      // di toccare le righe altrui, quindi non serve un where aggiuntivo.
      // Non si usa `.update()` senza filtro perche' PostgREST richiederebbe un
      // filtro e l'errore sarebbe solo silenzioso in sviluppo.
      final row = await _client
          .from('profiles')
          .update(payload)
          .eq('id', _uid)
          .select()
          .single();

      return UserProfile.parse(row);
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const ProfileFailure('Salvataggio non riuscito. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<NotificationPreferences> loadNotifications() async {
    try {
      final row = await _fetchRow(columns: {
        NotificationPreferences.pushColumn,
        NotificationPreferences.votesColumn,
        NotificationPreferences.friendsColumn,
        NotificationPreferences.tournamentsColumn,
        NotificationPreferences.rankChangesColumn,
        NotificationPreferences.recommendationsColumn,
      });

      if (row == null) return const NotificationPreferences();
      return NotificationPreferences.parse(row);
    } catch (_) {
      throw const ProfileFailure('Preferenze non disponibili. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<void> saveNotifications(NotificationPreferences preferences) async {
    try {
      await _client.from('profiles').update({
        NotificationPreferences.pushColumn: preferences.push,
        NotificationPreferences.votesColumn: preferences.votes,
        NotificationPreferences.friendsColumn: preferences.friends,
        NotificationPreferences.tournamentsColumn: preferences.tournaments,
        NotificationPreferences.rankChangesColumn: preferences.rankChanges,
        NotificationPreferences.recommendationsColumn: preferences.recommendations,
      }).eq('id', _uid);
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const ProfileFailure('Preferenze non salvate. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<int> countStoredFiles() async {
    var total = 0;

    // Conto per bucket invece che per elenco completo: la ricerca su un solo
    // prefisso di cartella restituisce solo i file dell'utente, che sono
    // quelli che la cancellazione deve aver tolto.
    for (final bucket in buckets) {
      total += (await _listFiles(bucket)).length;
    }

    return total;
  }

  @override
  Future<void> deleteStoredFiles() async {
    for (final bucket in buckets) {
      final files = await _listFiles(bucket);
      if (files.isEmpty) continue;

      // Rimozione per elenco, file per file.
      //
      // Non si passa il prefisso della cartella: la Storage API accetta i
      // percorsi esatti, e un percorso che non corrisponde a un file non
      // verrebbe rimosso ma potrebbe produrre un errore ambiguo.
      for (final path in files) {
        await _client.storage.from(bucket).remove([path]);
      }
    }
  }

  /// Percorsi dei file dell'utente dentro un bucket.
  ///
  /// La RLS di storage gia' limita la lista alla cartella dell'utente
  /// collegato, quindi il filtro per `user_id` qui e' una difesa in piu' e non
  /// un'ottimizzazione: senza, un errore di sessione potrebbe arrivare a
  /// cancellare file di qualcun altro.
  Future<List<String>> _listFiles(String bucket) async {
    final userId = _uid;

    try {
      // Una sola chiamata: la Storage API elenca i file direttamente dentro il
      // percorso indicato e non ricorre nelle sottocartelle. I file dell'app
      // sono tutti in `{user_id}/nome-file`, quindi non serve scendere oltre.
      final files = await _client.storage.from(bucket).list(path: userId);

      return [for (final file in files) '$userId/${file.name}'];
    } on StorageException catch (e) {
      throw _translateStorage(e);
    } catch (_) {
      throw ProfileFailure('Impossibile leggere i file caricati: ${_describe(bucket)}',
          isRetryable: true);
    }
  }

  @override
  Future<void> deleteAccount() async {
    // L'ordine non e' negoziabile: il backend conta i file e rifiuta la
    // cancellazione se ne restano. Senza questo passo l'utente riceverebbe un
    // errore senza sapere cosa fare.
    await deleteStoredFiles();

    try {
      await _client.rpc('delete_own_account');
    } on PostgrestException catch (e) {
      // 22023 e' l'errore dedicato ai file rimasti. Il numero arriva nel
      // messaggio ("Cancella prima i 2 file..."): si lo recupera per mostrarlo
      // all'utente, altrimenti il messaggio resterebbe interno.
      if (e.code == '22023') {
        throw AccountDeletionFailure(
          e.message,
          remainingFiles: _extractCount(e.message),
        );
      }

      // Se l'utente non e' piu' collegato la sessione e' caduta da sola: non
      // e' un errore da mostrare, l'utente e gia' uscito.
      if (e.code == '28000' || _isMissingSession(e.message)) {
        throw const AccountDeletionFailure('Sessione scaduta. Accedi di nuovo.');
      }

      throw _translate(e);
    } catch (e) {
      if (e is ProfileFailure) rethrow;
      throw const AccountDeletionFailure('Cancellazione non riuscita. Riprova.',
          isRetryable: true);
    }
  }

  /// Estrae il numero di file dal messaggio del backend.
  ///
  /// Il backend scrive "Cancella prima i % file caricati...". Se il formato
  /// cambia, si torna a 0: meglio un messaggio generico che un numero
  /// sbagliato.
  int _extractCount(String message) {
    final match = RegExp(r'(\d+)').firstMatch(message);
    return match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
  }

  bool _isMissingSession(String message) =>
      message.toLowerCase().contains('jwt') ||
      message.toLowerCase().contains('auth session missing') ||
      message.toLowerCase().contains('token');

  String _describe(String bucket) =>
      bucket == 'avatars' ? 'avatar.' : 'immagini dei gruppi.';

  /// Traduce un errore di PostgREST.
  ///
  /// Gli stessi codici di 42501 / 23505 del backend: 23505 e' la violazione
  /// dell'indice univoco sul nome utente, cioe' "nome gia preso".
  ProfileFailure _translate(PostgrestException e) {
    const passthrough = {'42501', '23505', '23503', '28000', 'P0002', '22023'};

    if (passthrough.contains(e.code) && e.message.trim().isNotEmpty) {
      final message = e.message.trim();

      // Il backend non ha una frase pronta per il nome utente duplicato:
      // il messaggio di Postgres cita l'indice, che non serve a nulla.
      if (e.code == '23505') return ProfileFailure('Questo nome utente e gia preso.');
      if (e.code == '23503') return ProfileFailure('Riferimento non valido.');

      return ProfileFailure(message);
    }

    return const ProfileFailure('Operazione non riuscita. Riprova.', isRetryable: true);
  }

  /// Traduce un errore della Storage API.
  ProfileFailure _translateStorage(StorageException e) {
    // La Storage API restituisce messaggi in inglese tecnici
    // ("Object not found"): si traduce solo quello che ha un corrispondente
    // per l'utente, il resto diventa un messaggio generico.
    if (e.statusCode == '404') {
      return ProfileFailure('File non trovato. Riprova.', isRetryable: true);
    }

    return const ProfileFailure('Operazione sui file non riuscita. Riprova.',
        isRetryable: true);
  }
}
