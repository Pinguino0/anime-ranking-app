import 'package:flutter/material.dart';

import 'app_theme.dart';

/// L'accento cromatico di una sezione dell'app.
///
/// Fino a ieri tutta l'app usava la stessa coppia viola/blu: la pastiglia
/// attiva della barra, il filetto di ogni intestazione e il gradiente delle
/// card erano sempre il gradiente del marchio. Funzionava, ma raccontava una
/// cosa sola: "questa e' AnimeRank". Dentro la classifica l'utente non sapeva
/// di essere in classifica da nient'altro che dal titolo in cima allo schermo.
///
/// Qui ogni sezione ha la sua tinta. Non e' decorazione fine a se': il colore
/// di una sezione e' il modo piu' rapido di dire "sei qui", e resta attaccato
/// alla sezione anche quando la si raggiunge da una rotta profonda (un gruppo,
/// la classifica di un gruppo) senza che la pagina debba ripeterlo.
///
/// Le tinte non sono inventate: escono dalla tavolozza di [ArColors]. L'oro
/// della classifica e' lo stesso dei voti, il teal dei gruppi lo stesso dello
/// stato "completato", il rosso dei duelli lo stesso dello stato "abbonato".
/// Cosi' il colore continua a significare qualcosa invece di essere solo un
/// modo diverso di colorare la stessa cosa.
enum ArAccent {
  /// Home e contesto senza una sezione propria: il gradiente del marchio.
  home(ArColors.primary, ArColors.accent),

  /// Catalogo e ricerca anime.
  anime(ArColors.primary, ArColors.primaryDim),

  /// Gruppi e i loro membri.
  groups(ArColors.success, Color(0xFF0E9384)),

  /// Classifiche: l'oro che l'app ha gia' riservato ai voti.
  ranking(ArColors.gold, Color(0xFFFF9A3C)),

  /// Duelli testa a testa.
  duels(ArColors.danger, Color(0xFFFF8A5C)),

  /// Tornei a eliminazione.
  tournaments(ArColors.warning, Color(0xFFFF8A3C)),

  /// Watchlist e titoli salvati.
  watchlist(ArColors.accent, ArColors.accentDim),

  /// Account, notifiche e impostazioni.
  profile(Color(0xFFA78BFA), Color(0xFF7C5CE0));

  const ArAccent(this.base, this.secondary);

  /// Colore principale dell'accento.
  final Color base;

  /// Secondo colore del gradiente.
  ///
  /// Non un colore qualsiasi: ha la stessa luminosita' percepita di [base],
  /// cosi' il gradiente resta una firma e non una macchia con un bordo chiaro.
  final Color secondary;

  /// Gradiente della sezione, con la stessa geometria del gradiente del
  /// marchio: cambiando solo i colori, un elemento accentato resta identico a
  /// se stesso in ogni sezione.
  LinearGradient get gradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [base, secondary],
      );

  /// Tinta tenue per riempire una pastiglia o un fondo attivo.
  ///
  /// Un riquadro pieno di [base] coprirebbe il contenuto; la stessa tinta
  /// all'11% dice "questo e' attivo" lasciando leggere cio' che sta sopra.
  Color get soft => base.withValues(alpha: 0.14);

  /// Tinta ancora piu' tenue, per gli sfondi dei riquadri decorativi.
  Color get faint => base.withValues(alpha: 0.08);

  /// Alone colorato dell'elemento attivo.
  ///
  /// Piu' tenue di quello del marchio: qui l'alone accompagna una tinta gia'
  /// diversa dal resto, quindi non deve coprire la differenza di colore.
  List<BoxShadow> glow({double strength = 0.26}) =>
      ArShadows.glow(base, strength: strength);
}

/// Rende disponibile ai discendenti l'accento della sezione corrente.
///
/// La shell sa in quale sezione si trova l'utente; i widget in fondo
/// all'albero — il filetto di un'intestazione, un'icona decorativa, una
/// pastiglia — non lo sanno, e passarglielo come parametro a mano
/// significherebbe ricablare ogni chiamante a ogni nuovo widget. Qui l'accento
/// scende come l'ambiente: chi lo vuole lo chiede con [of], e chi non lo chiede
/// riceve [ArAccent.home], che e' esattamente cio' che il resto dell'app
/// mostrava prima che esistesse un accento per sezione.
class SectionAccentScope extends InheritedWidget {
  const SectionAccentScope({
    required this.accent,
    required super.child,
    super.key,
  });

  /// Accento della sezione aperta.
  final ArAccent accent;

  /// Accento della sezione corrente, o [ArAccent.home] fuori da una shell.
  static ArAccent of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SectionAccentScope>()
          ?.accent ??
      ArAccent.home;

  /// Accento della sezione corrente, o `null` fuori da una shell.
  ///
  /// Serve dove l'assenza di accento e' un'informazione: un widget montato in
  /// un test o in un foglio non deve fingere di essere nella home.
  static ArAccent? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SectionAccentScope>()?.accent;

  @override
  bool updateShouldNotify(SectionAccentScope oldWidget) =>
      accent != oldWidget.accent;
}
