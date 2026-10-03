-- ============================================================================
-- Verifica funzionale della migration 019 (catalogo anime)
-- ============================================================================
-- Da usare DOPO che 019 e' stata applicata. Inserisce righe di prova in
-- public.anime, esercita ogni filtro, poi le rimuove: e' uno script di
-- test, non una migration. Non lasciare nulla nel DB.
-- ============================================================================

begin;

-- Dati di prova. external_id distinti perche' la UNIQUE e' su
-- (external_source, external_id) e il rollback deve poter ripartire pulito.
insert into public.anime (
  external_id, title, japanese_title, synonyms, synopsis, image_url,
  episodes, status, year, genres, media_type, season,
  aired_from, aired_to, score, scored_by, popularity, duration, studio,
  external_fetched_at, external_stale_at
) values
  (
    'test-419x', 'Attack on Titan', '進撃の巨人', array['Shingeki no Kyojin','AoT'],
    'Un villaggio vive dietro un muro.', 'https://img.test/aot.jpg',
    89, 'finished_airing', 2013, array['Action','Drama','Fantasy','Military'], 'TV',
    'spring', date '2013-04-07', date '2023-11-04', 9.1, 1200000, 3000000,
    '24 min per ep', 'Wit Studio', now(), now() + interval '30 days'
  ),
  (
    'test-418x', 'One Piece', 'ワンピース', array['Wan Pisu'],
    'Un pirata cerca il One Piece.', 'https://img.test/op.jpg',
    null, 'currently_airing', 1999, array['Action','Adventure','Comedy','Fantasy'], 'TV',
    'fall', date '1999-10-20', null, 8.7, 800000, 4000000,
    '24 min per ep', 'Toei Animation', now(), now() + interval '30 days'
  ),
  (
    'test-425x', 'Akira', null, '{}',
    'Citta giapponese, energia e macchine.', 'https://img.test/akira.jpg',
    1, 'finished_airing', 1988, array['Action','Sci-Fi'], 'Movie',
    'summer', date '1988-07-16', date '1988-07-16', 8.0, 180000, 900000,
    '124 min', 'Tokyo Movie Shinsha', now(), now() + interval '30 days'
  ),
  (
    'test-430x', 'Solo Leveling', '俺だけレベルアップな件', array['Ore dake Level Up'],
    'Il cacciatore piu debole.', 'https://img.test/sl.jpg',
    12, 'finished_airing', 2024, array['Action','Adventure','Fantasy'], 'TV',
    'winter', date '2024-01-06', date '2024-03-23', 8.4, 400000, 1200000,
    '24 min per ep', 'A-1 Pictures', now(), now() + interval '30 days'
  ),
  (
    'test-431x', 'ONA attuale', null, '{}',
    'Speciale piu recente.', 'https://img/test.ona.jpg',
    1, 'currently_airing', 2026, array['Comedy'], 'ONA',
    'fall', current_date - 3, null, 7.5, 1000, 5000,
    '15 min', 'Studio', now(), now() + interval '30 days'
  ),
  (
    'test-432x', 'Vecchio del 1970', null, '{}',
    'Capolavoro d epoca.', 'https://img.test/old.jpg',
    26, 'finished_airing', 1972, array['Drama'], 'TV',
    'spring', date '1972-04-01', date '1972-09-30', 8.8, 5000, 20000,
    '24 min', 'Nippon TV', now(), now() + interval '30 days'
  );

-- ---------------------------------------------------------------------------
-- Test 1: ricerca per titolo, anche parziale
-- ---------------------------------------------------------------------------
do $$
declare v_count int; v_title text;
begin
  select count(*), min(title) into v_count, v_title
  from public.anime_search(_query => 'titan');

  if v_count <> 1 or v_title <> 'Attack on Titan' then
    raise exception 'TEST 1 KO: "titan" -> % righe (%), atteso 1 Attack on Titan',
      v_count, v_title;
  end if;
  raise notice 'TEST 1 OK: ricerca parziale "titan"';
end $$;

