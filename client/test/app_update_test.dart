import 'package:animerank/features/update/data/app_release_repository.dart';
import 'package:animerank/features/update/data/install_permission.dart';
import 'package:animerank/features/update/data/ota_downloader.dart';
import 'package:animerank/features/update/data/update_background_task.dart';
import 'package:animerank/features/update/domain/app_release.dart';
import 'package:animerank/features/update/presentation/app_update_controller.dart';
import 'package:animerank/features/update/presentation/widgets/update_dialog.dart';
import 'package:animerank/features/update/presentation/widgets/update_gate.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_app_release.dart';

/// Finto del permesso di installazione: conta quante volte apre le impostazioni.
class FakeInstallPermission implements InstallPermission {
  FakeInstallPermission({this.canInstall = true});

  bool canInstall;
  int openCalls = 0;

  @override
  Future<bool> canInstallFromSource() async => canInstall;

  @override
  Future<void> openFromSettings() async {
    openCalls++;
  }
}

/// Download finto che emette un progresso e finisce subito: il plugin vero,
/// senza dispositivo Android, non produce mai eventi e lascerebbe il test
/// appeso a una stream che non si chiude.
class FakeApkDownloader implements ApkDownloader {
  int startCalls = 0;

  @override
  ApkDownload start(
    String url, {
    String? destinationFilename,
    String? sha256checksum,
  }) {
    startCalls++;
    return _FakeDownload();
  }
}

class _FakeDownload implements ApkDownload {
  @override
  Stream<OtaEvent> get events => Stream<OtaEvent>.fromIterable(<OtaEvent>[
        OtaEvent(OtaStatus.DOWNLOADING, '50'),
        OtaEvent(OtaStatus.DOWNLOADING, '100'),
      ]);

  @override
  Future<void> cancel() async {}
}

/// Pulsante che cambia testo solo se riceve davvero un tocco.
///
/// Serve a provare che sotto l'avviso l'app non e' piu' usabile: dire "il testo
/// e' rimasto quello di prima" dice molto piu' che contare i `ModalBarrier`,
/// perche' nel Navigator ce n'e' uno comunque.
class _TapProbe extends StatefulWidget {
  const _TapProbe({required this.label});

  final String label;

  @override
  State<_TapProbe> createState() => _TapProbeState();
}

class _TapProbeState extends State<_TapProbe> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => setState(() => _taps++),
      child: Text('${widget.label} $_taps'),
    );
  }
}

