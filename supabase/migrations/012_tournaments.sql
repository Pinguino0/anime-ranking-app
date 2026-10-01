-- ============================================================================
-- 012 — tournaments (bracket a eliminazione diretta)
-- ============================================================================
-- Il bracket viene GENERATO INTERAMENTE all'inizio: tutte le partite di tutti
-- i roundi nascono insieme, con gli anime gia' assegnati solo al primo
-- turno. Questo rende il tabellone disegnabile subito nell'app e la
-- logica di avanzamento deterministica, senza dover creare partite "al volo".
--
-- Cablaggio dei round: la partita m del round r va nella partita
-- (m+1)/2 del round r+1, nel posto a se m e dispari, b se m e pari.
-- ============================================================================

create type public.tournament_status as enum ('setup', 'ongoing', 'completed');
create type public.match_status    as enum ('pending', 'finished');

-- ---------------------------------------------------------------------------
-- tournaments
-- ---------------------------------------------------------------------------
create table public.tournaments (
  id             uuid primary key default gen_random_uuid(),
  group_id       uuid not null references public.groups (id) on delete cascade,
  name           text not null,
  status         public.tournament_status not null default 'ongoing',
  created_by     uuid not null references public.profiles (id) on delete cascade,

  -- 2, 4, 8 o 16. Potenza di due perche il bracket e a eliminazione diretta.
  bracket_size   integer not null,
  champion_anime_id uuid references public.anime (id) on delete set null,

  created_at     timestamptz not null default now(),
  started_at     timestamptz,
  completed_at   timestamptz,

  constraint tournaments_name_length check (char_length(btrim(name)) between 1 and 60),
  constraint tournaments_bracket_size check (bracket_size in (2, 4, 8, 16)),
  constraint tournaments_completion_consistent check (
    (status = 'completed' and champion_anime_id is not null and completed_at is not null)
    or (status <> 'completed' and champion_anime_id is null and completed_at is null)
  )
);

create index tournaments_group_idx on public.tournaments (group_id, created_at desc);
create index tournaments_status_idx on public.tournaments (group_id, status);

comment on table public.tournaments is
  'Torneo a eliminazione diretta fra anime, dentro un gruppo.';

-- ---------------------------------------------------------------------------
-- tournament_participants: chi parte e chi e stato eliminato
-- ---------------------------------------------------------------------------
create table public.tournament_participants (
  tournament_id uuid not null references public.tournaments (id) on delete cascade,
  anime_id      uuid not null references public.anime (id) on delete cascade,
  seed          integer not null,
  eliminated_at timestamptz,
  -- Chi vince le partite, finche la competizione non finisce.
  is_out        boolean not null default true,

  primary key (tournament_id, anime_id)
);

create index tournament_participants_anime_idx on public.tournament_participants (anime_id);

-- ---------------------------------------------------------------------------
-- tournament_matches
-- ---------------------------------------------------------------------------
create table public.tournament_matches (
  id             uuid primary key default gen_random_uuid(),
  tournament_id  uuid not null references public.tournaments (id) on delete cascade,

  -- 1 = primo turno. In un bracket da 8: 4 partite al round 1, 2 al 2, 1 al 3.
  round_number   integer not null,
  match_number   integer not null,

  anime_a_id     uuid references public.anime (id) on delete cascade,
  anime_b_id     uuid references public.anime (id) on delete cascade,
  winner_anime_id uuid references public.anime (id) on delete set null,

  status         public.match_status not null default 'pending',

  -- Dove finisce il vincitore: partita e slot del turno successivo.
  next_match_id  uuid references public.tournament_matches (id) on delete set null,
  next_slot      integer check (next_slot in (1, 2)),

  finished_at    timestamptz,

  constraint tournament_matches_unique unique (tournament_id, round_number, match_number),
  constraint tournament_matches_distinct_animes check (
    anime_a_id is null or anime_b_id is null or anime_a_id <> anime_b_id
  ),
  -- Finita significa: c'e un vincitore, ed e uno dei due partecipanti.
  constraint tournament_matches_finished_consistent check (
    (status = 'pending' and winner_anime_id is null and finished_at is null)
    or (
      status = 'finished'
      and winner_anime_id is not null
      and finished_at is not null
      and winner_anime_id in (anime_a_id, anime_b_id)
    )
  )
);

