import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Colori di AnimeRank.
///
/// Identita' visiva: nero AMOLED come base, superfici tonali con appena una
/// tinta indaco dentro, accento viola. Il nero non e' un grigio scuro travestito:
/// e' il fondo della app, e su uno schermo OLED spento non consuma quasi nulla.
///
/// Il viola non e' decorazione, e' la regola dei contrasti: su nero puro un
/// viola acceso legge come "premium" e al tempo stesso mantiene il rapporto
/// di contrasto del testo sopra le superfici tonali.
///
/// Da NON fare: prendere il blu acceso di AniList o il verde di MyAnimeList.
/// Qui la firma e' la coppia viola/magenta sui gradienti.
class ArColors {
  const ArColors._();

  // Sfondi, dal piu' profondo al piu' vicino al contenuto.
  //
  // La scala segue i cinque livelli tonali di Material 3. Sono volutamente
  // vicinissimi fra loro, dentro una sfumatura di viola: e' quello che fa
  // sembrare le card "sollevate" dal fondo senza dover aggiungere un bordo a
  // ogni elemento. I bordi netti si usano solo dove serve separare due
  // contenuti affiancati, non per definire ogni superficie.
  static const Color bg = Color(0xFF05050A);
  static const Color surface = Color(0xFF0D0D14);
  static const Color surfaceHigh = Color(0xFF15151F);
  static const Color surfaceTop = Color(0xFF1F1F2B);

  /// Livelli tonali Material 3, dalla superficie piu' profonda alla piu' in
  /// alto. Esposti perche' i widget non devono inventarsi colori propri.
  static const Color containerLowest = Color(0xFF08080E);
  static const Color containerLow = Color(0xFF0E0E16);
  static const Color container = Color(0xFF14141D);
  static const Color containerHigh = Color(0xFF1B1B26);
  static const Color containerHighest = Color(0xFF232330);

  // Accenti.
  static const Color primary = Color(0xFF8B72FF);
  static const Color primaryDim = Color(0xFF6A4FE0);
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

  /// Gradiente dei poster: dal trasparente al fondo.
  ///
  /// Serve a mettere il titolo del film leggibile sopra un'immagine che non
  /// controlliamo. Il nero e' quello dello sfondo della app, non un grigio
  /// neutro: se il fondo cambiasse il gradiente smetterebbe di innestarsi.
  static const LinearGradient posterScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00000000), Color(0xCC05050A), Color(0xFF05050A)],
    stops: [0.35, 0.72, 1],
  );

  /// Variante verticale per le intestazioni sopra un'immagine a tutta pagina.
  static const LinearGradient heroScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x0005050A), Color(0x9905050A), Color(0xFF05050A)],
    stops: [0, 0.55, 1],
  );

  /// Variante piu' fredda per sfondi grandi, meno aggressiva del brand.
  static const LinearGradient subtle = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF141426), Color(0xFF0A0A12)],
  );

  /// Colore del badge per posizione in classifica.
  static Color rank(int position) {
    if (position == 1) return gold;
    if (position == 2) return silver;
    if (position == 3) return bronze;
    return textLow;
  }
}

/// Raggio degli angoli.
///
/// Centralizzati perche' il raggio e' quello che distingue un'app "moderna" da
/// un form di amministrazione: qui tutto e' generoso e arrotondato, e i valori
/// crescono con la dimensione dell'elemento come in un sistema costruito bene.
/// Un ragolo a caso per ogni schermata e' quello che rende un'app rovinata anche
/// se i colori sono corretti.
class ArRadii {
  const ArRadii._();

  /// Chip, badge, pastiglia piccole.
  static const double chip = 12;

  /// Pulsanti e campi di testo.
  static const double control = 16;

  /// Card di contenuto.
  static const double card = 20;

  /// Sheet che sale dal basso.
  static const double sheet = 28;

  /// Dialog e menu.
  static const double dialog = 26;

  /// Locandine a tutta pagina: il raggio grande serve a far leggere l'immagine
  /// come una copertina e non come un banner.
  static const double poster = 24;
}

/// Passo della griglia.
///
/// I valori sono una progressione fissa (4-8-12-16-24-32-48), non un insieme
/// di numeri scelti a caso: quando due schermate usano lo stesso passo,
/// i bordi delle card si allineano da soli e la pagina sembra costruita.
/// Un `EdgeInsets(16, 14, 18, 12)` qua e' uno spazio di 2 px che si vede.
class ArSpace {
  const ArSpace._();

  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Margine laterale standard delle schermate.
  ///
  /// Cresce con la larghezza su tablet e desktop, dove il contenuto ha spazio
  /// da perdere e i bordi troppo stretti fanno leggere le righe come se
  /// arrivassero dal margine. Su telefono resta stretto per non sprecare
  /// schermo.
  static EdgeInsets page(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 1100) return const EdgeInsets.symmetric(horizontal: xl);
    if (width >= 700) return const EdgeInsets.symmetric(horizontal: lg);
    return const EdgeInsets.symmetric(horizontal: md);
  }
}

