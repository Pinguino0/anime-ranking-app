import 'package:animerank/features/episodes/domain/intro_markers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IntroMarkers', () {
    test('il pulsante vale dentro la finestra e non fuori', () {
      const intro = IntroMarkers(
        start: Duration.zero,
        end: Duration(seconds: 90),
      );

      expect(intro.isActive(Duration.zero), isTrue);
      expect(intro.isActive(const Duration(seconds: 60)), isTrue);
      // Sotto il margine finale il salto porterebbe dove si e' gia'.
      expect(intro.isActive(const Duration(seconds: 88)), isFalse);
      expect(intro.isActive(const Duration(seconds: 120)), isFalse);
    });

    test('legge la finestra da una riga del catalogo', () {
      final intro = IntroMarkers.fromRow({
        'intro_start_seconds': 12,
        'intro_end_seconds': 102,
      });

      expect(intro, isNotNull);
      expect(intro!.start, const Duration(seconds: 12));
      expect(intro.end, const Duration(seconds: 102));
    });

    test('una finestra incompleta o invertita vale come assente', () {
      expect(IntroMarkers.fromRow(const {}), isNull);
      expect(IntroMarkers.fromRow(const {'intro_start_seconds': 10}), isNull);
      expect(
        IntroMarkers.fromRow(const {
          'intro_start_seconds': 90,
          'intro_end_seconds': 90,
        }),
        isNull,
      );
    });
  });
}
