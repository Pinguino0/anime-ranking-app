import 'dart:typed_data';

import 'package:animerank/features/profile/data/avatar_picker.dart';

/// Picker finto: restituisce byte controllati senza aprire la galleria.
///
/// `image_picker` apre la galleria di sistema, che in un test non esiste:
/// senza questo finto l'upload non sarebbe verificabile e il test dovrebbe
/// fermarsi prima di toccare il codice che conta.
class FakeAvatarPicker implements AvatarPicker {
  int pickCalls = 0;

  /// Immagine restituita. `null` (il default) simula l'annullamento.
  PickedAvatar? result;

  /// Errore sollevato all'apertura, per il caso "immagini non disponibili".
  Object? failure;

  @override
  Future<PickedAvatar?> pick() async {
    pickCalls++;
    final error = failure;
    if (error != null) throw error;
    return result;
  }
}

/// Immagine di comodo per i test.
PickedAvatar buildPickedAvatar({int size = 64, String extension = 'jpg'}) =>
    PickedAvatar(bytes: Uint8List(size), extension: extension);
