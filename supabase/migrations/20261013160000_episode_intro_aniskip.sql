-- Dove sta la sigla di un episodio, letto da AniSkip e messo in cache.
--
-- Prima di questa migrazione la finestra stava su `anime` (`intro_start_seconds`
-- / `intro_end_seconds`) ed era un valore inventato: 0 e 90 su tutte le serie
-- TV. Il pulsante "Salta intro" esisteva, ma puntava a un punto arbitrario del
-- primo minuto: nella maggior parte dei casi dentro l'episodio, non dentro la
-- sigla.
--
-- La sigla cambia da episodio a episodio — il primo spesso non ce l'ha, e una
-- serie puo' cambiarla a meta' stagione — quindi la finestra va tenuta per
-- (anime, episodio). Il dato arriva da AniSkip, un database pubblico di
-- intervalli, attraverso una Edge Function che lo mette in cache qui: il
-- telefono non deve interrogare AniSkip a ogni apertura del player.

-- L'id MyAnimeList, che e' la chiave con cui AniSkip identifica un'opera.
-- Il catalogo non lo ha quasi mai (e' indicizzato su AniList/Kitsu); si ricava
-- una volta da AniList e si conserva qui, cosi' le volte successive non serve
-- piu' chiederlo.
alter table public.anime
  add column if not exists mal_id integer;

comment on column public.anime.mal_id is
  'Id MyAnimeList dell''opera, ricavato da AniList. Chiave per AniSkip.';

-- La cache delle finestre trovate, una riga per (anime, episodio).
create table if not exists public.episode_intro (
  anime_id uuid not null references public.anime (id) on delete cascade,
  episode_number integer not null,
  start_seconds integer not null,
  end_seconds integer not null,
  source text not null default 'aniskip',
  fetched_at timestamptz not null default now(),
  primary key (anime_id, episode_number)
);

comment on table public.episode_intro is
  'Intervallo della sigla per episodio, in cache da AniSkip.';

alter table public.episode_intro enable row level security;

-- Nessuna policy per `authenticated`/`anon`: la legge e la scrive solo la Edge
-- Function con la service key. Non e' un dato dell'utente e non ha un
-- proprietario; esporla permetterebbe a chiunque di riempirla a piacere.

-- Il seed sbagliato va via. Era 0-90 su tutte le TV, cioe' un intervallo
-- inventato: `null` e' la verita' ("non lo sappiamo"), e con `null` il player
-- non mostra il pulsante invece di saltare alla cieca. Le colonne restano:
-- cancellarle romperebbe la lettura alle versioni gia' installate, che le
-- interrogano direttamente, senza dare loro niente in cambio.
update public.anime
set intro_start_seconds = null,
    intro_end_seconds = null
where intro_start_seconds is not null
   or intro_end_seconds is not null;
