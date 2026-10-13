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

    test('legge la finestra dalla risposta della funzione', () {
      final intro = IntroMarkers.fromWindow(12, 102);

      expect(intro, isNotNull);
      expect(intro!.start, const Duration(seconds: 12));
      expect(intro.end, const Duration(seconds: 102));
    });

    test('una finestra incompleta o invertita vale come assente', () {
      expect(IntroMarkers.fromWindow(null, null), isNull);
      expect(IntroMarkers.fromWindow(10, null), isNull);
      expect(IntroMarkers.fromWindow(90, 90), isNull);
    });
  });
}
