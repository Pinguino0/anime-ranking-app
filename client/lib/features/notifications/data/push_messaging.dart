/// Un push ricevuto, in una forma che non conosce Firebase.
///
/// L'app non deve parlare con `RemoteMessage` fuori da un unico punto: qui il
/// messaggio e' gia' ridotto a testo e dati, cosi' il resto del codice (e i
/// test) non importa l'SDK di Google.
class PushMessage {
  const PushMessage({
    required this.title,
    required this.body,
    required this.data,
  });

  /// Titolo mostrato all'utente.
  final String title;

  /// Testo della notifica.
  final String body;

  /// Dati allegati: `anime_id`, `group_id`, `type`, ... Il server li manda nel
  /// campo `payload` come JSON; qui sono gia' sciolti in una mappa semplice.
  final Map<String, dynamic> data;

  /// L'opera consigliata, se il push ne parla.
  String? get animeId => _text(data['anime_id']);

  /// Il gruppo da cui arriva il consiglio.
  String? get groupId => _text(data['group_id']);

  /// Il tipo della notifica: `new_episode`, `anime_recommendation`, ...
  ///
  /// Arriva come campo a se' di `data` (il webhook lo scrive accanto al
  /// payload), non dentro il `payload` serializzato.
  String? get type => _text(data['type']);

  /// Numero dell'episodio annunciato, se la notifica ne parla.
  ///
  /// Sul filo puo' arrivare come stringa (FCM accetta solo stringhe nei `data`
  /// dell'Android, ma il payload JSON lo conserva numerico): qui si accettano
  /// entrambi invece di far dipendere il tap dal trasporto.
  int? get episodeNumber {
    final raw = data['episode_num'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  /// true se non c'e' niente da mostrare.
  bool get isEmpty => title.isEmpty && body.isEmpty;
}

String? _text(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// Nessun push disponibile: piattaforma non supportata (desktop, web) oppure
/// Firebase non configurato. Tutto resta muto invece di far esplodere l'avvio.
class UnsupportedPushMessaging implements PushMessaging {
  const UnsupportedPushMessaging();

  @override
  bool get isSupported => false;

  @override
  String get platform => 'android';

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<String?> token() async => null;

  @override
  Stream<String> get onTokenRefresh => const Stream.empty();

  @override
  Stream<PushMessage> get onMessage => const Stream.empty();

  @override
  Stream<PushMessage> get onMessageOpenedApp => const Stream.empty();

  @override
  Future<PushMessage?> initialMessage() async => null;
}

/// La porta verso il servizio push del sistema.
///
/// L'app non deve parlare con `firebase_messaging` fuori da un unico punto: qui
/// il messaggio e' gia' ridotto a testo e dati, cosi' il resto del codice (e i
/// test) non importa l'SDK di Google.
abstract interface class PushMessaging {
  /// true se la piattaforma puo' ricevere push.
  bool get isSupported;

  /// 'android' o 'ios'.
  String get platform;

  Future<void> initialize();

  /// Chiede il permesso di mostrare notifiche. true se concesso.
  Future<bool> requestPermission();

  /// Il token FCM del dispositivo, o null se non disponibile.
  Future<String?> token();

  Stream<String> get onTokenRefresh;

  /// Push arrivati mentre l'app e' aperta.
  Stream<PushMessage> get onMessage;

  /// Push su cui l'utente ha toccato, con l'app in secondo piano.
  Stream<PushMessage> get onMessageOpenedApp;

  /// Il push che ha aperto l'app, se e' stata lanciata da una notifica.
  Future<PushMessage?> initialMessage();
}
