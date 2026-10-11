const aw = require('./animeworld.js')

const probes = [
  'Re:Zero kara Hajimeru Isekai Seikatsu',
  'Re:Zero kara Hajimeru Isekai Seikatsu 3',
  'Re:Zero kara Hajimeru Isekai Seikatsu 4',
  'Sword Art Online',
  'One Punch Man 3',
  'Chainsaw Man',
]

;(async () => {
  for (const q of probes) {
    let c = []
    try { c = await aw.search(q) } catch (e) { console.log(`"${q}" ERR ${e.message}`); continue }
    console.log(`\n"${q}" -> ${c.length}`)
    for (const x of c) console.log(`    ${x.path} | ${x.jtitle || x.name}`)
    await new Promise((r) => setTimeout(r, 300))
  }
})()