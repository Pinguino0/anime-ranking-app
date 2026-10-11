# Comandi usati in AnimeRank

## Pubblicare un aggiornamento (consigliato)
```powershell
C:\Users\erent\Desktop\publish.ps1 -VersionName 0.1.5 -VersionCode 5 -Notes "Testo del dialogo"
```
Builda l'APK universale (arm32 + arm64) con i dart-define, carica la release
`v0.1.5` su `Pinguino0/animerank-releases` e alla fine stampa l'`INSERT` da
incollare nel SQL Editor di Supabase per `app_releases`. Deve girare su questa
stessa macchina: la firma APK e' quella di debug.

> Sempre `--target-platform android-arm,android-arm64`: il solo `android-arm64`
> produce un APK che sui telefoni a 32 bit (Galaxy A13 SM-A137F/A135F, ecc.) si
> installa ma si chiude subito, perche' manca `libflutter.so` in `armeabi-v7a`.

> **Da quando l'avviso di aggiornamento passa dal push**, l'`INSERT` in
> `app_releases` non e' piu' silenzioso: il trigger `app_releases_notify_update`
> manda una notifica a **tutti** gli utenti (su `notifications` → push FCM a chi
> ha le notifiche accese). Controlla `version_code` e le note prima di
> incollarlo.

## Build APK (con dart-define)
```powershell
cd 'C:\Users\erent\Desktop\anime ranking app\client'
flutter build apk --release --target-platform android-arm,android-arm64 --build-number 1 --build-name 0.0.1 --dart-define=SUPABASE_URL=https://sjbstiexythmapxmrfyp.supabase.co --dart-define=SUPABASE_ANON_KEY=sb_publishable_JqBGHeAUT068w6-Ex1L8OQ_f6OpCSMc
```
L'APK firmato sta in `build/app/outputs/flutter-apk/app-release.apk`.
`--build-number` e `--build-name` servono solo quando pubspec.yaml non e' stato
aggiornato: di solito si puo' togliere.

## Test e analyze
```powershell
cd 'C:\Users\erent\Desktop\anime ranking app\client'
flutter analyze
flutter test
```

## Git
```powershell
cd 'C:\Users\erent\Desktop\anime ranking app'
git status --short
git add -A
git commit -m "messaggio"
git log --oneline -5
```

## Migrazioni Supabase
```powershell
cd 'C:\Users\erent\Desktop\anime ranking app'
supabase migration list          # cosa manca
supabase db push                 # applica, chiede conferma
```

La CLI e' gia' autenticata: **non serve alcun token**.

Le tre chiavi di Supabase sono diverse, non scambiarle:

| Prefisso | Cos'e' | A cosa serve |
|---|---|---|
| `sb_publishable_` | chiave pubblica | `--dart-define=SUPABASE_ANON_KEY` |
| `sb_secret_` | secret key | **solo server. Non MAI nel client, in una chat o nella cronologia di PowerShell** |
| `sbp_` | personal access token | solo la Management API (`apply_migration.ps1`) |

Le prime due non sono JWT: se le metti come PAT, la Management API risponde
`JWT could not be decoded`. Il PAT si genera in Supabase -> profilo -> Access Tokens.

### Solo per lo script di una migrazione alla volta
```powershell
$env:SUPABASE_PAT = 'sbp_...'
cd 'C:\Users\erent\Desktop\anime ranking app\supabase\apply'
.\apply_migration.ps1 -File 027_episode_ratings.sql
.\check_privileges.ps1
.\check_drift.ps1
```

> Le migrazioni **non sono idempotenti**: rieseguirne una gia' applicata
> fallisce a meta'. Controllare prima con `supabase migration list`.
> Non usare `supabase db push --yes`: salta la conferma con l'elenco.

## Controllare il database
```powershell
cd 'C:\Users\erent\Desktop\anime ranking app'
supabase inspect db table-stats   # tabelle presenti e quante righe hanno
```

Funziona senza Docker e senza token. `supabase db dump` richiede Docker e qui non
e' disponibile.

## Edge Function jikan-proxy
```bash
cd 'C:\Users\erent\Desktop\anime ranking app\supabase\functions\jikan-proxy'
deno test -A index.test.ts
```
