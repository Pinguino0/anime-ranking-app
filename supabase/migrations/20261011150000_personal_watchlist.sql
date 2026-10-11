-- ============================================================================
-- personal_watchlist - la watchlist PERSONALE dell utente, slegata dai gruppi
-- ============================================================================
-- Fino ad ora la watchlist viveva solo dentro un gruppo (`public.watchlists`,
-- con `group_id NOT NULL`): "La mia lista" era l'unione delle voci di tutti i
-- gruppi. Da qui in avanti i due concetti si separano:
--
--   - `personal_watchlist` = cio che l utente sta guardando/lui solo. Nessun
--     gruppo, nessuna condivisione: e la sezione della barra in basso.
--   - `public.watchlists`    = la lista CONDIVISA di un gruppo ("consigliata
--     da tutti"), dove ogni riga e un anime che un membro ha messo nel gruppo.
--
-- Struttura e vincoli ricalcano `watchlists` (stessi stati, stesso controllo
-- sull episodio) cosi il client puo riusare modello e controlli.
--
-- Nessuna migrazione dei dati: si parte da una lista personale vuota. Le voci
-- gia presenti nei gruppi restano dove sono.
-- ============================================================================

create table public.personal_watchlist (
  id       uuid primary key default gen_random_uuid(),

  -- Personale: l unico legame e con l utente, mai con un gruppo.
  user_id  uuid not null references public.profiles (id) on delete cascade,
  anime_id uuid not null references public.anime    (id) on delete cascade,

  status          public.watchlist_status not null default 'planned',
  current_episode integer not null default 0,
  is_favorite     boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Un anime compare una volta sola nella lista personale.
  constraint personal_watchlist_unique unique (user_id, anime_id),
  constraint personal_watchlist_episode_positive check (current_episode >= 0)
);

create index personal_watchlist_user_status_idx on public.personal_watchlist (user_id, status);
create index personal_watchlist_favorites_idx    on public.personal_watchlist (user_id) where is_favorite;
create index personal_watchlist_anime_idx        on public.personal_watchlist (anime_id);

comment on table public.personal_watchlist is
  'Watchlist personale dell utente, indipendente dai gruppi: stato, episodio corrente, preferito.';

create trigger personal_watchlist_set_updated_at
  before update on public.personal_watchlist
  for each row execute function public.set_updated_at();

-- Stesso controllo episodio/anime di `watchlists`: riuso della funzione.
-- Un trigger la puo invocare anche se EXECUTE e revocato ai ruoli (il
-- database non controlla il privilegio sui trigger function).
create trigger personal_watchlist_check_episode
  before insert or update on public.personal_watchlist
  for each row execute function public.check_watchlist_episode();

-- ---------------------------------------------------------------------------
-- RLS: strettamente personale. Nessun altro utente legge queste righe.
-- ============================================================================
alter table public.personal_watchlist enable row level security;

create policy "personal_watchlist: lettura delle proprie"
  on public.personal_watchlist for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy "personal_watchlist: inserimento delle proprie"
  on public.personal_watchlist for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "personal_watchlist: modifica delle proprie"
  on public.personal_watchlist for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "personal_watchlist: rimozione delle proprie"
  on public.personal_watchlist for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- Difesa in profondita: anon non deve poter toccare la tabella nemmeno se in
-- futuro comparisse una policy per sbaglio. `authenticated` mantiene i grant
-- di default (RLS limita comunque alle proprie righe).
revoke all on public.personal_watchlist from anon;
