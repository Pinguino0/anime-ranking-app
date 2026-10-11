-- ============================================================================
-- cleanup_demo - rimuove tutto cio che ha creato seed_demo.sql
--
-- Da eseguire a mano: Supabase -> SQL Editor -> New query -> incolla -> Run.
--
-- Va eseguito DOPO fix_demo_login.sql, altrimenti si blocca: `auth.users` ha
-- una foreign key verso `auth.identities`, quindi cancellare l'utente senza
-- aver tolto prima l'identita' fa fallire l'operazione. E' la stessa ragione
-- per cui il pannello dice "Failed to delete user: Database error loading
-- user": prova a caricare l'utente, segue i link verso identities, e la riga
-- non c'e'.
--
-- L'ordine e' l'unica cosa che conta:
--   1. identita'   (figlia diretta, va via per prima)
--   2. utenti      (profiles, ratings, watch_progress ecc. seguono in cascade
--                    perche' hanno tutte `references auth.users on delete cascade`)
--   3. il resto    (gruppo e catalogo, senza utenti agganciati)
-- ============================================================================

begin;

-- 1. Identita'. Nessun cascade su questa tabella: va cancellata a mano.
delete from auth.identities
 where user_id in (
   '11111111-1111-1111-1111-111111111111',
   '22222222-2222-2222-2222-222222222222',
   '33333333-3333-3333-3333-333333333333'
 )
    or provider_id in (
   '11111111-1111-1111-1111-111111111111',
   '22222222-2222-2222-2222-222222222222',
   '33333333-3333-3333-3333-333333333333'
 );

-- 2. Utenti. Da qui in avanti va tutto a cascata: profiles, group_members,
--    ratings, watch_progress, notifications, activities, duel... spariti.
delete from auth.users where id in (
  '11111111-1111-1111-1111-111111111111',
  '22222222-2222-2222-2222-222222222222',
  '33333333-3333-3333-3333-333333333333'
);

-- 3. Gruppo di prova. Le membership sono gia' sparite con gli utenti, ma la
--    riga del gruppo resta e va tolta esplicitamente.
delete from public.groups where id = 'aaaaaaaa-0000-0000-0000-000000000001';

-- 4. Episodi. `on delete cascade` dalla tabella anime li porta via, quindi
--    questo e' solo per sicurezza: se l'errore di qualcuno lascia degli
--    episodi orfani, non sopravvivono al prossimo seed.
delete from public.episodes
 where anime_id in (
   select id from public.anime
    where external_source = 'mal' and external_id between '101' and '116'
 );

-- 5. Catalogo.
delete from public.anime
 where external_source = 'mal' and external_id between '101' and '116';

commit;

-- ============================================================================
-- Verifica: tutte e cinque le colonne devono dire 0.
--
-- Se `episodi` resta diverso da 0 vuol dire che c'erano righe in `episodes` con
-- un `anime_id` che non punta a nessun anime: non dovrebbe essere possibile con
-- il vinzo di integrita', quindi in quel caso vale la pena guardarle.
-- ============================================================================
select
  (select count(*) from auth.users
    where email in ('alice@t.test', 'bob@t.test', 'carol@t.test')
  ) as utenti,
  (select count(*) from auth.identities
    where user_id in (
      '11111111-1111-1111-1111-111111111111',
      '22222222-2222-2222-2222-222222222222',
      '33333333-3333-3333-3333-333333333333'
    )
  ) as identita,
  (select count(*) from public.groups
    where id = 'aaaaaaaa-0000-0000-0000-000000000001'
  ) as gruppi,
  (select count(*) from public.anime
    where external_source = 'mal' and external_id between '101' and '116'
  ) as anime,
  (select count(*) from public.episodes) as episodi;