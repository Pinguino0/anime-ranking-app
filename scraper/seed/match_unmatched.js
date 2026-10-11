// ============================================================================
// match_unmatched.js - passo C: aggancia i titoli rimasti senza animeunity_id
// ============================================================================
//
// Il passo B (import_anilist.js) aggancia lo slug della sitemap al titolo
// inglese/romaji, ma alcuni anime hanno lo slug ITALIANO (JoJo è il caso
// emblematico: "le-bizzarre-avventure-di-jojo") e il match non li trova.
//
// Questo script ricorre alla ricerca di catalogo POST /livesearch, che risponde
// ad ogni titolo con records che espongono `anilist_id`: il confronto avviene
// quindi per ID (esatto) e non per titolo, spazzando via il problema della
// lingua. Regole:
//   - si prova il titolo pieno e, se non dà record con il nostro anilist_id,
//     sotto-query più corte (togliendo le prime parole, tenendo le ultime),
//     perché /livesearch restituisce al massimo ~8 records per query;
//   - a parità di anilist_id si preferisce la versione sub (dub = 0) alla
//     doppiata (dub = 1), e si registra il flag `animeunity_dub` perché
//     seed_apply.sql linguaggi alle fonti giuste;
//   - chi non trova nulla su AnimeUnity resta senza id: è l'input naturale
//     per il provider di backup (AnimeWorld) quando ci sarà.
//
// Esecuzione:
//   $env:SUPABASE_SERVICE_ROLE_KEY="..." ; node match_unmatched.js
// Ripartibile: prosegue dall'indice salvato in match_progress.json.
// ============================================================================

const fs = require('fs')
const path = require('path')
const au = require('../animeunity.js')

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://sjbstiexythmapxmrfyp.supabase.co'
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!SERVICE_ROLE_KEY) {
  console.error('manca SUPABASE_SERVICE_ROLE_KEY')
  process.exit(1)
}

const DELAY_MS = 350
const PROGRESS_FILE = path.join(__dirname, 'match_progress.json')
const LOG_FILE = path.join(__dirname, 'match_unmatched.log')

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const restHeaders = {
  apikey: SERVICE_ROLE_KEY,
  authorization: `Bearer ${SERVICE_ROLE_KEY}`,
  'content-type': 'application/json',
}

