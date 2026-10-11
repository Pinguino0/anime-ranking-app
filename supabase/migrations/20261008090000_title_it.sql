-- ---------------------------------------------------------------------------
-- 20261008090000_title_it
--
-- Il titolo italiano nel catalogo.
--
-- Il problema che risolve
-- ----------------------
-- Il catalogo viene da AniList/Kitsu, che espongono solo romaji/english/native
-- (il kanji). L'utente italiano cerca per titolo italiano ("L'attacco dei
-- giganti") e la UI mostra il romaji ("Shingeki no Kyojin") o l'inglese
-- ("Attack on Titan") a seconda della riga. L'italiano compariva prima solo
-- dentro `synonyms[]`, nei casi sporadici in cui un utente di AniList lo aveva
-- aggiunto a mano: non era tipo di dato, era fortuna.
--
-- Quindi:
--   - due colonne nuove e nullable: `title_it` (titolo italiano se esiste) e
--     `title_it_source` (da dove arriva: anidb, tmdb, manual) per sapere di
--     che dato ci si fida;
--   - `search_blob` ricalcolata includendo il titolo italiano, cosi' la ricerca
--     trova anche quello (l'unico posto dove la ricerca guarda).
--
-- Niente `synonyms` come contenitore del titolo italiano: la UI deve poter
-- distinguere "questo e' il titolo ufficiale in italiano" da "questo e' un
-- alias qualsiasi". Una colonna dedicata e' il tipo di dato onesto; synonyms[]
-- serve agli alias.
--
-- Perche' si ricrea la colonna generata
-- ------------------------------------
-- L'espressione di una colonna GENERATED non si modifica con un ALTER: si
-- toglie e si riaggiunge. Su 6,7k righe e' istantaneo. Si ricrea anche perche'
-- la firma della funzione cambia (aggiunge il parametro italiano); la
-- EXECUTE resta solo a chi scrive la tabella (service_role), come voleva la
-- 20261004195554.
-- ---------------------------------------------------------------------------

alter table public.anime
  add column title_it text,
  add column title_it_source text;

comment on column public.anime.title_it is
  'Il titolo in italiano, se esiste. NULL quando l''opera non ha un titolo italiano conosciuto: la UI e la ricerca cade in inglese/romaji senza rompersi.';
comment on column public.anime.title_it_source is
  'Da dove arriva title_it: `anidb`, `tmdb`, `manual`. Serve a sapere di che dato ci si fida prima di sovrascriverlo.';

-- ---------------------------------------------------------------------------
-- search_blob con il titolo italiano
-- ---------------------------------------------------------------------------
create or replace function public.anime_search_blob(
  _title          text,
  _japanese_title text,
  _italian_title  text,
  _synonyms       text[],
  _original_title text
)
returns text
language sql
immutable
parallel safe
as $$
  select coalesce(array_to_string(
    array_remove(
      array[
        _title,
        _italian_title,
        _japanese_title,
        _original_title,
        array_to_string(_synonyms, ' ')
      ],
      null
    ),
    ' '
  ), '');
$$;

alter table public.anime drop column search_blob;

alter table public.anime
  add column search_blob text
  generated always as (
    public.anime_search_blob(
      title, japanese_title, title_it, synonyms, external_data ->> 'title'
    )
  ) stored;

create index anime_search_blob_idx
  on public.anime using gin (search_blob extensions.gin_trgm_ops);

comment on column public.anime.search_blob is
  'Titolo + italiano + giapponese + originale + sinonimi, uniti per la ricerca. Generata: non modificarla.';

-- Il corpo della colonna generata viene valutato con i permessi del ruolo che
-- scrive in `anime`, cioe' service_role: e' l'unico che deve poterla eseguire.
grant execute on function public.anime_search_blob(text, text, text, text[], text) to service_role;

-- La vecchia firma a 4 parametri non ha piu' nulla che la usi.
drop function public.anime_search_blob(text, text, text[], text);