-- ============================================================================
-- 006 — ratings (il sistema di voto)
-- ============================================================================
-- Un utente puo votare lo stesso anime UNA volta per gruppo.
-- La UNIQUE (group_id, user_id, anime_id) lo garantisce a livello di
-- database: due richieste simultanee da due device dello stesso utente
-- producono un solo voto, non due righe.
--
-- Solo score (voto generale) entra nel ranking. Gli altri sei voti sono
-- facoltativi e puramente descrittivi (sezione 8 del prompt).
-- ============================================================================

create table public.ratings (
  id         uuid primary key default gen_random_uuid(),

  group_id   uuid not null references public.groups (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  anime_id   uuid not null references public.anime   (id) on delete cascade,

  -- Voto generale: 0..10 step 0.5. E' questo il valore del ranking.
  score            numeric(3,1) not null,

  -- Voti secondari facoltativi, stessa scala.
  story_score      numeric(3,1),
  character_score  numeric(3,1),
  animation_score  numeric(3,1),
  fights_score     numeric(3,1),
  soundtrack_score numeric(3,1),
  fun_score        numeric(3,1),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint ratings_one_per_anime_per_group unique (group_id, user_id, anime_id),
  constraint ratings_score_valid      check (public.is_valid_rating(score)),
  constraint ratings_story_valid      check (story_score      is null or public.is_valid_rating(story_score)),
  constraint ratings_character_valid  check (character_score  is null or public.is_valid_rating(character_score)),
  constraint ratings_animation_valid  check (animation_score  is null or public.is_valid_rating(animation_score)),
  constraint ratings_fights_valid     check (fights_score     is null or public.is_valid_rating(fights_score)),
  constraint ratings_soundtrack_valid check (soundtrack_score is null or public.is_valid_rating(soundtrack_score)),
  constraint ratings_fun_valid        check (fun_score        is null or public.is_valid_rating(fun_score))
);

-- Ranking: per gruppo, ordinato per punteggio pesato. Calcolato in 013.
create index ratings_group_score_idx  on public.ratings (group_id, score desc);
create index ratings_user_idx         on public.ratings (user_id, score desc);
create index ratings_anime_idx        on public.ratings (anime_id);
-- Indice parziale: il calcolo della media guarda solo le righe votate,
-- quindi il rating medio di un anime non viene falsato da righe NULL.
create index ratings_group_anime_idx  on public.ratings (group_id, anime_id);

comment on table public.ratings is
  'Voti. score = voto generale (0..10 step 0.5, unico valore usato nel ranking). '
  'Gli altri campi sono facoltativi e non influenzano la classifica.';

create trigger ratings_set_updated_at
  before update on public.ratings
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS: i voti sono dati PRIVATI del gruppo.
-- Un utente non membro deve ricevere zero righe, non una lista filtrata.
-- ---------------------------------------------------------------------------
alter table public.ratings enable row level security;

create policy "ratings: lettura ai membri del gruppo"
  on public.ratings for select
  to authenticated
  using (public.is_group_member(group_id));

-- Solo i membri votano, e solo per se stessi.
-- Il check is_group_member() in WITH CHECK e indispensabile: da solo
-- verificherebbe solo che group_id sia valorizzato.
create policy "ratings: inserimento proprio da membro"
  on public.ratings for insert
  to authenticated
  with check (
    user_id = (select auth.uid())
    and public.is_group_member(group_id)
  );

-- Modifica: solo la propria riga. Il WITH CHECK impedisce di "spostare" il
-- proprio voto verso un altro utente o verso un gruppo di cui non si e membri.
create policy "ratings: modifica propria"
  on public.ratings for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- Cancellazione: il proprio voto, oppure rimozione forzata dall'admin del gruppo.
create policy "ratings: eliminazione propria o da admin"
  on public.ratings for delete
  to authenticated
  using (
    user_id = (select auth.uid())
    or public.is_group_admin(group_id)
  );
