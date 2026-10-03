-- ---------------------------------------------------------------------------
-- 022_rpc_privileges_... no: 022_word_similarity_schema
--
-- Qualifica la chiamata a word_similarity nello schema giusto.
--
-- Il problema: pg_trgm su Supabase e' installato nello schema `extensions`, non
-- in `public`. Le funzioni SECURITY DEFINER della 019 fissano
-- `set search_path = public`, quindi `word_similarity(...)` non risolveva e la
-- ricerca falliva a runtime con:
--
--   42883: function word_similarity(text, text) does not exist
--
-- Il DDL passava senza problemi: l'errore e' solo in esecuzione, e si vede
-- dalla prima ricerca con testo. Per questo la 019 risultava "applicata" e il
-- problema e' emerso solo con verify_019.sql.
--
-- La 019 usava gia' `extensions.gin_trgm_ops` per l'indice GIN, quindi lo
-- schema giusto era gia' noto: la chiamata alla funzione era l'unica rimasta
-- non qualificata.
--
-- Solo anime_title_similarity chiama pg_trgm. `similarity` nelle altre funzioni
-- e' un nome di colonna dell'output, non una chiamata.
-- ---------------------------------------------------------------------------

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