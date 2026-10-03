-- ============================================================================
-- 019 - Catalogo anime: colonne mancanti, ricerca e stagione corrente
-- ============================================================================
-- Fino a qui la tabella anime aveva solo il minimo per votare: non sapeva
-- cos'era un film o una season. Queste colonne e queste RPC servono a far
-- diventare il catalogo qualcosa che si sfoglia, non solo un riferimento.
--
-- La scrittura resta alla Edge Function (service_role): qui si aggiungono
-- solo colonne e letture.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Tipo di opera
-- ---------------------------------------------------------------------------
-- I valori sono quelli di MyAnimeList, perche' e' la fonte da cui arriva tutto
-- e perche' rimappare in SQLite/Latin-1 romperebbe il confronto con l'esterno.
create type public.anime_type as enum (
  'TV',
  'Movie',
  'OVA',
  'ONA',
  'Special',
  'Music'
);

comment on type public.anime_type is
  'Formato dell opera, con i valori di MyAnimeList (TV, Movie, OVA, ONA, Special, Music).';

alter table public.anime
  add column media_type public.anime_type;

comment on column public.anime.media_type is
  'Formato dell opera (TV, Movie, OVA...). NULL se Jikan non l ha fornito.';

-- ---------------------------------------------------------------------------
-- Stagione e date
-- ---------------------------------------------------------------------------
-- `season` e derivabile dal mese di aired_from, ma Jikan lo manda gia'
-- separato e in forma normalizzata: tenerlo evita di ricostruirlo e di
-- sbagliare i mesi di confine (dicembre = winter, non autunno).
create type public.anime_season as enum (
  'winter', 'spring', 'summer', 'fall'
);

comment on type public.anime_season is
  'Stagione di prima messa in onda, minuscola come in Jikan.';

alter table public.anime
  add column season       public.anime_season,
  add column aired_from   date,
  add column aired_to     date;

comment on column public.anime.season is
  'Stagione della prima uscita. NULL per le opere senza data.';
comment on column public.anime.aired_from is
  'Data della prima puntata. Comune e il campo piu utile per ordinare "recenti".';
comment on column public.anime.aired_to is
  'Data dell ultima puntata. NULL se l opera e ancora in corso.';

-- ---------------------------------------------------------------------------
-- Voto e valutazione
-- ---------------------------------------------------------------------------
-- `score` e il voto medio MyAnimeList, non il voto degli utenti di AnimeRank:
-- sta nella stessa tabella perche' i due voti si confrontano nella schermata
-- di dettaglio. I voti degli utenti stanno in `ratings`, per gruppo.
alter table public.anime
  add column score       numeric(3,1),
  add column scored_by   bigint,
  add column popularity  bigint;

comment on column public.anime.score is
  'Voto medio MyAnimeList (0-10). Diverso dal voto degli utenti, che sta in ratings.';
comment on column public.anime.scored_by is
  'Quanti utenti hanno votato su MyAnimeList: distingue 8.4 da 12 utenti da 8.4 da 50.000.';
comment on column public.anime.popularity is
  'Posizione/popolarita su MyAnimeList: numero di membri che l hanno in lista.';

-- ---------------------------------------------------------------------------
-- Indici per i filtri e per lo sfoglio "recenti"
-- ---------------------------------------------------------------------------
-- I filtri sono tutti opzionali e quasi sempre nulli: gli indici parziali
-- evitano indicizzare le righe che il filtro non puo' comunque restituire.
create index anime_media_type_idx on public.anime (media_type)
  where media_type is not null;

create index anime_season_year_idx on public.anime (season, year desc)
  where season is not null;

-- "Solo gli anime in onda" e' una delle domande piu' frequenti, e l'indice su
-- `anime_aired_from_idx` non la copre: qui si filtra sullo stato, non sulle
-- date.
create index anime_status_idx on public.anime (status)
  where status is not null;

-- `aired_from desc nulls last` e l'ordinamento della home: se il primo buco
-- della tabella restasse NULL, l'indice non aiuterebbe proprio le righe che
-- si vogliono mostrare per prime.
create index anime_aired_from_idx on public.anime (aired_from desc nulls last)
  where aired_from is not null;

create index anime_score_idx on public.anime (score desc nulls last)
  where score is not null;

-- Per il carosello iniziale: i piu votati fra quelli recenti. Composto perche'
-- e la combinazione che si chiede davvero, non le due colonne sciolte.
create index anime_recent_popular_idx on public.anime (aired_from desc, popularity desc nulls last)
  where aired_from is not null;

