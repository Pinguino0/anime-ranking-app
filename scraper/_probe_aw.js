const aw = require('./animeworld.js')

const probes = [
  ['Dragon Ball: Episode of Bardock', ['Dragon Ball: Episode of Bardock', 'dragon ball episode of bardock', 'bardock', 'episode of bardock']],
  ['Soul Eater Late Show', ['Soul Eater Late Show', 'soul eater', 'late show']],
  ['Nihon Animator Mihonichi', ['Nihon Animator Mihonichi', 'animator mihonichi', 'me me me']],
  ['Cowboy Bebop: Ein no Natsuyasumi', ['Cowboy Bebop', 'ein no natsuyasumi']],
  ['JoJo no Kimyou na Bouken: Phantom Blood', ['JoJo no Kimyou na Bouken', 'phantom blood', 'jojo']],
]

;(async () => {
  for (const [label, queries] of probes) {
    console.log(`\n===== ${label} =====`)
    for (const q of queries) {
      let cands = []
      try {
        cands = await aw.search(q)
      } catch (e) {
        console.log(`  "${q}" -> ERR ${e.message}`)
        continue
      }
      console.log(`  "${q}" -> ${cands.length}`)
      for (const c of cands.slice(0, 8)) {
        console.log(`      ${c.path} | name="${c.name}" | jtitle="${c.jtitle}" | dub=${c.dub}`)
      }
      await new Promise((r) => setTimeout(r, 400))
    }
  }
})().catch((e) => { console.error('FATAL', e); process.exit(1) })