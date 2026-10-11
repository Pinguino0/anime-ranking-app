import 'package:supabase_flutter/supabase_flutter.dart';

/// Scrittura del token FCM del dispositivo sul database.
///
/// Passa dalle RPC `register_device_token` / `remove_device_token` e non dalla
/// tabella: la RLS di `device_tokens` lascia toccare solo le proprie righe, e un
/// telefono che cambia account (logout/login) deve poter spostare il token dal
/// vecchio utente al nuovo. E' un caso che le policy da sole non coprono.
abstract interface class DeviceTokenRepository {
  /// Registra (o riassegna) il token all'utente collegato.
  Future<void> register({required String token, required String platform});

  /// Toglie il token, al logout.
  Future<void> remove({required String token});
}

/// Implementazione reale su Supabase.
class SupabaseDeviceTokenRepository implements DeviceTokenRepository {
  SupabaseDeviceTokenRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<void> register({
    required String token,
    required String platform,
  }) async {
    await _client.rpc(
      'register_device_token',
      params: {'p_token': token, 'p_platform': platform},
    );
  }

  @override
  Future<void> remove({required String token}) async {
    await _client.rpc(
      'remove_device_token',
      params: {'p_token': token},
    );
  }
}
