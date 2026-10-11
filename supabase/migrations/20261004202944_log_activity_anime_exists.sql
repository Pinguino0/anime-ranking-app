-- ---------------------------------------------------------------------------
-- 029_log_activity_anime_exists
--
-- Il catalogo non era cancellabile.
--
-- Il sintomo: qualunque delete su public.anime finiva con
--
--   23503: insert or update on table "activities" violates foreign key
--   constraint "activities_anime_id_fkey"
--   CONTEXT: SQL function "log_activity" ... activities_on_rating line 23
--
-- Cosa succedeva. Il trigger activities_on_rating scrive una riga in
-- activities su ogni delete di ratings, e lo fa dentro AFTER, quindi a quel
-- punto la riga di anime che stava provoking la cascata e' gia' sparita.
--activities.anime_id punta a anime(id): la riga che il trigger prova a
-- inserire si riferisce a un anime inesistente e la FK la rifiuta.
--
-- In pratica, finche' esiste la trigger, public.anime e' append-only: si
-- possono solo aggiungere righe. E' un buco operativo grosso, perche' il
-- catalogo e' alimentato dalla Edge Function e prima o poi qualcosa va
-- tolto (titoli non piu' disponibili, pulizia, seed di prova come i 16
-- "Anime 01..16").
--
-- La fix e' in log_activity, non nella trigger: la funzione gia' scrive
-- l'attivita' solo se il gruppo e l'utente esistono ancora, e li controlla
-- uno a uno. Aggiungere il terzo controllo, sull'anime, e' la stessa regola
-- con lo stesso motivo: un'attivita' che punta a una riga sparita non
-- racconta niente e non deve nemmeno entrare nel feed.
--
-- Il ramo DELETE della trigger non va toccato: continuera' a chiamare
-- log_activity, che semplicemente non scrivera' niente quando l'anime non
-- c'e' piu'. Cambiare la trigger avrebbe significato duplicare la condizione
-- in ogni ramo (INSERT, UPDATE, DELETE) per un controllo che e' lo stesso.
-- ---------------------------------------------------------------------------

create or replace function public.log_activity(
  _group_id   uuid,
  _user_id    uuid,
  _type       public.activity_type,
  _anime_id   uuid    default null,
  _metadata   jsonb   default '{}'::jsonb
)
returns void
language sql
security definer
set search_path to 'public'
as $$
  insert into public.activities (group_id, user_id, type, anime_id, metadata)
  select _group_id, _user_id, _type, _anime_id, _metadata
   where exists (select 1 from public.groups g where g.id = _group_id)
     and exists (select 1 from public.profiles p where p.id = _user_id)
     -- Terzo controllo, per lo stesso motivo degli altri due: su una delete a
     -- cascata l'anime e' gia' stato cancellato quando la trigger AFTER
     -- chiama questa funzione, e activities.anime_id ha una FK verso
     -- anime(id). Senza, il trigger impedisce di cancellare dal catalogo.
     and (
       _anime_id is null
       or exists (select 1 from public.anime a where a.id = _anime_id)
     );
$$;

comment on function public.log_activity(uuid, uuid, public.activity_type, uuid, jsonb) is
  'Scrive una riga nel feed del gruppo saltando il gruppo, il profilo o l''anime se nel frattempo non esistono piu''. Il controllo sull''anime e'' quello che permette a public.anime di essere cancellabile: la trigger activities_on_rating gira in AFTER e su una delete a cascata l''anime e'' gia'' sparito.';