-- Contesto: pg_trgm offre gia' gli indici GIN su title, japanese_title e
-- search_text (sinonimi). Qui si indicizza solo il raggruppamento per genere,
-- con l'operatore di contenimento che il filtro usa davvero.

-- ---------------------------------------------------------------------------
-- Colonna di ricerca unificata
-- ---------------------------------------------------------------------------
-- Titolo, titolo giapponese e sinonimi insieme in una colonna sola: una ricerca
-- per substring su tre colonne con OR e' il caso peggiore per l'indicizzazione,
-- perche' ogni ramo e' un indice diverso da mettere in OR e poi un merge.
-- Un solo campo GIN rende la ricerca un piano solo.
--
-- GENERATED perche' non puo' divergere dai campi di partenza, che l'Edge
-- Function aggiorna a ogni refresh.
create or replace function public.anime_search_blob(
  _title          text,
  _japanese_title text,
  _synonyms       text[],
  _original_title text
)
returns text
language sql
immutable
parallel safe
as $$
  -- coalesce perche' array_to_string(NULL) e' NULL e un NULL qui renderebbe
  -- l'intera concatenazione NULL.
  --
  -- NON dichiarare `strict`: la funzione riceve NULL di norma (titolo
  -- giapponese assente, external_data non valorizzato) e con strict tornava
  -- NULL prima di arrivare qui, rendendo questa coalesce codice morto e la
  -- colonna generata search_blob NULL. Tolto strict in 023.
  select coalesce(array_to_string(
    array_remove(
      array[
        _title,
        _japanese_title,
        _original_title,
        array_to_string(_synonyms, ' ')
      ],
      null
    ),
    ' '
  ), '');
$$;

alter table public.anime
  add column search_blob text
  generated always as (
    public.anime_search_blob(title, japanese_title, synonyms, external_data ->> 'title')
  ) stored;

-- L'indice GIN sul blob. `gin_trgm_ops` perche' il match e' di tipo
-- similarity/ILIKE, non di uguaglianza.
create index anime_search_blob_idx on public.anime using gin (search_blob extensions.gin_trgm_ops);

comment on column public.anime.search_blob is
  'Titolo + titolo giapponese + titolo originale + sinonimi, uniti per la ricerca. Generata: non modificarla.';

