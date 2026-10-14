import 'dart:convert';

import 'package:animerank/features/episodes/data/animesaturn_extractor.dart';
import 'package:animerank/features/episodes/domain/episode.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un client HTTP finto che risponde in base a sottostringhe dell'URL.
///
/// La mappa e' ordinata e si scorre dall'inizio: chi registra un path piu'
/// specifico lo mette prima di quello generico che lo contiene.
class _FakeHttp implements BackupHttpClient {
  _FakeHttp(this.routes);

  final Map<String, BackupHttpResponse Function()> routes;
  final List<String> requested = [];

  @override
  Future<BackupHttpResponse> get(String url, {Map<String, String>? headers}) async {
    requested.add(url);
    for (final entry in routes.entries) {
      if (url.contains(entry.key)) return entry.value();
    }
    return const BackupHttpResponse(404, '');
  }
}

/// L'inverso di cio' che l'estrattore decodifica: XOR, poi base64.
String _encodeXor(String value, String key) {
  final bytes = utf8.encode(value);
  final keyBytes = utf8.encode(key);
  final out = <int>[
    for (var i = 0; i < bytes.length; i++) bytes[i] ^ keyBytes[i % keyBytes.length],
  ];
  return base64Encode(out);
}

/// Una pagina di visione finta con lo stesso `x-data="watchPage({...})"` reale,
/// dove le virgolette sono entita' HTML.
String _watchPageHtml(String embedUrl) {
  final escaped = embedUrl.replaceAll('&', '&amp;');
  return '<!DOCTYPE html><html><body>'
      '<div x-data="watchPage({&quot;episodeId&quot;:90077,'
      '&quot;initialVideoUrl&quot;:&quot;$escaped&quot;,'
      '&quot;servers&quot;:[{&quot;id&quot;:1,&quot;link&quot;:&quot;$escaped&quot;}]})">'
      '</div></body></html>';
}

