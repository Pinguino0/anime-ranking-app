-- ============================================================================
-- reseed_real_catalog - toglie i dati di prova e ricollega il gruppo ai
-- titoli veri (NON e' una migration)
--
-- Da eseguire a mano: Supabase -> SQL Editor -> New query -> incolla -> Run.
--
-- Perche' esiste
-- --------------
-- seed_demo.sql inseriva 16 righe finte ("Anime 01" ... "Anime 16", 12
-- episodi ciascuna, 3 voti a testa) per avere qualcosa da mostrare. Ma da
-- quando il catalogo si riempie davvero dalla Edge Function, quelle righe
-- non servono piu' e peggio: sono cio' che l'utente vede in home e in
-- classifica al posto dei titoli veri.
--
-- Cosa fa, in ordine
-- ------------------
-- 1. Cancella le 16 righe 'mal'. Le foreign key verso anime sono tutte
--    ON DELETE CASCADE, quindi spariscono anche i 192 episodi e i 48 voti
--    che il seed aveva appesi a quelle righe. Nessuna tabella resta con
--    riferimenti puntati a un anime che non esiste piu'.
-- 2. Ricrea i voti del gruppo sugli anime veri gia' in catalogo.
--
-- Perche' i voti restano anche se sembrano roba di prova
-- -------------------------------------------------------
-- I voti servono a una cosa sola: senza, la classifica del gruppo e' vuota e
-- non si puo' vedere se l'ordinamento, i podi e le percentuali funzionano.
-- Il seed li metteva, quindi li si ricollega agli anime veri invece di
-- perderli. Poi ognuno puo' votare quello che vuole dal vivo.
--
-- Idempotente: rilanciarlo due volte non crea doppioni (on conflict do
-- nothing) e la delete dei 'mal' non trova piu' nulla.
-- ============================================================================

begin;

-- 1. via i 16 anime di prova, con tutti i figli.
delete from public.anime where external_source = 'mal';

-- 2. Voti del gruppo sugli anime veri.
--
-- Il punteggio varia per utente e per posizione: se tutti avessero lo
-- stesso voto la classifica li metterebbe tutti pari e non si vedrebbe se
-- l'ordinamento funziona davvero.
insert into public.ratings (group_id, user_id, anime_id, score)
select 'aaaaaaaa-0000-0000-0000-000000000001',
       m.user_id,
       a.id,
       5 + ((row_number() over (partition by m.user_id order by a.title)) % 5)
  from public.group_members m
  join public.anime a
    on a.external_source in ('anilist', 'kitsu')
 where m.group_id = 'aaaaaaaa-0000-0000-0000-000000000001'
on conflict (group_id, user_id, anime_id) do nothing;

commit;

-- ---------------------------------------------------------------------------
-- Verifica: attesi 0 anime 'mal', 0 episodi (il seed li aveva legati ai fake),
-- e voti pari a 3 utenti x anime in catalogo.
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.anime where external_source = 'mal') as anime_fake,
  (select count(*) from public.anime) as anime_reali,
  (select count(*) from public.episodes) as episodi,
  (select count(*) from public.ratings
     where group_id = 'aaaaaaaa-0000-0000-0000-000000000001') as voti;