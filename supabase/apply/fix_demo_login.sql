-- ============================================================================
-- fix_demo_login - rende utilizzabili gli utenti creati dal seed
--
-- Da eseguire a mano: Supabase -> SQL Editor -> New query -> incolla -> Run.
-- Non serve alcun token.
--
-- ---------------------------------------------------------------------------
-- Il problema
--
-- Il seed ha inserito le righe solo in `auth.users`. Ma GoTrue non cerca
-- l'utente li': per ogni accesso cerca in `auth.identities`, che e' la tabella
-- delle identita' dei provider (email, Google, ...). Un utente senza la riga
-- corrispondente in `auth.identities` esiste ma non puo' fare login, e
-- l'errore che torna non e' "credenziali sbagliate" - e' un generico che
-- l'app traduce in "Accesso non riuscito. Riprova."
--
-- Manca anche `raw_app_meta_data = {"provider":"email","providers":["email"]}`,
-- che GoTrue usa per sapere da quale provider arriva la sessione. Con `{}`
-- la sessione viene creata senza provider e il client non la accetta.
--
-- Entrambe le cose le sistemiamo qui, senza toccare le password: sono
--metadati, non credenziali.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. provider email sugli utenti del seed.
--    Solo dove manca, per non sovrascrivere un utente vero.
-- ---------------------------------------------------------------------------
update auth.users
   set raw_app_meta_data = '{"provider":"email","providers":["email"]}'::jsonb,
       updated_at = now()
 where email in ('alice@t.test', 'bob@t.test', 'carol@t.test')
   and (raw_app_meta_data is null
        or not (raw_app_meta_data ? 'providers')
        or raw_app_meta_data->'providers' = '[]'::jsonb);

-- ---------------------------------------------------------------------------
-- 2. Riga in `auth.identities` per ciascuno.
--
-- `provider_id` deve coincidere con l'id del utente per il provider email:
-- e' la chiave con cui GoTrue collega la sessione all'utente.
--
-- `where not exists` invece di `on conflict`: la chiave primaria di
-- `auth.identities` e' `provider_id` + `provider`, ma su alcuni progetti le
-- righe seed precedenti possono avere un id diverso. La condizione esplicita
-- non fallisce in quel caso e non duplica.
-- ---------------------------------------------------------------------------
insert into auth.identities (
  id,               -- uuid generato, non legato all'utente
  provider_id,      -- = user_id: e' la chiave del provider email
  user_id,
  identity_data,
  provider,
  last_sign_in_at,
  created_at,
  updated_at
)
select gen_random_uuid(),
       u.id,
       u.id,
       jsonb_build_object(
         'sub',             u.id::text,
         'email',           u.email,
         'email_verified',  true,
         'phone_verified',  false
       ),
       'email',
       null,
       now(),
       now()
  from auth.users u
 where u.email in ('alice@t.test', 'bob@t.test', 'carol@t.test')
   and not exists (
     select 1
       from auth.identities i
      where i.user_id = u.id
        and i.provider = 'email'
   );

commit;

-- ============================================================================
-- Verifica
--
-- Tutte e tre le colonne devono avere lo stesso numero. Se `con_identita` e'
-- minore di `utenti`, il fix non ha girato per qualche riga.
--
-- Poi accedi nell'app come:
--   alice@t.test / password123
-- ============================================================================
select
  (select count(*) from auth.users
    where email in ('alice@t.test', 'bob@t.test', 'carol@t.test')
  ) as utenti,
  (select count(*) from auth.users
    where email in ('alice@t.test', 'bob@t.test', 'carol@t.test')
      and raw_app_meta_data ? 'providers'
  ) as con_provider,
  (select count(*) from auth.identities i
     join auth.users u on u.id = i.user_id
    where u.email in ('alice@t.test', 'bob@t.test', 'carol@t.test')
      and i.provider = 'email'
  ) as con_identita;