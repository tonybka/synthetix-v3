import { ethers } from 'ethers';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { Systems } from '../bootstrap';
import { createStakedPool } from '@synthetixio/main/test/common';
import { AggregatorV3Mock } from '@synthetixio/oracle-manager/typechain-types';
import { createOracleNode } from '@synthetixio/oracle-manager/test/common';
import { SynthRouter } from '../generated/typechain';

export type SynthMarkets = Array<{
  marketId: () => ethers.BigNumber;
  buyAggregator: () => AggregatorV3Mock;
  sellAggregator: () => AggregatorV3Mock;
  synth: () => SynthRouter;
  synthAddress: () => string;
}>;

export type SynthArguments = Array<{
  name: string;
  token: string;
  buyPrice: ethers.BigNumber;
  sellPrice: ethers.BigNumber;
}>;

export function bootstrapSynthMarkets(
  data: SynthArguments,
  r: ReturnType<typeof createStakedPool>
) {
  let contracts: Systems, marketOwner: ethers.Signer;
  before('identify actors', () => {
    contracts = r.systems() as Systems;
    [, , marketOwner] = r.signers();
  });

  const synthMarkets: SynthMarkets = data.map(({ name, token, buyPrice, sellPrice }) => {
    let marketId: ethers.BigNumber,
      buyNodeId: string,
      buyAggregator: AggregatorV3Mock,
      sellNodeId: string,
      sellAggregator: AggregatorV3Mock,
      synthAddress: string,
      synth: SynthRouter;

    before('create price nodes', async () => {
      const buyPriceNodeResult = await createOracleNode(
        r.signers()[0],
        buyPrice,
        contracts.OracleManager
      );
      const sellPriceNodeResult = await createOracleNode(
        r.signers()[0],
        sellPrice,
        contracts.OracleManager
      );
      buyNodeId = buyPriceNodeResult.oracleNodeId;
      buyAggregator = buyPriceNodeResult.aggregator;
      sellNodeId = sellPriceNodeResult.oracleNodeId;
      sellAggregator = sellPriceNodeResult.aggregator;
    });

    before('register synth', async () => {
      marketId = await contracts.SpotMarket.callStatic.createSynth(
        name,
        token,
        await marketOwner.getAddress()
      );
      await contracts.SpotMarket.createSynth(name, token, await marketOwner.getAddress());
      await contracts.SpotMarket.connect(marketOwner).updatePriceData(
        marketId,
        buyNodeId,
        sellNodeId
      );
      synthAddress = await contracts.SpotMarket.getSynth(marketId);
      synth = contracts.Synth(synthAddress);
    });

    before('delegate collateral to market from pool', async () => {
      await contracts.Core.connect(r.owner()).setPoolConfiguration(r.poolId, [
        {
          marketId,
          weightD18: ethers.utils.parseEther('1'),
          maxDebtShareValueD18: ethers.utils.parseEther('1'),
        },
      ]);
    });

    before('allow synth as collateral in system', async () => {
      const tokenAddress = await contracts.SpotMarket.getSynth(marketId);
      await r.systems().Core.connect(r.owner()).configureCollateral({
        tokenAddress,
        oracleNodeId: buyNodeId,
        issuanceRatioD18: '5000000000000000000',
        liquidationRatioD18: '1500000000000000000',
        liquidationRewardD18: '20000000000000000000',
        minDelegationD18: '20000000000000000000',
        depositingEnabled: false,
      });
    });

    return {
      marketId: () => marketId,
      buyAggregator: () => buyAggregator,
      sellAggregator: () => sellAggregator,
      synth: () => synth,
      synthAddress: () => synthAddress,
    };
  });

  const restore = snapshotCheckpoint(r.provider);

  return {
    ...r,
    marketOwner: () => marketOwner,
    systems: () => contracts,
    synthMarkets: () => synthMarkets,
    restore,
  };
}
