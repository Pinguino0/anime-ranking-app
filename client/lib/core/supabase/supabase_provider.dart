import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Client Supabase condiviso da tutta l'app.
///
/// Vive in un Provider invece che in una variabile globale perche' nei test
/// si possa sovrascrivere il valore con un client finto, senza toccare la
/// rete. In [AnimeRankApp] non va mai letto direttamente dai widget: passare
/// sempre dai repository, cosi' i test restano isolati.
///
/// In [main] viene sovrascritto con il client vero, creato da
/// `Supabase.initialize`.
final supabaseProvider = Provider<SupabaseClient>((ref) {
  throw StateError(
    'supabaseProvider non e stato inizializzato. '
    'Deve essere sovrascritto in main() con ProviderScope(overrides: ...).',
  );
});