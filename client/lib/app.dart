import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/presentation/screens/setup_screen.dart';

/// Radice dell'app.
///
/// E' [ConsumerWidget] solo per poter leggere il router: [appRouterProvider]
/// tiene gia' dentro la dipendenza da [authRepositoryProvider], quindi il
/// router viene ricostruito da solo se la sessione cambia.
class AnimeRankApp extends ConsumerWidget {
  const AnimeRankApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'AnimeRank',
      debugShowCheckedModeBanner: false,
      // Il tema scuro e' quello di partenza: la palette del progetto e' costruita
      // su uno sfondo scuro, e il tema chiaro serve soprattutto a chi imposta
      // il tema di sistema su chiaro.
      themeMode: ThemeMode.dark,
      darkTheme: AppTheme.dark,
      theme: AppTheme.light,
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}

/// App mostrata quando mancano le credenziali Supabase.
///
/// Un'app separata, non una rotta: senza `supabaseProvider` il router
/// costruirebbe un client inesistente e ogni schermata che lo tocca
/// esploderebbe. Meglio fermarsi qui, prima.
class SetupApp extends StatelessWidget {
  const SetupApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AnimeRank',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: AppTheme.dark,
      theme: AppTheme.light,
      home: const SetupScreen(),
    );
  }
}