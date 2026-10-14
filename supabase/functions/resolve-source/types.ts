// ============================================================================
// resolve-source/types.ts - il contratto fra la Edge Function e i provider
// ============================================================================
//
// Questo file e' il punto in cui il provider vero si innesta. Un resolver
// implementa [VideoResolver] e fa una cosa sola: dato un indirizzo canonico,
// restituire un indirizzo riproducibile con gli header che servono ad aprirlo.
//
// Non riceve l'utente e non scrive nel database. E' deliberato: un resolver che
// sapesse chi ha chiesto il video potrebbe iniziare a servire contenuti diversi
// in base a chi chiede, e il modello di Aniyomi funziona perche' non lo fa — il
// risolutore restituisce il video di quell'episodio e basta. Chi stabilisce se
// un utente puo' guardare un episodio e' il database, non il resolver.
//
// I campi del risultato sonoVolte perche' ognuno serve al player:
//
//   resolvedUrl  l'indirizzo effimero da aprire
//   headers      la `Referer` / `Authorization` / i cookie senza cui il CDN
//                risponde 403 anche con l'URL giusto
//   sourceType   mp4 o hls: il player ne fa un caso diverso, e il provider e'
//                l'unico che sa quale sia — l'app non deve indovinarlo
//   expiresAt    quando il link muore. Il client lo usa per non riusare un
//                token scaduto e per decidere se risolvere di nuovo
// ============================================================================

/** Come si apre la sorgente, come nell'enum `episode_source_type`. */
export type SourceType = 'mp4' | 'hls' | 'iframe'

/** La riga di `episode_sources` che l'Edge Function ha letto. */
export interface SourceRow {
  id: string
  sourceUrl: string | null
  canonicalUrl: string | null
  sourceType: SourceType
  quality: string | null
  language: string | null
}

/** Il provider che sa risolvere, letto dalla riga corrispondente in `providers`. */
export interface ProviderRow {
  slug: string
  label: string
  resolveEndpoint: string
}

/**
 * I metadati dell'episodio che la fonte canalizza.
 *
 * Non sono obbligatori per la risoluzione del provider primario — un canonico
 * AnimeWorld si risolve dal solo URL — ma per i provider di backup servono:
 * un fallback deve potere ritrovare lo stesso episodio altrove, e quell'"altrove"
 * lo si trova per titolo e numero episodio, non per l'URL del provider caduto.
 */
export interface AnimeEpisodeMeta {
  /** Numero dell'episodio, come in `episodes.episode_num`. */
  episodeNumber: number | null

  /** `anime.title`: il titolo principale (romaji) dal catalogo. */
  title: string | null

  /** `anime.japanese_title`. */
  japaneseTitle: string | null

  /** `anime.synonyms`: i titoli alternativi (inglese, italiano, ...). */
  synonyms: string[]

  /** `anime.external_id`, quando la fonte esterna e' MyAnimeList. */
  malId: number | null

  /**
   * `anime.external_id` quando la fonte esterna e' AniList.
   *
   * Oggi il catalogo e' costruito su AniList, quindi questo e' l'identificativo
   * affidabile dell'opera. Serve ai fallback che devono ritrovare lo *stesso*
   * anime altrove senza agganciarlo per titolo: AnimeSaturn, per esempio,
   * pubblica il link AniList nella pagina dell'anime, e confrontare quell'id
   * dice con certezza se la pagina e' la stessa opera.
   */
  anilistId: number | null

  /**
   * Tutti i titoli utili a cercare l'anime altrove, gia' ripuliti e senza
   * duplicati: titolo principale, giapponese e sinonimi.
   */
  titles: string[]

  /** `anime.year`: l'anno di inizio, per disambiguare le stagioni. */
  year: number | null
}

/** Cosa arriva al resolver. */
export interface ResolveRequest {
  /** L'id della fonte in `episode_sources`, per risposte e per log. */
  source: SourceRow

  /** L'indirizzo canonico da risolvere. Sempre presente: se manca, la funzione ha gia' risposto 400. */
  canonicalUrl: string

  /** Il provider che si occupa di questa risoluzione. */
  provider: ProviderRow

  /** Metadati dell'episodio, per i provider che devono ritrovare la stessa fonte altrove. */
  anime?: AnimeEpisodeMeta
}

/** Cosa il resolver restituisce. */
export interface ResolveResult {
  /** L'indirizzo effimero, da aprire subito e da non salvare. */
  resolvedUrl: string

  /** Header necessari ad aprirlo. */
  headers: Record<string, string>

  /** Il formato effettivo, che puo' non coincidere con quello dichiarato. */
  sourceType: SourceType

  /** Scadenza ISO 8601 del link, quando il provider la dichiara. */
  expiresAt?: string
}

/**
 * Un adapter di risoluzione.
 *
 * `endpoint` deve corrispondere a `providers.resolve_endpoint`: e' il nome con
 * cui la tabella indica questo adapter. Se i due non coincidono la funzione
 * risponde 501, che e' un modo piu' utile di fallire che ignorare la fonte e
 * restituire un link rotto.
 */
export interface VideoResolver {
  readonly endpoint: string
  resolve(request: ResolveRequest): Promise<ResolveResult>
}
