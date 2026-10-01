import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Colori di AnimeRank.
///
/// Identita' visiva: base indaco-violaceo molto scuro, accento viola che
/// sfuma nel magenta. Il contrasto e' voluto e non neutro: la app si
/// riconosce da lontano nei giochi fra amici.
///
/// Da NON fare: prendere il blu acceso di AniList o il verde di MyAnimeList.
/// Qui la firma e' la coppia viola/magenta sui gradienti.
class ArColors {
  const ArColors._();

  // Sfondi, dal piu' profondo al piu' vicino al contenuto.
  static const Color bg = Color(0xFF0A0A12);
  static const Color surface = Color(0xFF14141F);
  static const Color surfaceHigh = Color(0xFF1E1E2D);
  static const Color surfaceTop = Color(0xFF262638);

  // Accenti.
  static const Color primary = Color(0xFF7C5CFF);
  static const Color primaryDim = Color(0xFF5B3FD9);
  static const Color accent = Color(0xFFFF4D8D);
  static const Color accentDim = Color(0xFFC7346B);

  // Semantici.
  static const Color success = Color(0xFF2DD4BF);
  static const Color warning = Color(0xFFFFB020);
  static const Color danger = Color(0xFFFF5C6C);
  static const Color info = Color(0xFF4DA6FF);

  // Testo.
  static const Color textHigh = Color(0xFFF2F2F7);
  static const Color textMid = Color(0xFFA8A8BD);
  static const Color textLow = Color(0xFF6E6E85);

  // Bordi.
  static const Color border = Color(0xFF2A2A3D);
  static const Color borderSoft = Color(0xFF20202E);

  // Medaglie della classifica.
  static const Color gold = Color(0xFFFFC542);
  static const Color silver = Color(0xFFC0C6D4);
  static const Color bronze = Color(0xFFCD7F45);

  // Stati watchlist, coerenti con le emoji del prompt.
  static const Color planned = Color(0xFFF5C518);
  static const Color watching = Color(0xFF4DA6FF);
  static const Color completed = Color(0xFF2DD4BF);
  static const Color dropped = Color(0xFFFF5C6C);
  static const Color paused = Color(0xFFA78BFA);
  static const Color favorite = Color(0xFFFF4D8D);

  /// Gradiente principale: usato su header, CTA e card in evidenza.
  static const LinearGradient brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, accent],
  );

  /// Variante piu' fredda per sfondi grandi, meno aggressiva del brand.
  static const LinearGradient subtle = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1A1A2E), Color(0xFF12121C)],
  );

  /// Colore del badge per posizione in classifica.
  static Color rank(int position) {
    if (position == 1) return gold;
    if (position == 2) return silver;
    if (position == 3) return bronze;
    return textLow;
  }
}

/// ThemeMode salvato nelle impostazioni dell'utente.
enum AppThemeMode { dark, light, system }

class AppTheme {
  const AppTheme._();

  static const String _fontFamily = 'Roboto';

