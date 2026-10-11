import 'dart:io';

import 'package:animerank/features/update/data/update_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

/// La pulizia degli APK lasciati dagli aggiornamenti.
///
/// Il test passa una cartella temporanea vera invece della cartella dell'app:
/// la funzione accetta [deleteLeftoverUpdateApks] un percorso proprio proprio
/// per questo, cosi' si prova il filesystem senza dipendere da path_provider.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('animerank_cleanup_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('cancella gli APK lasciati dagli aggiornamenti', () async {
    await File('${dir.path}${Platform.pathSeparator}animerank-3.apk')
        .writeAsBytes([1, 2, 3]);
    await File('${dir.path}${Platform.pathSeparator}animerank-4.apk')
        .writeAsBytes([1, 2, 3]);

    final removed = await deleteLeftoverUpdateApks(directory: dir);

    expect(removed, 2);
    final apks = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.apk'));
    expect(apks, isEmpty);
  });

  test('lascia stare i file che non sono APK', () async {
    final apk = File('${dir.path}${Platform.pathSeparator}animerank-3.apk')
      ..writeAsBytesSync([1]);
    final keep = File('${dir.path}${Platform.pathSeparator}note.txt')
      ..writeAsStringSync('non cancellarmi');

    final removed = await deleteLeftoverUpdateApks(directory: dir);

    expect(removed, 1);
    expect(apk.existsSync(), isFalse);
    expect(keep.existsSync(), isTrue);
  });

  test('una cartella che non esiste non e un errore', () async {
    final missing = Directory('${dir.path}${Platform.pathSeparator}assente');

    expect(await deleteLeftoverUpdateApks(directory: missing), 0);
  });

  group('isCleanupDue', () {
    final now = DateTime(2026, 10, 10, 12);

    test('la prima volta pulisce subito', () {
      expect(isCleanupDue(now: now, lastCleanup: null), isTrue);
    });

    test('non ripulisce se non e passata una settimana', () {
      expect(
        isCleanupDue(
          now: now,
          lastCleanup: now.subtract(const Duration(days: 3)),
        ),
        isFalse,
      );
    });

    test('ripulisce dopo una settimana', () {
      expect(
        isCleanupDue(
          now: now,
          lastCleanup: now.subtract(const Duration(days: 7)),
        ),
        isTrue,
      );
    });
  });
}