-- Test 1b: il sinonimo deve trovare l'opera. E' il motivo per cui esiste
-- search_blob: un utente scrive "Shingeki" e deve trovare "Attack on Titan".
do $$
declare v_count int;
begin
  select count(*) into v_count
  from public.anime_search(_query => 'Shingeki');
  if v_count <> 1 then
    raise exception 'TEST 1b KO: sinonimo "Shingeki" -> % righe, atteso 1', v_count;
  end if;
  raise notice 'TEST 1b OK: ricerca per sinonimo';
end $$;

-- Test 1c: query con troppo pochi caratteri per i trigram. Senza il ramo
-- `or title = q` (e il fallback su ILIKE) risulterebbe vuota.
do $$
declare v_count int;
begin
  select count(*) into v_count
  from public.anime_search(_query => 'Ak');
  if v_count = 0 then
    raise exception 'TEST 1c KO: query di 2 caratteri non trova nulla';
  end if;
  -- %% e non %: in PL/pgSQL il segnaposto dei parametri, e questa notice non ha
  -- argomenti. Scritto "%" singolo, "too few parameters specified for RAISE".
  raise notice 'TEST 1c OK: query corta "%%" di trigram';
end $$;

-- Test 1d: '%' e '_' devono essere letterali, non wildcards. Senza l'escaping
-- la query '%' diventerebbe '%%%' e restituirebbe TUTTO il catalogo, ignorando
-- ogni filtro: qui devono tornare 0 righe.
do $$
declare v_count int;
begin
  select count(*) into v_count
  from public.anime_search(_query => '%');
  if v_count <> 0 then
    raise exception 'TEST 1d KO: il wildcard %% ha iniettato il filtro (% righe)', v_count;
  end if;
  raise notice 'TEST 1d OK: %% trattato come letterale';
end $$;

-- Test 1e: '_' e' un wildcard che matcha un qualunque carattere. La query '_'
-- senza escaping troverebbe qualsiasi titolo di un solo carattere: con
-- l'escaping deve tornare 0. Nota che tutti i titoli di prova hanno piu' di
-- un carattere, quindi il test distingue i due comportamenti.
do $$
declare v_count int;
begin
  select count(*) into v_count
  from public.anime_search(_query => '_');
  if v_count <> 0 then
    raise exception 'TEST 1e KO: il wildcard _ ha iniettato il filtro (% righe)', v_count;
  end if;
  raise notice 'TEST 1e OK: _ trattato come letterale';
end $$;

-- Test 1f: l'escaping non deve rompercere le ricerche normali. Un titolo che
-- contiene davvero un '%' si trova solo se il match e' esatto.
do $$
declare v_count int;
begin
  insert into public.anime (external_id, title, image_url)
    values ('test-433x', '100% Tiger', 'https://img.test/pct.jpg');

  select count(*) into v_count
  from public.anime_search(_query => '100%');
  if v_count <> 1 then
    raise exception 'TEST 1f KO: titolo con %% reale -> % righe, atteso 1', v_count;
  end if;

  -- Rimossa subito: i test successivi contano le righe di prova e questa
  -- righe ne aggiungerebbe una, facendoli fallire per il motivo sbagliato.
  delete from public.anime where external_id = 'test-433x';

  raise notice 'TEST 1f OK: %% reale nel titolo resta ricercabile';
end $$;

-- ---------------------------------------------------------------------------
-- Test 2: filtro genere (AND, non OR)
-- ---------------------------------------------------------------------------
do $$
declare v_count int;
begin
  -- Action da solo: quattro righe di prova (AoT, One Piece, Akira, Solo
  -- Leveling). L'attesa diceva 3: il conto era sbagliato, non il filtro.
  select count(*) into v_count
  from public.anime_search(_genres => array['Action']);
  if v_count <> 4 then
    raise exception 'TEST 2 KO: genere Action -> % righe, atteso 4', v_count;
  end if;

  -- Action E Fantasy: tre righe (AoT, One Piece, Solo Leveling). Con OR
  -- sarebbero state quattro, perche' anche Akira ha Action. Il numero che
  -- distingue AND da OR e' questo, non il 2 che c'era prima.
  select count(*) into v_count
  from public.anime_search(_genres => array['Action','Fantasy']);
  if v_count <> 3 then
    raise exception 'TEST 2b KO: Action+Fantasy -> % righe, atteso 3 (AND non OR)', v_count;
  end if;

  -- Genere inesistente: zero, senza errore.
  select count(*) into v_count
  from public.anime_search(_genres => array['Polinomi']);
  if v_count <> 0 then
    raise exception 'TEST 2c KO: genere inesistente -> % righe', v_count;
  end if;

  raise notice 'TEST 2 OK: filtro genere AND';
