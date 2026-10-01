-- ============================================================================
-- 015 â€” account, amministrazione, Elo, storage
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Trasferimento della proprieta del gruppo
-- ---------------------------------------------------------------------------
-- Il prompt non lo chiede esplicitamente, ma senza questo l'owner non puo
-- mai uscire dal gruppo: leave_group() glielo vieta per evitare di lasciare
-- un gruppo orfano. Con il trasferimento il problema si risolve alla radice.
-- ---------------------------------------------------------------------------
create or replace function public.transfer_group_ownership(
  _group_id uuid,
  _new_owner uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_group_owner(_group_id) then
    raise exception 'Solo il owner puo cedere la proprieta' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.group_members
     where group_id = _group_id and user_id = _new_owner
  ) then
    raise exception 'Il nuovo owner deve essere un membro del gruppo'
      using errcode = '23503';
  end if;

  update public.group_members set role = 'owner'
   where group_id = _group_id and user_id = _new_owner;

  update public.group_members set role = 'admin'
   where group_id = _group_id
     and user_id = (select owner_id from public.groups where id = _group_id);

  update public.groups set owner_id = _new_owner where id = _group_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Cancellazione account (punto 53)
-- ---------------------------------------------------------------------------
-- Tutto e collegato con ON DELETE CASCADE a partire da profiles -> auth.users:
-- cancellando l'utente su auth.users spariscono voti, watchlist, commenti,
-- watchlist e notifiche. Nessun record orfano.
--
-- Le righe in activities / ratings di altri utenti che riguardavano questo
-- utente spariscono col cascade: si perde un po' di storico del gruppo, ma
-- l'alternativa (conservare le righe con user_id NULL) mostrerebbe voci
-- incomprensibili nel feed. Delibero, con commento.
--
-- Nota: elimina l'utente su auth.users usando i privilegi del proprietario.
-- Nessun client puo chiamarla per un altro utente: il check e su auth.uid().
-- ---------------------------------------------------------------------------
create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := (select auth.uid());
  v_left integer;
begin
  if v_uid is null then
    raise exception 'Autenticazione richiesta' using errcode = '28000';
  end if;

  -- I file su Supabase Storage NON si possono cancellare da SQL: il trigger
  -- di piattaforma storage.protect_delete() vieta ogni DELETE diretto su
  -- storage.objects, anche da una funzione SECURITY DEFINER. La pulizia va
  -- quindi fatta dal client con la Storage API, che autorizza l'utente per i
  -- propri file, PRIMA di chiamare questa funzione.
  --
  -- Qui si controlla solo che non restino file: la lettura e consentita.
  -- Cosi l'account non viene cancellato lasciando immagini orfane, e il
  -- client ricece un errore actionable invece di un fallimento silenzioso.
  select count(*) into v_left
    from storage.objects
   where bucket_id in ('avatars', 'group-images')
     and (storage.foldername(name))[1] = v_uid::text;

  if v_left > 0 then
    raise exception 'Cancella prima i % file caricati tramite la Storage API', v_left
      using errcode = '22023';
  end if;

  -- Da qui in poi le tabelle si cancellano a cascata. I trigger che scrivono
  -- in activities sono a prova di cascata (vedi public.log_activity in 009),
  -- altrimenti il cascade profiles -> groups -> ratings fallirebbe con 23503.
  delete from auth.users where id = v_uid;
end;
$$;

