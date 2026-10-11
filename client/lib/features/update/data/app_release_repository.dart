import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_failure.dart';
import '../domain/app_release.dart';

/// Lettura delle versioni pubblicate.
///
/// Una sola operazione, e di sola lettura: le versioni le pubblica il
/// maintainer dal SQL Editor, il client non scrive niente. Il motivo e' che una
/// RPC scrivibile darebbe a ogni utente registrato il permesso di far
/// installare APK a chiunque altro avesse un account.
abstract interface class AppReleaseRepository {
  /// Il rilascio piu' recente, o `null` se non ne e' stato pubblicato nessuno.
  ///
  /// `null` non e' un errore: e' la situazione normale del primo giorno e
  /// anche quella di un'app installata senza configurazione. Un errore vero e'
  /// [AppReleaseFailure].
  Future<AppRelease?> latest();
}

/// Errore nel controllo degli aggiornamenti.
class AppReleaseFailure extends AppFailure {
  const AppReleaseFailure(super.message, {super.isRetryable});
}

/// Repository per la produzione.
///
/// Di default esiste solo per i test: senza un client Supabase non c'e'
/// niente da leggere, e fingere che non ci siano aggiornamenti nasconderebbe
/// un errore di configurazione dietro un'app che sembra funzionare.
final appReleaseRepositoryProvider = Provider<AppReleaseRepository>((ref) {
  throw UnimplementedError(
    'appReleaseRepositoryProvider va sovrascritto in main.dart: senza un client '
    'Supabase non c\'e\' nessuna versione da leggere.',
  );
});

/// Implementazione che legge `public.app_releases`.
class SupabaseAppReleaseRepository implements AppReleaseRepository {
  SupabaseAppReleaseRepository(this._client);

  final SupabaseClient _client;

  /// Le colonne sono esplicite perche' la tabella non deve poter crescere di
  /// colonne in modo da far fallire una build vecchia: se un giorno sotto ci
  /// fosse un campo che richiede il permesso di scrittura, questa `select` non
  /// lo prenderebbe.
  static const String _columns =
      'version_code, version_name, apk_url, sha256, size_bytes, notes';

  @override
  Future<AppRelease?> latest() async {
    try {
      final rows = await _client
          .from('app_releases')
          .select(_columns)
          .order('version_code', ascending: false)
          .limit(1);

      if (rows.isEmpty) return null;

      return AppRelease.parse(rows.first);
    } on AppFailure {
      rethrow;
    } catch (_) {
      // Nessuna traduzione dei codici: sotto questa tabella non ci sono
      // decisioni del server, solo "c'e' la tabella" oppure "non c'e'". Il
      // chiamante non deve fare niente di diverso in un caso e nell'altro,
      // quindi il messaggio basta.
      throw const AppReleaseFailure(
        'Non riesco a controllare gli aggiornamenti.',
        isRetryable: true,
      );
    }
  }
}