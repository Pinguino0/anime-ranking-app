-- ============================================================================
-- seed_demo - dati per vedere l'app con dentro (NON e' una migration)
--
-- Da eseguire a mano: Supabase -> SQL Editor -> New query -> incolla -> Run.
-- Non serve alcun token.
--
-- Cosa crea:
--   - 3 utenti (alice, bob, carol) con un gruppo in comune e i voti
--   - 16 anime in catalogo, cosi' home, ricerca e classifica hanno roba
--   - 12 episodi per anime, cosi' la schermata episodio si puo' vedere
--
-- NON crea le fonti: quelle servono provider ufficiali con licenza propria e
-- non si inventano. E' il comportamento voluto - senza fonti, il player dice
-- "questo episodio non ha ancora una sorgente in catalogo".
--
-- Va rimosso con cleanup_test.sql quando la valutazione e' finita.
--
-- ---------------------------------------------------------------------------
-- Perche' alice e non l'utente che sta guardando il telefono: il seed crea
-- account nuovi, quindi l'utente deve entrare come alice@t.test / password123
-- per vedere il gruppo con i membri e le classifiche. Il proprio account resta
-- com'era e continua a non avere gruppi.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Utenti. handle_new_user() crea i profili e il primo gruppo.
--
-- I campi che GoTrue legge in stringhe non nullabili sono '' e non null:
-- confirmation_token, phone_change e phone_change_token. Con un NULL la
-- lettura dell'utente fallisce e il login risponde 500 "Database error
-- querying schema", senza nemmeno dire che la password e' sbagliata.
-- Gli utenti creati dalla dashboard non hanno il problema: GoTrue li
-- inserisce lui e riempie quei campi.
-- ---------------------------------------------------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, email_change, confirmation_token,
  email_change_token_new, recovery_token, email_change_token_current,
  email_change_confirm_status, phone,
  phone_confirmed_at, phone_change, phone_change_token,
  is_super_admin, raw_app_meta_data, raw_user_meta_data
)
select
  '00000000-0000-0000-0000-000000000000',
  u.uid,
  'authenticated',
  'authenticated',
  u.mail,
  crypt('password123', gen_salt('bf')),
  now(), now(), now(),
  '', '',
  '', '', '',
  0, null, null, '', '',
  false, '{}'::jsonb, '{}'::jsonb
from (values
  ('11111111-1111-1111-1111-111111111111'::uuid, 'alice@t.test'),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'bob@t.test'),
  ('33333333-3333-3333-3333-333333333333'::uuid, 'carol@t.test')
) as u(uid, mail)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Gruppo con tre membri: ranking, duelli e voti sono per gruppo, quindi senza
-- questo le classifiche resterebbero vuote anche con i voti dentro.
-- ---------------------------------------------------------------------------
insert into public.groups (id, name, invite_code, owner_id)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'G Demo', 'ANIME-DEMO1',
        '11111111-1111-1111-1111-111111111111')
on conflict (id) do nothing;

insert into public.group_members (group_id, user_id, role)
values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'owner'),
  ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'member'),
  ('aaaaaaaa-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'member')
on conflict (group_id, user_id) do nothing;

-- ---------------------------------------------------------------------------
-- Catalogo: 16 anime, per i bracket da 2, 8 e 16.
-- ---------------------------------------------------------------------------
insert into public.anime (external_id, external_source, title, episodes)
select (100 + g)::text, 'mal', 'Anime ' || lpad(g::text, 2, '0'), 12
from generate_series(1, 16) g
on conflict (external_source, external_id) do nothing;

-- ---------------------------------------------------------------------------
-- Voti: punteggi diversi per utente, altrimenti la classifica li mette tutti
-- pari e non si vede se l'ordinamento funziona.
-- ---------------------------------------------------------------------------
insert into public.ratings (group_id, user_id, anime_id, score)
select 'aaaaaaaa-0000-0000-0000-000000000001',
       m.user_id,
       a.id,
       5 + ((row_number() over (partition by m.user_id order by a.title)) % 5)
  from public.group_members m
  join public.anime a on true
 where m.group_id = 'aaaaaaaa-0000-0000-0000-000000000001'
on conflict (group_id, user_id, anime_id) do nothing;

-- ---------------------------------------------------------------------------
-- Episodi: 12 per anime.
--
-- La data di messa in onda e' sfalsata all'indietro di un giorno per episodio,
-- cosi' la lista ha un ordine temporale credibile invece di dodici date
-- identiche.
--
-- Nessuna fonte: vedi la nota in testa al file.
-- ---------------------------------------------------------------------------
insert into public.episodes (anime_id, episode_num, title, aired_at)
select a.id,
       g,
       'Episodio ' || lpad(g::text, 2, '0'),
       now() - make_interval(days => 12 - g)
  from public.anime a
 cross join generate_series(1, 12) g
on conflict (anime_id, episode_num) do nothing;

commit;

-- ---------------------------------------------------------------------------
-- Verifica: questo SELECT deve restituire una sola riga con tutti e 5 a 1.
--   utenti 3 | anime 16 | episodi 192 | voti 48
--
-- episodi = 16 anime x 12 episodi. Se tornasse 0, la 026 non c'e' ancora.
-- ---------------------------------------------------------------------------
select
  (select count(*) from auth.users
    where email in ('alice@t.test', 'bob@t.test', 'carol@t.test')
  ) as utenti,
  (select count(*) from public.anime
    where external_source = 'mal' and external_id between '101' and '116'
  ) as anime,
  (select count(*) from public.episodes) as episodi,
  (select count(*) from public.ratings
    where group_id = 'aaaaaaaa-0000-0000-0000-000000000001'
  ) as voti;