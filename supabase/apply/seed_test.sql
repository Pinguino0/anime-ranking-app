-- ============================================================================
-- seed di test (NON e una migration)
-- Crea 3 utenti, 1 gruppo con 3 membri e 16 anime, per collaudare i bracket
-- da 2, 8 e 16. Va eseguito come postgres e poi rimosso con cleanup_test.sql.
-- ============================================================================

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, email_change,
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
  '', '', '', '',
  0, null, null, null, null,
  false, '{}'::jsonb, '{}'::jsonb
from (values
  ('11111111-1111-1111-1111-111111111111'::uuid, 'alice@t.test'),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'bob@t.test'),
  ('33333333-3333-3333-3333-333333333333'::uuid, 'carol@t.test')
) as u(uid, mail);

-- handle_new_user() crea i profili; il gruppo e il primo owner.
insert into public.groups (id, name, invite_code, owner_id)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'G Test', 'ANIME-SEED1',
        '11111111-1111-1111-1111-111111111111');

insert into public.group_members (group_id, user_id, role)
values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'owner'),
  ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'member'),
  ('aaaaaaaa-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'member');

insert into public.anime (external_id, external_source, title, episodes)
select (100 + g)::text, 'mal', 'Anime ' || lpad(g::text, 2, '0'), 12
from generate_series(1, 16) g;

-- tutti votano 8: serve un punteggio iniziale per duel_elo e ranking
insert into public.ratings (group_id, user_id, anime_id, score)
select 'aaaaaaaa-0000-0000-0000-000000000001',
       m.user_id,
       a.id,
       5 + ((row_number() over (partition by m.user_id order by a.title)) % 5)
from public.group_members m
join public.anime a on true
where m.group_id = 'aaaaaaaa-0000-0000-0000-000000000001';