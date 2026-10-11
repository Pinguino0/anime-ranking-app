# Consigli su "questione titoli" — prompt per Gemini / Claude

Copia e incolla tutto quanto segue (inclusa la parte di contesto) sia a Gemini sia a
Claude, una domanda alla volta oppure tutte insieme. Le risposte andranno salvate
sotto questo file per il confronto.

---

## Contesto (leggi prima)

Sto sviluppando un'app Flutter per il ranking di anime, rivolta a un pubblico
**italiano e inglese** (la UI è in italiano). Il backend è Supabase (PostgreSQL) e
la ricerca degli anime avviene con una RPC `anime_search` che fa LIKE su `pg_trgm`.

**Come è fatto oggi il catalogo** (tabella `public.anime`, 6.719 righe, popolata da
una Edge Function `jikan-proxy` che interroga AniList come fonte primaria e Kitsu
come fallback; il vecchio provider Jikan/MyAnimeList è stato dismesso):

- `title` — il titolo principale: **romaji** se la riga è arrivata di recente da
  AniList, **inglese** se è una riga vecchia dell'era Jikan/MAL. Quindi lo stesso
  franchise ha righe miste (`Shingeki no Kyojin` accanto a `Attack on Titan`).
- `japanese_title` — titolo in kanji (es. 進撃の巨人).
- `synonyms` (text[]) — gli alias che la fonte espone: per AniList sono
  `synonyms` + english + native + romaji; per Kitsu `titles.en/en_jp/ja_jp/ja`.
  **L'italiano compare solo in casi sporadici** quando un utente di AniList ha
  aggiunto a mano il titolo italiano tra i "synonyms".
- `search_blob` (colonna generata) = `title + japanese_title + synonyms +
  external_data->>'title'`; è su questo che `anime_search` fa il match.

Né AniList né Kitsu espongono un campo "titolo italiano" affidabile.

**Il problema dimostrato** (query reali sulla RPC):

| query | risultato |
|---|---|
| `attack on titan` | trova la serie (ordina però "Season 3 Part 2" prima della serie, a parità di similitudine) |
| `shingeki` | **non trova** la serie principale (la riga è intitolata "Attack on Titan") |
| `attacco dei giganti` | trova **1 solo special** oscuro, non la serie |

L'utente italiano che cerca "L'attacco dei giganti" non trova niente, e quando la
trova per altra via la UI gli mostra il romaji/inglese (`Shingeki no Kyojin` /
`Attack on Titan`) invece del titolo italiano.

---

## Domanda 1 — Da dove tiro fuori i titoli italiani?

AniList e Kitsu non li hanno. Le fonti che li hanno sono ad esempio TMDB (ha
`translations` per lingua, incluso l'italiano, e quasi tutti gli anime popolari ci
sono), AniDB, IMDB, o liste curate da community. Il problema è la **crosswalk**: il
catalogo locale è indicizzato per `external_id` che è l'id **AniList** (per Kitsu
l'id Kitsu). Senza una mappatura AniListid ↔ fonte italiana, non so a quale riga
associare il titolo italiano.

Mi servono consigli concreti:

1. Quale fonte (TMDB vs AniDB vs IMDB vs curata?) è la più adatta per titoli
   italiani di anime, copertura, licenza/ToS, affidabilità e facilità di query?
2. Come faccio la crosswalk in modo robusto (per id diretti, per titolo, con
   fuzzy match e quante conferme servono prima di accettarne uno)?
3. Meglio una colonna nuova `italian_title` sulla tabella `anime`, o estendere
   `synonyms[]`? Considera che `search_blob` è una colonna generata che oggi
   deriva da title+japanese_title+synonyms, quindi ogni scelta cambia anche la
   ricerca.
4. Come gestire i titoli completamente in kanji o in lingue senza traduzione
   (es. roba oscura che in Italia non è mai uscita)?

## Domanda 2 — Cosa mostro dove, e in che ordine di priorità?

Il `title` oggi viene mostrato ovunque (cercatore, dettaglio, watchlist,
classifica). Se aggiungo `italian_title`, qual è la strategia di fallback giusta
per una UI in italiano? Io pensavo: **italiano se presente, altrimenti inglese,
altrimenti romaji**. Vale anche una gerarchia diversa per la UI e per la ricerca
(mostrare X ma cercare su tutto)? E come risolvo il fatto che righe della stessa
serie hanno oggi una lingua diversa per il titolo principale, senza rifare il
catalogo a mano?

## Domanda 3 — Come sanare i 6.719 dati esistenti?

Le righe vecchie hanno `title` in inglese e `synonyms` con sola la coppia
inglese/kanji: anche solo il romaji manca su quelle righe. Serve:

- un piano per rifare un fetch che porti romaji+english+native+synonyms coerenti
  su tutte le righe (upsert sicuro, idempotente, senza duplicati visto che
  `external_id` non è piazzato in un UNIQUE? verifica tu), e
- un trigger o un ricalcolo di `search_blob` per le righe toccate.

Vincoli: la scrittura sul catalogo passa solo dalla Edge Function con
service_role (RLS: niente scritture dal client); Jikan/MAL è morto dal
1/10/2026 quindi niente crosswalk via MAL; l'app deve continuare a funzionare
mentre il catalogo si aggiorna in background.

---

## Formato di risposta che mi serve

Per ogni domanda:

1. **Opzione consigliata** con motivazione in 2-3 righe.
2. **Alternative** e quando preferirle.
3. Passi concreti di implementazione nell'ordine (schema → fetch → search → UI).
4. Rischi e costi (tempo di fetch, rate limit, falsi positivi nella crosswalk).

Non scrivere codice completo: basta design e pseudocodice.