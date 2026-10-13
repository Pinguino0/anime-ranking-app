-- Finestra della sigla, per il pulsante "Salta intro" del player.
--
-- I due secondi vivono sull'anime e non sull'episodio: la sigla di una serie e'
-- quasi sempre la stessa dall'episodio 2 in poi, e ripeterla per ogni episodio
-- moltiplicherebbe le righe senza aggiungere informazione. La prima puntata, che
-- spesso non ha sigla, resta coperta dallo stesso valore e non e' un problema:
-- il pulsante si tocca, non parte da solo.
--
-- `null` vuol dire "non lo sappiamo", che e' diverso da zero: senza un dato il
-- player non mostra il pulsante. Inventare una finestra a schermo taglierebbe
-- contenuto vero, che e' peggio di un pulsante in meno.

alter table public.anime
  add column if not exists intro_start_seconds integer,
  add column if not exists intro_end_seconds integer;

alter table public.anime
  drop constraint if exists anime_intro_window_check;

-- Una finestra con la fine prima dell'inizio manderebbe il player indietro
-- invece che avanti: si blocca a monte, dove il dato entra in catalogo.
alter table public.anime
  add constraint anime_intro_window_check check (
    intro_start_seconds is null
    or intro_end_seconds is null
    or intro_end_seconds > intro_start_seconds
  );

comment on column public.anime.intro_start_seconds is
  'Secondo in cui comincia la sigla. NULL se il catalogo non lo conosce.';

comment on column public.anime.intro_end_seconds is
  'Secondo in cui finisce la sigla: il punto in cui atterra "Salta intro".';

-- Valore di partenza per le serie che il catalogo gia' conosce.
--
-- Non e' una misura ricavata dal video: e' una stima (la sigla di una serie TV
-- italiana sta quasi sempre nei primi 90 secondi) che serve a far comparire il
-- pulsante da subito. Essendo una stima, e' pensata per essere corretta riga per
-- riga piu' avanti: il pulsante non salta da solo, quindi un valore approssimativo
-- non fa danni se non lo si tocca.
update public.anime
set intro_start_seconds = 0,
    intro_end_seconds = 90
where media_type::text = 'TV'
  and intro_start_seconds is null
  and intro_end_seconds is null;
