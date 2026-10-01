import 'package:flutter/widgets.dart';

/// Soglie di larghezza che separano i tre formati di interfaccia.
///
/// Il prompt chiede esplicitamente di NON fare "desktop rimpicciolito":
/// sotto [tablet] cambia il numero di colonne e il tipo di componente
/// (tabella -> card), non solo la dimensione.
enum LayoutSize {
  /// Telefono: bottom navigation, card verticali, una colonna.
  compact,

  /// Tablet: layout intermedio, due colonne, bottom navigation.
  medium,

  /// Desktop: sidebar laterale, tabelle, piu' colonne.
  expanded;

  bool get isCompact => this == LayoutSize.compact;
  bool get isMedium => this == LayoutSize.medium;
  bool get isExpanded => this == LayoutSize.expanded;

  /// True quando serve la navigazione laterale invece della bottom bar.
  /// La soglia e' 900px: sotto, con la bottom bar + SafeArea, resta spazio
  /// utile per il contenuto; una sidebar a 800px mangerebbe un terzo dello
  /// schermo senza guadagnare nulla.
  bool get usesSidebar => this == LayoutSize.expanded;
}

class Breakpoints {
  const Breakpoints._();

  /// Soglia verso tablet.
  static const double medium = 700;

  /// Soglia verso desktop (attiva la sidebar).
  static const double expanded = 900;

  /// Larghezza oltre la quale una griglia passa a 3 colonne.
  static const double wideGrid = 1400;

  static LayoutSize of(double width) {
    if (width >= expanded) return LayoutSize.expanded;
    if (width >= medium) return LayoutSize.medium;
    return LayoutSize.compact;
  }

  static LayoutSize fromContext(BuildContext context) =>
      of(MediaQuery.sizeOf(context).width);

  /// Numero di colonne per una griglia di card.
  ///
  /// Non e' una divisione fissa: sotto 900px una griglia a 3 colonne
  /// produrrebbe card larghe 280px su uno schermo da 800px, illeggibili.
  static int gridColumns(double width, {int min = 1, int max = 4}) {
    if (width >= wideGrid) return 4;
    if (width >= expanded) return 3;
    if (width >= medium) return 2;
    return min;
  }
}