end $$;

-- ---------------------------------------------------------------------------
-- Test 3: filtro tipo
-- ---------------------------------------------------------------------------
do $$
declare v_count int; v_title text;
begin
  select count(*), min(title) into v_count, v_title
  from public.anime_search(_media_type => 'Movie');
  if v_count <> 1 or v_title <> 'Akira' then
    raise exception 'TEST 3 KO: Movie -> % righe (%), atteso 1 Akira', v_count, v_title;
  end if;
  raise notice 'TEST 3 OK: filtro media_type';
end $$;

-- ---------------------------------------------------------------------------
-- Test 4: filtro anno
-- ---------------------------------------------------------------------------
do $$
declare v_count int;
begin
  -- Dal 2000 in poi escludono Akira (1988) e il 1972.
  select count(*) into v_count
  from public.anime_search(_year_from => 2000);
  if v_count <> 3 then
    raise exception 'TEST 4 KO: year_from 2000 -> % righe, atteso 3', v_count;
  end if;

  -- Finestra chiusa: 1972-1988 prende il vecchio e Akira.
  select count(*) into v_count
  from public.anime_search(_year_from => 1970, _year_to => 1990);
  if v_count <> 2 then
    raise exception 'TEST 4b KO: 1970-1990 -> % righe, atteso 2', v_count;
  end if;
  raise notice 'TEST 4 OK: filtro anno';
end $$;

-- ---------------------------------------------------------------------------
-- Test 4c: filtro stato
-- ---------------------------------------------------------------------------
-- Il filtro per stato e' quello con piu' rischi di bug silenzioso: se il
-- parametro non arrivasse al WHERE la ricerca tornerebbe risultati sbagliati
-- senza alcun errore, quindi qui si verifica che filtri davvero.
do $$
declare v_count int; v_title text;
begin
  -- Solo One Piece e l'ONA sono in corso nel catalogo di prova.
  select count(*), min(title) into v_count, v_title
  from public.anime_search(_status => 'currently_airing');

  if v_count <> 2 then
    raise exception 'TEST 4c KO: currently_airing -> % righe, atteso 2', v_count;
  end if;

  -- Con lo stato insieme a un altro filtro i due devono applicarsi insieme,
  -- non in alternativa.
  select count(*) into v_count
  from public.anime_search(_status => 'currently_airing', _media_type => 'TV');
  if v_count <> 1 then
    raise exception 'TEST 4d KO: in corso + TV -> % righe, atteso 1', v_count;
  end if;

  -- Lo stato inesistente non e' un errore: zero righe, come gli altri filtri.
  select count(*) into v_count
  from public.anime_search(_status => 'not_yet_aired');
  if v_count <> 0 then
    raise exception 'TEST 4e KO: not_yet_aired -> % righe, atteso 0', v_count;
  end if;

  raise notice 'TEST 4c OK: filtro stato';
end $$;

-- ---------------------------------------------------------------------------
-- Test 5: filtro voto
-- ---------------------------------------------------------------------------
do $$
declare v_count int;
begin
  -- score >= 9 prende solo AoT. Le righe con score NULL non devono passare:
  -- e' il comportamento che l utente si aspetta da "almeno 9".
  select count(*) into v_count
  from public.anime_search(_min_score => 9);
  if v_count <> 1 then
    raise exception 'TEST 5 KO: score>=9 -> % righe, atteso 1', v_count;
  end if;
  raise notice 'TEST 5 OK: filtro voto minimo (NULL esclusi)';
end $$;

-- ---------------------------------------------------------------------------
-- Test 6: filtro episodi. Uno dei casi che la nota del codice segnala:
-- One Piece ha episodes NULL e non deve comparire in "almeno 10 episodi".
-- ---------------------------------------------------------------------------
do $$
declare v_count int;
begin
  select count(*) into v_count
  from public.anime_search(_min_episodes => 10);
  -- Tre righe hanno almeno 10 episodi: AoT (89), Solo Leveling (12) e il Vecchio
  -- del 1970 (26). L'attesa diceva 2 perche' il 1970 era stato dimenticato.
  -- One Piece (episodes NULL) e gli altri due da 1 restano esclusi.
  if v_count <> 3 then
    raise exception 'TEST 6 KO: min_episodes 10 -> % righe, atteso 3 (NULL escluso)', v_count;
  end if;
  raise notice 'TEST 6 OK: filtro episodi (NULL escluso)';
