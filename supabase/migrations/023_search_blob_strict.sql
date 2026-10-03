-- ---------------------------------------------------------------------------
-- 023_search_blob_strict
--
-- Toglie `strict` da anime_search_blob.
--
-- Il bug: la funzione era dichiarata STRICT ma il suo corpo faceva coalesce
-- esattamente per gestire i NULL. I due si contraddicono. STRICT cortocircuita
-- prima di entrare nel corpo, quindi con un solo argomento NULL la funzione
-- restituiva NULL e il coalesce non veniva mai raggiunto: era codice morto.
--
-- Effetto: la colonna generata passava external_data ->> 'title', che e' NULL
-- quando external_data non e' valorizzato, quindi search_blob finiva NULL e
-- l'anime era invisibile a ogni ricerca per titolo. verify_019.sql lo
-- segnalava con:
--
--   P0001: TEST 1 KO: "titan" -> 0 righe (NULL), atteso 1 Attack on Titan
--
-- Nota: la 019 si applicava senza errori e le ricerche "funzionavano", quindi
-- il difetto era silenzioso finche una riga senza external_data non entrava.
--
-- Perche' si toglie strict invece di fare coalesce nella colonna generata:
--   - la funzione ha gia' la coalesce al suo interno, dichiarare STRICT era
--     l'errore, non il corpo;
--   - correggere la colonna generata avrebbe obbligato a droppare la colonna e
--     il suo indice GIN per ricrearli, perde l'ordine delle colonne e rebuilda
--     l'indice su tutto il catalogo;
--   - qui basta un create or replace: la colonna generata continua a chiamare
--     la stessa funzione con la stessa firma e l'indice non si tocca.
--
-- Con il fix un anime senza titoli alternativi e senza external_data ottiene
-- search_blob con il solo titolo principale invece di NULL, che e' il
-- comportamento che le verify gia' si aspettavano.
-- ---------------------------------------------------------------------------

create or replace function public.anime_search_blob(
  _title          text,
  _japanese_title text,
  _synonyms       text[],
  _original_title text
)
returns text
language sql
immutable
parallel safe
as $$
  -- coalesce perche' array_to_string(NULL) e' NULL e un NULL qui renderebbe
  -- l'intera concatenazione NULL. La coalesce serve perche' adesso la funzione
  -- e' davvero chiamabile con NULL: senza strict, gli argomenti mancanti
  -- arrivano qui e vengono scartati da array_remove.
  select coalesce(array_to_string(
    array_remove(
      array[
        _title,
        _japanese_title,
        _original_title,
        array_to_string(_synonyms, ' ')
      ],
      null
    ),
    ' '
  ), '');
$$;

comment on function public.anime_search_blob(text, text, text[], text) is
  'Titolo + titolo giapponese + titolo originale + sinonimi, uniti per la ricerca. Accetta NULL e restituisce testo vuoto se non c''e'' nulla.';