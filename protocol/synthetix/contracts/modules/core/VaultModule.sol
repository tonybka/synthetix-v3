//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";

import "../../storage/Account.sol";
import "../../storage/Pool.sol";

import "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";

import "../../interfaces/IVaultModule.sol";

/**
 * @title Allows accounts to delegate collateral to a pool.
 * @dev See IVaultModule.
 */
contract VaultModule is IVaultModule {
    using SetUtil for SetUtil.UintSet;
    using SetUtil for SetUtil.Bytes32Set;
    using SetUtil for SetUtil.AddressSet;
    using DecimalMath for uint256;
    using Pool for Pool.Data;
    using Vault for Vault.Data;
    using VaultEpoch for VaultEpoch.Data;
    using Collateral for Collateral.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using AccountRBAC for AccountRBAC.Data;
    using Distribution for Distribution.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using ScalableMapping for ScalableMapping.Data;
    using SafeCastU128 for uint128;
    using SafeCastU256 for uint256;
    using SafeCastI128 for int128;
    using SafeCastI256 for int256;

    bytes32 private constant _DELEGATE_FEATURE_FLAG = "delegateCollateral";

    /**
     * @inheritdoc IVaultModule
     */
    function delegateCollateral(
        uint128 accountId,
        uint128 poolId,
        address collateralType,
        uint256 newCollateralAmountD18,
        uint256 leverage
    ) external override {
        FeatureFlag.ensureAccessToFeature(_DELEGATE_FEATURE_FLAG);
        Pool.loadExisting(poolId);
        Account.loadAccountAndValidatePermission(accountId, AccountRBAC._DELEGATE_PERMISSION);

        // Each collateral type may specify a minimum collateral amount that can be delegated.
        // See CollateralConfiguration.minDelegationD18.
        if (newCollateralAmountD18 > 0) {
            CollateralConfiguration.requireSufficientDelegation(
                collateralType,
                newCollateralAmountD18
            );
        }

        // System only supports leverage of 1.0 for now.
        if (leverage != DecimalMath.UNIT) revert InvalidLeverage(leverage);

        // Identify the vault that corresponds to this collateral type and pool id.
        Vault.Data storage vault = Pool.load(poolId).vaults[collateralType];

        // Use account interaction to update its rewards.
        vault.updateRewards(accountId);

        uint256 currentCollateralAmount = vault.currentAccountCollateral(accountId);

        // Ensure current collateral amount differs from the new collateral amount.
        if (newCollateralAmountD18 == currentCollateralAmount) revert InvalidCollateralAmount();

        // If increasing delegated collateral amount,
        // Check that the account has sufficient collateral.
        if (newCollateralAmountD18 > currentCollateralAmount) {
            // Check if the collateral is enabled here because we still want to allow reducing delegation for disabled collaterals.
            CollateralConfiguration.collateralEnabled(collateralType);

            Account.requireSufficientCollateral(
                accountId,
                collateralType,
                newCollateralAmountD18 - currentCollateralAmount
            );
        }

        // Update the account's position for the given pool and collateral type,
        // Note: This will trigger an update in the entire debt distribution chain.
        uint256 collateralPrice = _updatePosition(
            accountId,
            poolId,
            collateralType,
            newCollateralAmountD18,
            currentCollateralAmount,
            leverage
        );

        // If decreasing the delegated collateral amount,
        // check the account's collateralization ratio.
        // Note: This is the best time to do so since the user's debt and the collateral's price have both been updated.
        if (newCollateralAmountD18 < currentCollateralAmount) {
            int256 debt = vault.currentEpoch().consolidatedDebtAmountsD18[accountId];

            // Minimum collateralization ratios are configured in the system per collateral type.abi
            // Ensure that the account's updated position satisfies this requirement.
            CollateralConfiguration.load(collateralType).verifyIssuanceRatio(
                debt < 0 ? 0 : debt.toUint(),
                newCollateralAmountD18.mulDecimal(collateralPrice)
            );

            // Accounts cannot reduce collateral if any of the pool's
            // connected market has its capacity locked.
            _verifyNotCapacityLocked(poolId);
        }

        emit DelegationUpdated(
            accountId,
            poolId,
            collateralType,
            newCollateralAmountD18,
            leverage,
            msg.sender
        );
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getPositionCollateralizationRatio(
        uint128 accountId,
        uint128 poolId,
        address collateralType
    ) external override returns (uint256) {
        return Pool.load(poolId).currentAccountCollateralizationRatio(collateralType, accountId);
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getVaultCollateralRatio(
        uint128 poolId,
        address collateralType
    ) external override returns (uint256) {
        return Pool.load(poolId).currentVaultCollateralRatio(collateralType);
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getPositionCollateral(
        uint128 accountId,
        uint128 poolId,
        address collateralType
    ) external view override returns (uint256 amount, uint256 value) {
        (amount, value) = Pool.load(poolId).currentAccountCollateral(collateralType, accountId);
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getPosition(
        uint128 accountId,
        uint128 poolId,
        address collateralType
    )
        external
        override
        returns (
            uint256 collateralAmount,
            uint256 collateralValue,
            int256 debt,
            uint256 collateralizationRatio
        )
    {
        Pool.Data storage pool = Pool.load(poolId);

        debt = pool.updateAccountDebt(collateralType, accountId);
        (collateralAmount, collateralValue) = pool.currentAccountCollateral(
            collateralType,
            accountId
        );
        collateralizationRatio = pool.currentAccountCollateralizationRatio(
            collateralType,
            accountId
        );
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getPositionDebt(
        uint128 accountId,
        uint128 poolId,
        address collateralType
    ) external override returns (int256) {
        return Pool.load(poolId).updateAccountDebt(collateralType, accountId);
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getVaultCollateral(
        uint128 poolId,
        address collateralType
    ) public view override returns (uint256 amount, uint256 value) {
        return Pool.load(poolId).currentVaultCollateral(collateralType);
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getVaultDebt(uint128 poolId, address collateralType) public override returns (int256) {
        return Pool.load(poolId).currentVaultDebt(collateralType);
    }

    /**
     * @dev Updates the given account's position regarding the given pool and collateral type,
     * with the new amount of delegated collateral.
     *
     * The update will be reflected in the registered delegated collateral amount,
     * but it will also trigger updates to the entire debt distribution chain.
     */
    function _updatePosition(
        uint128 accountId,
        uint128 poolId,
        address collateralType,
        uint256 newCollateralAmount,
        uint256 oldCollateralAmount,
        uint256 leverage
    ) internal returns (uint256 collateralPrice) {
        Pool.Data storage pool = Pool.load(poolId);

        // Trigger an update in the debt distribution chain to make sure that
        // the user's debt is up to date.
        pool.updateAccountDebt(collateralType, accountId);

        // Get the collateral entry for the given account and collateral type.
        Collateral.Data storage collateral = Account.load(accountId).collaterals[collateralType];

        // Adjust collateral depending on increase/decrease of amount.
        if (newCollateralAmount > oldCollateralAmount) {
            collateral.decreaseAvailableCollateral(newCollateralAmount - oldCollateralAmount);
        } else {
            collateral.increaseAvailableCollateral(oldCollateralAmount - newCollateralAmount);
        }

        // If the collateral amount is not negative, make sure that the pool exists
        // in the collateral entry's pool array. Otherwise remove it.
        bool containsPool = collateral.pools.contains(poolId);
        if (newCollateralAmount >= 0 && !containsPool) {
            collateral.pools.add(poolId);
        } else if (containsPool) {
            collateral.pools.remove(poolId);
        }

        // Update the account's position in the vault data structure.
        pool.vaults[collateralType].currentEpoch().updateAccountPosition(
            accountId,
            newCollateralAmount,
            leverage
        );

        // Trigger another update in the debt distribution chain,
        // and surface the latest price for the given collateral type (which is retrieved in the update).
        collateralPrice = pool.recalculateVaultCollateral(collateralType);
    }

    function _verifyNotCapacityLocked(uint128 poolId) internal view {
        Pool.Data storage pool = Pool.load(poolId);

        Market.Data storage market = pool.findMarketWithCapacityLocked();

        if (market.id > 0) {
            revert CapacityLocked(market.id);
        }
    }
}
