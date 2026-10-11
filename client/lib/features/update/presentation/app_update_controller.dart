import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/app_release_repository.dart';
import '../data/install_permission.dart';
import '../data/ota_downloader.dart';
import '../domain/app_release.dart';

/// In che punto si trova il controllo aggiornamenti.
///
/// La catena e' lineare e non ha ritorni: controllo, avviso, download,
/// installazione. Ogni stadio sa qual e' il successivo e nessuno puo'
/// saltare al mezzo.
enum UpdateStage {
  /// Nessun controllo ancora fatto.
  idle,

  /// Controllo in corso. L'app e' gia' utilizzabile: e' uno stato che non
  /// blocca niente.
  checking,

  /// Nessuna versione piu' recente. Lo stato normale di quasi sempre.
  upToDate,

  /// C'e' una versione piu' recente e l'app aspetta che l'utente prema.
  ///
  /// Il pulsante e' "Aggiorna" e non "Piu' tardi": e' bloccante per scelta,
  /// cosi' nessuno resta indietro su uno schema del database diverso.
  available,

  /// APK in arrivo, con la percentuale in [UpdateState.progress].
  downloading,

  /// Download finito, installatore di Android aperto o in apertura.
  installing,

  /// Il download o l'installazione e' falliti. [UpdateState.message] spiega
  /// perche', e da li si riprova.
  failed,
}

/// Stato completo del controllo aggiornamenti.
@immutable
class UpdateState {
  const UpdateState({
    this.stage = UpdateStage.idle,
    this.release,
    this.installedVersionName,
    this.progress = 0,
    this.message,
    this.needsInstallPermission = false,
  });

  final UpdateStage stage;

  /// Il rilascio da cui scaricare, presente da [UpdateStage.available] in poi.
  final AppRelease? release;

  /// Versione gia' installata, per la riga "da 1.0.1 a 1.0.2".
  final String? installedVersionName;

  /// 0.0 - 1.0 durante [UpdateStage.downloading].
  final double progress;

  /// Perche' e' fallito, quando [stage] e' [UpdateStage.failed].
  final String? message;

  /// true quando l'utente ha premuto Aggiorna ma Android non puo' installare:
  /// l'app ha aperto le impostazioni e aspetta che l'utente abiliti il
  /// consenso e ripeta. Vero solo insieme a [UpdateStage.available].
  final bool needsInstallPermission;

  /// true quando c'e' qualcosa da mostrare a schermo intero.
  ///
  /// La schermata compare solo per `available`, `downloading`, `installing` e
  /// `failed`: durante `idle`, `checking` e `upToDate` non c'e' niente da
  /// dire e l'app si usa normalmente.
  bool get isBlocking =>
      stage == UpdateStage.available ||
      stage == UpdateStage.downloading ||
      stage == UpdateStage.installing ||
      stage == UpdateStage.failed;
}

/// true dove l'auto-aggiornamento ha senso.
///
/// Solo Android: qui l'app scarica un APK e apre l'installatore di sistema. Su
/// iOS Apple non permette a un'app di scaricare e installare un binario per
/// conto proprio, quindi gli aggiornamenti li consegna TestFlight/App Store e
/// questo flusso non va mai avviato. Anche sul desktop non c'e' un installatore
/// da lanciare e sul web non esiste il filesystem: altrove il gate resta
/// "tutto aggiornato" e non blocca mai l'app.
///
/// Si usa [defaultTargetPlatform] e non `dart:io Platform` perche' nei test
/// vale `TargetPlatform.android`, cosi' la logica resta testabile e non
/// dipende dal sistema che esegue i test.
bool get _otaUpdatesSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Il numero di versione dell'app installata.
///
/// Va letto una volta sola e tenuto: e' l'unico confronto possibile con la
/// tabella, e ricaricarlo a ogni build cambierebbe il riferimento senza
/// motivo. Il `Future` fuori provider evita che chi lo usa debba ricordarsi di
/// aspettare.
final installedVersionCodeProvider = FutureProvider<int>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return int.tryParse(info.buildNumber) ?? 0;
});

/// Il nome della versione installata, per la riga nella schermata.
final installedVersionNameProvider = FutureProvider<String?>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.version.trim().isEmpty ? null : info.version.trim();
});

/// Controlla e scarica gli aggiornamenti.
///
/// Non e' un [AsyncNotifier] perche' i suoi stadi sono piu' di due e l'errore
/// non e' uno stato finale ma uno stadio a se' con dentro un messaggio
/// mostrato e un bottone per riprovare.
class AppUpdateController extends Notifier<UpdateState> {
  @override
  UpdateState build() {
    // Fuori da Android non si controlla niente: gli aggiornamenti li gestisce
    // la piattaforma (su iOS TestFlight/App Store). Lo stato parte gia'
    // "tutto aggiornato", cosi' il gate non mostra mai l'avviso e l'app si apre
    // normalmente su iPhone.
    if (!_otaUpdatesSupported) {
      return const UpdateState(stage: UpdateStage.upToDate);
    }

    // Il controllo parte da solo appena l'app si avvia, e una volta sola: il
    // gate puo' ricostruirsi senza che ogni ricostruzione faccia una richiesta.
    Future.microtask(check);
    ref.onDispose(() => _cancelDownload());
    return const UpdateState();
  }

