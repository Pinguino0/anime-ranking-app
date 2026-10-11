-- ============================================================================
-- 028 – risoluzione delle fonti: canonical_url, providers, resolve-source
-- ============================================================================
--
-- Perche' una migrazione nuova e non una modifica alla 026
-- -----------------------------------------------------------------------
-- Stessa regola della 20261005120000: la 026 e la 027 risultano gia' applicate
-- sul database remoto, quindi cambiarne il contenuto non le fa rieseguire e le
-- righe gia' esistenti resterebbero com' erano. Quello che segue vale per un
-- ambiente nuovo che nasce da `supabase db reset` e per quello remoto che
-- riceve questa migrazione: stesso risultato, una sola cronologia.
--
-- ----------------------------------------------------------------------------
--  IL MODELLO ANIYOMI, TRADOTTO
-- ----------------------------------------------------------------------------
--
-- In Aniyomi ogni episodio ha un `url` canonico — l'indirizzo della pagina del
-- provider — e il video si ottiene solo al momento della riproduzione, con
-- `VideoSource.resolve()` che chiama l'API del provider, si porta dietro
-- `Referer`, `User-Agent` e cookie, e restituisce l'URL effimero piu' gli
-- header necessari. Aniyomi non scrive mai quegli URL su disco: durano pochi
-- minuti e al secondo avvio sarebbero gia' scaduti.
--
-- Qui il modello era diverso: `episode_sources.source_url` era un URL gia'
-- riproducibile, salvato e usato cos' com'era. Va bene finche' le fonti sono
-- file pubblici stabili; non va bene con provider che richiedono risoluzione,
-- perche' un token finisce scaduto nel database e non si sa piu' quale
-- richiesta rifare.
--
-- Quindi: `source_url` resta al suo posto e resta la colonna dei file diretti,
-- `canonical_url` aggiunge il caso risolto, e `providers` dice *chi* sa
-- risolvere cosa. Le due cose convivono perche' servono a due situazioni
-- diverse, e non e' over-engineering: sono le due forme che si trovano in
-- cataloghi reali.
--
-- ----------------------------------------------------------------------------
--  providers
-- ----------------------------------------------------------------------------
--
-- Una riga per backend che sa trasformare un riferimento in un link
-- riproducibile. Non contiene segreti: lo slug e' un indirizzo logico
-- (`mock`, poi il nome vero del provider), e le credenziali stanno nelle
-- variabili d'ambiente della Edge Function. E' quindi una tabella che si puo'
-- leggere dall'app senza paura, ed e' quello che permette all'app di sapere
-- quali fonti risolvere senza chiedere ogni volta.
--
-- `resolve_endpoint` non e' un URL: e' il nome logico che la Edge Function
-- usa per scegliere l'adapter. Cosi' aggiungere un provider non richiede una
-- migrazione — basta una riga e il codice dell'adapter.
-- ----------------------------------------------------------------------------
create table public.providers (
  id               uuid primary key default gen_random_uuid(),
  slug             text not null unique,
  label            text not null,
  -- Nome logico dell'adapter dentro `resolve-source`. Piu' di uno per lo stesso
  -- provider quando lo stesso backend ha implementazioni diverse (per esempio
  -- un resolver "api" e uno "scraping"), che e' il modo in cui Aniyomi tratta
  -- le source: piu' VideoSource, stesso MangaSource.
  resolve_endpoint text not null default 'mock',
  is_active        boolean not null default true,
  -- Priorita' fra provider equivalenti a parita' di qualita': piu' basso
  -- viene provato prima. Un provider che si rompe non si toglie dalla tabella,
  -- gli si abbassa il numero.
  priority         smallint not null default 100,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint providers_priority_positive check (priority > 0),
  constraint providers_slug_format check (slug ~ '^[a-z0-9][a-z0-9_-]*$')
);

create index providers_active_idx on public.providers (is_active);
create index providers_priority_idx on public.providers (priority);

create trigger providers_set_updated_at
  before update on public.providers
  for each row execute function public.set_updated_at();

comment on table public.providers is
  'Backend che risolvono un riferimento episodio in un URL riproducibile. Gli slug sono indirizzi logici, i segreti stanno nella Edge Function.';

comment on column public.providers.resolve_endpoint is
  'Adapter usato dalla Edge Function resolve-source per questo provider.';

