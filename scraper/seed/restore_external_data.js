// ============================================================================
// restore_external_data.js - ripristina anime.external_data dal backup
// ============================================================================
//
// Carica il backup { id, external_id, external_data } nella tabella di staging
// public._anime_extdata_restore via PostgREST, in batch. L'update effettivo e
// la drop della staging si fanno a parte in SQL (una singola UPDATE ... FROM).
//
// Uso:
//   $env:SUPABASE_SERVICE_ROLE_KEY="..."; node restore_external_data.js [file.json]
// ============================================================================

const fs = require('fs')
const path = require('path')

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://sjbstiexythmapxmrfyp.supabase.co'
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!SERVICE_ROLE_KEY) {
  console.error('manca SUPABASE_SERVICE_ROLE_KEY')
  process.exit(1)
}

const BATCH = 1000

const dir = __dirname
const argFile = process.argv.slice(2).find((a) => a.endsWith('.json'))
const backupPath = argFile
  ? path.resolve(argFile)
  : path.join(
      dir,
      fs
        .readdirSync(dir)
        .filter((f) => f.startsWith('backup_anime_external_data_') && f.endsWith('.json'))
        .sort()
        .pop(),
    )

const headers = {
  apikey: SERVICE_ROLE_KEY,
  authorization: `Bearer ${SERVICE_ROLE_KEY}`,
  'content-type': 'application/json',
  prefer: 'return=minimal',
}

async function insertBatch(rows) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/_anime_extdata_restore`, {
    method: 'POST',
    headers,
    body: JSON.stringify(rows),
  })
  if (!res.ok) {
    const text = await res.text()
    throw new Error(`insert fallito (${res.status}): ${text.slice(0, 400)}`)
  }
}

async function main() {
  console.log(`backup: ${backupPath}`)
  const raw = JSON.parse(fs.readFileSync(backupPath, 'utf8'))
  const rows = raw
    .filter((r) => r && r.id)
    .map((r) => ({ id: r.id, external_data: r.external_data ?? null }))
  console.log(`righe da ripristinare: ${rows.length}`)

  for (let i = 0; i < rows.length; i += BATCH) {
    const slice = rows.slice(i, i + BATCH)
    await insertBatch(slice)
    console.log(`caricate ${Math.min(i + BATCH, rows.length)}/${rows.length}`)
  }

  console.log('staging pronta. Ora esegui la UPDATE ... FROM e la DROP.')
}

main().catch((e) => {
  console.error('ERR', e.message)
  process.exit(1)
})