  /// Controlla se c'e' una versione piu' recente.
  ///
  /// Non fallisce mai: se il controllo non riesce, l'app deve partire lo
  /// stesso. Un errore qui mostrerebbe un avviso "non riesco a controllare gli
  /// aggiornamenti" sopra un'app che funziona benissimo, che e' rumore.
  Future<void> check() async {
    if (!_otaUpdatesSupported) return;
    if (state.stage == UpdateStage.downloading ||
        state.stage == UpdateStage.installing) {
      return;
    }

    state = const UpdateState(stage: UpdateStage.checking);

    try {
      final current = await ref.read(installedVersionCodeProvider.future);
      final release =
          await ref.read(appReleaseRepositoryProvider).latest();

      final installedName = await ref
          .read(installedVersionNameProvider.future)
          .catchError((_) => null);

      if (release == null || !release.isNewerThan(current)) {
        state = UpdateState(
          stage: UpdateStage.upToDate,
          installedVersionName: installedName,
        );
        return;
      }

      state = UpdateState(
        stage: UpdateStage.available,
        release: release,
        installedVersionName: installedName,
      );
    } catch (_) {
      // Fallito il controllo: nessun avviso, si torna come se fosse tutto
      // regolare. La prossima apertura riprova.
      state = const UpdateState(stage: UpdateStage.upToDate);
    }
  }

  /// Scarica l'APK e apre l'installatore.
  Future<void> install() async {
    final release = state.release;
    if (release == null) return;

    // Prima di scaricare 60 MB controlla che Android possa installare davvero.
    //
    // Il caso che giustifica il controllo e' il tipico: chi installa l'APK dal
    // browser da' il consenso "app sconosciute" al browser, non alla app, e
    // senza consenso il plugin scarica, lancia l'installatore e Android lo
    // ignora in silenzio. Meglio farsi aprire le impostazioni adesso, prima del
    // download, e non al termine, quando l'utente ha gia' aspettato.
    final permission = ref.read(installPermissionProvider);
    final canInstall = await permission.canInstallFromSource();
    if (!canInstall) {
      await permission.openFromSettings();
      state = UpdateState(
        stage: UpdateStage.available,
        release: release,
        installedVersionName: state.installedVersionName,
        needsInstallPermission: true,
      );
      return;
    }
    state = UpdateState(
      stage: UpdateStage.downloading,
      release: release,
      installedVersionName: state.installedVersionName,
    );

    final download = ref.read(apkDownloaderProvider).start(
      release.apkUrl,
      // Il nome porta il version_code perche' nella cartella di download si
      // distingue da solo quale versione sia, e un file lasciato indietro da
      // un download fallito non viene sovrascritto da un altro tentativo.
      destinationFilename: 'animerank-${release.versionCode}.apk',
      sha256checksum: release.sha256,
    );
    _activeDownload = download;

    try {
      await for (final event in download.events) {
        switch (event.status) {
          case OtaStatus.DOWNLOADING:
            final parsed = double.tryParse(event.value ?? '');
            state = UpdateState(
              stage: UpdateStage.downloading,
              release: release,
              installedVersionName: state.installedVersionName,
              // Il plugin manda solo interi percentuali: non far sembrare che
              // si sappia di piu' di quanto si sappia davvero.
              progress: parsed == null ? 0 : (parsed / 100).clamp(0.0, 1.0),
            );

          case OtaStatus.INSTALLING:
          case OtaStatus.INSTALLATION_DONE:
            state = UpdateState(
              stage: UpdateStage.installing,
              release: release,
              installedVersionName: state.installedVersionName,
              progress: 1,
            );

          case OtaStatus.CHECKSUM_ERROR:
            // Caso importante e non raro: il checksum dichiarato non
            // corrisponde al file scaricato. Significa file troncato o
            // APK diverso da quello annunciato, e in entrambi i casi
            // installare sarebbe peggio che non fare niente.
            _fail('Il file scaricato non corrisponde a quello annunciato.', release);

          case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
            _fail(
              'Android non permette di installare l\'aggiornamento. '
              'Serve autorizzare le installazioni da questa app.',
              release,
            );

          case OtaStatus.DOWNLOAD_ERROR:
            _fail('Download interrotto. Controlla la connessione.', release);

          case OtaStatus.ALREADY_RUNNING_ERROR:
            _fail('C\'e\' gia\' un aggiornamento in corso.', release);

          case OtaStatus.INSTALLATION_ERROR:
            _fail('Installazione non riuscita.', release);

          case OtaStatus.CANCELED:
            // Lo annulla solo l'utente chiudendo l'app o il download da
            // fuori. Torna a "c'e' da aggiornare" e non a errore: nessuno ha
            // sbagliato niente, il tentativo e' solo finito.
            state = UpdateState(
              stage: UpdateStage.available,
              release: release,
              installedVersionName: state.installedVersionName,
            );
            return;

          case OtaStatus.INTERNAL_ERROR:
            _fail(event.value ?? 'Aggiornamento non riuscito.', release);
        }
      }
    } catch (_) {
      _fail('Aggiornamento non riuscito.', release);
    } finally {
      _activeDownload = null;
    }
  }

  void _fail(String message, AppRelease? release) {
    state = UpdateState(
      stage: UpdateStage.failed,
      release: release,
      installedVersionName: state.installedVersionName,
      message: message,
    );
  }

  void _cancelDownload() async {
    await _activeDownload?.cancel();
    _activeDownload = null;
  }

  ApkDownload? _activeDownload;
}

final appUpdateProvider =
    NotifierProvider<AppUpdateController, UpdateState>(AppUpdateController.new);