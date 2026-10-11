-- ---------------------------------------------------------------------------
-- 20261011130000_manual_titles_lotm.sql
--
-- Titoli manuali per la serie "Lord of Mysteries" (Guimi Zhi Zhu).
--
-- Perche': il catalogo arriva da AniList, dove `title` e' il romaji cinese
-- ("Guimi Zhi Zhu: Xiaochou Pian") e `title_it` e' NULL. La UI mostra
-- `displayTitle => italianTitle ?? title`, quindi apparivano i nomi cinesi.
-- La pipeline di matching (scraper/seed/match_unmatched.js) NON ha un titolo
-- inglese da scrivere in `title_it`: lo lascia NULL.
--
-- Qui si fissa il titolo internazionale (inglese) come `title_it`, con
-- `title_it_source='manual'` per marcare che e' un intervento a mano e non un
-- dato dedotto. `search_blob` e' una colonna GENERATED che include `title_it`,
-- quindi si aggiorna da sola: gli anime diventano cercabili anche in inglese.
--
-- Idempotente: riscrivere gli stessi valori non cambia nulla.
-- ---------------------------------------------------------------------------

update public.anime
set title_it = v.title_it,
    title_it_source = 'manual'
from (values
  ('137667', 'Lord of Mysteries'),
  ('199448', 'Lord of Mysteries Specials'),
  ('206875', 'Lord of Mysteries: Chibi Theatre')
) as v(external_id, title_it)
where public.anime.external_source = 'anilist'
  and public.anime.external_id = v.external_id;