/// Durate delle animazioni.
///
/// Una sola scala per tutta l'app: transizioni con durate diverse l'una dopo
/// l'altra sembrano un'applicazione che "si prepara" invece di una che risponde.
/// Sono deliberatamente corte. Un'interfaccia snella si riconosce da quanto
/// velocemente restituisce il controllo a chi tocca.
class ArMotion {
  const ArMotion._();

  /// Micro-interazione: cambio di stato su un elemento gia' visibile.
  static const Duration fast = Duration(milliseconds: 150);

  /// Transizione fra schermate e comparse di contenuto.
  static const Duration base = Duration(milliseconds: 260);

  /// Ingressi di elementi grandi: apertura di un foglio, cambio di sezione.
  static const Duration slow = Duration(milliseconds: 420);

  /// Curva standard.
  ///
  /// `easeOutCubic` per l'ingresso: l'elemento arriva presto e si assesta,
  /// che e' come si muove qualcosa di fisico. `easeInOut` per l'uscita, dove
  /// l'elemento accelera verso la scomparsa.
  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
}

/// Ombre.
///
/// Su fondo scuro l'ombra e' quasi invisibile: quello che stacca davvero una
/// card dal fondo e' un alone colorato. Per questo qui ci sono due livelli, e
/// il secondo e' un bagliore del colore di accento: e' quello che fa sembrare
/// "illuminata" una card in evidenza senza doverla illuminare davvero.
class ArShadows {
  const ArShadows._();

  /// Ombra portante delle card galleggianti.
  ///
  /// `const` e non un getter perche' non dipende da niente: e' sempre la stessa
  /// ombra, e renderla disponibile in costante permette a `BoxDecoration` di
  /// evitare di ricostruire la lista a ogni build.
  static const List<BoxShadow> card = [
    BoxShadow(
      color: Color(0x73000000),
      blurRadius: 24,
      offset: Offset(0, 8),
    ),
  ];

  /// Alone colorato, per gli elementi in evidenza.
  static List<BoxShadow> glow(Color color, {double strength = 0.30}) => [
        BoxShadow(
          color: color.withValues(alpha: strength),
          blurRadius: 28,
          spreadRadius: -6,
          offset: const Offset(0, 6),
        ),
      ];

  /// Ombra morbida per i pannelli che galleggiano sopra al contenuto.
  static const List<BoxShadow> panel = [
    BoxShadow(
      color: Color(0x8C000000),
      blurRadius: 32,
      offset: Offset(0, 12),
    ),
  ];
}

/// ThemeMode salvato nelle impostazioni dell'utente.
enum AppThemeMode { dark, light, system }

class AppTheme {
  const AppTheme._();

  /// Testo e numeri.
  static const String bodyFont = 'Inter';

  /// Titoli grandi e intestazioni.
  static const String displayFont = 'SpaceGrotesk';

  /// Famiglia predefinita: display.
  ///
  /// I titoli sono la voce piu' forte dell'interfaccia e devono avere una forma
  /// riconoscibile; il corpo del testo resta su Inter, piu' neutro e leggibile
  /// a 14px.
  static const String _fontFamily = displayFont;

  /// Applica il peso reale del font variabile.
  ///
  /// Necessario perche' i file scaricati da Google Fonts sono variabili
  /// (`Inter[opsz,wght]`): senza `fontVariations` Flutter non sa quale
  /// istanza dell'asse `wght` prendere e il `fontWeight` diventerebbe
  /// ininfluente, con tutti i testi allo stesso peso.
  static List<FontVariation> _wght(double weight) => [
        FontVariation('wght', weight),
      ];