void main() {
  group('watchPageJson', () {
    test('estrae il JSON da x-data con entita HTML e graffe annidate', () {
      final html = _watchPageHtml(
        'https://play.saturncdn.net/embed/90077?token=abc&expires=123',
      );

      final json = AnimeSaturnExtractor.watchPageJson(html);

      expect(json, isNotNull);
      final data = jsonDecode(json!) as Map<String, dynamic>;
      expect(data['episodeId'], 90077);
      expect(
        data['initialVideoUrl'],
        'https://play.saturncdn.net/embed/90077?token=abc&expires=123',
      );
    });

    test('una graffa dentro una stringa non chiude il JSON', () {
      const html =
          '<div x-data="watchPage({&quot;title&quot;:&quot;a } b&quot;,'
          '&quot;n&quot;:1})"></div>';

      final json = AnimeSaturnExtractor.watchPageJson(html);

      expect(json, isNotNull);
      expect((jsonDecode(json!) as Map)['n'], 1);
    });

    test('senza watchPage restituisce null', () {
      expect(AnimeSaturnExtractor.watchPageJson('<html></html>'), isNull);
    });
  });

  group('xorDecodeBase64', () {
    test('decodifica URL offuscato con chiave il token', () {
      const url = 'https://srv30.example.org/x.mp4?token=T&expires=1';
      final encoded = _encodeXor(url, 'abc123');

      expect(AnimeSaturnExtractor.xorDecodeBase64(encoded, 'abc123'), url);
    });

    test('una chiave vuota non produce nulla', () {
      expect(AnimeSaturnExtractor.xorDecodeBase64('AAAA', ''), '');
    });
  });

  group('embedUrlOf', () {
    test('preferisce initialVideoUrl', () {
      final url = AnimeSaturnExtractor.embedUrlOf({
        'initialVideoUrl': 'https://play.saturncdn.net/embed/1?token=a&expires=2',
        'servers': [
          {'link': 'https://play.saturncdn.net/embed/9?token=z&expires=3'},
        ],
      });
      expect(url, contains('/embed/1'));
    });

    test('ripiega sul primo server se initialVideoUrl e vuoto', () {
      final url = AnimeSaturnExtractor.embedUrlOf({
        'initialVideoUrl': '',
        'servers': [
          {'link': 'https://play.saturncdn.net/embed/9?token=z&expires=3'},
        ],
      });
      expect(url, contains('/embed/9'));
    });

    test('senza nulla restituisce null', () {
      expect(AnimeSaturnExtractor.embedUrlOf(const {'servers': []}), isNull);
    });
  });

  group('anilistIdOf', () {
    test('legge l id dal link AniList', () {
      expect(
        AnimeSaturnExtractor.anilistIdOf(
          '<a href="https://anilist.co/anime/212888/">AniList</a>',
        ),
        '212888',
      );
    });

    test('senza link restituisce null', () {
      expect(AnimeSaturnExtractor.anilistIdOf('<html></html>'), isNull);
    });
  });

  group('candidateQueries', () {
    test('ripulisce, toglie i duplicati e taglia al massimo', () {
      final queries = AnimeSaturnExtractor.candidateQueries([
        ' Overgeared ',
        'overgeared',
        '',
        'Tempal: Item no Chikara',
        'a',
        'b',
        'c',
        'd',
        'e',
      ]);

      expect(queries.first, 'Overgeared');
      expect(queries.where((q) => q.toLowerCase() == 'overgeared').length, 1);
      expect(queries.length, AnimeSaturnExtractor.maxSearchQueries);
    });
  });

  group('dice', () {
    test('titoli con le stesse parole valgono 1', () {
      expect(AnimeSaturnExtractor.dice('naruto shippuden', 'naruto shippuden'), 1);
    });

    test('titoli senza parole in comune valgono 0', () {
      expect(AnimeSaturnExtractor.dice('naruto', 'bleach'), 0);
    });
  });

  group('extract', () {
    test('trova l anime per id AniList e decodifica il video', () async {
      const media = 'https://srv30.example.org/E/Tempal_Ep_01_SUB_ITA.mp4?token=X&expires=9';
      const embed = 'https://play.saturncdn.net/embed/90077?token=abc&expires=123';

      final http = _FakeHttp({
        '/anime/overgeared-zzb4X/ep-1': () => BackupHttpResponse(200, _watchPageHtml(embed)),
        '/anime/overgeared-zzb4X': () => const BackupHttpResponse(
              200,
              '<a href="https://anilist.co/anime/212888/">AniList</a>',
            ),
        '/api/search': () => BackupHttpResponse(
              200,
              jsonEncode({
                'results': [
                  {'title': 'Overgeared', 'url': '/anime/overgeared-zzb4X', 'year': '2026'},
                ],
              }),
            ),
        '/playlist': () => BackupHttpResponse(200, jsonEncode({'d': _encodeXor(media, 'abc')})),
      });

      final extractor = AnimeSaturnExtractor(http: http);
      final resolved = await extractor.extract(
        sourceId: 'source-1',
        titles: ['Overgeared', 'Tempal: Item no Chikara'],
        episodeNumber: 1,
        anilistId: '212888',
        year: 2026,
        language: 'sub',
      );

      expect(resolved.resolvedUrl, media);
      expect(resolved.sourceType, EpisodeSourceType.mp4);
      expect(resolved.providerSlug, 'animesaturn');
      expect(resolved.sourceId, 'source-1');
    });

    test('un id AniList diverso non aggancia l anime sbagliato', () async {
      final http = _FakeHttp({
        '/anime/overgeared-zzb4X': () => const BackupHttpResponse(
              200,
              '<a href="https://anilist.co/anime/999999/">AniList</a>',
            ),
        '/api/search': () => BackupHttpResponse(
              200,
              jsonEncode({
                'results': [
                  {'title': 'Overgeared', 'url': '/anime/overgeared-zzb4X', 'year': '2026'},
                ],
              }),
            ),
      });

      final extractor = AnimeSaturnExtractor(http: http);

      await expectLater(
        extractor.extract(
          sourceId: 'source-1',
          titles: ['Overgeared'],
          episodeNumber: 1,
          anilistId: '212888',
        ),
        throwsA(isA<Exception>()),
      );
      // Non deve mai arrivare a chiedere il video.
      expect(http.requested.any((u) => u.contains('/ep-1')), isFalse);
    });

    test('senza titoli fallisce senza toccare la rete', () async {
      final http = _FakeHttp(const {});
      final extractor = AnimeSaturnExtractor(http: http);

      await expectLater(
        extractor.extract(sourceId: 's', titles: const [], episodeNumber: 1),
        throwsA(isA<Exception>()),
      );
      expect(http.requested, isEmpty);
    });
  });
}
