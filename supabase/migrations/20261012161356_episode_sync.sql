-- ============================================================================
-- episode_sync - il telefono tiene gli episodi allineati al provider
-- ============================================================================
-- Il problema: la pipeline di scoperta (harvest) riconosce gli ANIME nuovi, ma
-- nessuno rilegge il conteggio delle puntate di un anime gia' in catalogo. Un
-- anime in corso resta fermo all'episodio con cui e' entrato.
--
-- La soluzione: invece di un job sul server, e' l'app a rileggere il provider
-- quando la si apre. Non e' un capriccio — AnimeUnity sta dietro Cloudflare e
-- risponde 403 a un IP di datacenter, mentre accetta quello residenziale del
-- telefono. L'app ha gia' tutti i pezzi per parlarci (animeunity_extractor).
--
-- Qui vivono le due funzioni che il telefono chiama:
--
--   1. `anime_episode_ref`    -> "per questo anime, a quale record del provider
--                                devo chiedere il conteggio?"
--   2. `sync_anime_episodes`  -> "il conteggio vero e' N: allinea il catalogo"
--                                (e avvisa chi segue l'anime)
--
-- Il passaggio dal client e non dal DB e' voluto: quale sia il record giusto e
-- quante puntate abbia lo sa AnimeUnity, non il database. Il DB si fida del
-- numero solo entro limiti stretti (cresce, non cala; tetto di sicurezza) e
-- solo per anime che hanno davvero un mapping — non si puo' inventare un anime
-- e riempirlo di episodi.
-- ============================================================================

-- 1) il riferimento provider per un anime ------------------------------------
-- Il client lo usa per costruire la richiesta verso AnimeUnity. Si preferisce
-- la versione sub (is_dub = false): il doppiaggio e' indietro di mesi, e
-- "quanti episodi ci sono" e' la domanda sulla versione originale.
create or replace function public.anime_episode_ref(_anime_id uuid)
returns table (
  provider_slug     text,
  provider_anime_id text,
  canonical_url     text,
  episodes_count    integer,
  is_dub            boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    m.provider_slug,
    m.provider_anime_id,
    case m.provider_slug
      when 'mio_provider' then 'https://www.animeunity.so/anime/' || m.provider_anime_id || '-x'
      else null
    end as canonical_url,
    i.episodes_count,
    m.is_dub
  from public.anime_provider_mappings m
  join public.provider_anime_index i
    on i.provider_slug = m.provider_slug
   and i.provider_anime_id = m.provider_anime_id
  where m.anime_id = _anime_id
    and m.provider_slug = 'mio_provider'
  order by m.is_dub, i.episodes_count desc nulls last
  limit 1;
$$;

comment on function public.anime_episode_ref(uuid) is
  'Il record provider (e l''URL canonico) da cui chiedere il conteggio episodi di un anime.';

revoke all on function public.anime_episode_ref(uuid) from public, anon;
grant execute on function public.anime_episode_ref(uuid) to authenticated;

-- 2) allineamento del conteggio ---------------------------------------------
-- Additiva: non cancella niente e non riscrive gli episodi che ci sono gia'.
-- Le fonti AnimeUnity restano (a differenza del vecchio seed, che le cancellava
-- e ricreava in blocco): qui si aggiungono solo quelle mancanti.
create or replace function public.sync_anime_episodes(
  _anime_id          uuid,
  _provider_slug     text,
  _provider_anime_id text,
  _episodes_count    integer
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Tetto di sicurezza sul numero di episodi (One Piece e' a ~1180): protegge
  -- da un conteggio sbagliato e da una richiesta costruita a mano.
  v_cap constant integer := 2000;

  v_target   integer;
  v_previous integer;
  v_added    integer := 0;
  v_new_max  integer := 0;
  v_title    text;
  v_provider uuid;
  v_mapping  record;
  v_tracker  record;
begin
  if _anime_id is null or _episodes_count is null or _episodes_count < 0 then
    return 0;
  end if;
  v_target := least(_episodes_count, v_cap);

  -- Si sincronizza solo un anime che ha davvero un mapping verso QUEL record
  -- provider: senza questo, chiunque potrebbe inventare episodi per un anime a
  -- caso. Il client riceve il record dalla lettura (anime_episode_ref), quindi
  -- per il flusso normale e' sempre vero.
  if not exists (
    select 1
      from public.anime_provider_mappings m
     where m.anime_id = _anime_id
       and m.provider_slug = _provider_slug
       and m.provider_anime_id = _provider_anime_id
  ) then
    return 0;
  end if;

  -- Ultimo episodio noto PRIMA di questo giro: dice cosa e' nuovo e, se era
  -- zero, che non e' "un episodio nuovo" ma la prima comparsa dell'anime.
  select coalesce(max(episode_num), 0)
    into v_previous
    from public.episodes
   where anime_id = _anime_id;

  -- Il conteggio sale: sub e dub possono disallinearsi e un client non deve
  -- poter far sparire episodi gia' presenti.
  update public.provider_anime_index
     set episodes_count = greatest(coalesce(episodes_count, 0), v_target)
   where provider_slug = _provider_slug
     and provider_anime_id = _provider_anime_id;

  -- Episodi nuovi (solo quelli oltre l'ultimo noto). Il `returning` dice
  -- quanti ne sono entrati davvero e il massimo e' quello da annunciare:
  -- contare le righe di generate_series sarebbe sbagliato in due telefono
  -- aperti insieme, dove a uno dei due l'insert non aggiunge niente.
  with inserted as (
    insert into public.episodes (anime_id, episode_num)
    select _anime_id, g.n
      from generate_series(v_previous + 1, v_target) g(n)
    on conflict (anime_id, episode_num) do nothing
    returning episode_num
  )
  select count(*), coalesce(max(episode_num), 0)
    into v_added, v_new_max
    from inserted;

  -- Fonti AnimeUnity per i nuovi episodi, una per versione (sub/dub). Anche
  -- qui solo per gli episodi appena creati: le fonti degli altri esistono gia'.
  if v_added > 0 then
    select p.id into v_provider from public.providers p where p.slug = 'mio_provider';

    if v_provider is not null then
      for v_mapping in
        select m.provider_anime_id, m.is_dub, coalesce(i.episodes_count, 0) as episodes_count
          from public.anime_provider_mappings m
          join public.provider_anime_index i
            on i.provider_slug = m.provider_slug
           and i.provider_anime_id = m.provider_anime_id
         where m.anime_id = _anime_id
           and m.provider_slug = 'mio_provider'
      loop
        insert into public.episode_sources
          (episode_id, provider_id, canonical_url, source_type, quality, language, is_active)
        select
          e.id,
          v_provider,
          'https://www.animeunity.so/anime/' || v_mapping.provider_anime_id || '-x',
          'hls', '1080p',
          case when v_mapping.is_dub then 'ita' else 'sub' end,
          true
        from public.episodes e
        where e.anime_id = _anime_id
          and e.episode_num between v_previous + 1
                                and least(v_target, v_mapping.episodes_count);
      end loop;
    end if;
  end if;

  -- "Nuovo episodio" solo a chi segue l'anime e solo se l'anime era gia'
  -- iniziato (v_previous > 0): la prima comparsa in catalogo non e' una
  -- novita' da annunciare, e non deve svegliare nessuno.
  if v_added > 0 and v_previous > 0 then
    select coalesce(a.title_it, a.title)
      into v_title
      from public.anime a
     where a.id = _anime_id;

    for v_tracker in
      select distinct on (t.user_id) t.user_id, t.group_id
        from (
          select user_id, null::uuid as group_id
            from public.personal_watchlist
           where anime_id = _anime_id
          union all
          select user_id, group_id
            from public.watchlists
           where anime_id = _anime_id
        ) t
       order by t.user_id, t.group_id nulls last
    loop
      perform public.notify_user(
        v_tracker.user_id,
        'new_episode',
        'Nuovo episodio',
        coalesce(v_title, 'Un anime che segui') ||
          ': episodio ' || v_new_max || ' disponibile.',
        jsonb_build_object(
          'anime_id', _anime_id,
          'episode_num', v_new_max,
          'group_id', v_tracker.group_id
        ),
        false
      );
    end loop;
  end if;

  return v_added;
end;
$$;

comment on function public.sync_anime_episodes(uuid, text, text, integer) is
  'Allinea episodi e fonti di un anime al conteggio dichiarato dal provider; avvisa chi lo segue se non e'' la prima comparsa.';

revoke all on function public.sync_anime_episodes(uuid, text, text, integer) from public, anon;
grant execute on function public.sync_anime_episodes(uuid, text, text, integer) to authenticated;