end $$;

-- ---------------------------------------------------------------------------
-- Test 7: filtri combinati
-- ---------------------------------------------------------------------------
do $$
declare v_count int;
begin
  select count(*) into v_count
  from public.anime_search(
    _genres       => array['Action'],
    _media_type   => 'TV',
    _year_from    => 2000,
    _min_score    => 9
  );
  if v_count <> 1 then
    raise exception 'TEST 7 KO: combinazione -> % righe, atteso 1', v_count;
  end if;
  raise notice 'TEST 7 OK: filtri combinati';
end $$;

-- ---------------------------------------------------------------------------
-- Test 8: paginazione senza duplicati a cavallo
-- ---------------------------------------------------------------------------
do $$
declare v_all text[]; v_p1 text[]; v_p2 text[]; v_dup int;
begin
  -- Catalogo di prova: 6 righe, ma la query 'a' ne matcha 5. "Vecchio del 1970"
  -- non contiene la lettera 'a' da nessuna parte, e la ricerca e' un ILIKE
  -- senza soglia di somiglianza, quindi non lo recupera. L'attesa diceva 6.
  -- Due pagine da 4.
  select array_agg(id::text order by id) into v_p1
  from public.anime_search(_limit => 4, _offset => 0, _query => 'a')
     having count(*) > 0;  -- no-op per non fallire su set vuoto

  -- Uso lo stesso ordinamento della funzione per confrontare le pagine.
  select coalesce(array_agg(id::text order by aired_from desc nulls last, popularity desc nulls last, id), '{}')
    into v_all
  from public.anime_search(_query => 'a', _limit => 60);

  if array_length(v_all, 1) is distinct from 5 then
    raise exception 'TEST 8 KO: la query che matcha tutti doveva dare 5, ha dato %',
      array_length(v_all, 1);
  end if;

  -- Pagina 1 e pagina 2 non devono condividere elementi. E' il controllo che
  -- vale sull'infinite scroll.
  select coalesce(array_agg(id::text order by aired_from desc nulls last, popularity desc nulls last, id), '{}')
    into v_p1
  from public.anime_search(_query => 'a', _limit => 4, _offset => 0);

  select coalesce(array_agg(id::text order by aired_from desc nulls last, popularity desc nulls last, id), '{}')
    into v_p2
  from public.anime_search(_query => 'a', _limit => 4, _offset => 4);

  if v_p1 && v_p2 then
    select count(*) into v_dup
    from unnest(v_p1) t(id) join unnest(v_p2) u(id) on t.id = u.id;
    if v_dup > 0 then
      raise exception 'TEST 8 KO: % duplicati fra pagina 1 e 2', v_dup;
    end if;
  end if;
  raise notice 'TEST 8 OK: paginazione senza duplicati';
end $$;

-- ---------------------------------------------------------------------------
-- Test 9: stagione corrente
-- ---------------------------------------------------------------------------
do $$
declare v_count int; v_title text;
begin
  select count(*), min(title) into v_count, v_title
  from public.anime_current_season();
  -- L'ONA di 3 giorni fa entra; nient'altro della finestra 90 giorni.
  if v_count < 1 then
    raise exception 'TEST 9 KO: stagione vuota, atteso almeno l ONA recente';
  end if;
  if v_title is distinct from 'ONA attuale' then
    raise exception 'TEST 9b KO: atteso "ONA attuale" in cima, trovato %', v_title;
  end if;
  raise notice 'TEST 9 OK: stagione corrente';
end $$;

