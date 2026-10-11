import 'dart:async';

import 'package:animerank/features/auth/data/auth_repository.dart';
import 'package:animerank/features/auth/domain/auth_status.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Costruisce un [User] finto.
///
/// Il vero tipo arriva da gotrue e i suoi campi sono quasi tutti obbligatori:
/// costruirlo a mano in ogni test rende illeggibile il test stesso, quindi
/// qui si dichiarano una volta sola i minimi indispensabili.
User buildUser({String id = 'u1', String? email = 'mario@example.com'}) {
  return User(
    id: id,
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    email: email,
    createdAt: '2024-01-01T00:00:00.000Z',
  );
}

/// Costruisce una [Session] finta che contiene [user].
Session buildSession({User? user, String userId = 'u1'}) {
  return Session(
    accessToken: 'token-di-test',
    refreshToken: 'refresh-di-test',
    tokenType: 'bearer',
    user: user ?? buildUser(id: userId),
  );
}

/// Repository finto: nessuna rete, stato controllato dal test.
///
/// I campi pubblici servono a programmare il comportamento:
///
/// - [session] e lo stato iniziale, e viene emesso sul canale a ogni cambio;
/// - [signInFailure] e [signUpFailure] fanno fallire l'operazione, cosi' si
///   verifica che la UI mostri l'errore e non cambi schermata.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({
    this.session,
    this.userId = 'u1',
    this.email = 'mario@example.com',
    this.signInFailure,
    this.signUpFailure,
    this.signUpOutcome = SignUpOutcome.alreadySignedIn,
  });

  Session? session;

  /// Id dell'utente prodotto da una registrazione o un accesso riuscito.
  final String userId;
  final String email;

  /// Se valorizzato, [signIn] e [signUp] sollevano questo errore.
  final Object? signInFailure;
  final Object? signUpFailure;

  /// Esito restituito da [signUp] quando non fallisce.
  final SignUpOutcome signUpOutcome;

  /// Tiene conto delle chiamate, per verificare che i pulsanti non si
  /// duplicchino quando l'utente preme a piu' volte.
  int signInCalls = 0;
  int signUpCalls = 0;
  int signOutCalls = 0;
  int resetCalls = 0;
  int updatePasswordCalls = 0;

  /// Ultima password passata a [updatePassword], per verificarla nei test.
  String? lastNewPassword;

  /// Se valorizzato, [updatePassword] fallisce con questo errore.
  Object? updatePasswordFailure;

  final _events = StreamController<AuthStatus>.broadcast();
  final _recovery = StreamController<void>.broadcast();

  /// Simula l'arrivo di un link di recupero password da Supabase.
  void emitPasswordRecovery() => _recovery.add(null);

  /// Espone un cambio di sessione come farebbe Supabase.
  void emit(Session? next) {
    session = next;
    _events.add(AuthStatus.fromSession(next));
  }

  @override
  Session? get currentSession => session;

  @override
  Stream<AuthStatus> watch() => _events.stream;

  @override
  Future<void> signIn({required String email, required String password}) async {
    signInCalls++;
    final failure = signInFailure;
    if (failure != null) throw failure;
    emit(buildSession(user: buildUser(id: userId, email: this.email)));
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    String? userName,
  }) async {
    signUpCalls++;
    final failure = signUpFailure;
    if (failure != null) throw failure;

    if (signUpOutcome == SignUpOutcome.alreadySignedIn) {
      emit(buildSession(user: buildUser(id: userId, email: this.email)));
    }
    return signUpOutcome;
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    resetCalls++;
  }

  @override
  Stream<void> watchPasswordRecovery() => _recovery.stream;

  @override
  Future<void> updatePassword(String password) async {
    updatePasswordCalls++;
    lastNewPassword = password;
    final failure = updatePasswordFailure;
    if (failure != null) throw failure;
    // Come Supabase: la sessione resta valida, l'utente e' collegato.
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    emit(null);
  }

  void dispose() {
    _events.close();
    _recovery.close();
  }
}