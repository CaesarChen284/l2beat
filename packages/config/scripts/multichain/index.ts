import { getEnv } from '@l2beat/backend-tools'
import { writeFile } from 'fs/promises'

import { fetchMultichainConfig } from './fetchMultichainConfig'
import { generateFinalConfig } from './generateFinalConfig'
import { generateIntermediateConfig } from './generateIntermediateConfig'

main().catch((e) => {
  console.error(e)
  process.exit(1)
})

async function main() {
  const env = getEnv()
  const useCache = env.optionalBoolean('USE_CACHE')
  const config = await fetchMultichainConfig(useCache)
  const intermediate = generateIntermediateConfig(config)

  const comment =
    'This file was autogenerated. Do not modify it by hand, instead use: pnpm update-multichain'

  await writeFile(
    'scripts/multichain/intermediate.json',
    JSON.stringify({ comment, ...intermediate }, null, 2),
  )
  const final = await generateFinalConfig(intermediate)
  await writeFile(
    'src/bridges/multichain-config.json',
    JSON.stringify({ comment, ...final }, null, 2),
  )
}