-- ---------------------------------------------------------------------------
-- Fuga dei caratteri speciali di LIKE
-- ---------------------------------------------------------------------------
-- `%` e `_` dentro la query non devono restare wildcards: un client che passa
-- '%' si prenderebbe tutto il catalogo ignorando i filtri, e i conteggi
-- "trovati N di M" mentirebbero. Non e' SQL injection (il valore resta un
-- parametro bindato) e non e' una fuga di dati (il catalogo e leggibile da
-- tutti gli autenticati per progetto): e' solo un filtro che non filtra.
--
-- escape del backslash per primo, altrimenti il backslash inserito per
-- proteggere i '%' successivi verrebbe lui stesso scappato. Con
-- standard_conforming_strings = on (il default da PostgreSQL 9.1) i
-- backslash sono gia' letterali in SQL, quindi non serve E''.
create or replace function public.escape_like(_text text)
returns text
language sql
immutable
parallel safe
strict
as $$
  select replace(replace(replace(_text, '\', '\\'), '%', '\%'), '_', '\_');
$$;

comment on function public.escape_like(text) is
  'Scappa i wildcards di LIKE. Va usato sui valori che l utente scrive dentro un pattern.';

-- ---------------------------------------------------------------------------
-- Similarita': quanto il risultato somiglia a quello scritto
-- ---------------------------------------------------------------------------
-- pg_trgm calcola anche un punteggio di somiglianza (0-1). Serve per due cose:
-- ordinare i risultanti per quanto somigliano alla ricerca invece che per
-- titolo, e distinguere "nessun risultato" da "risultato debole".
--
-- Immutabile non e' corretto qui: word_similarity dipende dai dati di confronto,
-- quindi non puo' finire in una colonna generata ne' in un indice.
create or replace function public.anime_title_similarity(_query text, _candidate text)
returns real
language sql
stable
parallel safe
strict
as $$
  select case
    when length(btrim(_query)) = 0 then 0::real
    else extensions.word_similarity(_query, _candidate)
  end;
$$;

comment on function public.anime_title_similarity(text, text) is
  'Somiglianza 0-1 fra la ricerca e un campo testo (parola intera, non sottostringa).';

-- ---------------------------------------------------------------------------
-- Filtro: tutti i criteri opzionali, NULL = non filtrare
-- ---------------------------------------------------------------------------
-- Una sola funzione per il filtro, richiamata sia dalla ricerca sia dalla
-- stagione corrente. Se i due percorsi avessero copie diverse del WHERE,
-- finirebbero per mostrare risultati incoerenti fra loro: qui la condizione e'
-- definita una volta sola.
--
-- `_genres` e un AND di contenimento: cercando ['Action','Fantasy'] si vuole
-- un anime che sia entrambe le cose, non uno qualsiasi dei due. E il comportamento
-- atteso da un filtro con piu' generi selezionati.
create or replace function public.anime_matches_filters(
  _row          public.anime,
  _genres       text[],
  _media_type   public.anime_type,
  _season       public.anime_season,
  _status       public.anime_status,
  _year_from    integer,
  _year_to      integer,
  _min_score    numeric,
  _min_episodes integer,
  _max_episodes integer
)
returns boolean
language sql
immutable
parallel safe
as $$
  select
    -- genre: ogni genere richiesto deve essere presente. cardinality(NULL) = 0
    -- e 0 < 0 e' falso, quindi il ramo NULL e' gia' "passa tutto".
    (select count(*)
       from unnest(coalesce(_genres, '{}'::text[])) g
      where _row.genres @> array[g])
    = cardinality(coalesce(_genres, '{}'::text[]))

    and (_media_type is null or _row.media_type = _media_type)
    -- Lo stato come filtro: "solo gli anime in corso" e' una domanda che
    -- l'utente fa spesso, e senza questo parametro non si puo' porla.
    and (_status is null or _row.status = _status)
    and (_season   is null or _row.season   = _season)
    and (_year_from is null or _row.year is not null and _row.year >= _year_from)
    and (_year_to   is null or _row.year is not null and _row.year <= _year_to)
    and (_min_score is null or _row.score is not null and _row.score >= _min_score)
    -- Episodi null su un film o su un ancora non aggiornato: un filtro
    -- "almeno 100 episodi" deve scartarli, non accettarli perche' il confronto
    -- con NULL e' NULL. E il comportamento che l utente si aspetta.
    and (_min_episodes is null or _row.episodes is not null and _row.episodes >= _min_episodes)
    and (_max_episodes is null or _row.episodes is not null and _row.episodes <= _max_episodes);
$$;

comment on function public.anime_matches_filters(public.anime, text[], public.anime_type,
  public.anime_season, public.anime_status, integer, integer, numeric, integer, integer) is
  'Verifica tutti i filtri opzionali su una riga anime. NULL = criterio non applicato.';

-- ---------------------------------------------------------------------------
-- Ricerca paginata nel catalogo locale
-- ---------------------------------------------------------------------------
-- E' la via veloce: nessuna chiamata a Jikan, opera solo su cio' che e' gia'
-- in cache. E' anche il fallback quando la Edge Function non risponde.
--
-- SECURITY DEFINER perche' il filtro usa una funzione che accetta un tipo
-- composite di riga: senza, la policy RLS entrerebbe nel mezzo del confronto.
-- `stable` perche' non scrive. search_path fisso come in tutte le altre.
create or replace function public.anime_search(
  _query         text default null,
  _genres        text[] default null,
  _media_type    public.anime_type default null,
  _season        public.anime_season default null,
  _status        public.anime_status default null,
  _year_from     integer default null,
  _year_to       integer default null,
  _min_score     numeric default null,
  _min_episodes  integer default null,
  _max_episodes  integer default null,
  _sort          text default 'relevance',
  _limit         integer default 24,
  _offset        integer default 0
)
returns table (
  id               uuid,
  external_id      text,
  title            text,
  japanese_title   text,
  synopsis         text,
  image_url        text,
  episodes         integer,
  status           public.anime_status,
  year             integer,
  genres           text[],
  media_type       public.anime_type,
  season           public.anime_season,
  aired_from       date,
  aired_to         date,
  score            numeric,
  scored_by        bigint,
  popularity       bigint,
  duration         text,
  studio           text,
  similarity       real,
  in_catalog       boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with prepared as (
    -- Una sola volta, e non per riga: il trigram della query non cambia.
    -- La query viene scappata qui, una volta sola per tutta la query: se
    -- l'escaping fosse dentro il WHERE, il planner lo rivaluterebbe per
    -- riga e il piano peggiorerebbe proprio quando il catalogo e' grande.
    select
      nullif(btrim(coalesce(_query, '')), '') as q,
      -- Pattern gia' pronto: i wildcard del testo sono diventati letterali.
      '%' || public.escape_like(btrim(coalesce(_query, ''))) || '%' as pattern,
      greatest(coalesce(_offset, 0), 0)        as off,
      least(greatest(coalesce(_limit, 24), 1), 60) as lim
  ),
  matched as (
    select
      a.*,
      -- Con query vuota la similitudine e' 0 per tutti: l'ordinamento la
      -- ignorerebbe comunque, ma il valore va comunque restituito coerente
      -- invece che NULL, cosi' il client non deve distinguere i due casi.
      public.anime_title_similarity(p.q, a.search_blob) as similarity
    from public.anime a, prepared p
    where
      -- Testo: match di sottostringa, non di parola intera. 'one' deve trovare
      -- 'One Piece', 'Attack on Titan'. Il fallback `or title = p.q` copre il
      -- caso in cui la query e piu' corta del trigramma minimo di pg_trgm:
      -- con 1-2 caratteri l'indice trigram non produce nulla e senza questo
      -- ramo la ricerca sembrerebbe vuota.
      (p.q is null
       or a.search_blob ilike p.pattern escape '\'
       or a.title = p.q)
      and public.anime_matches_filters(
        a, _genres, _media_type, _season, _status,
        _year_from, _year_to, _min_score,
        _min_episodes, _max_episodes
      )
  )
  select
    m.id,
    m.external_id,
    m.title,
    m.japanese_title,
    m.synopsis,
    m.image_url,
    m.episodes,
    m.status,
    m.year,
    m.genres,
    m.media_type,
    m.season,
    m.aired_from,
    m.aired_to,
    m.score,
    m.scored_by,
    m.popularity,
    m.duration,
    m.studio,
    m.similarity,
    -- Dice al client se il risultato arriva dalla cache o no: e' quello che
    -- permette a una schermata vuota di spiegare "catalogo non ancora
    -- popolato" invece di "nessun risultato".
    true as in_catalog
  from matched m, prepared p
  order by
    -- Ordinamento per relevance solo con una query vera: altrimenti il primo
    -- risultato sarebbe sempre l'omonimo esatto e il resto sparirebbe sotto.
    --
    -- `desc` sta FUORI dal case e non dentro il `then`. Dentro un espressione
    -- `desc` non e valido: la direzione di ordinamento fa parte dell ORDER BY,
    -- non dell espressione calcolata. Scritto dentro, PostgreSQL rispondeva
    -- "syntax error at or near desc" e la 019 non si applicava affatto.
    case
      when p.q is not null then m.similarity
      else 0
    end desc,
    case
      when p.q is not null then m.score
      else 0
    end desc nulls last,
    -- Tie-break: piu' recenti prima, poi id per stabilita'. Senza l'id due
    -- pagine diverse possono restituire lo stesso risultato due volte e
    -- l'infinite scroll mostrerebbe duplicati.
    m.aired_from desc nulls last,
    m.popularity  desc nulls last,
    m.id
  limit (select p.lim from prepared p)
  offset (select p.off from prepared p);
$$;

comment on function public.anime_search(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer, text, integer, integer) is
  'Ricerca paginata nel catalogo anime locale. Tutti i filtri sono opzionali (NULL = disattivato).';

-- ---------------------------------------------------------------------------
-- Anime della stagione corrente
-- ---------------------------------------------------------------------------
-- "Gli ultimi usciti" e' una domanda sul mese di prima messa in onda, non
-- sull'anno: un anime del 2023 non e' fra le novita' di oggi. Per questo la
-- finestra e ancorata a date relative, non a una stagione scritta a mano.
--
-- La stagione corrente si calcola da now():dicembre/gen/feb = winter, e il
-- cambio di stagione e dentro la stessa query, quindi fra il 31 marzo e il 1
-- aprile la lista cambia da sola senza nessun intervento.
create or replace function public.current_season(_at date default current_date)
returns public.anime_season
language sql
immutable
parallel safe
strict
as $$
  select case
    when extract(month from _at) in (12, 1, 2) then 'winter'::public.anime_season
    when extract(month from _at) in (3, 4, 5)  then 'spring'::public.anime_season
    when extract(month from _at) in (6, 7, 8)  then 'summer'::public.anime_season
    else 'fall'::public.anime_season
  end;
$$;

comment on function public.current_season(date) is
  'Stagione corrente come codice Jikan. Le stagioni sono a cavallo d anno: winter = dic-gen-feb.';

-- Anche gli anime che hanno cominciato prima e continuano ora: sono "in corso"
-- adesso e l utente che apre l'app li vuole vedere. Percio' la finestra parte
-- da prima di inizio stagione, non dal primo giorno.
create or replace function public.anime_current_season(
  _limit    integer default 24,
  _offset   integer default 0,
  _genre    text default null
)
returns table (
  id               uuid,
  external_id      text,
  title            text,
  japanese_title   text,
  synopsis         text,
  image_url        text,
  episodes         integer,
  status           public.anime_status,
  year             integer,
  genres           text[],
  media_type       public.anime_type,
  season           public.anime_season,
  aired_from       date,
  aired_to         date,
  score            numeric,
  scored_by        bigint,
  popularity       bigint,
  duration         text,
  studio           text,
  similarity       real,
  in_catalog       boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id, a.external_id, a.title, a.japanese_title, a.synopsis, a.image_url,
    a.episodes, a.status, a.year, a.genres, a.media_type, a.season,
    a.aired_from, a.aired_to, a.score, a.scored_by, a.popularity,
    a.duration, a.studio,
    0::real as similarity,
    true as in_catalog
  from public.anime a
  where
    -- Le tre finestre sono raggruppate in un solo blocco perche' AND binds
    -- piu' forte di OR: senza le parentesi, `and (_genre is null ...)` si
    -- legherebbe solo all'ultimo ramo e il filtro genere sarebbe ignorato
    -- per gli anime recenti. E un bug silenzioso: la lista sembra funzionare
    -- e restituisce solo opere che l'utente non ha chiesto.
    (
      -- Ultimi usciti: cominciati negli ultimi 90 giorni.
      (a.aired_from is not null
       and a.aired_from >= current_date - 90)
      -- Gli ONA e gli Special escono a singhiozzo tutto l'anno: con la data di
      -- prima puntata risalgono subito fuori dai 90 giorni, quindi verrebbero
      -- sempre esclusi. Sono esattamente cio' che l utente cerca in una
      -- sezione "recenti".
      or (a.media_type in ('ONA', 'Special', 'Music')
          and a.aired_from is not null
          and a.aired_from >= current_date - 365)
      -- E ancora in onda: iniziati prima della finestra ma non finiti.
      or (a.status = 'currently_airing'
          and a.aired_from is not null
          and a.aired_from >= current_date - 365)
    )
    and (_genre is null or a.genres @> array[_genre])
  order by
    -- Prima quelli che sono gia' iniziati e non sono finiti: sono i piu'
    -- guardabili adesso. Poi i piu' recenti in assoluto.
    case when a.status = 'currently_airing' then 0 else 1 end,
    a.aired_from desc nulls last,
    a.popularity desc nulls last,
    a.id
  limit least(greatest(coalesce(_limit, 24), 1), 60)
  offset greatest(coalesce(_offset, 0), 0);
$$;

comment on function public.anime_current_season(integer, integer, text) is
  'Anime usciti negli ultimi 90 giorni o ancora in onda, piu recenti e popolari prima.';

-- ---------------------------------------------------------------------------
-- Generi disponibili, per costruire il filtro senza duplicare la lista
-- ---------------------------------------------------------------------------
-- Il client non deve conoscere a memoria i generi: un elenco scritto a mano
-- nell'app invecchierebbe e mostrerebbe filtri che restituiscono niente.
create or replace function public.anime_genres()
returns table (
  genre        text,
  anime_count  bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select g.genre, count(*)::bigint
  from public.anime a, lateral unnest(a.genres) as g(genre)
  where a.genres is not null and array_length(a.genres, 1) > 0
  group by g.genre
  -- Piu' anime prima: i generi che non tornano a nessuno stanno in fondo,
  -- dove non spingono nessuno a sceglierli.
  order by count(*) desc, g.genre
  limit 40;
$$;

comment on function public.anime_genres() is
  'Generi presenti nel catalogo con il numero di anime per ciascuno. I piu usati, per primi.';

-- ---------------------------------------------------------------------------
-- Statistiche per la barra "trovati N di M"
-- ---------------------------------------------------------------------------
-- Il numero totale serve per sapere se una ricerca vuota e' un filtro troppo
-- restrittivo oppure un catalogo vuoto: sono due problemi diversi e mostrano
-- due messaggi diversi.
create or replace function public.anime_search_count(
  _query         text default null,
  _genres        text[] default null,
  _media_type    public.anime_type default null,
  _season        public.anime_season default null,
  _status        public.anime_status default null,
  _year_from     integer default null,
  _year_to       integer default null,
  _min_score     numeric default null,
  _min_episodes  integer default null,
  _max_episodes  integer default null
)
returns table (
  total    bigint,
  catalog  bigint
)
language sql
stable
security definer
set search_path = public
as $$
  with q as (
    select
      nullif(btrim(coalesce(_query, '')), '') as qq,
      '%' || public.escape_like(btrim(coalesce(_query, ''))) || '%' as pattern
  )
  select
    count(*)::bigint as total,
    (select count(*)::bigint from public.anime) as catalog
  from public.anime a, q
  where
    (q.qq is null or a.search_blob ilike q.pattern escape '\' or a.title = q.qq)
    and public.anime_matches_filters(
      a, _genres, _media_type, _season, _status,
      _year_from, _year_to, _min_score,
      _min_episodes, _max_episodes
    );
$$;

comment on function public.anime_search_count(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer) is
  'Quanti anime corrispondono ai filtri, e quanti ce ne sono in totale: distingue "nessun risultato" da "catalogo vuoto".';

-- ---------------------------------------------------------------------------
-- Statistiche di catalogo per la home
-- ---------------------------------------------------------------------------
-- Una chiamata sola invece di tre: numero di opere, ultima sincronizzazione e
-- freshness. Una home che fa tre query per tre numeri e' una home che
-- aspetta il triplo.
create or replace function public.anime_catalog_stats()
returns table (
  total_anime    bigint,
  last_synced_at timestamptz,
  season         public.anime_season,
  airing_now     bigint,
  newest_aired   date
)
language sql
stable
security definer
set search_path = public
as $$
  select
    count(*)::bigint,
    max(a.external_fetched_at),
    public.current_season(current_date),
    count(*) filter (where a.status = 'currently_airing')::bigint,
    max(a.aired_from)
  from public.anime a;
$$;

comment on function public.anime_catalog_stats() is
  'Riepilogo del catalogo: totale, ultima sincronizzazione, stagione corrente, anime in onda.';

-- ---------------------------------------------------------------------------
-- Privilegi
-- ---------------------------------------------------------------------------
-- Tutte read-only e gia' dentro una funzione SECURITY DEFINER, quindi revoke
-- da PUBLIC e grant esplicito ad authenticated. Nessun EXECUTE ad anon: un
-- anon potrebbe enumerare il catalogo e i filtri.
--
-- service_role riceve EXECUTE perche' e' la Edge Function a leggere dalla cache
-- prima di andare su Jikan. Senza questo grant la ricerca remota non funziona:
-- la funzione chiama `anime_search` con la service key, che per RLS e' un
-- utente come gli altri e senza EXECUTE riceve "permission denied".
revoke all on function public.anime_search(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer, text, integer, integer) from public;
revoke all on function public.anime_search_count(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer) from public;
revoke all on function public.anime_current_season(integer, integer, text) from public;
revoke all on function public.anime_genres() from public;
revoke all on function public.anime_catalog_stats() from public;

-- Gli helper pubblici ma senza EXECUTE per nessuno: li chiama solo il codice
-- interno delle funzioni di sopra.
revoke all on function public.anime_matches_filters(public.anime, text[], public.anime_type,
  public.anime_season, public.anime_status, integer, integer, numeric, integer, integer) from public;
revoke all on function public.anime_title_similarity(text, text) from public;
revoke all on function public.escape_like(text) from public;

grant execute on function public.anime_search(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer, text, integer, integer) to authenticated;
grant execute on function public.anime_search_count(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer) to authenticated;
-- La Edge Function interroga la cache con la service key: senza il grant qui
-- riceve "permission denied" e va sempre su Jikan, bruciando la quota.
grant execute on function public.anime_search(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer, text, integer, integer) to service_role;
grant execute on function public.anime_search_count(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer) to service_role;
grant execute on function public.anime_current_season(integer, integer, text) to service_role;
grant execute on function public.anime_genres() to service_role;
grant execute on function public.anime_catalog_stats() to service_role;
grant execute on function public.anime_current_season(integer, integer, text) to authenticated;
grant execute on function public.anime_genres() to authenticated;
grant execute on function public.anime_catalog_stats() to authenticated;
