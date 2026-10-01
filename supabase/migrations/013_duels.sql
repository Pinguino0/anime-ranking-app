-- ============================================================================
-- 013 — anime_duel
-- ============================================================================
-- Confronto rapido 1vs1: l'utente sceglie quale dei due anime preferisce.
-- I dati sono di per se anonimi, quindi il gruppo non li vede in modo
-- che possano essere usati per "taggare" chi ha scelto cosa. Il risultato
-- serve principalmente per l'eventuale classifica Elo separata.
-- ============================================================================

create table public.duels (
  id               uuid primary key default gen_random_uuid(),
  group_id         uuid not null references public.groups (id) on delete cascade,
  user_id          uuid not null references public.profiles (id) on delete cascade,
  anime_a_id       uuid not null references public.anime (id) on delete cascade,
  anime_b_id       uuid not null references public.anime (id) on delete cascade,
  selected_anime_id uuid not null references public.anime (id) on delete cascade,

  created_at       timestamptz not null default now(),

  constraint duels_distinct_animes check (anime_a_id <> anime_b_id),
  constraint duels_selected_in_pair check (
    selected_anime_id in (anime_a_id, anime_b_id)
  )
);

-- Per evitare di ripetere all'infinito lo stesso duello verso lo stesso utente:
-- non imposto una UNIQUE, ma l'indice partial impedisce esattamente (a,b)
-- e (b,a) in sequenza troppo ravvicinata. Il client puo decidere di pescare
-- anime mai confrontati.
create index duels_user_group_idx on public.duels (group_id, user_id, created_at desc);
create index duels_pair_idx       on public.duels (anime_a_id, anime_b_id);

comment on table public.duels is
  'Duel anime 1vs1: preferenze rapide. Statistiche per calcolo Elo interno separato dal ranking.';

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.duels enable row level security;

create policy "duels: lettura ai membri del gruppo"
  on public.duels for select
  to authenticated
  using (public.is_group_member(group_id));

-- Ogni membro salva solo i propri duelli. L'utente e obbligato ad essere
-- membro del gruppo e la scelta deve riguardare la coppia proposta.
create policy "duels: inserimento proprio da membro"
  on public.duels for insert
  to authenticated
  with check (
    user_id = (select auth.uid())
    and public.is_group_member(group_id)
  );

-- Nessuna UPDATE: un duello e irreversibile. Nessuna DELETE per utenti.
