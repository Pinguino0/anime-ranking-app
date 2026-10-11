# Stato della sessione - 5 ottobre 2026

File di passaggio per chi apre una chat nuova. `RESUME.md` ha lo stato
dell'unico redesign; questo ha **quello che è successo dopo**, cioè blocco
episodi, DB, resolver e app.

Vedi `RESUME.md` per design system e backlog UI. Non si ripete niente di già scritto lì.

## In una riga

Resolver **Option A** implementato (canonical_url + provider + Edge Function `resolve-source`), player riscritto con `media_kit` (header HTTP + fallback automatico), `flutter analyze` pulito, `flutter test` **506/506**.

## 1. Risoluzione fonti (Option A)

Completato oggi: canonical URL persistito, provider risolvibili, URL effimeri con header, nessun URL risolto scritto sul DB.

### DB (migrato)
| File | Note |
|---|---|
| `supabase/migrations/028_episode_source_resolution.sql` | Crea `providers`, aggiunge `episode_sources.canonical_url`, `provider_id`, rende `source_url` nullable, indice per risoluzione, inserisce provider `mock`, aggiorna `episode_sources_list` (restituisce `canonical_url`, `provider_slug`, `provider_label`), ordina per qualità/priority/created_at, RLS/GRANT per `providers`. | 

Verificato su remoto: tabella `providers`, row `mock`, RPC aggiornata.

### Edge Function `resolve-source`
| File | Note |
|---|---|
| `supabase/functions/resolve-source/index.ts` | Handler con CORS, health check pubblico, verifica Authorization, lettura fonte+provider (service role), dispatch via `providers.resolve_endpoint`, validazioni `isUuid/isHttpUrl`, errori espliciti. Esporta funzioni per test. |
| `supabase/functions/resolve-source/types.ts` | Contratto `SourceRow`, `ProviderRow`, `ResolveRequest`, `ResolveResult`, `VideoResolver`. |
| `supabase/functions/resolve-source/providers/mock.ts` | Adapter mock. Firma HMAC con nonce `jti` (token unico per richiesta, evita link stabili). TTL 300s. Header: `Referer`, `Origin`, `Authorization`, `X-AnimeRank-Provider`, `X-AnimeRank-Source`, `User-Agent`, `Accept`. Sceglie MP4/HLS in base a `sourceType`. URL esempio: `https://test-streams.mux.dev/...` |
| `supabase/functions/resolve-source/index.test.ts` | **17/17** passati (`deno test --no-check --allow-env`). Copre validazioni, token univoco, rotte/CORS/health/auth. |

Principi applicati: il client invia **solo `source_id`**, la EF legge canonical_url/provider dal DB (no proxy aperto), risoluzione **al playback** (non persistita), errore distinto (adapter mancante 501, fonte spenta/non trovata 404, non risolvibile 422).

### Seed
| File | Note |
|---|---|
| `supabase/apply/seed_episode_sources.sql` | Aggiornato con documentazione per fonti dirette (`source_url`) vs canoniche (`canonical_url`+`provider_id`), esempi con provider `mock`, query di verifica. |

## 2. Flutter - episodi + player

### Dominio/Data
| File | Note |
|---|---|
| `client/lib/features/episodes/domain/episode.dart` | `EpisodeSource`: aggiunti `canonicalUrl`, `providerSlug/Label`, `needsResolution`, `playbackAddress`. Nuovo `ResolvedSource` (headers, expiresAt, `isFresh` con margine 1m). Parser aggiornato a RPC nuova. |
| `client/lib/features/episodes/data/episodes_repository.dart` | Aggiunto `resolveSource(String sourceId)` via `supabase.functions.invoke(AppConfig.sourceResolverFunction, body: {...})`. Traduzione `FunctionException` (status 0/4xx/5xx), messaggi server passati quando utili. |
| `client/lib/core/env/app_config.dart` | `sourceResolverFunction = 'resolve-source'`. |
| `client/test/helpers/fake_episodes.dart` | `failResolutionWith`, `resolvedById`, `resolutionCalls`, `resolvedFor/expiredFor`, fixture aggiornate. |

### UI/Player/Bootstrap
| File | Note |
|---|---|
| `client/lib/features/episodes/presentation/widgets/episode_player.dart` | Riscritto su `media_kit` (Player + VideoController). Risoluzione lazy: fonti dirette aperte subito, canoniche risolte al momento con timeout 8s. Fallback automatico a fonte successiva su timeout/errore/link scaduto (`isFresh`), retry forza nuova risoluzione (token nuovo), header HTTP su `Media(..., httpHeaders: ...)`, gestione flussi `position/playing`, cleanup sicuro (dispose con timeout), messaggi non mostrano dettagli interni. |
| `client/lib/features/episodes/presentation/screens/episode_screen.dart` | Passa `resolver: ref.read(episodesRepositoryProvider).resolveSource`. |
| `client/lib/main.dart` | `MediaKit.ensureInitialized()` all'avvio. |

## 3. Test + qualità

- `flutter analyze`: **No issues found!**
- `flutter test`: **506/506** passati (inclusi 27 episodi + nuovi widget test per risoluzione: fonte diretta vs canonica, senza resolver passa a successiva, timeout non blocca, link scaduto va rifatto, errore non finisce a schermo, chiamate per apertura).

## 4. Stato build/run

Ambiente: Flutter 3.47.5, Dart 3.13.4, Deno 2.9.6. `flutter pub get` ok (media_kit aggiunto, video_player rimosso). App compilabile, test verdi.

## 5. Cosa resta aperto

1. **Deploy Edge Function `resolve-source`** su progetto Supabase (JWT true). Verifica health/resolve con token valido.
2. **Verifica in-app**: aggiungere fonte canonica mock per episodio di prova, aprire player, verificare fallback e scadenza.
3. **Fonti reali**: quando arriveranno, basta aggiungere adapter in `resolve-source/providers/<provider>.ts`, registrarne `resolve_endpoint` in `RESOLVERS`, riga in `providers`. Schema/player invariati.

## 6. Come riprendere

```powershell
cd 'C:\Users\erent\Desktop\anime ranking app\client'
flutter analyze
flutter test

cd 'C:\Users\erent\Desktop\anime ranking app\supabase\functions\resolve-source'
deno test --no-check --allow-env index.test.ts
```