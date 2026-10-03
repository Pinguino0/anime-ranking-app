# Stato del deploy — da dove riprendere

**Tutte le migrazioni applicate e verificate.** Le due query di verifica passano.

## Applicato sul DB remoto

| Migration | Contenuto | Stato |
|---|---|---|
| 001–018 | schema base | già applicate prima |
| 019 | catalogo anime, cache, filtri, status | applicata |
| 020 | inviti singoli `group_invites` | applicata |
| 021 | revoca EXECUTE da `anon` e `public` | applicata |
| 022 | `extensions.word_similarity` | applicata |
| 023 | rimozione di `strict` da `anime_search_blob` | applicata |
| 024 | revoca dei privilegi di tabella | applicata |

## Verificato

- `check_privileges.ps1` → **TUTTO OK**
- `check_drift.ps1` → **nessun drift** (il 64° nome è `rls_auto_enable`, escluso di proposito)
- `verify_019.sql` → **passata** (17 test)
- `verify_020.sql` → **passata**

`Success. No rows returned` è il risultato corretto: le `raise notice` non sono righe, quindi non
compaiono nel risultato. L'assenza di eccezioni vuol dire che tutti i test sono passati.

## Da fare ora

**Deploy della Edge Function: FATTO.** `jikan-proxy` è online su `sjbstiexythmapxmrfyp`.
Non servono secret: la funzione usa solo `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY`, che
Supabase inietta da solo. Jikan si chiama senza API key.

Bug risolto al primo deploy: `interface Retry-Options` non è un identificatore TypeScript
valido, il bundle falliva con `Expected '{', got '-'` su index.ts:75. Rinominato in
`RetryOptions`. Validato con esbuild, che fa lo stesso parsing del bundler lato Supabase:

```powershell
npx --yes esbuild@0.25.0 supabase/functions/jikan-proxy/index.ts --bundle --format=esm --platform=neutral "--external:*" --outfile=NUL
```

**1. Ricostruire l'APK** (la copia attuale è precedente alla 020/021/024)

```powershell
cd "C:\Users\erent\Desktop\anime ranking app\client"
C:\src\flutter\bin\flutter.bat build apk --debug
```

**2. Test Deno** (richiede Deno installato, non c'era)

```powershell
deno test -A supabase\functions\jikan-proxy\index.test.ts
```

## Opzionale — audit dei grant rimanenti

La `024` ha coperto le tabelle verificate nel codice client. Restano sei tabelle su cui il
client **legge** e che non sono state toccate, perché un GRANT potrebbe essere legittimo:
`tournaments`, `tournament_participants`, `tournament_matches`, `tournament_votes`,
`comments`, `notifications`. (`activities`, `achievements`, `user_achievements`,
`ranking_snapshots` non sono toccate dal client.)

Query per decidere:

```sql
select table_name,
       string_agg(distinct grantee, ', ' order by grantee) as ruoli,
       string_agg(distinct privilege_type, ', ' order by privilege_type) as privilegi
  from information_schema.role_table_grants
 where table_schema = 'public'
   and grantee in ('anon','authenticated')
 group by table_name
 order by table_name;
```

## Bug trovati e corretti (per non reintrodurli)

- `desc` dentro un `CASE` in `ORDER BY`: la direzione va **fuori** dall'espressione.
- `raise notice` sciolto in SQL puro: `raise` esiste solo dentro PL/pgSQL.
- `%` singolo in una `raise` senza argomenti va scritto `%%`.
- `when others then` senza `exception` prima: in PL/pgSQL serve `begin ... exception ... end`.
- `pg_trgm` sta in `extensions`: le chiamate vanno qualificate.
- `STRICT` su una funzione il cui corpo fa `coalesce`: i due si contraddicono, la coalesce
  diventa codice morto e la colonna generata resta NULL.
- `display_name` non è mai esistito su `profiles`: le colonne sono `id, username, avatar_url, bio`.
- `profiles.id` referenzia `auth.users(id)`: nei fixture di `verify_020` il vincolo va tolto
  dentro la transizione, il `rollback` lo ripristina.
- `has_function_privilege` su una firma inesistente **solleva un errore**, non restituisce false.
- Supabase concede per default `EXECUTE` sulle funzioni e `ALL` sulle tabelle dei nuovi ruoli:
  senza revoke espliciti, `anon` poteva eseguire 13 RPC e `authenticated` scrivere su
  `group_invites`. Sistemato da 021 e 024.

## Comandi ricorrenti

```powershell
$env:SUPABASE_PAT = 'sbp_...'
cd "C:\Users\erent\Desktop\anime ranking app"
.\supabase\apply\apply_migration.ps1 -File <file>.sql
.\supabase\apply\check_privileges.ps1
.\supabase\apply\check_drift.ps1
Get-Content -Raw .\supabase\apply\verify_020.sql | Set-Clipboard
```

I `verify_*.sql` finiscono con `rollback`: non lasciano nulla e si possono rilanciare.

## Cosa non è stato fatto

- Nessun **commit**: tutto il lavoro è non committato.
- Nessun **push**: nessun remoto Git configurato.
- Test Deno non eseguiti (Deno assente).
- Client social non implementato: lo schema c'è (004), l'app no.
- Migliorie anime remote ancora da fare: infinite scroll oltre la prima pagina Jikan,
  bootstrap `recent` quando il catalogo è vuoto, gating rating/watchlist fino alla
  rilettura dell'id post-cache.