-- ----------------------------------------------------------------------------
-- episode_sources: canonical_url
-- ----------------------------------------------------------------------------
--
-- La colonna si chiama `canonical_url` e non `url` perche' dice cosa contiene:
-- l'indirizzo che si puo' salvare per sempre, non quello che si puo' usare
-- subito. Le due righe diverse nella stessa tabella sono distinguibili dal
-- valore, e la CHECK qui sotto rende impossibile la terza forma, quella senza
-- nessuno dei due.
--
-- `source_url` diventa nullable perche' una fonte risolta non ce l'ha. La
-- not-null resterebbe sulle righe gia' inserite: si toglie il vincolo e lo
-- sostituisce con la CHECK, che copre il caso esatto che la NOT NULL non
-- sapeva vedere — "manca perche' e' altrove", non "manca perche' e' un errore".
--
-- `provider_id` e' la chiave esterna verso `providers`. ON DELETE SET NULL e non
-- CASCADE: cancellare un provider non deve cancellare le fonti, che sono
-- informazione sull'episodio e sopravvivono al provider che le serviva.
-- ----------------------------------------------------------------------------
alter table public.episode_sources
  add column canonical_url  text,
  add column provider_id    uuid references public.providers (id) on delete set null;

alter table public.episode_sources
  alter column source_url drop not null;

alter table public.episode_sources
  add constraint episode_sources_has_address
  check (canonical_url is not null or source_url is not null);

comment on column public.episode_sources.canonical_url is
  'Indirizzo canonico del provider, da risolvere al momento della riproduzione. Non e'' un URL riproducibile.';

comment on column public.episode_sources.source_url is
  'URL gia'' riproducibile, per le fonti pubbliche. Con canonical_url e'' il campo che non va riletto al posto del primo.';

create index episode_sources_provider_idx on public.episode_sources (provider_id);

-- L'indice serve a una domanda precisa: "quali fonti di questo episodio vanno
-- risolte", cioe' quelle con canonical_url e senza canonical gia' salvato. Un
-- indice parziale su canonical_url is not null e' molto piu' piccolo di uno
-- su tutta la tabella e risponde esattamente a quella domanda.
create index episode_sources_resolvable_idx
  on public.episode_sources (episode_id)
  where canonical_url is not null;

-- ----------------------------------------------------------------------------
-- provider di esempio
-- ----------------------------------------------------------------------------
--
-- Una riga sola, con il resolver finto. Serve a due cose: dare al seed delle
-- fonti un provider da referenziare, e poter provare la catena intera senza
-- avere ancora il provider vero.
--
-- Quando arriva il provider reale si aggiungono le sue righe con lo slug
-- vero: il client, lo schema e il player non cambiano, perche' leggono lo slug
-- dal database e non lo conoscono.
-- ----------------------------------------------------------------------------
insert into public.providers (slug, label, resolve_endpoint, priority)
values
  ('mock', 'Provider di prova', 'mock', 10)
on conflict (slug) do update
  set label            = excluded.label,
      resolve_endpoint = excluded.resolve_endpoint,
      priority         = excluded.priority;

-- ----------------------------------------------------------------------------
-- episode_sources_list
-- ----------------------------------------------------------------------------
--
-- La stessa funzione della 027 con tre colonne in piu': `canonical_url`,
-- `provider_slug` e `provider_label`. Il client le usa per capire se la fonte
-- va risolta (`canonical_url` presente) e come chiamarla in pastiglia.
--
-- Il nome del provider arriva qui e non dal client per la stessa ragione dei
-- dati dell'episodio nella 027: se la UI unisse le due risposte a mano, un id
-- sbagliato mostrerebbe "720p ITA" del provider sbagliato accanto al video
-- giusto, e non ci sarebbe modo di accorgersene.
--
-- `create or replace` non puo' cambiare il tipo di ritorno di una funzione
-- gia' esistente, quindi la funzione viene-droppata prima. Il drop non lascia
-- buchi: le righe che la funzione ridefinisce tornano con il GRANT in fondo,
-- e nella stessa transazione nessuna richiesta vede lo stato intermedio.
--
-- Nota su `resolve_endpoint`: NON viene restituito al client. E' un indirizzo
-- interno che serve solo alla Edge Function per scegliere l'adapter, e
-- mandarlo al telefono significa esporre il nome dell'implementazione a
-- chiunque apra il pannello di rete. Per il client bastano slug ed etichetta.
-- ----------------------------------------------------------------------------
drop function if exists public.episode_sources_list(uuid);