-- Test 9c: la funzione current_season e coerente col calendario.
do $$
declare v_winter public.anime_season; v_spring public.anime_season;
begin
  select public.current_season(date '2026-01-15') into v_winter;
  select public.current_season(date '2026-04-15') into v_spring;
  if v_winter <> 'winter' or v_spring <> 'spring' then
    raise exception 'TEST 9c KO: current_season -> %, %', v_winter, v_spring;
  end if;
  -- Le stagioni Jikan sono a cavallo d anno: aprile e' spring, non winter.
  select public.current_season(date '2026-12-15') into v_winter;
  if v_winter <> 'winter' then
    raise exception 'TEST 9d KO: dicembre deve essere winter, non %', v_winter;
  end if;
  raise notice 'TEST 9c OK: calcolo stagione';
end $$;

-- ---------------------------------------------------------------------------
-- Test 10: generi con conteggio
-- ---------------------------------------------------------------------------
do $$
declare v_count int;
begin
  select count(*) into v_count from public.anime_genres();
  if v_count < 4 then
    raise exception 'TEST 10 KO: solo % generi, attesi almeno 4', v_count;
  end if;
  raise notice 'TEST 10 OK: elenco generi';
end $$;

-- ---------------------------------------------------------------------------
-- Test 11: conteggio distingue "vuoto" da "nessun risultato"
-- ---------------------------------------------------------------------------
do $$
declare v_total bigint; v_catalog bigint;
begin
  -- Catalogo vuoto in questo momento: il conteggio deve dirlo, cosi' la UI
  -- puo' distinguere "catalogo da popolare" da "filtro troppo restrittivo".
  select total, catalog into v_total, v_catalog
  from public.anime_search_count(_query => 'inesistente');

  if v_total <> 0 then
    raise exception 'TEST 11 KO: total % per una query inesistente', v_total;
  end if;
  if v_catalog <> 6 then
    raise exception 'TEST 11b KO: catalog % ma ci sono 6 righe di prova', v_catalog;
  end if;
  raise notice 'TEST 11 OK: conteggio e catalogo distinguibili';
end $$;

-- ---------------------------------------------------------------------------
-- Test 12: statistiche catalogo
-- ---------------------------------------------------------------------------
do $$
declare v_total bigint; v_airing bigint;
begin
  select total_anime, airing_now into v_total, v_airing
  from public.anime_catalog_stats();
  if v_total <> 6 then
    raise exception 'TEST 12 KO: total_anime %', v_total;
  end if;
  -- One Piece e l ONA sono in corso.
  if v_airing <> 2 then
    raise exception 'TEST 12b KO: airing_now % atteso 2', v_airing;
  end if;
  raise notice 'TEST 12 OK: statistiche catalogo';
end $$;

-- ---------------------------------------------------------------------------
-- Test 13: search_blob include titolo, giapponese, sinonimi e originale
-- ---------------------------------------------------------------------------
do $$
declare v_blob text; v_ok boolean;
begin
  select search_blob into v_blob from public.anime where external_id = 'test-419x';

  v_ok := v_blob ilike '%Attack on Titan%'
      and v_blob ilike '%進撃の巨人%'
      and v_blob ilike '%Shingeki%'
      and v_blob ilike '%AoT%';
  if not v_ok then
    raise exception 'TEST 13 KO: search_blob = %', v_blob;
  end if;
  raise notice 'TEST 13 OK: search_blob completo';
end $$;

-- Test 13b: un anime senza titolo giapponese e senza sinonimi non deve
-- avere search_blob NULL, altrimenti ogni ricerca su quella riga fallirebbe.
do $$
declare v_blob text;
begin
  select search_blob into v_blob from public.anime where external_id = 'test-432x';
  if v_blob is null then
    raise exception 'TEST 13b KO: search_blob NULL su anime senza titoli alternativi';
  end if;
  if v_blob !~ 'Vecchio del 1970' then
    raise exception 'TEST 13b KO: search_blob = %, non contiene il titolo', v_blob;
  end if;
  raise notice 'TEST 13b OK: search_blob senza titoli alternativi';
end $$;

