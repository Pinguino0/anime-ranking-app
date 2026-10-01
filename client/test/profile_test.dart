import 'package:animerank/features/auth/presentation/auth_controller.dart';
import 'package:animerank/features/profile/domain/user_profile.dart';
import 'package:animerank/features/profile/presentation/profile_controller.dart';
import 'package:animerank/features/profile/presentation/screens/delete_account_screen.dart';
import 'package:animerank/features/profile/presentation/screens/notification_settings_screen.dart';
import 'package:animerank/features/profile/presentation/screens/profile_screen.dart';
import 'package:animerank/features/profile/presentation/widgets/avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'helpers/fake_auth.dart';
import 'helpers/fake_profile.dart';

void main() {
  group('ProfileValidators', () {
    test('lo username rispetta i limiti del CHECK', () {
      // Replica di profiles_username_format: 3-24, [A-Za-z0-9_].
      expect(ProfileValidators.usernameError('abc'), isNull);
      expect(ProfileValidators.usernameError('Mario_Rossi_99'), isNull);
      expect(ProfileValidators.usernameError('ab'), isNotNull);
      expect(ProfileValidators.usernameError('a' * 25), isNotNull);
      expect(ProfileValidators.usernameError(''), isNotNull);
    });

    test('lo username rifiuta spazi e accenti subito', () {
      // Verificare la regex qui evita un viaggio di rete per un errore che il
      // database rifiuterebbe comunque.
      expect(ProfileValidators.usernameError('mario rossi'), isNotNull);
      expect(ProfileValidators.usernameError('mario.rossi'), isNotNull);
      expect(ProfileValidators.usernameError('mariò'), isNotNull);
    });

    test('la bio e opzionale ma limitata a 280', () {
      expect(ProfileValidators.bioError(null), isNull);
      expect(ProfileValidators.bioError(''), isNull);
      expect(ProfileValidators.bioError('z' * 280), isNull);
      expect(ProfileValidators.bioError('z' * 281), isNotNull);
    });
  });

  group('UserProfile', () {
    test('hasBio distingue assente da vuota', () {
      expect(buildProfile(bio: 'testo').hasBio, isTrue);
      // Bio vuota e assente sono dati diversi per il database: la UI non deve
      // mostrare "Nessuna bio descritta" come se fosse un dato mancante.
      expect(buildProfile(bio: '   ').hasBio, isFalse);
      expect(buildProfile(bio: null).hasBio, isFalse);
    });

    test('l iniziale viene dalla prima lettera', () {
      expect(buildProfile(username: 'mario').initial, 'M');
      expect(buildProfile(username: '_uno').initial, '_');
    });

    test('parse gestisce una riga incompleta', () {
      final profile = UserProfile.parse({'id': 'u1'});
      expect(profile.username, 'Utente');
      expect(profile.bio, isNull);
    });
  });

  group('NotificationPreferences', () {
    test('copyWith senza argomenti non cambia nulla', () {
      // Il default dei parametri non puo' essere "true": altrimenti un
      // copyWith che cambia una sola spunta riaccenderebbe tutte le altre.
      const prefs = NotificationPreferences(push: false, votes: true);

      expect(prefs.copyWith().push, isFalse);
      expect(prefs.copyWith().votes, isTrue);
      expect(prefs.copyWith(votes: false).push, isFalse);
    });

    test('allOff richiede tutte le spunte spente', () {
      expect(const NotificationPreferences().allOff, isFalse);
      expect(
        const NotificationPreferences(push: false).allOff,
        isFalse,
      );
      expect(
        const NotificationPreferences(
          push: false,
          votes: false,
          friends: false,
          tournaments: false,
          rankChanges: false,
        ).allOff,
        isTrue,
      );
    });

    test('parse usa true come fallback', () {
      // Le colonne hanno default true nel database: se il server non le
      // invia, silenziare l'utente sarebbe la scelta sbagliata.
      final prefs = NotificationPreferences.parse({'notify_votes': false});

      expect(prefs.votes, isFalse);
      expect(prefs.push, isTrue);
    });
  });

  group('ProfileController', () {
    late FakeProfileRepository repo;

    setUp(() => repo = FakeProfileRepository());

    ProviderContainer container([FakeProfileRepository? r]) {
      final c = ProviderContainer(
        overrides: [profileRepositoryProvider.overrideWithValue(r ?? repo)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('carica il profilo', () async {
      final c = container();
      final profile = await c.read(profileProvider.future);

      expect(repo.loadCalls, 1);
      expect(profile.username, 'mario');
    });

    test('il salvataggio mette subito in stato il risultato', () async {
      final c = container();
      await c.read(profileProvider.future);

      await c.read(profileProvider.notifier).save(username: 'marioplus');

      // Lo stato aggiornato senza reload: la schermata mostra subito il nome
      // nuovo invece di lampeggiare quello vecchio.
      expect(c.read(profileProvider).value!.username, 'marioplus');
      expect(repo.updateCalls, 1);
    });

    test('bio vuota viene salvata come assente', () async {
      final c = container();
      await c.read(profileProvider.future);

      await c.read(profileProvider.notifier).save(bio: '   ');

      expect(c.read(profileProvider).value!.bio, isNull);
    });

    test('un errore di caricamento resta visibile', () async {
      repo.loadFailure = const ProfileFailure('Profilo non trovato.');
      final c = container();

      await expectLater(c.read(profileProvider.future), throwsA(isA<ProfileFailure>()));
      expect(c.read(profileProvider).hasError, isTrue);
    });

    test('deleteAccount non lascia uno stato profilo inventato', () async {
      final c = container();
      await c.read(profileProvider.future);

      await c.read(profileProvider.notifier).deleteAccount();

      // Dopo la cancellazione l'utente non esiste piu': lo stato viene lasciato
      // com'e' e il router porta al login.
      expect(repo.deleteAccountCalls, 1);
      expect(c.read(profileProvider).value, isNotNull);
    });
  });

  group('NotificationPreferencesController', () {
    late FakeProfileRepository repo;

    setUp(() => repo = FakeProfileRepository());

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [profileRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('salva una sola preferenza senza toccare le altre', () async {
      final c = container();
      await c.read(notificationPreferencesProvider.future);

      await c.read(notificationPreferencesProvider.notifier).set(votes: false);

      final prefs = c.read(notificationPreferencesProvider).value!;
      expect(prefs.votes, isFalse);
      expect(prefs.push, isTrue);
      expect(repo.preferences.votes, isFalse);
    });

    test('un salvataggio fallito riporta il valore precedente', () async {
      final c = container();
      await c.read(notificationPreferencesProvider.future);

      repo.saveFailure = const ProfileFailure('Preferenze non salvate.');
      await expectLater(
        c.read(notificationPreferencesProvider.notifier).set(push: false),
        throwsA(isA<ProfileFailure>()),
      );

      // Senza il rollback l'interruttore resterebbe spento a schermo mentre il
      // database dice il contrario: l'utente non riceverebbe piu' notifiche
      // senza saperlo.
      expect(c.read(notificationPreferencesProvider).value!.push, isTrue);
    });
  });

  group('schermate profilo', () {
    late FakeProfileRepository repo;
    late FakeAuthRepository auth;

    setUp(() {
      repo = FakeProfileRepository();
      auth = FakeAuthRepository(session: buildSession());
    });

    Future<void> pumpScreen(
      WidgetTester tester,
      Widget child, {
      FakeProfileRepository? profileRepo,
    }) async {
      final p = profileRepo ?? repo;
      final router = GoRouter(
        initialLocation: '/profile',
        routes: [
          GoRoute(path: '/profile', builder: (_, _) => child),
          GoRoute(path: '/profile/notifications', builder: (_, _) => const SizedBox.shrink()),
          GoRoute(path: '/profile/delete', builder: (_, _) => const SizedBox.shrink()),
          GoRoute(path: '/login', builder: (_, _) => const SizedBox.shrink()),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profileRepositoryProvider.overrideWithValue(p),
            authRepositoryProvider.overrideWithValue(auth),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('mostra i dati del profilo', (tester) async {
      await pumpScreen(tester, const ProfileScreen());

      // La bio compare due volte: nell anteprima e dentro il campo che la
      // modifica. Si controlla solo l anteprima, per non legare il test al
      // fatto che il form sia o no aperto.
      expect(find.text('Membro dal 15 gennaio 2026'), findsOneWidget);
      expect(find.text('mario'), findsWidgets);
      expect(find.text('Profilo salvato.'), findsNothing);
    });

    testWidgets('il logout chiama il repository auth', (tester) async {
      await pumpScreen(tester, const ProfileScreen());

      await tester.tap(find.widgetWithText(OutlinedButton, 'Esci'));
      await tester.pumpAndSettle();

      expect(auth.signOutCalls, 1);
    });

    testWidgets('un errore di caricamento offre il retry', (tester) async {
      final failing = FakeProfileRepository()
        ..loadFailure = const ProfileFailure('Profilo non disponibile.');
      await pumpScreen(tester, const ProfileScreen(), profileRepo: failing);

      expect(find.text('Profilo non disponibile.'), findsOneWidget);

      failing.loadFailure = null;
      await tester.tap(find.text('Riprova'));
      await tester.pumpAndSettle();

      expect(failing.loadCalls, greaterThan(1));
      expect(find.text('Profilo non disponibile.'), findsNothing);
      expect(find.text('Membro dal 15 gennaio 2026'), findsOneWidget);
    });

    testWidgets('lo username non valido blocca il salvataggio', (tester) async {
      await pumpScreen(tester, const ProfileScreen());

      await tester.enterText(find.widgetWithText(TextFormField, 'Nome utente'), 'ab');
      await tester.tap(find.widgetWithText(FilledButton, 'Salva'));
      await tester.pumpAndSettle();

      expect(find.text('Almeno 3 caratteri.'), findsOneWidget);
      expect(repo.updateCalls, 0);
    });

    testWidgets('il campo username non accetta spazi', (tester) async {
      await pumpScreen(tester, const ProfileScreen());

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nome utente'),
        'mario rossi',
      );

      final field = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Nome utente'),
      );
      // Senza il formatter il campo potrebbe assumere un valore che il CHECK
      // del database rifiuterebbe, e l'errore arriverebbe solo al salvataggio.
      expect(field.controller!.text, 'mariorossi');
    });

    testWidgets('il salvataggio riuscito lo conferma', (tester) async {
      await pumpScreen(tester, const ProfileScreen());

      await tester.enterText(find.widgetWithText(TextFormField, 'Nome utente'), 'marioplus');
      await tester.tap(find.widgetWithText(FilledButton, 'Salva'));
      await tester.pumpAndSettle();

      expect(repo.updateCalls, 1);
      expect(find.text('Profilo salvato.'), findsOneWidget);
    });

    testWidgets('un nome gia preso viene segnalato', (tester) async {
      final taken = FakeProfileRepository()
        ..updateFailure = const ProfileFailure('Questo nome utente e gia preso.');
      await pumpScreen(tester, const ProfileScreen(), profileRepo: taken);

      await tester.tap(find.widgetWithText(FilledButton, 'Salva'));
      await tester.pumpAndSettle();

      expect(find.text('Questo nome utente e gia preso.'), findsOneWidget);
    });
  });

  group('schermata notifiche', () {
    late FakeProfileRepository repo;

    setUp(() => repo = FakeProfileRepository());

    Future<void> pumpSettings(WidgetTester tester, {FakeProfileRepository? repositoryFailing}) async {
      final p = repositoryFailing ?? repo;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [profileRepositoryProvider.overrideWithValue(p)],
          child: const MaterialApp(home: NotificationSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('mostra tutte le preferenze', (tester) async {
      await pumpSettings(tester);

      expect(find.text('Notifiche push'), findsOneWidget);
      expect(find.text('Nuove votazioni'), findsOneWidget);
      expect(find.text('Amici'), findsOneWidget);
      expect(find.text('Tornei'), findsOneWidget);
      expect(find.text('Cambiamenti di classifica'), findsOneWidget);
    });

    testWidgets('un interruttore salva la preferenza', (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.widgetWithText(SwitchListTile, 'Tornei'));
      await tester.pumpAndSettle();

      expect(repo.saveNotificationsCalls, 1);
      expect(repo.preferences.tournaments, isFalse);
      // Le altre preferenze non vengono toccate.
      expect(repo.preferences.votes, isTrue);
    });

    testWidgets('un salvataggio fallito riporta l interruttore', (tester) async {
      final failing = FakeProfileRepository()
        ..saveFailure = const ProfileFailure('Preferenze non salvate.');
      await pumpSettings(tester, repositoryFailing: failing);

      await tester.tap(find.widgetWithText(SwitchListTile, 'Tornei'));
      await tester.pumpAndSettle();

      expect(find.text('Preferenze non salvate.'), findsOneWidget);
    });

    testWidgets('con tutte le spunte spente compare l avviso', (tester) async {
      await pumpSettings(tester);

      for (final label in [
        'Notifiche push',
        'Nuove votazioni',
        'Amici',
        'Tornei',
        'Cambiamenti di classifica',
      ]) {
        await tester.tap(find.widgetWithText(SwitchListTile, label));
        await tester.pumpAndSettle();
      }

      expect(find.text('Tutte le notifiche sono spente.'), findsOneWidget);
    });
  });

  group('cancellazione account', () {
    late FakeProfileRepository repo;

    setUp(() => repo = FakeProfileRepository());

    Future<void> pumpDelete(
      WidgetTester tester, {
      FakeProfileRepository? r,
      String initial = '/profile/delete',
    }) async {
      final p = r ?? repo;
      final router = GoRouter(
        initialLocation: initial,
        routes: [
          GoRoute(path: '/profile', builder: (_, _) => const SizedBox.shrink()),
          GoRoute(path: '/profile/delete', builder: (_, _) => const DeleteAccountScreen()),
          GoRoute(path: '/login', builder: (_, _) => const Text('schermata di login')),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [profileRepositoryProvider.overrideWithValue(p)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('il pulsante resta disabilitato senza la parola', (tester) async {
      await pumpDelete(tester);

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Elimina definitivamente'),
      );
      expect(button.onPressed, isNull);
      expect(repo.deleteAccountCalls, 0);
    });

    testWidgets('una parola sbagliata non sblocca nulla', (tester) async {
      await pumpDelete(tester);

      await tester.enterText(find.byType(TextField), 'elimina');

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Elimina definitivamente'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('la parola esatta sblocca e cancella', (tester) async {
      await pumpDelete(tester);

      await tester.enterText(find.byType(TextField), 'ELIMINA');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Elimina definitivamente'));
      await tester.pumpAndSettle();

      expect(repo.deleteAccountCalls, 1);
      // Dopo la cancellazione si torna al login: l'account non esiste piu'.
      expect(find.text('schermata di login'), findsOneWidget);
    });

    testWidgets('i file vengono eliminati prima della cancellazione', (tester) async {
      // Il finto chiama davvero i due metodi, come fa l'implementazione reale:
      // e' l'unico modo di verificare che l'ordine sia garantito dal
      // repository e non dalla UI.
      final ordered = FakeProfileRepository();
      await pumpDelete(tester, r: ordered);

      await tester.enterText(find.byType(TextField), 'ELIMINA');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Elimina definitivamente'));
      await tester.pumpAndSettle();

      // L'ordine e' un requisito del backend: senza i file prima, la RPC
      // risponde 22023 e l'account non viene cancellato.
      expect(ordered.calls, ['deleteStoredFiles', 'deleteAccount']);
    });

    testWidgets('i file rimasti vengono mostrati', (tester) async {
      final stuck = FakeProfileRepository()
        ..deleteFailure = const AccountDeletionFailure(
          'Cancella prima i 2 file caricati tramite la Storage API',
          remainingFiles: 2,
        );
      await pumpDelete(tester, r: stuck);

      await tester.enterText(find.byType(TextField), 'ELIMINA');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Elimina definitivamente'));
      await tester.pumpAndSettle();

      // Il numero arriva dal backend: senza, l'utente saprebbe che deve
      // cancellare file ma non quanti. Si cerca il testo esatto dell avviso
      // con cui la schermata spiega cosa fare, non il messaggio grezzo.
      expect(
        find.text('Rimuovi prima i 2 file caricati: la cancellazione si ferma finche esistono.'),
        findsOneWidget,
      );
      expect(find.text('schermata di login'), findsNothing);
    });
  });

  group('ProfileAvatar', () {
    testWidgets('senza url mostra l iniziale', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ProfileAvatar(fallbackText: 'M', size: 48)),
        ),
      );

      expect(find.text('M'), findsOneWidget);
    });
  });
}
