import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../domain/user_profile.dart';

/// Immagine scelta dall'utente, pronta per l'upload.
///
/// Byte ed estensione viaggiano insieme di proposito: il chiamante non deve
/// rileggere il file. Su Android il percorso temporaneo della foto scelta dalla
/// galleria puo' non essere piu' leggibile quando l'upload finisce.
class PickedAvatar {
  const PickedAvatar({required this.bytes, required this.extension});

  final Uint8List bytes;

  /// Estensione senza punto, minuscola e gia' fra quelle accettate dal bucket
  /// (`jpg`, `png`, `webp`).
  final String extension;

  int get sizeInBytes => bytes.length;
}

/// Scelta della foto profilo dal dispositivo.
///
/// E' un'interfaccia perche' `image_picker` apre la galleria di sistema e nei
/// test non esiste: i test iniettano un finto che restituisce byte controllati,
/// cosi' l'upload si verifica senza toccare il sistema operativo.
abstract interface class AvatarPicker {
  /// Restituisce l'immagine scelta, o `null` se l'utente annulla.
  Future<PickedAvatar?> pick();
}

/// Implementazione reale basata su `image_picker`.
///
/// Un unico pacchetto copre Android, iOS e Windows: su desktop e' un wrapper di
/// `file_selector`, quindi il codice non sceglie il canale per piattaforma.
class ImagePickerAvatarPicker implements AvatarPicker {
  ImagePickerAvatarPicker({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<PickedAvatar?> pick() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      // Ridimensiona e ricomprime: una foto da 12 MP supera il tetto di 2 MB
      // del bucket e verrebbe rifiutata. Su desktop questi parametri non hanno
      // effetto, quindi il controllo di dimensione resta anche nel client.
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (file == null) return null;

    return PickedAvatar(
      bytes: await file.readAsBytes(),
      extension: _normalizeExtension(file.name),
    );
  }

  /// Normalizza l'estensione del file scelto.
  ///
  /// Il bucket accetta solo `jpg`, `png` e `webp`: tutto il resto ricade su
  /// `jpg`. Non e' una perdita per l'utente, perche' `imageQuality` fa
  /// ricomprimere l'immagine in JPEG prima ancora di arrivare qui.
  static String _normalizeExtension(String fileName) {
    final lower = fileName.toLowerCase();

    for (final extension in ProfileValidators.avatarExtensions) {
      if (lower.endsWith('.$extension')) return extension;
    }

    return 'jpg';
  }
}