  /// Il tema scuro e il default (prompt sezione 28).
  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: ArColors.primary,
      onPrimary: Color(0xFF14091F),
      primaryContainer: Color(0xFF332468),
      onPrimaryContainer: Color(0xFFE7E1FF),
      secondary: ArColors.accent,
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFF6E1B3E),
      onSecondaryContainer: Color(0xFFFFE0EB),
      tertiary: ArColors.success,
      onTertiary: Color(0xFF04302B),
      error: ArColors.danger,
      onError: Colors.white,
      // Superfici tonali: l'unico posto dove il nero e' davvero nero e' lo
      // scaffold. Tutto il resto e' una superficie appena sollevata.
      surface: ArColors.surface,
      onSurface: ArColors.textHigh,
      onSurfaceVariant: ArColors.textMid,
      surfaceContainerLowest: ArColors.containerLowest,
      surfaceContainerLow: ArColors.containerLow,
      surfaceContainer: ArColors.container,
      surfaceContainerHigh: ArColors.containerHigh,
      surfaceContainerHighest: ArColors.containerHighest,
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
      primary: Color(0xFF5B3FD9),
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFE7E1FF),
      onPrimaryContainer: Color(0xFF241468),
      secondary: Color(0xFFD6356F),
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFFFE0EB),
      onSecondaryContainer: Color(0xFF5C0F2B),
      tertiary: Color(0xFF0E9384),
      onTertiary: Colors.white,
      error: Color(0xFFD32F3D),
      onError: Colors.white,
      surface: Color(0xFFF7F7FB),
      onSurface: Color(0xFF15151E),
      onSurfaceVariant: Color(0xFF56566B),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: Color(0xFFFCFCFE),
      surfaceContainer: Color(0xFFF2F2F7),
      surfaceContainerHigh: Color(0xFFEBEBF1),
      surfaceContainerHighest: Color(0xFFE3E3EB),
      outline: Color(0xFFD9D9E5),
      outlineVariant: Color(0xFFE8E8F0),
    );

    return _base(scheme, const Color(0xFFF2F2F7)).copyWith(
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
        // Superficie tonale, non "riempimento + bordo": il bordo e' la
        // tecnica delle tabelle, non delle card. Qui il livello di superficie
        // fa il lavoro da solo e la gerarchia resta leggibile al buio.
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ArRadii.card),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        side: BorderSide.none,
        labelStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ArRadii.chip),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ArRadii.control),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ArRadii.control),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ArRadii.control),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ArRadii.control),
          borderSide: BorderSide(color: scheme.error),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: .5)),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ArRadii.control),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 50),
          side: BorderSide(color: scheme.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ArRadii.control),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        // Fondo semitrasparente e bordo in alto: la barra "appoggia" sopra il
        // contenuto invece di essere un blocco piu' chiaro che taglia lo schermo.
        backgroundColor: isDark
            ? ArColors.container.withValues(alpha: .92)
            : Colors.white,
        indicatorColor: scheme.primary.withValues(alpha: .20),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 72,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ArRadii.control),
        ),
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
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark ? ArColors.container : Colors.white,
        indicatorColor: scheme.primary.withValues(alpha: .20),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ArRadii.control),
        ),
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
        backgroundColor: isDark ? ArColors.containerHighest : ArColors.surfaceHigh,
        contentTextStyle: TextStyle(color: scheme.onSurface, fontSize: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ArRadii.control),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? ArColors.containerHigh : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ArRadii.dialog),
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? ArColors.containerHigh : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(ArRadii.sheet)),
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
    // il tratto che rende un'interfaccia moderna invece che "Material 3 di
    // default". I titoli su Space Grotesk perche' hanno una forma propria e
    // riconoscibile; il corpo su Inter, che a 14px e' piu' leggibile.
    //
    // Nessuno stile qui mette `fontWeight` senza `fontVariations`: sui file
    // variabili il peso va richiesto all'asse, altrimenti il testo esce
    // sempre allo stesso peso e tutta la gerarchia si appiattisce.
    return TextTheme(
      displaySmall: TextStyle(
        fontFamily: displayFont,
        fontSize: 36,
        fontWeight: FontWeight.w700,
        fontVariations: _wght(700),
        letterSpacing: -1.4,
        color: scheme.onSurface,
        height: 1.05,
      ),
      headlineMedium: TextStyle(
        fontFamily: displayFont,
        fontSize: 28,
        fontWeight: FontWeight.w700,
        fontVariations: _wght(700),
        letterSpacing: -1,
        color: scheme.onSurface,
        height: 1.1,
      ),
      headlineSmall: TextStyle(
        fontFamily: displayFont,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        fontVariations: _wght(700),
        letterSpacing: -0.6,
        color: scheme.onSurface,
        height: 1.15,
      ),
      titleLarge: TextStyle(
        fontFamily: displayFont,
        fontSize: 19,
        fontWeight: FontWeight.w700,
        fontVariations: _wght(700),
        letterSpacing: -0.4,
        color: scheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontFamily: bodyFont,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        fontVariations: _wght(600),
        letterSpacing: -0.2,
        color: scheme.onSurface,
      ),
      titleSmall: TextStyle(
        fontFamily: bodyFont,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        fontVariations: _wght(600),
        color: scheme.onSurface,
      ),
      bodyLarge: TextStyle(
        fontFamily: bodyFont,
        fontSize: 15,
        fontWeight: FontWeight.w400,
        fontVariations: _wght(400),
        height: 1.55,
        color: scheme.onSurface,
      ),
      bodyMedium: TextStyle(
        fontFamily: bodyFont,
        fontSize: 14,
        fontWeight: FontWeight.w400,
        fontVariations: _wght(400),
        height: 1.55,
        color: scheme.onSurface,
      ),
      bodySmall: TextStyle(
        fontFamily: bodyFont,
        fontSize: 12.5,
        fontWeight: FontWeight.w400,
        fontVariations: _wght(400),
        height: 1.5,
        color: scheme.onSurfaceVariant,
      ),
      labelLarge: TextStyle(
        fontFamily: bodyFont,
        fontSize: 13,
        fontWeight: FontWeight.w700,
        fontVariations: _wght(700),
        letterSpacing: 0.1,
        color: scheme.onSurface,
      ),
      labelMedium: TextStyle(
        fontFamily: bodyFont,
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        fontVariations: _wght(600),
        color: scheme.onSurfaceVariant,
      ),
      // Le etichette piccole hanno letter-spacing positivo: sono maiuscolette di
      // sezione, e la spaziatura e' quello che le fa leggere come intestazioni
      // invece che come testo più piccolo.
      labelSmall: TextStyle(
        fontFamily: bodyFont,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        fontVariations: _wght(600),
        letterSpacing: 1.1,
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