create index tournament_matches_tournament_idx
  on public.tournament_matches (tournament_id, round_number, match_number);
create index tournament_matches_pending_idx
  on public.tournament_matches (tournament_id) where status = 'pending';

-- ---------------------------------------------------------------------------
-- tournament_votes
-- ---------------------------------------------------------------------------
create table public.tournament_votes (
  match_id     uuid not null references public.tournament_matches (id) on delete cascade,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  anime_id     uuid not null references public.anime (id) on delete cascade,
  created_at   timestamptz not null default now(),

  -- Un voto per membro per partita: ripetere non conta niente.
  constraint tournament_votes_unique unique (match_id, user_id)
);

create index tournament_votes_match_idx on public.tournament_votes (match_id);

comment on table public.tournament_votes is
  'Voti di ogni membro su ogni scontro. Vince chi ne raccoglie di piu.';

-- ---------------------------------------------------------------------------
-- RLS (le funzioni di creazione/voto vengono dopo: il bracket si crea
-- solo tramite RPC, mai con insert diretti)
-- ---------------------------------------------------------------------------
alter table public.tournaments            enable row level security;
alter table public.tournament_participants enable row level security;
alter table public.tournament_matches      enable row level security;
alter table public.tournament_votes        enable row level security;

create policy "tournaments: lettura ai membri"
  on public.tournaments for select
  to authenticated
  using (public.is_group_member(group_id));

create policy "tournament_participants: lettura ai membri"
  on public.tournament_participants for select
  to authenticated
  using (exists (
    select 1 from public.tournaments t
     where t.id = tournament_id and public.is_group_member(t.group_id)
  ));

create policy "tournament_matches: lettura ai membri"
  on public.tournament_matches for select
  to authenticated
  using (exists (
    select 1 from public.tournaments t
     where t.id = tournament_id and public.is_group_member(t.group_id)
  ));

create policy "tournament_votes: lettura ai membri"
  on public.tournament_votes for select
  to authenticated
  using (exists (
    select 1 from public.tournament_matches m
      join public.tournaments t on t.id = m.tournament_id
     where m.id = match_id and public.is_group_member(t.group_id)
  ));

-- Nessuna policy di scrittura: tutto passa dalle RPC controllate.
-- Gli admin possono cancellare un torneo (via RPC delete_tournament in 015).

-- ---------------------------------------------------------------------------
-- Creazione del torneo + generazione del bracket
-- ---------------------------------------------------------------------------
create or replace function public.create_tournament(
  _group_id  uuid,
  _name      text,
  _anime_ids uuid[]
)
returns public.tournaments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tournament public.tournaments;
  v_size       integer;
  v_matches    integer;
  v_round      integer;
  v_rounds     integer;
  v_i          integer;
  v_match_ids  uuid[];
  v_next_ids   uuid[];
