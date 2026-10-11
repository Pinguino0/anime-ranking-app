-- ---------------------------------------------------------------------------
-- 20261005130000_app_releases
--
-- Le versioni dell'app, cosi' il telefono puo' sapere da solo che c' e' da
-- aggiornare.
--
-- Il problema che risolve
-- ----------------------
-- Oggi l'aggiornamento e' una cosa che fa la persona: le passo l'APK nuovo,
-- la reinstalla a mano. Con piu' dispositivi in giro e un database che cambia
-- sotto, prima o poi qualcuno resta indietro e si trova un'app che non
-- parla piu' con il backend.
--
-- Il meccanismo e' il piu' semplice che funziona senza un server di update
-- dedicato: l'app al proprio avvio chiede a questa tabella qual e' l'ultima
-- versione pubblicata, la confronta con il proprio versionCode e, se e'
-- maggiore, mostra l'avviso e scarica l'APK. Nessun account, nessun canale,
-- nessun processo: e' una riga.
--
-- Perche' version_code e non version_name
-- --------------------------------------
-- Il confronto deve essere numerico e non lessicale, altrimenti "1.0.10" risulta
-- piu' piccolo di "1.0.9" e l'aggiornamento non viene mai proposto. Il
-- version_code e' l'intero che Android usa gia' per capire quale APK e' piu'
-- recente, quindi e' anche l'unico numero di cui l'app e' sicura di conoscere il
-- proprio valore: lo legge con package_info_plus.
--
-- Perche' sha256 e' facoltativo
-- ----------------------------
-- Il checksum protegge da un download corrotto a meta' o da uno Storage
-- manomesso. Il plugin ota_update verifica il file scaricato prima di
-- lanciare l'installazione e, se il checksum non torna, rifiuta di installare
-- invece di far partire un APK a meta'. Per questo e' una colonna nullable:
-- finche' non c'e' si puo' pubblicare una versione senza dover calcolare
-- l'hash prima, ma appena si sa farlo va riempita: una colonna presente e
-- sempre NULL e' peggio di una assente, perche' sembra controllata.
--
-- Chi scrive
-- ----------
-- Nessuno dal client: le versioni si pubblicano a mano dal SQL Editor. E' un
-- dato che cambia una volta per rilascio, e mettergli davanti una RPC
-- scrivibile significherebbe dare a ogni utente registrato il permesso di
-- far installare APK a chiunque altro abbiano un account.
-- ---------------------------------------------------------------------------

create table if not exists public.app_releases (
  -- Deve combaciare con il `versionCode` di android/app/build.gradle.kts. E'
  -- la chiave naturale: due righe con lo stesso codice non possono esistere,
  -- altrimenti l'app non saprebbe quale delle due scaricare.
  version_code integer primary key check (version_code > 0),

  -- Solo per mostrarlo all'utente ("1.0.2"). Non serve a confrontare nulla.
  version_name text not null check (length(version_name) between 1 and 32),

  -- URL dell'APK. Con il bucket `releases` e' della forma
  -- <SUPABASE_URL>/storage/v1/object/public/releases/animerank-<code>.apk
  -- In pubblico perche' il download parte da ota_update con una richiesta
  -- anonima, senza header di autenticazione: metterlo dietro una policy
  -- storage.objects obbligherebbe a passare la chiave del chiamante dentro
  -- l'app, e una chiave dentro l'app finisce dentro l'APK che tutti leggono.
  -- Un APK scaricabile da chiunque non e' un segreto: e' il file che
  -- l'utente deve installare, non un dato suo.
  apk_url text not null check (length(apk_url) between 1 and 2048),

  -- Hash SHA-256 dell'APK in esadecimale, 64 caratteri. Se presente viene
  -- verificato dopo il download.
  sha256 text check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$'),

  size_bytes bigint check (size_bytes is null or size_bytes > 0),

  -- Testo mostrato nella schermata di aggiornamento.
  notes text not null default '',

  published_at timestamptz not null default now()
);

comment on table public.app_releases is
  'Le versioni pubblicate dell''app, una riga per rilascio. La aggiorna il maintainer a mano dal SQL Editor; il client la legge solo e confronta version_code con il proprio.';

-- L'app chiede la versione piu' alta. Senza questo indice la domanda diventa
-- una scansione della tabella: oggi sono poche righe, ma il costo di due righe
-- di DDL e' nullo e la domanda e' l'unica che gira a ogni avvio, quindi su
-- centinaia di dispositivi e' quella che si vede.
create index if not exists app_releases_version_idx
  on public.app_releases (version_code desc);

-- RLS attiva: e' il default del progetto, scritto qui esplicitamente perche'
-- una tabella nuova senza la riga esplicita e' una tabella che aspetta che
-- qualcuno se ne accorga.
alter table public.app_releases enable row level security;

-- Lettura per tutti, utente o no.
--
-- Serve anche ad anon perche' il controllo versione parte prima del login:
-- l'utente che apre l'app dal collegamento senza essere entrato deve vedere
-- lo stesso avviso di chi e' gia' dentro. Il dato non e' personale: numero di
-- versione, indirizzo di un file pubblico, note del rilascio.
--
-- Le due righe insieme sono il pattern che `assert_no_anon_reads` controlla: se
-- una tabella ha il GRANT ma non la policy, la funzione la segnala come
-- scrittura lasciata a metà. Solo GRANT senza policy, o solo policy senza
-- GRANT, non bastano a nessuno dei due.
create policy "app_releases: lettura per tutti"
  on public.app_releases for select
  to anon, authenticated
  using (true);

-- Nessuna policy di scrittura, e nessun GRANT: il client non pubblica
-- versioni. Le righe si inseriscono dal SQL Editor, che gira come postgres e
-- non passa per PostgREST.
revoke all on public.app_releases from anon, authenticated;
grant select on public.app_releases to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Bucket per gli APK
--
-- Pubblico, per il motivo scritto sopra sulla colonna apk_url: il download
-- parte senza credenziali. Il limite di dimensione e' alto perche' un APK
-- release con i font dentro supera facilmente i 50 MB, e il default di
-- Supabase (50 MB) farebbe fallire il caricamento senza un motivo che l'utente
-- puo' capire.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'releases',
  'releases',
  true,
  157286400,  -- 150 MB
  array['application/vnd.android.package-archive', 'application/octet-stream']
)
on conflict (id) do nothing;

-- Nessun comment qui dentro: `storage.buckets` e' una tabella di Supabase e un
-- `comment on` le cambierebbe a tutto il progetto. Il nome del file porta il
-- version_code (animerank-<code>.apk) cosi' l'APK si ritrova senza aprire il
-- database.

-- ---------------------------------------------------------------------------
-- Verifica
--
-- Le due assert della 016 e della 017 sono le reti di sicurezza del progetto.
-- Qui si richiama solo la seconda, quella sulle funzioni: questa tabella non
-- aggiunge RPC, e `assert_no_anon_reads` restituirebbe questa tabella come
-- risultato invece di fallire, quindi chiamarla qui non avrebbe senso.
-- ---------------------------------------------------------------------------
do $$
begin
  perform public.assert_no_public_exec_for_anon();
end $$;