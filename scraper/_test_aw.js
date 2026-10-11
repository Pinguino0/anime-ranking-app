const aw = require('./animeworld.js')

const titles = [
  'Tengen Toppa Gurren Lagann',
  'JoJo no Kimyou na Bouken: Phantom Blood',
  'Soul Eater Late Show',
  'Dragon Ball: Episode of Bardock',
  'Nihon Animator Mihonichi',
]

;(async () => {
  for (const t of titles) {
    console.log(`\n===== ${t} =====`)
    let cands = []
    try {
      cands = await aw.search(t)
    } catch (e) {
      console.log('  search ERR', e.message)
      continue
    }
    console.log(`  candidati: ${cands.length}`)
    for (const c of cands.slice(0, 6)) {
      const score = Math.max(
        aw.dice(aw.cleaned(t).toLowerCase(), aw.cleaned(c.name).toLowerCase()),
        aw.dice(aw.cleaned(t).toLowerCase(), aw.cleaned(c.jtitle).toLowerCase()),
      )
      console.log(`   ${cands.indexOf(c)}) ${c.path} | name="${c.name}" jtitle="${c.jtitle}" dub=${c.dub} score=${c.score ? '' : score.toFixed(2)}`)
    }
    if (cands.length) {
      try {
        const ep = await aw.episodes(cands[0].path)
        console.log(`  episodes(${cands[0].path}) -> resolved ${cands[0].path} = ${ep.episodes.length} ep`)
        console.log('   primi:', JSON.stringify(cands.length ? (await aw.episodes(cands[0].path)).episodes.slice(0, 3) : []))
      } catch (e) {
        console.log('  episodes ERR', e.message)
      }
    }
    await new Promise((r) => setTimeout(r, 500))
  }
})().catch((e) => {
  console.error('FATAL', e)
  process.exit(1)
})