begin
  if not public.is_group_member(_group_id) then
    raise exception 'Permessi insufficienti' using errcode = '42501';
  end if;

  v_size := coalesce(array_length(_anime_ids, 1), 0);

  -- Potenza di due tra 2 e 16: senza questa verifica il bracket non si chiude.
  if v_size not in (2, 4, 8, 16) then
    raise exception 'Il numero di anime deve essere 2, 4, 8 o 16 (non %)', v_size
      using errcode = '22023';
  end if;

  if (select count(distinct x)::int from unnest(_anime_ids) as x) <> v_size then
    raise exception 'Nella lista ci sono anime duplicati' using errcode = '22023';
  end if;

  insert into public.tournaments
    (group_id, name, status, created_by, bracket_size, started_at)
  values (_group_id, btrim(_name), 'ongoing', (select auth.uid()), v_size, now())
  returning * into v_tournament;

  insert into public.tournament_participants (tournament_id, anime_id, seed)
  select v_tournament.id, x, i
    from unnest(_anime_ids) with ordinality as u(x, i);

  -- Numero di round: log2(size). 2->1, 4->2, 8->3, 16->4.
  v_rounds := 1;
  while (2::integer ^ v_rounds) < v_size loop
    v_rounds := v_rounds + 1;
  end loop;

  -- Genera i turni dal fondo verso l'inizio, cosi quando creo il turno N
  -- posso subito agganciare next_match_id del turno N-1, appena creato.
  v_next_ids := null;

  -- NB: "reverse a..b" parte da 'a' e scende verso 'b', quindi il primo
  -- numero e' quello da cui si parte. Scrivere "reverse 1..v_rounds" non
  -- eseguirebbe nessuna iterazione (1 e' gia' il minimo): il bracket
  -- resterebbe vuoto senza alcun errore. Da qui "reverse v_rounds..1".
  for v_round in reverse v_rounds..1 loop

    -- 2 ^ v_round restituisce double precision, quindi il cast a integer
    -- e' necessario per non perdere il valore.
    v_matches := (v_size / (2 ^ v_round))::integer;

    -- Gli id vengono generati PRIMA dell'insert, non raccolti con
    -- "returning id into v_match_ids": in PL/pgSQL RETURNING ... INTO non
    -- colleziona piu' righe in un array, assegna il primo valore e lo
    -- coercia al tipo della variabile (un uuid forzato a uuid[] fallisce con
    -- "malformed array literal"). Avendo gli id in mano si aggancia anche
    -- next_match_id senza dover rileggere nulla.
    v_match_ids := array(
      select gen_random_uuid() from generate_series(1, v_matches)
    );

    insert into public.tournament_matches (id, tournament_id, round_number, match_number)
    select m.id, v_tournament.id, v_round, m.ord
      from unnest(v_match_ids) with ordinality as m(id, ord);

    -- Aggancio al turno successivo: due scontri del turno corrente vanno
    -- nello stesso scontro del turno dopo (1 e 2 insieme, 3 e 4 insieme...).
    -- next_slot dice in quale dei due posti finira' il vincitore.
    if v_next_ids is not null then
      update public.tournament_matches m
         set next_match_id = v_next_ids[((m.match_number - 1) / 2) + 1],
             next_slot     = case when m.match_number % 2 = 1 then 1 else 2 end
       where m.id = any (v_match_ids);
    end if;

    -- Solo al primo turno si assegnano gli anime: i turni successivi si
    -- popolano da soli con i vincitori.
    if v_round = 1 then
      update public.tournament_matches m
         set anime_a_id = _anime_ids[(m.match_number - 1) * 2 + 1],
             anime_b_id = _anime_ids[m.match_number * 2]
       where m.id = any (v_match_ids);
    end if;

    v_next_ids := v_match_ids;
  end loop;

  perform public.log_activity(
    _group_id, (select auth.uid()), 'tournament_created', null,
    jsonb_build_object('tournament_id', v_tournament.id, 'name', v_tournament.name)
  );

  perform public.notify_user(
    u.user_id, 'tournament_created',
    'Nuovo torneo!',
    (select username from public.profiles where id = (select auth.uid()))
      || ' ha lanciato il torneo ' || v_tournament.name,
    jsonb_build_object('tournament_id', v_tournament.id, 'group_id', _group_id),
    false
  ) from (
    select user_id from public.group_members
     where group_id = _group_id and user_id <> (select auth.uid())
  ) u;

  return v_tournament;
end;
$$;