-- ---------------------------------------------------------------------------
-- Amministrazione: eliminazione di un torneo
-- ---------------------------------------------------------------------------
create or replace function public.delete_tournament(_tournament_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group uuid;
begin
  select group_id into v_group from public.tournaments where id = _tournament_id;

  if v_group is null then
    raise exception 'Torneo non trovato' using errcode = 'P0002';
  end if;

  if not public.is_group_admin(v_group) then
    raise exception 'Permessi insufficienti' using errcode = '42501';
  end if;

  delete from public.tournaments where id = _tournament_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Snapshot giornaliero del ranking (chiamato dalla Edge Function schedulata)
-- ---------------------------------------------------------------------------
-- Va eseguito una volta al giorno PRIMA che il giorno venga ricalcolato:
-- lo snapshot congela la posizione di oggi, cosi domani la variazione si
-- misura contro il dato di ieri.
create or replace function public.take_ranking_snapshot(_group_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.ranking_snapshots
    (group_id, anime_id, snapshot_date, rank_position, ranking_score, mean_score, vote_count)
  select
    _group_id,
    x.anime_id,
    current_date,
    row_number() over (order by x.ranking_score desc, x.mean_score desc, x.vote_count desc),
    x.ranking_score,
    x.mean_score,
    x.vote_count
  from (
    -- NB: count(*) e' bigint, quindi "count(*) / (count(*) + 3)" e' una
    -- divisione INTERA e troncava a zero (2/5 = 0, 3/5 = 0): ranking_score
    -- veniva salvato come 0.000 per ogni anime. Il cast a numeric va fatto
    -- PRIMA della divisione, non sul risultato.
    select
      r.anime_id,
      count(*)::bigint as vote_count,
      avg(r.score)::numeric(5,2) as mean_score,
      round(
        (count(*)::numeric / (count(*)::numeric + 3)) * avg(r.score)
        + (3::numeric / (count(*)::numeric + 3)) * coalesce(
            (select avg(score) from public.ratings where group_id = _group_id), 0)
      , 3) as ranking_score
    from public.ratings r
    where r.group_id = _group_id
    group by r.anime_id
  ) x
  on conflict (group_id, anime_id, snapshot_date) do update
    set rank_position      = excluded.rank_position,
        ranking_score = excluded.ranking_score,
        mean_score    = excluded.mean_score,
        vote_count    = excluded.vote_count;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Elo dei duelli (punto 26)
-- ---------------------------------------------------------------------------
-- Sistema SEPARATO dal ranking basato sui voti. Serve a rispondere a una
-- domanda diversa: "chi dei due mi piace di piu se mi costringi a scegliere".
-- Non sostituisce e non influenza in alcun modo la classifica principale.
--
-- K = 32, punteggio iniziale 1000. L'attesa si calcola con la formula Elo
-- standard; il delta applicato a B e l'opposto di quello applicato ad A,
-- cosi la somma degli Elo resta costante.
--
-- Costo: la ricorsione e lineare sul numero di duelli del gruppo. Per un
-- gruppo di amici (centinaia/poche migliaia di dueli) e irrilevante; se
-- diventasse un problema andrebbe calcolato in una tabella materializzata.
create or replace function public.duel_elo(_group_id uuid)
returns table (
  anime_id   uuid,
  title      text,
  image_url  text,
  elo        numeric,
  duel_count bigint
)
language sql
stable
security definer
set search_path = public
as $$
with recursive
  ord as (
    select
      row_number() over (order by d.created_at, d.id) as n,
      d.anime_a_id, d.anime_b_id, d.selected_anime_id
    from public.duels d
    where d.group_id = _group_id
  ),
  -- Lo stato e' una mappa anime_id -> Elo di TUTTI gli anime gia' incontrati.
  -- La versione precedente portava in avanti solo i due contendenti del
  -- duello precedente: gli anime che non combaciavano con l'ultimo duello
  -- ripartivano da 1000 e, soprattutto, i due Elo del passo precedente
  -- finivano per essere entrambi lo stesso numero (i due "case when" si
  -- scambiavano a vicenda). Con tre duelli Naruto/Bleach si trovavano a
  -- 1048/1032 cioe' sempre +16 a ogni passo, e Death Note risorgeva a 1016
  -- dopo aver perso. Ora ogni passo legge e aggiorna la mappa completa.
  walk (n, state) as (
    -- Caso base: n = 0, nessun duello ancora giocato, stato vuoto.
    -- NB: la base deve essere 0, non 1. Con la base a 1 la ricorsione
    -- "o.n = w.n + 1" applicava il duello 2 su uno stato ancora vuoto e il
    -- duello 1 non veniva mai calcolato: ogni anime si fermava al primo
    -- risultato e i punteggi non dipendevano dall'ordine reale dei duelli.
    select 0::bigint, '{}'::jsonb

    union all

    select
      o.n,
      w.state || jsonb_build_object(
        -- L'attesa di a si calcola con l'Elo di b e viceversa.
        o.anime_a_id::text,
          cur.ea + 32 * (
            (case when o.anime_a_id = o.selected_anime_id then 1 else 0 end)
            - 1 / (1 + power(10, (cur.eb - cur.ea) / 400.0))
          ),
        o.anime_b_id::text,
          cur.eb + 32 * (
            (case when o.anime_b_id = o.selected_anime_id then 1 else 0 end)
            - 1 / (1 + power(10, (cur.ea - cur.eb) / 400.0))
          )
      )
    from walk w
    join ord o on o.n = w.n + 1
    cross join lateral (
      -- Elo corrente dei due contendenti: se non sono mai apparsi valgono 1000.
      select
        coalesce((w.state ->> o.anime_a_id::text)::numeric, 1000) as ea,
        coalesce((w.state ->> o.anime_b_id::text)::numeric, 1000) as eb
    ) cur
  ),
  last_state as (
    -- Lo stato finale e' quello dell'ultimo passo: contiene gia' gli Elo
    -- aggiornati dopo l'ultimo duello. Va isolato PRIMA di aprire il jsonb:
    -- mettere il limit 1 insieme a jsonb_each_text restituirebbe una sola
    -- coppia chiave/valore invece di tutto lo stato.
    select state
      from walk
     order by n desc
     limit 1
  ),
  final_state as (
    select (e.key)::uuid as anime_id, (e.value)::numeric as elo
      from last_state ls,
           lateral jsonb_each_text(ls.state) e
  ),
  participation as (
    select anime_id, count(*)::bigint as cnt
    from (
      select anime_a_id as anime_id from public.duels where group_id = _group_id
      union all
      select anime_b_id from public.duels where group_id = _group_id
    ) c
    group by anime_id
  )
  select
    f.anime_id,
    a.title,
    a.image_url,
    round(f.elo, 0) as elo,
    p.cnt
  from final_state f
  join public.anime a on a.id = f.anime_id
  join participation p on p.anime_id = f.anime_id
  where public.is_group_member(_group_id)
  order by f.elo desc, f.anime_id
  limit 100;
$$;

-- ---------------------------------------------------------------------------
-- Prossimo duello: due anime mai messi faccia a faccia da questo utente
-- ---------------------------------------------------------------------------
-- Esclude le coppie gia' incontrate, cosi l'utente non si ritrova sempre
-- davanti allo stesso duello. Se non c'e piu' nulla di nuovo, il fallback
-- restituisce comunque una coppia casuale fra i piu' votati.
create or replace function public.next_duel_pair(_group_id uuid)
returns table (anime_a_id uuid, anime_b_id uuid, title_a text, title_b text, image_a text, image_b text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_a    uuid;
  v_b    uuid;
  v_pair uuid[];
begin
  if not public.is_group_member(_group_id) then
    raise exception 'Permessi insufficienti' using errcode = '42501';
  end if;

  select a.id, b.id into v_a, v_b
  from (
    select distinct r.anime_id as id
      from public.ratings r
     where r.group_id = _group_id
     limit 60
  ) a
  cross join lateral (
    -- NB: niente "distinct" qui. Con DISTINCT l'ORDER BY deve comparire
    -- nella select list, quindi "order by random()" fallirebbe con 42P10.
    -- I duplicati sono innocui: "limit 1" restituisce comunque una riga sola.
    select r.anime_id as id
      from public.ratings r
     where r.group_id = _group_id
       and r.anime_id <> a.id
       and not exists (
         select 1 from public.duels d
          where d.group_id = _group_id
            and d.user_id  = v_uid
            and (d.anime_a_id, d.anime_b_id) in ((a.id, r.anime_id), (r.anime_id, a.id))
       )
     order by random()
     limit 1
  ) b
  limit 1;

  if v_a is null then
    -- Fallback: non c'e nessuna coppia nuova, prendi i due piu' votati.
    select array_agg(id) into v_pair
    from (
      select r.anime_id as id
        from public.ratings r
       where r.group_id = _group_id
       group by r.anime_id
       order by count(*) desc
       limit 2
    ) t;
    v_a := v_pair[1];
    v_b := v_pair[2];
  end if;

  return query
  select a.id, b.id, a.title, b.title, a.image_url, b.image_url
    from public.anime a, public.anime b
   where a.id = v_a and b.id = v_b;
end;
$$;

-- ---------------------------------------------------------------------------
-- Storage: bucket per avatar e immagini dei gruppi
-- ---------------------------------------------------------------------------
-- Limiti deliberatamente stretti. Senza allowed_mime_types un utente
-- potrebbe caricare .html o .svg con script dentro, che alcuni visualizzatori
-- aprono come pagine. Solo i tre formati immagine necessari.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars',      'avatars',      true,  2097152, array['image/jpeg','image/png','image/webp']),
  ('group-images', 'group-images', true,  5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- NB: "comment on bucket" non e' sintassi PostgreSQL (esiste in altri
-- dialetti come Snowflake). La documentazione del bucket va tenuta qui.
-- avatars: percorso obbligatorio {user_id}/{filename}.

-- Un utente puo scrivere solo nella propria cartella e solo se il nome del
-- file inizia con il proprio id: senza questo controllo potrebbe sovrascrivere
-- l'avatar di un amico.
create policy "avatars: lettura pubblica"
  on storage.objects for select
  to public
  using (bucket_id in ('avatars', 'group-images'));

create policy "avatars: upload nella propria cartella"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id in ('avatars', 'group-images')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "avatars: modifica nella propria cartella"
  on storage.objects for update
  to authenticated
  using (
    bucket_id in ('avatars', 'group-images')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "avatars: eliminazione nella propria cartella"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id in ('avatars', 'group-images')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- ---------------------------------------------------------------------------
-- Permessi finali
-- ---------------------------------------------------------------------------
revoke all on function public.transfer_group_ownership(uuid, uuid) from public;
revoke all on function public.delete_own_account()                    from public;
revoke all on function public.delete_tournament(uuid)                   from public;
revoke all on function public.take_ranking_snapshot(uuid)              from public;
revoke all on function public.duel_elo(uuid)                           from public;
revoke all on function public.next_duel_pair(uuid)                     from public;

grant execute on function public.transfer_group_ownership(uuid, uuid) to authenticated;
grant execute on function public.delete_own_account()                   to authenticated;
grant execute on function public.delete_tournament(uuid)                to authenticated;
grant execute on function public.duel_elo(uuid)                        to authenticated;
grant execute on function public.next_duel_pair(uuid)                  to authenticated;

-- take_ranking_snapshot NON e concesso ad authenticated: la chiama solo la
-- Edge Function schedulata con service_role.
