-- ============================================================================
-- 005 — anime (catalogo condiviso + cache della API esterna)
-- ============================================================================
-- Non inseriamo a mano migliaia di anime: la tabella e una CACHE.
-- Popolata dall'Edge Function jikan-proxy che parla con Jikan/MyAnimeList.
-- Nessuna policy di scrittura per 'authenticated': solo service_role
-- (Edge Function) puo scrivere, cosi un client malevolo non puo iniettare
-- anime falsi nel catalogo.
-- ============================================================================

create extension if not exists pg_trgm with schema extensions;

create type public.anime_status as enum (
  'finished_airing',
  'currently_airing',
  'not_yet_aired'
);

create table public.anime (
  id               uuid primary key default gen_random_uuid(),

  -- ID esterno (MyAnimeList/Jikan). La coppia (source, external_id) e univoca.
  external_id      text not null,
  external_source  text not null default 'mal',

  title            text not null,
  japanese_title   text,
  synonyms         text[] not null default '{}',
  synopsis         text,

  image_url        text,
  trailer_url      text,

  episodes         integer,
  status           public.anime_status,
  year             integer,
  duration         text,
  studio           text,
  genres           text[] not null default '{}',
  demographics     text[] not null default '{}',

  -- Dati grezzi di Jikan, per non perdere informazioni che il modello non
  -- espone (score MAL, trailer, titoli alternativi, ecc.).
  external_data    jsonb,

  -- Freshness della cache: se piu vecchio di N giorni l'Edge Function
  -- ricarica da Jikan (sezione 29 del prompt).
  external_fetched_at timestamptz,
  external_stale_at   timestamptz,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint anime_external_unique unique (external_source, external_id),
  constraint anime_title_not_blank check (char_length(btrim(title)) > 0),
  constraint anime_episodes_positive check (episodes is null or episodes > 0),
  constraint anime_year_range check (year is null or year between 1900 and 2100)
);

-- Indici di ricerca: il client cerca per titolo, titolo giapponese e sinonimi.
-- pg_trgm permette anche ricerche parziali e tolleranza ai typo ("atack on").
-- Sintassi: l'opclass va DOPO il nome della colonna, non prima.
create index anime_title_idx  on public.anime using gin (title extensions.gin_trgm_ops);
create index anime_jtitle_idx on public.anime using gin (japanese_title extensions.gin_trgm_ops);

-- pg_trgm non puo indicizzare direttamente un text[]: serve una colonna di
-- testo che accorpi i sinonimi.
--
-- array_to_string() e' marcata STABLE (dipende dall'output function del tipo
-- degli elementi), quindi non puo essere usata direttamente in una colonna
-- GENERATED. Il wrapper qui sotto e' IMMUTABLE, ma solo per text[]: e' corretto
-- perche' text non ha output function dipendente dai dati.
create function public.text_array_to_search(p_synonyms text[])
returns text
language sql
immutable
parallel safe
strict
as $$
  select coalesce(array_to_string(p_synonyms, ' '), '');
$$;

-- E' GENERATED, quindi non puo divergere dai sinonimi e non va mantenuta a mano.
alter table public.anime
  add column search_text text
  generated always as (public.text_array_to_search(synonyms)) stored;

create index anime_synonyms_idx on public.anime using gin (search_text extensions.gin_trgm_ops);
-- Per le query "questo anime ha il sinonimo X" (contenimento array).
create index anime_synonyms_arr_idx on public.anime using gin (synonyms);
create index anime_genres_idx    on public.anime using gin (genres);
create index anime_year_idx      on public.anime (year);
create index anime_stale_idx     on public.anime (external_stale_at);
-- Il catalogo si sfoglia per voto medio decrescente: utile al carosello iniziale.
create index anime_fetched_idx   on public.anime (external_fetched_at desc);

comment on table public.anime is
  'Cache locale del catalogo anime. Fonte dei dati: API Jikan (MyAnimeList). '
  'Scrittura consentita solo alla Edge Function via service_role.';

create trigger anime_set_updated_at
  before update on public.anime
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS: lettura globale per autenticati, scrittura solo service_role
-- ---------------------------------------------------------------------------
alter table public.anime enable row level security;

-- Il catalogo e condiviso fra tutti i gruppi: serve per mostrare i risultati
-- di ricerca e i titoli prima di entrare in un gruppo. Non contiene dati
-- personali, quindi nessun rischio di fuga fra gruppi.
create policy "anime: lettura da autenticati"
  on public.anime for select
  to authenticated
  using (true);

-- Nessuna policy INSERT/UPDATE/DELETE per 'authenticated':
-- l'accesso in scrittura avviene solo tramite service_role, che bypassa RLS.
