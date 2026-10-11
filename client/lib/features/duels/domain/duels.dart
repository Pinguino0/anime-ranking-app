import '../../../core/error/app_failure.dart';

/// Errore sulle operazioni duello.
class DuelsFailure extends AppFailure {
  const DuelsFailure(super.message, {super.isRetryable});
}

/// Una coppia proposta da `next_duel_pair`.
///
/// Il backend restituisce gia' titolo e immagine dei due contendenti: senza i
/// dati dell anime la schermata dovrebbe fare una seconda richiesta per ids,
/// e la coppia mostrata potrebbe cambiare nel frattempo.
class DuelPair {
  const DuelPair({
    required this.animeAId,
    required this.animeBId,
    required this.titleA,
    required this.titleB,
    this.titleItA,
    this.titleItB,
    this.imageA,
    this.imageB,
  });

  final String animeAId;
  final String animeBId;
  final String titleA;
  final String titleB;

  /// Titoli italiani dei due contendenti, se il catalogo li conosce.
  final String? titleItA;
  final String? titleItB;
  final String? imageA;
  final String? imageB;

  /// Titolo mostrato per il primo contendente: italiano se disponibile.
  String get displayTitleA => titleItA ?? titleA;

  /// Titolo mostrato per il secondo contendente: italiano se disponibile.
  String get displayTitleB => titleItB ?? titleB;

  /// true se la coppia regge i vincoli del database.
  ///
  /// `next_duel_pair` puo' restituire una riga con il secondo contendente
  /// vuoto quando il gruppo ha un solo anime votato: il fallback prende i due
  /// piu' votati e il secondo potrebbe non esistere.
  bool get isPlayable => animeAId.isNotEmpty && animeBId.isNotEmpty && animeAId != animeBId;

  factory DuelPair.parse(Map<String, dynamic> json) => DuelPair(
        animeAId: _text(json['anime_a_id']) ?? '',
        animeBId: _text(json['anime_b_id']) ?? '',
        titleA: _text(json['title_a']) ?? 'Senza titolo',
        titleB: _text(json['title_b']) ?? 'Senza titolo',
        titleItA: _text(json['title_it_a']),
        titleItB: _text(json['title_it_b']),
        imageA: _text(json['image_a']),
        imageB: _text(json['image_b']),
      );

  String titleOf(String animeId) => animeId == animeAId ? displayTitleA : displayTitleB;

  String? imageOf(String animeId) => animeId == animeAId ? imageA : imageB;

  /// Errore da mostrare se la scelta non e' fra i due contendenti, null se va
  /// bene.
  ///
  /// Replica i CHECK `duels_distinct_animes` e `duels_selected_in_pair`: senza
  /// questi controlli l inserimento fallirebbe sul backend e l'utente
  /// vedrebbe un errore tecnico per una scelta impossibile da fare a mano.
  DuelsFailure? validate(String? selectedAnimeId) {
    if (!isPlayable) {
      return const DuelsFailure('Questa coppia non e giocabile.');
    }

    if (selectedAnimeId != animeAId && selectedAnimeId != animeBId) {
      return const DuelsFailure('Scegli uno dei due anime.');
    }

    return null;
  }
}

/// Una riga della classifica Elo.
///
/// La posizione e calcolata qui e non arriva dal backend: `duel_elo` restituisce
/// solo i punteggi gia' ordinati e limitati a 100 righe, quindi il numero della
/// posizione si ricava dall ordine ricevuto.
class DuelStanding {
  const DuelStanding({
    required this.position,
    required this.animeId,
    required this.title,
    required this.elo,
    required this.duelCount,
    this.italianTitle,
    this.imageUrl,
  });

  final int position;
  final String animeId;
  final String title;
  final int elo;
  final int duelCount;

  /// Titolo italiano, se il catalogo lo conosce. La UI usa [displayTitle].
  final String? italianTitle;
  final String? imageUrl;

  /// Titolo mostrato all'utente: italiano se disponibile, altrimenti il titolo
  /// del catalogo.
  String get displayTitle => italianTitle ?? title;

  factory DuelStanding.parse(Map<String, dynamic> json, {required int position}) =>
      DuelStanding(
        position: position,
        animeId: _text(json['anime_id']) ?? '',
        title: _text(json['title']) ?? 'Senza titolo',
        italianTitle: _text(json['title_it']),
        elo: _toInt(json['elo']) ?? DuelElo.starting,
        duelCount: _toInt(json['duel_count']) ?? 0,
        imageUrl: _text(json['image_url']),
      );

  /// Elo con segno, per capire subito chi e' salito e chi e' sceso.
  ///
  /// Il backend non tiene la serie storica degli Elo, quindi il confronto con il
  /// valore iniziale di 1000 e' tutto quello che si puo' mostrare: e' il punto
  /// di partenza di ogni anime, non un valore medio.
  int get eloDelta => elo - DuelElo.starting;

  @override
  bool operator ==(Object other) =>
      other is DuelStanding && other.animeId == animeId;

  @override
  int get hashCode => animeId.hashCode;
}

/// Parametri dell Elo usati da `duel_elo`.
///
/// Non sono scelte del client: il backend calcola `start + K * (S - E)` con
/// questi valori (migration `015_account_admin_elo_storage.sql`). Sono qui perche'
/// i confronti con il punteggio iniziale servono a mostrare la variazione, e un
/// numero duplicato nel client comincerebbe a divergere dal server alla prima
/// modifica.
class DuelElo {
  const DuelElo._();

  /// Punteggio di un anime che non ha ancora duellato.
  static const int starting = 1000;

  /// Quanti punti si spostano a ogni duello al massimo.
  static const int factor = 32;
}

/// Una scelta registrata, per la conferma a schermo.
///
/// Non arriva dal backend: `play` restituisce solo un esito vuoto, quindi
/// l'anime scelto lo sa il client e puo' mostrarlo subito senza rileggere
/// nulla.
class DuelResult {
  const DuelResult({required this.animeId, required this.title});

  final String animeId;
  final String title;
}

/// Quanto ne caricano di duelli per schermata.
///
/// `duel_elo` tronca comunque a 100 righe lato server: mostrare solo quelle e'
/// coerente con quello che il backend calcola, e un elenco piu' lungo sarebbe
/// comunque incompleto.
class DuelsPage {
  const DuelsPage._();

  static const int size = 100;
}

/// Conversione da numeric/bigint di Postgres.
int? _toInt(Object? raw) => switch (raw) {
      final num n => n.toInt(),
      final String s => int.tryParse(s),
      _ => null,
    };

String? _text(Object? raw) => switch (raw) {
      final String s when s.isNotEmpty => s,
      final num n => '$n',
      _ => null,
    };