create or replace function public.episode_sources_list(_episode_id uuid)
returns table (
  id             uuid,
  source_url     text,
  canonical_url  text,
  provider_slug  text,
  provider_label text,
  source_type    public.episode_source_type,
  quality        varchar,
  language       varchar,
  is_active      boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    s.id,
    s.source_url,
    s.canonical_url,
    p.slug,
    p.label,
    s.source_type,
    s.quality,
    s.language,
    s.is_active
  from public.episode_sources s
  left join public.providers p on p.id = s.provider_id
  where s.episode_id = _episode_id
    and s.is_active
  order by
    -- La stessa regola della 027, e per lo stesso motivo: 720p e 1080p sono
    -- stringhe e ordinarle alfabeticamente metterebbe 720p prima di 1080p.
    case s.quality
      when '2160p' then 1 when '1440p' then 2 when '1080p' then 3
      when '720p'  then 4 when '480p'  then 5 else 6
    end,
    -- Dentro la stessa qualita' vince il provider piu' affidabile, che la
    -- tabella `providers` dichiara con `priority`. Era il pezzo mancante del
    -- fallback: prima l'ordine era solo temporale, quindi chiunque avesse
    -- inserito per ultimo decideva quale fonte si provava per prima.
    coalesce(p.priority, 1000),
    s.created_at;
$$;

comment on function public.episode_sources_list(uuid) is
  'Fonti attive di un episodio, dalla qualita'' piu'' alta in giu'' e, a parita'', dal provider piu'' affidabile.';

-- ----------------------------------------------------------------------------
-- Privilegi
-- ----------------------------------------------------------------------------
--
-- `providers`: l'app deve poterlo leggere. E' una tabella di indirizzi logici,
-- senza segreti, e serve al client per sapere quali fonti sono risolvibili.
-- Il criterio e' quello di `public.anime`: lettura per `authenticated`,
-- scrittura solo per `service_role`.
--
-- `episode_sources` resta chiusa al client diretto come l'aveva decisa la
-- 20261005120000: si legge solo da `episode_sources_list`.
-- ----------------------------------------------------------------------------
revoke all on public.providers from anon, authenticated;
grant  select on public.providers to authenticated;

-- La colonna nuova non e' un modo per aggirare niente: `episode_sources`
-- resta senza privilegi per `authenticated`, quindi questa GRANT non cambia
-- nulla per il client diretto. E' qui per simmetria con le altre tabelle e
-- perche' il giorno in cui si vorrebbe aprire la lettura ci sia gia' il
-- ragionamento scritto.
revoke all on public.episode_sources from anon, authenticated;

-- RLS su `providers`: lettura per gli autenticati, scrittura per il servizio.
alter table public.providers enable row level security;

create policy "providers: lettura autenticati attivi"
  on public.providers for select
  to authenticated
  using (is_active = true);

create policy "providers: service write"
  on public.providers for all
  to service_role
  using (true)
  with check (true);

-- La Edge Function gira con la service key, quindi per leggere i provider e le
-- fonti non ha bisogno di nessuna policy: `service_role` le scavalca. Le policy
-- qui sopra servono al client, non alla funzione.

-- ----------------------------------------------------------------------------
-- Privilegi sulle funzioni
-- ----------------------------------------------------------------------------
-- Come nella 027: `anon` non chiama mai queste funzioni, `authenticated` puo'
-- eseguirle ma non leggerne il sorgente.
-- ----------------------------------------------------------------------------
revoke all on function public.episode_sources_list(uuid) from public, anon;

grant execute on function public.episode_sources_list(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- Verifica
-- ----------------------------------------------------------------------------
-- Stessa rete di sicurezza delle altre migration: fallisce qui se in futuro
-- qualcuno aggiunge una funzione raggiungibile da `anon` dimenticandosi della
-- revoca.
-- ----------------------------------------------------------------------------
do $$
begin
  perform public.assert_no_public_exec_for_anon();
end $$;

-- Il risultato atteso: una riga sola, `mock`, attiva.
--
--   select slug, label, resolve_endpoint, priority, is_active from public.providers;