  /// Il tema scuro e il default (prompt sezione 28).
  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: ArColors.primary,
      onPrimary: Colors.white,
      primaryContainer: ArColors.primaryDim,
      onPrimaryContainer: Colors.white,
      secondary: ArColors.accent,
      onSecondary: Colors.white,
      tertiary: ArColors.success,
      onTertiary: Color(0xFF04302B),
      error: ArColors.danger,
      onError: Colors.white,
      surface: ArColors.surface,
      onSurface: ArColors.textHigh,
      onSurfaceVariant: ArColors.textMid,
      outline: ArColors.border,
      outlineVariant: ArColors.borderSoft,
    );

    return _base(scheme, ArColors.bg).copyWith(
      scaffoldBackgroundColor: ArColors.bg,
      extensions: const [ArExtension(
        reward: ArColors.gold,
        heroGradient: ArColors.brand,
        glass: Color(0x14FFFFFF),
      )],
    );
  }

  /// Tema chiaro richiesto dalla sezione 35. Non e solo un'inversione:
  /// gli accenti sono scuriti per restare leggibili su fondo bianco
  /// (un viola acceso su bianco non passa il contrasto AA).
  static ThemeData get light {
    const scheme = ColorScheme.light(
      primary: Color(0xFF6244E8),
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFE6E0FF),
      onPrimaryContainer: Color(0xFF241468),
      secondary: Color(0xFFD6356F),
      onSecondary: Colors.white,
      tertiary: Color(0xFF0E9384),
      onTertiary: Colors.white,
      error: Color(0xFFD32F3D),
      onError: Colors.white,
      surface: Color(0xFFF7F7FB),
      onSurface: Color(0xFF15151E),
      onSurfaceVariant: Color(0xFF56566B),
      outline: Color(0xFFD9D9E5),
      outlineVariant: Color(0xFFE8E8F0),
    );

    return _base(scheme, Color(0xFFF2F2F7)).copyWith(
      extensions: const [ArExtension(
        reward: Color(0xFFB8860B),
        heroGradient: ArColors.brand,
        glass: Color(0x0A000000),
      )],
    );
  }

  /// Costruzione comune ai due temi: qui vivono i componenti, cosi dark e
  /// light restano coerenti senza duplicare 200 righe.
  static ThemeData _base(ColorScheme scheme, Color scaffold) {
    final isDark = scheme.brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: _fontFamily,
      // Leggermente arrotondate: leggere come amiche, non come form.
      visualDensity: VisualDensity.standard,

      textTheme: _textTheme(scheme),

      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        systemOverlayStyle:
            isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),

      cardTheme: CardThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: isDark ? ArColors.surfaceHigh : Colors.white,
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? ArColors.surfaceHigh : Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.error),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: .5)),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          side: BorderSide(color: scheme.outline),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? ArColors.surface : Colors.white,
        indicatorColor: scheme.primary.withValues(alpha: .18),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark ? ArColors.surface : Colors.white,
        indicatorColor: scheme.primary.withValues(alpha: .18),
        selectedIconTheme: IconThemeData(color: scheme.primary, size: 24),
        unselectedIconTheme:
            IconThemeData(color: scheme.onSurfaceVariant, size: 24),
        selectedLabelTextStyle: TextStyle(
          color: scheme.primary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? ArColors.surfaceTop : ArColors.surfaceHigh,
        contentTextStyle: TextStyle(color: scheme.onSurface, fontSize: 14),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? ArColors.surfaceHigh : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? ArColors.surfaceHigh : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.outlineVariant,
        thumbColor: scheme.primary,
        trackHeight: 6,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.outlineVariant,
        circularTrackColor: scheme.outlineVariant,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? ArColors.surfaceTop : ArColors.surfaceHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outline),
        ),
        textStyle: TextStyle(color: scheme.onSurface, fontSize: 12),
      ),
    );
  }

  static TextTheme _textTheme(ColorScheme scheme) {
    // Scala tipografica stretta: titoli con letter-spacing negativo, che e'
    // il tratto che rende un'interfaccia moderna invece che " Material 3
    // di default".
    return TextTheme(
      displaySmall: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
        color: scheme.onSurface,
        height: 1.1,
      ),
      headlineMedium: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
        color: scheme.onSurface,
        height: 1.15,
      ),
      headlineSmall: TextStyle(
        fontSize: 21,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: scheme.onSurface,
        height: 1.2,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: scheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: scheme.onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      bodyLarge: TextStyle(
        fontSize: 15,
        height: 1.5,
        color: scheme.onSurface,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 1.5,
        color: scheme.onSurface,
      ),
      bodySmall: TextStyle(
        fontSize: 12.5,
        height: 1.45,
        color: scheme.onSurfaceVariant,
      ),
      labelLarge: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
      labelMedium: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
      labelSmall: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        letterSpacing: .4,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// Colori che non hanno un posto nello standard ColorScheme ma servono.
///
/// Aggiungerli qui e' preferibile a hardcodarli nei widget: se serve
/// cambiarne uno, si cambia una volta sola.
@immutable
class ArExtension extends ThemeExtension<ArExtension> {
  const ArExtension({
    required this.reward,
    required this.heroGradient,
    required this.glass,
  });

  /// Oro delle medaglie e dei traguardi.
  final Color reward;

  /// Gradiente delle sezioni in evidenza.
  final LinearGradient heroGradient;

  /// Colore delle superfici translucide (simula il blur).
  final Color glass;

  @override
  ArExtension copyWith({
    Color? reward,
    LinearGradient? heroGradient,
    Color? glass,
  }) =>
      ArExtension(
        reward: reward ?? this.reward,
        heroGradient: heroGradient ?? this.heroGradient,
        glass: glass ?? this.glass,
      );

  @override
  ArExtension lerp(ArExtension? other, double t) {
    if (other == null) return this;
    return ArExtension(
      reward: Color.lerp(reward, other.reward, t)!,
      heroGradient:
          LinearGradient.lerp(heroGradient, other.heroGradient, t)!,
      glass: Color.lerp(glass, other.glass, t)!,
    );
  }
}

/// Accesso corto ai colori custom dentro il build.
extension ArThemeContext on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
  ArExtension get ar => Theme.of(this).extension<ArExtension>()!;
}