-- ---------------------------------------------------------------------------
-- Test 14: i filtri non lasciano passare righe NULL
-- ---------------------------------------------------------------------------
do $$
declare v_count int;
begin
  -- media_type NULL su una riga non deve passare il filtro Movie.
  -- Copro il caso settando il tipo a NULL su una riga di prova.
  update public.anime set media_type = null where external_id = 'test-425x';

  select count(*) into v_count
  from public.anime_search(_media_type => 'Movie');
  -- Ora Movie non deve piu' restituire Akira.
  if v_count <> 0 then
    raise exception 'TEST 14 KO: media_type NULL ha passato il filtro Movie (% righe)', v_count;
  end if;

  -- E senza filtro deve tornare: NULL non e' "escluso dal catalogo".
  select count(*) into v_count
  from public.anime_search(_query => 'Akira');
  if v_count <> 1 then
    raise exception 'TEST 14b KO: senza filtro Akira non trovata (% righe)', v_count;
  end if;

  raise notice 'TEST 14 OK: NULL non passa i filtri ma resta nel catalogo';
end $$;

-- ---------------------------------------------------------------------------
-- Test 15: anon non puo' eseguire nessuna di queste funzioni
-- ---------------------------------------------------------------------------
do $$
declare v_ok boolean;
begin
  -- La firma deve includere anime_status: senza, has_function_privilege cerca una
  -- funzione inesistente e solleva un errore invece di rispondere true/false.
  select has_function_privilege('anon', 'public.anime_search(text,text[],public.anime_type,public.anime_season,public.anime_status,integer,integer,numeric,integer,integer,text,integer,integer)', 'execute')
    into v_ok;
  if v_ok then
    raise exception 'TEST 15 KO: anon ha EXECUTE su anime_search';
  end if;

  select has_function_privilege('anon', 'public.anime_genres()', 'execute') into v_ok;
  if v_ok then
    raise exception 'TEST 15b KO: anon ha EXECUTE su anime_genres';
  end if;

  raise notice 'TEST 15 OK: nessuna RPC del catalogo eseguibile da anon';
end $$;

-- ---------------------------------------------------------------------------
-- Test 16: service_role puo' eseguire le RPC
-- ---------------------------------------------------------------------------
-- La Edge Function interroga la cache con la service key prima di andare su
-- Jikan. service_role e' un utente come gli altri per i privilegi EXECUTE: senza
-- il grant riceve "permission denied" e la cache non serve mai, quindi ogni
-- ricerca consuma quota. Il sintomo sarebbe lentissimo, non un errore.
do $$
declare v_ok boolean;
begin
  select has_function_privilege(
    'service_role',
    'public.anime_search(text,text[],public.anime_type,public.anime_season,public.anime_status,integer,integer,numeric,integer,integer,text,integer,integer)',
    'execute'
  ) into v_ok;
  if not v_ok then
    raise exception 'TEST 16 KO: service_role non puo eseguire anime_search';
  end if;

  select has_function_privilege('service_role', 'public.anime_genres()', 'execute') into v_ok;
  if not v_ok then
    raise exception 'TEST 16b KO: service_role non puo eseguire anime_genres';
  end if;

  raise notice 'TEST 16 OK: service_role puo usare la cache';
end $$;

-- ---------------------------------------------------------------------------
-- Test 17: il filtro genere della stagione corrente
-- ---------------------------------------------------------------------------
-- Il bug e' nella precedenza AND/OR: senza parentesi, il filtro genere si
-- legherebbe solo all'ultimo ramo e la lista mostrerebbe anche opere di altri
-- generi. Il test fallisce se il genere non viene applicato.
do $$
declare v_count int;
begin
  select count(*) into v_count
  from public.anime_current_season(_genre => 'Comedy');
  if v_count <> 1 then
    raise exception 'TEST 17 KO: stagione con genere Comedy -> % righe, atteso 1', v_count;
  end if;

  -- Genere inesistente: zero, non "tutto".
  select count(*) into v_count
  from public.anime_current_season(_genre => 'Horror');
  if v_count <> 0 then
    raise exception 'TEST 17b KO: stagione con genere Horror -> % righe, atteso 0', v_count;
  end if;

  raise notice 'TEST 17 OK: il filtro genere si applica alla stagione corrente';
end $$;

-- ---------------------------------------------------------------------------
-- Rollback: le righe di prova non devono restare.
-- ---------------------------------------------------------------------------
rollback;

-- Dentro un blocco do $$ e non sciolto: `raise` esiste solo in PL/pgSQL, in
-- SQL puro il SQL Editor rispondeva "syntax error at or near raise".
do $$ begin
  raise notice 'Verifica 019 completata. Le righe di prova sono state rimosse dal rollback.';
end $$;