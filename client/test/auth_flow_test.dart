import 'package:animerank/app.dart';
import 'package:animerank/core/router/app_router.dart';
import 'package:animerank/features/auth/data/auth_repository.dart';
import 'package:animerank/features/auth/presentation/auth_controller.dart';
import 'package:animerank/features/auth/presentation/screens/login_screen.dart';
import 'package:animerank/features/auth/presentation/screens/register_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_auth.dart';

void main() {
  /// Avvia l'app con un repository finto, senza toccare Supabase.
  Future<FakeAuthRepository> pumpApp(
    WidgetTester tester, {
    FakeAuthRepository? repository,
  }) async {
    final repo = repository ?? FakeAuthRepository();
    addTearDown(repo.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(repo)],
        child: const AnimeRankApp(),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  group('rotte e sessione', () {
    testWidgets('senza sessione la home reindirizza al login', (tester) async {
      await pumpApp(tester);

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Bentornato'), findsOneWidget);
    });

    testWidgets('con sessione si parte dalla shell', (tester) async {
      final repo = FakeAuthRepository(session: buildSession());
      await pumpApp(tester, repository: repo);

      expect(find.text('Accesso effettuato'), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
    });

    testWidgets('la registrazione e raggiungibile dal login', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Registrati'));
      await tester.pumpAndSettle();

      expect(find.byType(RegisterScreen), findsOneWidget);
      expect(find.text('Crea il tuo account'), findsOneWidget);
    });

    testWidgets('il login rimanda alla registrazione', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Registrati'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Accedi'));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
    });
  });

  group('accesso', () {
    testWidgets('un campo vuoto non chiama il repository', (tester) async {
      final repo = await pumpApp(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Accedi'));
      await tester.pumpAndSettle();

      expect(repo.signInCalls, 0);
      expect(find.text('Inserisci la tua email.'), findsOneWidget);
    });

    testWidgets('l accesso riuscito porta alla shell', (tester) async {
      final repo = await pumpApp(tester);

      await tester.enterText(find.byType(TextFormField).first, 'mario@example.com');
      await tester.enterText(find.byType(TextFormField).last, 'password123');
      await tester.tap(find.widgetWithText(FilledButton, 'Accedi'));
      await tester.pumpAndSettle();

      expect(repo.signInCalls, 1);
      expect(find.text('Accesso effettuato'), findsOneWidget);
    });

    testWidgets('credenziali sbagliate mostrano l errore e restano sul login',
        (tester) async {
      final repo = FakeAuthRepository(signInFailure: const AuthFailure('Email o password sbagliate.'));
      await pumpApp(tester, repository: repo);

      await tester.enterText(find.byType(TextFormField).first, 'mario@example.com');
      await tester.enterText(find.byType(TextFormField).last, 'sbagliata');
      await tester.tap(find.widgetWithText(FilledButton, 'Accedi'));
      await tester.pumpAndSettle();

      expect(repo.signInCalls, 1);
      expect(find.text('Email o password sbagliate.'), findsOneWidget);
      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('la sessione che arriva dopo il login porta alla shell',
        (tester) async {
      final repo = FakeAuthRepository(signInFailure: const AuthFailure('Connessione assente.'));
      await pumpApp(tester, repository: repo);

      await tester.enterText(find.byType(TextFormField).first, 'mario@example.com');
      await tester.enterText(find.byType(TextFormField).last, 'password123');
      await tester.tap(find.widgetWithText(FilledButton, 'Accedi'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);

      // La sessione arriva dopo, per esempio da un refresh del token.
      repo.emit(buildSession());
      await tester.pumpAndSettle();

      expect(find.text('Accesso effettuato'), findsOneWidget);
    });

    testWidgets('il logout torna al login', (tester) async {
      final repo = FakeAuthRepository(session: buildSession());
      await pumpApp(tester, repository: repo);

      final controller = ProviderScope.containerOf(
        tester.element(find.text('Accesso effettuato')),
      );
      await controller.read(authStatusProvider.notifier).signOut();
      await tester.pumpAndSettle();

      expect(repo.signOutCalls, 1);
      expect(find.byType(LoginScreen), findsOneWidget);
    });
  });

  group('registrazione', () {
    testWidgets('con conferma email non entra ma avvisa', (tester) async {
      final repo = FakeAuthRepository(signUpOutcome: SignUpOutcome.needsEmailConfirmation);
      await pumpApp(tester, repository: repo);

      await tester.tap(find.widgetWithText(TextButton, 'Registrati'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).at(0), 'mario@example.com');
      await tester.enterText(find.byType(TextFormField).at(1), 'mario1');
      await tester.enterText(find.byType(TextFormField).at(2), 'password123');
      await tester.tap(find.widgetWithText(FilledButton, 'Crea account'));
      await tester.pumpAndSettle();

      expect(repo.signUpCalls, 1);
      expect(find.text('Controlla la tua email'), findsOneWidget);
    });

    testWidgets('senza conferma email entra subito', (tester) async {
      final repo = FakeAuthRepository(signUpOutcome: SignUpOutcome.alreadySignedIn);
      await pumpApp(tester, repository: repo);

      await tester.tap(find.widgetWithText(TextButton, 'Registrati'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).at(0), 'mario@example.com');
      await tester.enterText(find.byType(TextFormField).at(1), 'mario1');
      await tester.enterText(find.byType(TextFormField).at(2), 'password123');
      await tester.tap(find.widgetWithText(FilledButton, 'Crea account'));
      await tester.pumpAndSettle();

      expect(find.text('Accesso effettuato'), findsOneWidget);
    });

    testWidgets('un nome gia preso dal database viene segnalato', (tester) async {
      final repo = FakeAuthRepository(signUpFailure: const AuthFailure('Questa email e gia registrata.'));
      await pumpApp(tester, repository: repo);

      await tester.tap(find.widgetWithText(TextButton, 'Registrati'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).at(0), 'mario@example.com');
      await tester.enterText(find.byType(TextFormField).at(1), 'mario1');
      await tester.enterText(find.byType(TextFormField).at(2), 'password123');
      await tester.tap(find.widgetWithText(FilledButton, 'Crea account'));
      await tester.pumpAndSettle();

      expect(find.text('Questa email e gia registrata.'), findsOneWidget);
    });

    testWidgets('il nome utente viene pulito mentre si digita', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Registrati'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).at(1), 'Mario Rossi!');

      // Gli spazi diventano underscore, il punto esclamativo sparisce: il
      // campo non deve mai poter assumere un valore che il CHECK rifiuterebbe.
      final field = tester.widget<TextFormField>(find.byType(TextFormField).at(1));
      final controller = field.controller!;
      expect(controller.text, 'Mario_Rossi');
    });
  });

  group('AppRoutes', () {
    test('le rotte pubbliche sono solo login e registrazione', () {
      // Se una schermata privata finisse in AppRoutes.public, il redirect
      // lascerebbe entrare senza sessione: questa assunzione va tenuta
      // sott'occhio.
      expect(AppRoutes.public, {AppRoutes.login, AppRoutes.register});
      expect(AppRoutes.public, isNot(contains(AppRoutes.home)));
    });
  });
}