import 'package:animerank/features/auth/domain/auth_status.dart';
import 'package:animerank/features/auth/domain/auth_validators.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_auth.dart';

void main() {
  group('AuthValidators.usernameError', () {
    test('accetta i nomi che il CHECK del database ammette', () {
      // Stessi casi del CHECK profiles_username_format: 002_profiles.sql.
      expect(AuthValidators.usernameError('mario'), isNull);
      expect(AuthValidators.usernameError('mario1'), isNull);
      expect(AuthValidators.usernameError('Mario_92'), isNull);
      expect(AuthValidators.usernameError('___'), isNull);
      expect(AuthValidators.usernameError('a' * 24), isNull);
    });

    test('rifiuta cio che il CHECK del database rifiuta', () {
      expect(AuthValidators.usernameError('ab'), isNotNull); // troppo corto
      expect(AuthValidators.usernameError('a' * 25), isNotNull); // troppo lungo
      expect(AuthValidators.usernameError('mario rossi'), isNotNull); // spazio
      expect(AuthValidators.usernameError('mariò'), isNotNull); // accento
      expect(AuthValidators.usernameError('mario!'), isNotNull); // simbolo
      expect(AuthValidators.usernameError('a-b_c'), isNotNull); // trattino
    });

    test('non impone regole che il database non ha', () {
      // Nessuna richiesta di cifra sul nome: il CHECK del database non la
      // prevede e imporla significherebbe rifiutare nomi che il backend
      // accetterebbe, costringendo a scrivere "mario1".
      expect(AuthValidators.usernameError('abcdefgh'), isNull);
    });

    test('ignora gli spazi attorno', () {
      expect(AuthValidators.usernameError('  mario1  '), isNull);
    });

    test('distingue vuoto da non valido', () {
      expect(AuthValidators.usernameError(null), isNotNull);
      expect(AuthValidators.usernameError(''), isNotNull);
      expect(AuthValidators.usernameError('   '), isNotNull);
    });
  });

  group('AuthValidators.emailError', () {
    test('accetta indirizzi normali', () {
      expect(AuthValidators.emailError('mario@example.com'), isNull);
      expect(AuthValidators.emailError('  mario@example.com '), isNull);
      expect(AuthValidators.emailError('mario.rossi+tag@example.co.uk'), isNull);
    });

    test('rifiuta i casi piu frequenti di errore di digitazione', () {
      expect(AuthValidators.emailError('mario'), isNotNull);
      expect(AuthValidators.emailError('mario@'), isNotNull);
      expect(AuthValidators.emailError('@example.com'), isNotNull);
      expect(AuthValidators.emailError('mario@example'), isNotNull);
      expect(AuthValidators.emailError('mario example@it'), isNotNull);
    });
  });

  group('AuthValidators.passwordError', () {
    test('in registrazione chiede almeno 6 caratteri e una cifra', () {
      expect(AuthValidators.passwordError('abc', isRegistration: true), isNotNull);
      expect(AuthValidators.passwordError('abcdefgh', isRegistration: true), isNotNull);
      expect(AuthValidators.passwordError('abc123', isRegistration: true), isNull);
    });

    test('in accesso non pretende una cifra', () {
      // Se pretendesse una cifra, un account creato con una password debole
      // resterebbe irraggiungibile per sempre.
      expect(AuthValidators.passwordError('abcdefgh', isRegistration: false), isNull);
      expect(AuthValidators.passwordError('abc', isRegistration: false), isNotNull);
    });

    test('rifiuta il vuoto in entrambi i casi', () {
      expect(AuthValidators.passwordError(null, isRegistration: true), isNotNull);
      expect(AuthValidators.passwordError('', isRegistration: false), isNotNull);
    });
  });

  group('AuthStatus', () {
    test('da sessione nulla produce SignedOut', () {
      final status = AuthStatus.fromSession(null);
      expect(status, isA<AuthSignedOut>());
      expect(status.isSignedIn, isFalse);
      expect(status.user, isNull);
    });

    test('da sessione valida produce SignedIn con lo stesso utente', () {
      final status = AuthStatus.fromSession(buildSession(user: buildUser(id: 'u42')));
      expect(status, isA<AuthSignedIn>());
      expect(status.isSignedIn, isTrue);
      expect(status.user?.id, 'u42');
    });
  });
}