-- ---------------------------------------------------------------------------
-- Risoluzione di una partita e avanzamento nel bracket
-- ---------------------------------------------------------------------------
-- Vince chi ha piu' voti. Parita risolta in tre passi deterministici:
--   1. numero di voti
--   2. media del gruppo sull'anime (stesso criterio del ranking, sezione 7)
--   3. anime_id ascendente -- arbitrario ma sempre uguale,
--      cosi due dispositivi non mostrano risultati diversi
-- ---------------------------------------------------------------------------
create or replace function public.resolve_tournament_match(_match_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_match      public.tournament_matches;
  v_tournament public.tournaments;
  v_members    integer;
  v_cast       integer;
  v_winner     uuid;
  v_progressed boolean := false;
  v_next       public.tournament_matches;
begin
  select * into v_match from public.tournament_matches where id = _match_id for update;
  if v_match.id is null or v_match.status = 'finished' then
    return false;
  end if;

  -- Servono entrambi i partecipanti prima di poter votare.
  if v_match.anime_a_id is null or v_match.anime_b_id is null then
    return false;
  end if;

  select * into v_tournament from public.tournaments where id = v_match.tournament_id;

  select count(*)::integer into v_members
    from public.group_members where group_id = v_tournament.group_id;

  select count(*)::integer into v_cast
    from public.tournament_votes where match_id = _match_id;

  -- La partita si chiude solo quando hanno votato tutti i membri del gruppo.
  if v_cast < v_members then
    return false;
  end if;

  -- L'alias 'v' vale solo dentro la sua subquery: fuori si usa 't'.
  -- A parita' di voti si sceglie l'anime con la media piu alta nel gruppo,
  -- e come ultimo criterio l'id, cosi' il risultato e' deterministico.
  select t.anime_id into v_winner
    from (
      select v.anime_id,
             count(*)::int as votes,
             coalesce((
               select avg(r.score) from public.ratings r
                where r.group_id = v_tournament.group_id and r.anime_id = v.anime_id
             ), 0) as group_avg
        from public.tournament_votes v
       where v.match_id = _match_id
       group by v.anime_id
    ) t
   order by t.votes desc, t.group_avg desc, t.anime_id asc
   limit 1;

  if v_winner is null then
    return false;
  end if;

  update public.tournament_matches
     set winner_anime_id = v_winner,
         status = 'finished',
         finished_at = now()
   where id = _match_id;

  update public.tournament_participants
     set is_out = false, eliminated_at = null
   where tournament_id = v_tournament.id and anime_id = v_winner;

  update public.tournament_participants
     set is_out = true, eliminated_at = coalesce(eliminated_at, now())
   where tournament_id = v_tournament.id and anime_id in (v_match.anime_a_id, v_match.anime_b_id)
     and anime_id <> v_winner;

  v_progressed := true;

  -- Avanza il vincitore al turno successivo e tenta di chiudere anche li
  -- scontri a valle. Il loop serve per la finale: chiudere la semifinale
  -- puo riempire la finale, che a sua volta puo essere gia votata.
  while v_match.next_match_id is not null loop
    if v_match.next_slot = 1 then
      update public.tournament_matches set anime_a_id = v_winner where id = v_match.next_match_id;
    else
      update public.tournament_matches set anime_b_id = v_winner where id = v_match.next_match_id;
    end if;

    select * into v_next from public.tournament_matches where id = v_match.next_match_id;

    if v_next.anime_a_id is not null and v_next.anime_b_id is not null then
      if public.resolve_tournament_match(v_next.id) then
        v_match := v_next;
        continue;
      end if;
    end if;

    exit;
  end loop;

  -- Ultima partita del bracket? Allora il torneo e finito.
  if v_match.next_match_id is null
     and not exists (
       select 1 from public.tournament_matches
        where tournament_id = v_tournament.id and status = 'pending'
     )
  then
    update public.tournaments
       set status = 'completed',
           champion_anime_id = v_winner,
           completed_at = now()
     where id = v_tournament.id;

    perform public.log_activity(
      v_tournament.group_id, v_tournament.created_by, 'tournament_finished', v_winner,
      jsonb_build_object(
        'tournament_id', v_tournament.id,
        'champion_anime_id', v_winner
      )
    );

    -- Rivaluta gli achievement dei partecipanti: l'sblocco dipende dal fatto
    -- che il torneo sia arrivato alla finale, che solo ora e noto.
    perform public.evaluate_achievements(v.user_id)
      from public.group_members v
     where v.group_id = v_tournament.group_id;
  end if;

  return v_progressed;
end;
$$;

-- ---------------------------------------------------------------------------
-- Voto su uno scontro
-- ---------------------------------------------------------------------------
create or replace function public.cast_tournament_vote(
  _match_id uuid,
  _anime_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_match public.tournament_matches;
  v_tour  public.tournaments;
  v_uid   uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'Autenticazione richiesta' using errcode = '28000';
  end if;

  select * into v_match from public.tournament_matches where id = _match_id;
  select * into v_tour  from public.tournaments where id = v_match.tournament_id;

  if v_tour.id is null then
    raise exception 'Scontro non trovato' using errcode = 'P0002';
  end if;

  if not public.is_group_member(v_tour.group_id) then
    raise exception 'Permessi insufficienti' using errcode = '42501';
  end if;

  if v_tour.status <> 'ongoing' then
    raise exception 'Il torneo non e in corso' using errcode = '22023';
  end if;

  if v_match.status <> 'pending' then
    raise exception 'Questo scontro e gia finito' using errcode = '22023';
  end if;

  if _anime_id not in (v_match.anime_a_id, v_match.anime_b_id) then
    raise exception 'Questo anime non partecipa allo scontro' using errcode = '22023';
  end if;

  -- Cambiare idea e' consentito finche lo scontro non e chiuso:
  -- on conflict aggiorna il voto precedente.
  insert into public.tournament_votes (match_id, user_id, anime_id)
  values (_match_id, v_uid, _anime_id)
  on conflict (match_id, user_id)
  do update set anime_id = excluded.anime_id, created_at = now();

  perform public.log_activity(
    v_tour.group_id, v_uid, 'tournament_vote', _anime_id,
    jsonb_build_object('tournament_id', v_tour.id, 'match_id', _match_id)
  );

  return public.resolve_tournament_match(_match_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Esito delle partite aperte (il client lo chiama all'apertura del tabellone)
-- ---------------------------------------------------------------------------
create or replace function public.tournament_standings(_tournament_id uuid)
returns table (
  anime_id      uuid,
  title         text,
  image_url     text,
  is_out        boolean,
  matches_won   bigint,
  votes_received bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.anime_id,
    a.title,
    a.image_url,
    p.is_out,
    (select count(*) from public.tournament_matches m
      where m.winner_anime_id = p.anime_id) as matches_won,
    (select count(*) from public.tournament_votes v
       join public.tournament_matches m2 on m2.id = v.match_id
      where m2.tournament_id = p.tournament_id and v.anime_id = p.anime_id) as votes_received
  from public.tournament_participants p
  join public.anime a on a.id = p.anime_id
 where p.tournament_id = _tournament_id
   and exists (
     select 1 from public.tournaments t
      where t.id = p.tournament_id and public.is_group_member(t.group_id)
   )
 order by p.is_out, matches_won desc, votes_received desc, a.title;
$$;

revoke all on function public.resolve_tournament_match(uuid) from public;
revoke all on function public.create_tournament(uuid, text, uuid[]) from public;
revoke all on function public.cast_tournament_vote(uuid, uuid) from public;
revoke all on function public.tournament_standings(uuid) from public;

grant execute on function public.create_tournament(uuid, text, uuid[]) to authenticated;
grant execute on function public.cast_tournament_vote(uuid, uuid) to authenticated;
grant execute on function public.tournament_standings(uuid) to authenticated;
