import type { ChainConfig, Project, ProjectTvlEscrow } from '@l2beat/config'
import {
  assert,
  type AggLayerNativeEtherPreminted,
  AssetId,
} from '@l2beat/shared-pure'
import { AGGLAYER_L2BRIDGE_ADDRESS } from '../aggLayer'

export function getAggLayerNativeEtherPremintedEntry(
  chain: ChainConfig,
  escrow: ProjectTvlEscrow,
  project: Project<'tvlConfig', 'chainConfig'>,
): AggLayerNativeEtherPreminted {
  assert(escrow.sharedEscrow?.type === 'AggLayer')
  assert(chain.sinceTimestamp, 'Chain should have sinceTimestamp')

  // We are hardcoding assetId because aggLayerNativeEtherPreminted is a canonical token
  const assetId = AssetId.create('ethereum', 'native')
  const type = 'aggLayerNativeEtherPreminted'
  const dataSource = `${chain.name}_agglayer`
  const premintedAmount = escrow.sharedEscrow.premintedAmount
    ? BigInt(escrow.sharedEscrow.premintedAmount)
    : BigInt(0)
  const source = 'canonical'
  const category = 'ether'
  const decimals = 18
  const includeInTotal = true
  const isAssociated = false
  const symbol = 'ETH'
  const sinceTimestamp = Math.max(chain.sinceTimestamp, escrow.sinceTimestamp)
  const untilTimestamp = escrow.untilTimestamp

  return {
    assetId: assetId,
    category: category,
    chain: project.id,
    dataSource: dataSource,
    decimals: decimals,
    escrowAddress: escrow.address,
    includeInTotal: includeInTotal,
    isAssociated: isAssociated,
    l2BridgeAddress: AGGLAYER_L2BRIDGE_ADDRESS,
    premintedAmount: premintedAmount,
    project: project.id,
    sinceTimestamp: sinceTimestamp,
    source: source,
    symbol: symbol,
    type: type,
    untilTimestamp: untilTimestamp,
  }
}
