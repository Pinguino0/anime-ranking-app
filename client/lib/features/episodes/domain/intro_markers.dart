/// La sigla di un anime, in secondi dall'inizio dell'episodio.
///
/// Non e' un dato ricavato dal video: il catalogo lo tiene per anime, perche' la
/// sigla di una serie e' la stessa dall'episodio 2 in poi. Averla per episodio
/// moltiplicherebbe le righe senza aggiungere informazione.
///
/// Assente non vuol dire "zero": vuol dire "non lo sappiamo", e in quel caso il
/// player non mostra nessun pulsante. Saltare a un secondo inventato
/// taglierebbe contenuto vero, che e' peggio di un pulsante in meno.
class IntroMarkers {
  const IntroMarkers({required this.start, required this.end});

  /// Dove comincia la sigla.
  final Duration start;

  /// Dove finisce: e' il punto in cui atterra "Salta intro".
  final Duration end;

  /// Quanto prima della fine il pulsante sparisce da solo.
  ///
  /// Tre secondi: sotto, il salto porterebbe quasi dove si e' gia' e il
  /// pulsante sembrerebbe non fare niente.
  static const Duration _tail = Duration(seconds: 3);

  /// Se ha senso mostrare il pulsante mentre il video e' a [position].
  bool isActive(Duration position) =>
      position >= start && position < end - _tail;

  /// Legge la finestra da una riga di `public.anime`.
  ///
  /// Restituisce `null` se una delle due colonne manca o se la fine non segue
  /// l'inizio: una sigla con un solo estremo non e' una finestra, e usarla per
  /// meta' salterebbe alla cieca.
  static IntroMarkers? fromRow(Map<String, dynamic> row) {
    final start = _seconds(row['intro_start_seconds']);
    final end = _seconds(row['intro_end_seconds']);
    if (start == null || end == null || end <= start) return null;
    return IntroMarkers(start: start, end: end);
  }

  static Duration? _seconds(Object? value) {
    if (value is int) return Duration(seconds: value);
    if (value is num) return Duration(seconds: value.round());
    return null;
  }
}