// Il titolo ripulito per la ricerca: fuori parentesi ("(TV)", "(2000)"...),
// e commerciali, tutto il resto collassato in spazi.
function cleaned(value) {
  return String(value ?? '')
    .replace(/[\[\(].*?[\]\)]/g, ' ')
    .replace(/&amp;/g, ' ')
    .replace(/&/g, ' ')
    .replace(/[^a-zA-Z0-9À-ÿ']+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

// Query in ordine di preferenza per un anime.
function searchQueries(anime) {
  const list = []
  const push = (v) => {
    const c = cleaned(v)
    if (c.length >= 3 && !list.includes(c)) list.push(c)
  }

  push(anime.title)
  push(anime.japanese_title)
  for (const s of anime.synonyms ?? []) push(s)

  const base = cleaned(anime.title)
  const tokens = base ? base.split(' ') : []
  // Toglie via via le parole iniziali: le serie lunghe ("JoJo no Kimyou na
  // Bouken: Ougon no Kaze") trovano la puntata giusta chiamando la parte.
  for (let cut = 1; cut <= Math.min(3, tokens.length - 1); cut += 1) {
    push(tokens.slice(cut).join(' '))
  }
  // Toglie le parole finali: titoli con numero/anno in coda ("Ranma 1/2 (2024)
  // 3rd Season") trovano la stagione giusta senza il suffisso.
  for (let drop = 1; drop <= 3 && tokens.length - drop >= 2; drop += 1) {
    push(tokens.slice(0, -drop).join(' '))
  }
  // Le parole finali sono le più caratteristiche (stagione/saga): la ricerca
  // AnimeUnity risponde meglio a "Ougon no Kaze" che al titolo intero.
  for (const n of [6, 4, 3, 2]) {
    if (tokens.length > n) push(tokens.slice(-n).join(' '))
  }
  // Ultima risorsa: la sola prima parola ("Steins", "Jujutsu", "Ranma"):
  // recupera i record che il motore non trova con le altre combinazioni, ma
  // resta in fondo alla lista perché è la query più ambigua.
  if (tokens.length >= 2 && tokens[0].length >= 4 && !/^\d+$/.test(tokens[0])) {
    push(tokens[0])
  }
  return list
}

// Titoli alternativi che il record di AnimeUnity rende disponibili: quello
// italiano, quello inglese del sito e il titolo ricavato dallo slug. Servono a
// `anime.synonyms` (e quindi alla ricerca dell'app) e al sync futuro.
function auTitles(record) {
  const out = []
  const push = (v) => {
    if (typeof v !== 'string' || v.trim() === '') return
    const t = v.trim().replace(/\s+/g, ' ')
    if (t && !out.includes(t)) out.push(t)
  }
  push(record.title)
  push(record.title_eng)
  push(record.title_it)
  if (typeof record.slug === 'string' && record.slug) {
    push(record.slug.split('-').filter(Boolean).join(' '))
  }
  return out
}

function mergeSynonyms(existing, additions) {
  const seen = new Set()
  const out = []
  for (const s of [...(existing ?? []), ...additions]) {
    if (typeof s !== 'string') continue
    const t = s.trim()
    if (!t) continue
    const key = t.toLowerCase()
    if (seen.has(key)) continue
    seen.add(key)
    out.push(t)
  }
  return out
}

// Coefficiente di Dice tra due stringhe di parole: 1 = stesse parole, 0 = niente
// in comune. È il nucleo del fallback fuzzy (stage 2).
function dice(a, b) {
  const ta = (a || '').split(' ').filter(Boolean)
  const tb = (b || '').split(' ').filter(Boolean)
  if (!ta.length || !tb.length) return 0
  const setB = new Set(tb)
  let inter = 0
  for (const w of ta) if (setB.has(w)) inter += 1
  return (2 * inter) / (ta.length + tb.length)
}

// Confronta il nostro titolo (+ il romaji) con i titoli del record AnimeUnity
// (title, title_eng, title_it e parole dello slug) e restituisce il meglio.
// NOTA: NON si usano i `synonyms` del catalogo come titoli "nostri": quelli
// contengono titoli di altre opere (polluti da passi precedenti) e avrebbero
// fatto matchare per sbaglio ("Onigiri" -> "Demon Slayer").
function titleScore(anime, record) {
  const fields = []
  for (const v of [record.title, record.title_eng, record.title_it]) {
    const c = cleaned(v)
    if (c) fields.push(c)
  }
  if (typeof record.slug === 'string' && record.slug) {
    const c = cleaned(record.slug.replace(/-/g, ' '))
    if (c) fields.push(c)
  }
  const ours = [anime.title, anime.japanese_title].map(cleaned).filter(Boolean)
  let best = 0
  for (const o of ours) {
    for (const f of fields) best = Math.max(best, dice(o, f))
  }
  return best
}

// Tipo di AniList vs tipo di AnimeUnity, confrontati dopo normalizzazione
// ("TV_SHORT" == "TV Short").
function typeEquals(anime, record) {
  const normalize = (t) =>
    String(t ?? '')
      .toLowerCase()
      .replace(/[_\-\s]+/g, ' ')
      .trim()
  const a = normalize(anime.media_type)
  const b = normalize(record.type)
  return !!a && a === b
}

// Stessa opera: confronto case-insensitive dei token. Il "containment" da solo
// è troppo permissivo ("Noroi no One Piece" conterrebbe "One Piece"); si
// accetta un doppione solo quando i titoli normalizzati sono quasi identici
// ("Jujutsu Kaisen" == "JUJUTSU KAISEN"). "Tengen Toppa Gurren Lagann" vs
// "Gurren Lagann" (dice 0.67) resta fuori: sono righe duplicate del catalogo
// da sistemare in un passo di dedup dedicato.
function sameWork(a, b) {
  if (a === b) return true
  return dice(cleaned(a).toLowerCase(), cleaned(b).toLowerCase()) >= 0.85
}

// Regola di accettazione per un candidato fuzzy "libero" (record non rivendicato
// da un altro anime del catalogo). Il numero di episodi che casa è il vincolo
// più forte (scarta gli spin-off/special dalla stessa saga con lo stesso titolo
// ma puntate diverse); per i titoli in corso (episodi ignoti) servono
// uguaglianza di tipo e identità quasi totale.
function fuzzyAccepted(score, typeEq, epsAgree) {
  if (epsAgree && score >= 0.8) return true
  if (typeEq && score >= 0.9) return true
  if (score >= 0.95) return true
  return false
}

async function listUnmatched() {
  const rows = []
  let offset = 0
  while (true) {
    const url =
      `${SUPABASE_URL}/rest/v1/anime?select=id,external_id,title,japanese_title,synonyms,episodes,media_type` +
      `&external_data-%3E%3Eanimeunity_id=is.null&limit=1000&offset=${offset}`
    const response = await fetch(url, { headers: restHeaders, signal: AbortSignal.timeout(30000) })
    if (!response.ok) {
      throw new Error(`listUnmatched HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`)
    }
    const page = await response.json()
    rows.push(...page)
    if (page.length < 1000) break
    offset += 1000
  }
  return rows
}

async function patchAnime(id, body) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/anime?id=eq.${id}`, {
    method: 'PATCH',
    headers: { ...restHeaders, prefer: 'resolution=merge-duplicates,return=minimal' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30000),
  })
  if (!response.ok) {
    throw new Error(`patch ${id} HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`)
  }
}

async function listClaimed() {
  const map = new Map()
  let offset = 0
  while (true) {
    const url =
      `${SUPABASE_URL}/rest/v1/anime?select=external_id,title` +
      `&external_data-%3E%3Eanimeunity_id=not.is.null&limit=1000&offset=${offset}`
    const response = await fetch(url, { headers: restHeaders, signal: AbortSignal.timeout(30000) })
    if (!response.ok) {
      throw new Error(`listClaimed HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`)
    }
    const page = await response.json()
    for (const row of page) if (row.external_id) map.set(String(row.external_id), row.title)
    if (page.length < 1000) break
    offset += 1000
  }
  return map
}

function log(line) {
  const ts = new Date().toISOString().replace('T', ' ').slice(0, 19)
  const out = `[${ts}] ${line}`
  console.log(out)
  fs.appendFileSync(LOG_FILE, out + '\n')
}

async function main() {
  const all = await listUnmatched()
  log(`passo C - anime senza animeunity_id: ${all.length}`)

  // Record AnimeUnity già agganciati: `anilist_id -> titolo del detentore`.
  // Se il candidato fuzzy appartiene a un detentore diverso da noi, è un altro
  // anime: si accetta solo se il titolo è lo stesso (doppione di catalogo).
  const claimedMap = await listClaimed()
  log(`record già agganciati nel catalogo: ${claimedMap.size}`)

  let start = 0
  try {
    start = JSON.parse(fs.readFileSync(PROGRESS_FILE, 'utf8')).i || 0
  } catch {
    /* primo giro */
  }
  log(`riprendo dall'indice ${start}`)

  let matched = 0
  let skipped = 0
  // Record AnimeUnity assegnati in questa passata: `claimedMap` e' letto una
  // volta sola all'avvio, quindi senza questo due anime senza id potevano
  // agganciare lo stesso record libero nella stessa esecuzione.
  const takenRecordIds = new Set()

  for (let i = start; i < all.length; i += 1) {
    const anime = all[i]
    const target = String(anime.external_id)

    let chosen = null
    let how = null
    let fuzzyBest = null
    let deniedId = null
    let deniedWho = null

    for (const query of searchQueries(anime)) {
      let records = []
      try {
        records = await au.liveSearch(query)
      } catch (e) {
        log(`  [ERR ${i + 1}/${all.length}] "${anime.title}": ${e.message}`)
        await fs.promises.writeFile(PROGRESS_FILE, JSON.stringify({ i }))
        return
      }
      if (records.length === 0) continue

      // Stage 1: match per anilist_id esatto (infallibile se il dato AU è giusto).
      const exact = records.filter(
        (r) => String(r.anilist_id) === target && !takenRecordIds.has(r.id),
      )
      if (exact.length > 0) {
        chosen = exact.find((r) => r.dub === 0) ?? exact[0]
        how = 'anilist'
        break
      }

      // Stage 2 (accumula): per questa query il miglior candidato per titolo.
      for (const r of records) {
        if (takenRecordIds.has(r.id)) continue
        const score = titleScore(anime, r)
        if (!fuzzyBest || score > fuzzyBest.score) fuzzyBest = { record: r, score }
      }
    }

    if (!chosen && fuzzyBest) {
      const rec = fuzzyBest.record
      const typeEq = typeEquals(anime, rec)
      const epsAgree =
        anime.episodes > 0 &&
        rec.episodes_count > 0 &&
        anime.episodes === rec.episodes_count

      // Il record ha già un detentore nel catalogo (anilist_id di qualcun altro)?
      const claimed =
        rec.anilist_id != null && String(rec.anilist_id) !== target
          ? claimedMap.get(String(rec.anilist_id))
          : null

      if (claimed) {
        // Stesso titolo (a parte le maiuscole) e stesso tipo => doppione di
        // catalogo innocuo: si aggancia alla stessa fonte. Altrimenti il record
        // appartiene a un'altra opera ("One Piece Film Z" non è "GOD VALLEY").
        if (sameWork(anime.title, claimed) && typeEq) {
          chosen = rec
          how = `dup (doppione di "${claimed}")`
        } else {
          deniedId = rec.id
          deniedWho = claimed
        }
      } else if (fuzzyAccepted(fuzzyBest.score, typeEq, epsAgree)) {
        chosen = rec
        how =
          `fuzzy(${fuzzyBest.score.toFixed(2)}, ` +
          `eps:${epsAgree ? 'ok' : anime.episodes ?? '-'}/` +
          `${rec.episodes_count ?? '-'}, ` +
          `tipo:${typeEq})`
      }
    }

    if (!chosen) {
      skipped += 1
      if (deniedId) {
        log(
          `  [SKIP ${i + 1}/${all.length}] denied: ${anime.title} (anilist ${target})` +
          ` -> record ${deniedId} appartiene a "${deniedWho}"`,
        )
      } else if (fuzzyBest) {
        log(
          `  [SKIP ${i + 1}/${all.length}] no match: ${anime.title} (anilist ${target})` +
          ` [fuzzy best ${fuzzyBest.score.toFixed(2)} ${fuzzyBest.record.slug} al=${fuzzyBest.record.anilist_id}]`,
        )
      } else {
        log(`  [SKIP ${i + 1}/${all.length}] no match: ${anime.title} (anilist ${target})`)
      }
    } else {
      // Conteggio episodi: quello noto del catalogo, ma zero (in corso) è un
      // non-valore: si ripiega su real_episodes_count, altrimenti null.
      const eps =
        chosen.episodes_count > 0
          ? chosen.episodes_count
          : chosen.real_episodes_count > 0
            ? chosen.real_episodes_count
            : null

      const newData = {
        animeunity_id: chosen.id,
        animeunity_eps: eps,
        animeunity_dub: chosen.dub === 1,
      }
      const newSynonyms = mergeSynonyms(anime.synonyms, auTitles(chosen))
      takenRecordIds.add(chosen.id)
      matched += 1
      log(
        `  [MATCH ${i + 1}/${all.length}] ${anime.title} (anilist ${target}, ${anime.episodes}ep)` +
        ` -> au ${chosen.id} ${chosen.slug} (${eps}ep, ${chosen.dub ? 'dub' : 'sub'}, ${chosen.type})` +
        ` +synonyms ${auTitles(chosen).length} [${how}]`,
      )

      try {
        // Niente patch su `episodes`: quella colonna ha un vincolo (>= 1 o
        // NULL) e il conteggio vero arriva da AnimeUnity al momento del
        // playback. Qui si basta a esternal_data + synonyms.
        await patchAnime(anime.id, {
          synonyms: newSynonyms,
          external_data: newData,
        })
      } catch (e) {
        log(`  [PATCH ERR ${i + 1}/${all.length}] ${anime.title}: ${e.message}`)
      }
    }

    await fs.promises.writeFile(PROGRESS_FILE, JSON.stringify({ i: i + 1 }))
    await sleep(DELAY_MS)
  }

  log(`passo C finito: ${matched} match, ${skipped} senza match su AnimeUnity`)
}

main().catch((e) => {
  console.error('ERR', e.message)
  process.exit(1)
})