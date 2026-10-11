-- ============================================================================
-- provider index + mappings — "harvest once, join forever"
-- ============================================================================
--
-- Problema risolto
-- ---------------------------------------------------------------------------
-- Finora l'animeunity_id veniva assegnato per somiglianza di titolo (fuzzy),
-- senza prenotazione: due anime diversi potevano ricevere lo stesso id e
-- mostrare gli episodi sbagliati (891 id condivisi, 2865 anime).
--
-- La regola nuova e' una sola: il binding fonte -> episodi NON si fa mai per
-- nome. Si scarica una volta l'indice del provider (ogni record dichiara il
-- proprio anilist_id/mal_id) e si unisce per ID esatto.
--
-- Due tabelle, due responsabilita' diverse:
--
--   provider_anime_index     = specchio del catalogo del provider. Contiene
--                              TUTTI i record, anche se due puntano allo stesso
--                              anilist_id (succede con sub/dub o voci doppie).
--                              Nessun vincolo di unicita' sull'anilist_id qui,
--                              altrimenti l'harvest fallirebbe per dati del
--                              provider fuori dal nostro controllo.
--
--   anime_provider_mappings  = la DECISIONE: quale record usa quale anime.
--                              Qui stanno i vincoli che rendono le collisioni
--                              impossibili per costruzione.
--
-- Cosi' un dato sporco del provider non rompe l'harvest (lo registriamo e lo
-- mettiamo in revisione), ma non puo' nemmeno mai produrre due anime con lo
-- stesso record.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- provider_anime_index
-- ----------------------------------------------------------------------------
create table public.provider_anime_index (
  -- Provider e id del record nel provider. Questa coppia e' l'identita' vera
  -- della riga: e' quella che l'harvest scrive e riscrive (idempotente).
  provider_slug     text    not null references public.providers (slug) on update cascade,
  provider_anime_id text    not null,

  -- ID esterni dichiarati DAL provider: sono la chiave del join.
  anilist_id        integer,
  mal_id            integer,

  -- Nomi come li espone il provider (servono ad arricchire la ricerca).
  title             text,
  title_eng         text,
  title_it          text,
  slug              text,

  -- Versione: sub o dub. Un provider puo' avere due record distinti per lo
  -- stesso anime; sono due righe perche' hanno due provider_anime_id diversi.
  is_dub            boolean not null default false,

  episodes_count    integer,

  -- JSON grezzo della risposta: non si perde nulla che il modello non espone.
  raw_data          jsonb,

  fetched_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  primary key (provider_slug, provider_anime_id),
  constraint provider_anime_index_eps_nonneg
    check (episodes_count is null or episodes_count >= 0)
);

-- Lookup per il join (anilist_id) e per il fallback (mal_id). Parziali perche'
-- le righe senza id esterno non servono a nessuna query di mapping.
create index provider_anime_index_anilist_idx
  on public.provider_anime_index (provider_slug, anilist_id)
  where anilist_id is not null;

create index provider_anime_index_mal_idx
  on public.provider_anime_index (provider_slug, mal_id)
  where mal_id is not null;

create trigger provider_anime_index_set_updated_at
  before update on public.provider_anime_index
  for each row execute function public.set_updated_at();

comment on table public.provider_anime_index is
  'Specchio del catalogo di un provider (es. AnimeUnity). Una riga per record del provider, popolata dall''harvest. Serve a unire per ID esatto, mai per titolo.';

-- ----------------------------------------------------------------------------
-- anime_provider_mappings
-- ----------------------------------------------------------------------------
-- La PK (anime_id, provider_slug, is_dub) dice: ogni anime ha AL MASSIMO una
-- fonte per provider e per versione (sub/dub).
--
-- Il vincolo (provider_slug, provider_anime_id) dice: ogni record del provider
-- alimenta AL MASSIMO un anime. E' questo che elimina i doppioni per costruzione.
create table public.anime_provider_mappings (
  anime_id          uuid not null references public.anime (id) on delete cascade,
  provider_slug     text not null,
  provider_anime_id text not null,
  is_dub            boolean not null default false,

  -- Come e' stato deciso il match: join esatto (preferito) o revisione.
  matched_by        text not null default 'anilist_id'
    check (matched_by in ('anilist_id', 'mal_id', 'fuzzy_review', 'manual')),
  confidence        real,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  primary key (anime_id, provider_slug, is_dub),
  constraint anime_provider_mappings_record_unique
    unique (provider_slug, provider_anime_id),
  foreign key (provider_slug, provider_anime_id)
    references public.provider_anime_index (provider_slug, provider_anime_id)
    on delete cascade
);

create trigger anime_provider_mappings_set_updated_at
  before update on public.anime_provider_mappings
  for each row execute function public.set_updated_at();

comment on table public.anime_provider_mappings is
  'Decisione anime <-> record provider. I vincoli qui rendono impossibile che due anime condividano una fonte o che un anime ne abbia due per la stessa versione.';

-- ----------------------------------------------------------------------------
-- RLS e privilegi: tabelle interne, accesso solo service_role
-- ----------------------------------------------------------------------------
-- L'app non le legge: legge `episode_sources` (gia' filtrato da RLS). Restano
-- chiuse anche in lettura per non esporre l'indice grezzo del provider.
alter table public.provider_anime_index    enable row level security;
alter table public.anime_provider_mappings enable row level security;

revoke all on public.provider_anime_index    from anon, authenticated;
revoke all on public.anime_provider_mappings from anon, authenticated;

create policy "provider_anime_index: service write"
  on public.provider_anime_index for all
  to service_role using (true) with check (true);

create policy "anime_provider_mappings: service write"
  on public.anime_provider_mappings for all
  to service_role using (true) with check (true);