void main() {
  /// Costruisce l'app con il gate e il repository finto.
  ///
  /// Il gate dentro `builder`, non attorno a `MaterialApp`: `app.dart` lo mette
  /// li' e i test devono metterlo li', altrimenti proverebbero una posizione
  /// che l'app non usa.
  ///
  /// Le versioni installate sono sovrascritte perche' altrimenti arriverebbero
  /// da `PackageInfo`, che su una macchina senza app installata restituisce
  /// zero: ogni test passerebbe o fallirebbe perche' della macchina.
  Widget harness(
    FakeAppReleaseRepository repo, {
    Widget? home,
    InstallPermission? permission,
  }) {
    return ProviderScope(
      overrides: [
        appReleaseRepositoryProvider.overrideWithValue(repo),
        installedVersionCodeProvider.overrideWith((ref) async => 1),
        installedVersionNameProvider.overrideWith((ref) async => '1.0.0'),
        installPermissionProvider.overrideWithValue(
          permission ?? FakeInstallPermission(),
        ),
      ],
      child: MaterialApp(
        home: home ?? const Scaffold(body: Text('contenuto')),
        builder: (context, child) => UpdateGate(
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }

  group('confronto delle versioni', () {
    test('una versione maggiore viene proposta', () {
      final r = releaseFixture(versionCode: 2, versionName: '1.0.1');
      expect(r.isNewerThan(1), isTrue);
    });

    test('la stessa versione non viene proposta', () {
      final r = releaseFixture(versionCode: 1);
      expect(r.isNewerThan(1), isFalse);
    });

    test('una versione minore non viene proposta', () {
      final r = releaseFixture(versionCode: 1);
      expect(r.isNewerThan(2), isFalse);
    });

    test('il confronto e\' numerico, non lessicale', () {
      // Il caso che giustifica il version_code: "1.0.10" come testo viene
      // prima di "1.0.9", quindi un confronto di stringhe sbaglierebbe qui e
      // l'aggiornamento non arriverebbe mai.
      final r = releaseFixture(versionCode: 110, versionName: '1.0.10');
      expect(r.isNewerThan(109), isTrue);
    });
  });

  group('lettura di una riga', () {
    test('legge tutti i campi', () {
      final parsed = AppRelease.parse({
        'version_code': 7,
        'version_name': '1.2.0',
        'apk_url': 'https://esempio.invalid/a.apk',
        'sha256': 'a' * 64,
        'size_bytes': 12345,
        'notes': 'Corretti i crash.',
      });

      expect(parsed, isNotNull);
      expect(parsed!.versionCode, 7);
      expect(parsed.versionName, '1.2.0');
      expect(parsed.apkUrl, 'https://esempio.invalid/a.apk');
      expect(parsed.sha256, 'a' * 64);
      expect(parsed.sizeBytes, 12345);
      expect(parsed.notes, 'Corretti i crash.');
    });

    test('senza version_code la riga viene scartata', () {
      expect(
        AppRelease.parse({'version_name': '1.0.0', 'apk_url': 'https://x/a.apk'}),
        isNull,
      );
    });

    test('senza apk_url la riga viene scartata', () {
      // Un rilascio senza file scaricabile e' l'unico caso in cui accettare la
      // riga farebbe Crashare l'app invece di saltare il controllo.
      expect(
        AppRelease.parse({'version_code': 2, 'version_name': '1.0.1'}),
        isNull,
      );
    });

    test('sha256 e notes mancanti non rendono la riga invalida', () {
      final parsed = AppRelease.parse({
        'version_code': 2,
        'version_name': '1.0.1',
        'apk_url': 'https://esempio.invalid/a.apk',
      });

      expect(parsed, isNotNull);
      expect(parsed!.sha256, isNull);
      expect(parsed.notes, isEmpty);
    });

    test('notes nulle diventano stringa vuota', () {
      final parsed = AppRelease.parse({
        'version_code': 2,
        'version_name': '1.0.1',
        'apk_url': 'https://esempio.invalid/a.apk',
        'notes': null,
      });

      expect(parsed!.notes, isEmpty);
    });
  });

  group('controllo all\'avvio', () {
    testWidgets('senza rilasci resta su tutto aggiornato', (tester) async {
      final repo = FakeAppReleaseRepository();
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      // Lo stato si legge dal container, non dal contesto: quando non c'e' un
      // rilascio il gate restituisce il figlio com'e', quindi nel albero non
      // c'e' piu' nessun widget da cui prendere un `WidgetRef`.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(UpdateGate)),
      );
      final state = container.read(appUpdateProvider);

      expect(state.stage, UpdateStage.upToDate);
      expect(state.isBlocking, isFalse);
      expect(find.text('Aggiornamento disponibile'), findsNothing);
    });

    testWidgets('con un rilascio nuovo compare l\'avviso', (tester) async {
      final repo = FakeAppReleaseRepository(
        release: releaseFixture(versionCode: 2, versionName: '1.0.1'),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.text('Aggiornamento disponibile'), findsOneWidget);
      expect(find.text('Aggiorna'), findsOneWidget);
      expect(find.textContaining('1.0.0'), findsWidgets);
      expect(find.textContaining('1.0.1'), findsWidgets);
    });

    testWidgets('l\'avviso non si puo\' chiudere', (tester) async {
      final repo = FakeAppReleaseRepository(
        release: releaseFixture(versionCode: 2),
      );
      // Un pulsante sotto l'avviso, che cambia testo solo se riceve il tocco.
      await tester.pumpWidget(harness(
        repo,
        home: const Scaffold(
          body: Center(
            child: _TapProbe(label: 'premuti'),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Un solo bottone: niente "Annulla", niente "Piu' tardi". E il gesture
      // "indietro" non chiude niente, perche' la coperta non e' una rotta.
      expect(find.text('Annulla'), findsNothing);
      expect(find.text('Più tardi'), findsNothing);
      expect(find.text('Aggiorna'), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);

      // Il contenuto resta montato ma non e' piu' toccabile: senza il
      // ModalBarrier si potrebbe usare l'app vecchia con l'avviso davanti.
      // Non basta contare i barrier (il Navigator ne ha uno suo): conta che il
      // tocco non arrivi.
      expect(find.text('contenuto'), findsNothing);
      expect(find.text('premuti 0'), findsOneWidget);
      // `warnIfMissed: false` perche' e' proprio quello che si vuole: il tocco
      // manca il pulsante perche' la coperta e' sopra. Il framework lo segnala
      // come sospetto, ma qui e' il risultato atteso.
      await tester.tap(
        find.text('premuti 0'),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('premuti 0'), findsOneWidget);
      expect(find.text('Aggiornamento disponibile'), findsOneWidget);
    });

    testWidgets('un rilascio vecchio non blocca l\'app', (tester) async {
      final repo = FakeAppReleaseRepository(
        release: releaseFixture(versionCode: 1, versionName: '0.9.0'),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.text('Aggiornamento disponibile'), findsNothing);
      expect(find.text('contenuto'), findsOneWidget);
    });

    testWidgets('un controllo fallito non blocca l\'app', (tester) async {
      // Il caso importante: senza rete l'app deve partire come se nulla fosse,
      // non mostrare un avviso su un errore che all'utente non serve.
      final repo = FakeAppReleaseRepository(
        failWith: const AppReleaseFailure('niente rete', isRetryable: true),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.text('Aggiornamento disponibile'), findsNothing);
      expect(find.text('contenuto'), findsOneWidget);
    });

    testWidgets('il controllo parte una volta sola', (tester) async {
      final repo = FakeAppReleaseRepository();
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      // Ricostruire l'app non deve far partire un'altra richiesta: il gate puo'
      // essere ricostruito da un cambio di sessione o da una rotta.
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(repo.calls, 1);
    });
  });

  group('schermata di aggiornamento', () {
    testWidgets('mostra le note del rilascio quando ci sono', (tester) async {
      final repo = FakeAppReleaseRepository(
        release: releaseFixture(
          versionCode: 2,
          notes: 'Rivista la classifica.\nCorretti i crash.',
        ),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.text('Rivista la classifica.\nCorretti i crash.'), findsOneWidget);
    });

    testWidgets('senza note non lascia un vuoto', (tester) async {
      final repo = FakeAppReleaseRepository(release: releaseFixture());
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.text('Aggiorna'), findsOneWidget);
    });

    testWidgets('dopo un errore il bottone dice Riprova', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: UpdateDialog(
                state: UpdateState(
                  stage: UpdateStage.failed,
                  message: 'Download interrotto.',
                ),
                onInstall: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('Riprova'), findsOneWidget);
      expect(find.text('Download interrotto.'), findsOneWidget);
    });

    testWidgets('durante il download il bottone sparisce', (tester) async {
      // Un bottone premibile che non fa niente fa sembrare l'app rotta.
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: UpdateDialog(
                state: const UpdateState(
                  stage: UpdateStage.downloading,
                  progress: 0.42,
                ),
                onInstall: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('Aggiorna'), findsNothing);
      expect(find.text('42%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('durante l\'installazione spiega cosa sta succedendo',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: UpdateDialog(
                state: const UpdateState(stage: UpdateStage.installing),
                onInstall: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('installando'), findsOneWidget);
      expect(find.text('Aggiorna'), findsNothing);
    });

    test('uno stato non bloccante non mostra la schermata', () {
      for (final stage in [
        UpdateStage.idle,
        UpdateStage.checking,
        UpdateStage.upToDate,
      ]) {
        expect(UpdateState(stage: stage).isBlocking, isFalse,
            reason: '$stage non deve bloccare');
      }
    });

    test('uno stato bloccante la mostra', () {
      for (final stage in [
        UpdateStage.available,
        UpdateStage.downloading,
        UpdateStage.installing,
        UpdateStage.failed,
      ]) {
        expect(UpdateState(stage: stage).isBlocking, isTrue,
            reason: '$stage deve bloccare');
      }
    });
  });

  group('permesso di installazione', () {
    test('senza permesso apre le impostazioni e resta ad attendere', () async {
      final permission = FakeInstallPermission(canInstall: false);
      final release = releaseFixture(versionCode: 2);

      final container = ProviderContainer(
        overrides: [
          appReleaseRepositoryProvider.overrideWithValue(
            FakeAppReleaseRepository(release: release),
          ),
          installedVersionCodeProvider.overrideWith((ref) async => 1),
          installedVersionNameProvider.overrideWith((ref) async => '1.0.0'),
          installPermissionProvider.overrideWithValue(permission),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(appUpdateProvider.notifier);
      await controller.check();
      expect(controller.state.stage, UpdateStage.available);

      await controller.install();

      expect(permission.openCalls, 1);
      expect(controller.state.stage, UpdateStage.available);
      expect(controller.state.needsInstallPermission, isTrue);
      expect(controller.state.release, same(release));
    });

    test('con permesso non apre le impostazioni e parte', () async {
      final permission = FakeInstallPermission(canInstall: true);
      final downloader = FakeApkDownloader();
      final container = ProviderContainer(
        overrides: [
          appReleaseRepositoryProvider.overrideWithValue(
            FakeAppReleaseRepository(release: releaseFixture(versionCode: 2)),
          ),
          installedVersionCodeProvider.overrideWith((ref) async => 1),
          installedVersionNameProvider.overrideWith((ref) async => '1.0.0'),
          installPermissionProvider.overrideWithValue(permission),
          apkDownloaderProvider.overrideWithValue(downloader),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(appUpdateProvider.notifier);
      await controller.check();
      await controller.install();

      expect(permission.openCalls, 0);
      expect(downloader.startCalls, 1);
      // Il download e' partito e completato senza toccare le impostazioni.
      expect(controller.state.stage, UpdateStage.downloading);
      expect(controller.state.needsInstallPermission, isFalse);
    });

    testWidgets('il dialogo spiega come abilitare il consenso', (tester) async {
      final permission = FakeInstallPermission(canInstall: false);
      final repo = FakeAppReleaseRepository(
        release: releaseFixture(versionCode: 2, versionName: '1.0.1'),
      );

      await tester.pumpWidget(harness(repo, permission: permission));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Aggiorna'));
      await tester.pumpAndSettle();

      expect(permission.openCalls, 1);
      expect(find.textContaining('Consenti installazione'), findsOneWidget);
      expect(find.text('Aggiorna'), findsOneWidget);
    });
  });

  group('fuori da Android l\'aggiornamento non parte', () {
    // Su iOS l'app non si aggiorna da sola: gli aggiornamenti li consegna
    // TestFlight/App Store. Il controllo non deve nemmeno interrogare la
    // tabella, altrimenti mostrerebbe un avviso che su iPhone non si puo'
    // soddisfare.
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('non interroga il repository e resta tutto aggiornato', () async {
      final repo = FakeAppReleaseRepository(
        release: releaseFixture(versionCode: 2, versionName: '1.0.1'),
      );

      final container = ProviderContainer(
        overrides: [
          appReleaseRepositoryProvider.overrideWithValue(repo),
          installedVersionCodeProvider.overrideWith((ref) async => 1),
          installedVersionNameProvider.overrideWith((ref) async => '1.0.0'),
          installPermissionProvider.overrideWithValue(FakeInstallPermission()),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(appUpdateProvider.notifier);
      await controller.check();

      expect(controller.state.stage, UpdateStage.upToDate);
      expect(controller.state.isBlocking, isFalse);
      expect(repo.calls, 0);
    });
  });

  group('manutenzione in background', () {
    test('fuori da Android non tocca WorkManager', () async {
      // Il test gira su desktop: il bootstrap deve uscire subito, senza
      // chiamare WorkManager (che qui non e' disponibile) e senza lanciare.
      // L'avviso di aggiornamento ormai arriva dal server, quindi sul
      // dispositivo resta solo la pulizia periodica degli APK.
      await bootstrapUpdateMaintenance();
    });
  });
}