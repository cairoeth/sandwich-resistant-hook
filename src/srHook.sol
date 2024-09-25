// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice Sandwich resistant hook with v4-like liquidity and swap logic
/// @author cairoeth <https://github.com/cairoeth>
contract srHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using Pool for *;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    struct Checkpoint {
        uint32 blockNumber;
        Slot0 slot0;
        Pool.State state;
    }

    mapping(PoolId => Checkpoint) private _lastCheckpoints;
    mapping(PoolId => BalanceDelta) private _fairDeltas;

    /// @notice Sets the constants for base hook.
    /// @param _poolManager The pool manager contract.
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @dev Execute swap with custom logic
    /// @param key The key for the pool
    /// @param params The parameters for the swap
    /// @return bytes4 The function selector for the hook
    /// @return BeforeSwapDelta The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    /// @return uint24 Optionally override the lp fee, only used if three conditions are met: 1. the Pool has a dynamic fee, 2. the value's 2nd highest bit is set (23rd bit, 0x400000), and 3. the value is less than or equal to the maximum fee (1 million)
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        virtual
        override
        onlyByPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        Checkpoint storage _lastCheckpoint = _lastCheckpoints[poolId];

        // update the top-of-block `slot0` if new block
        if (_lastCheckpoint.blockNumber != uint32(block.number)) {
            _lastCheckpoint.slot0 = Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(poolId)));
        } else {
            // constant bid price
            if (!params.zeroForOne) {
                _lastCheckpoint.state.slot0 = _lastCheckpoint.slot0;
            }

            (_fairDeltas[poolId],,,) = Pool.swap(
                _lastCheckpoint.state,
                Pool.SwapParams({
                    tickSpacing: key.tickSpacing,
                    zeroForOne: params.zeroForOne,
                    amountSpecified: params.amountSpecified,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                    lpFeeOverride: 0
                })
            );
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice The hook called after a swap
    /// @param key The key for the pool
    /// @param delta The amount owed to the caller (positive) or owed to the pool (negative)
    /// @return bytes4 The function selector for the hook
    /// @return int128 The hook's delta in unspecified currency. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4, int128) {
        uint32 blockNumber = uint32(block.number);
        PoolId poolId = key.toId();
        Checkpoint storage _lastCheckpoint = _lastCheckpoints[poolId];

        // after the first swap in block, initialize the temporary pool state
        if (_lastCheckpoint.blockNumber != blockNumber) {
            _lastCheckpoint.blockNumber = blockNumber;

            // iterate over ticks
            (, int24 tickAfter,,) = poolManager.getSlot0(poolId);
            for (int24 tick = _lastCheckpoint.slot0.tick(); tick < tickAfter; tick += key.tickSpacing) {
                (
                    uint128 liquidityGross,
                    int128 liquidityNet,
                    uint256 feeGrowthOutside0X128,
                    uint256 feeGrowthOutside1X128
                ) = poolManager.getTickInfo(poolId, tick);
                _lastCheckpoint.state.ticks[tick] =
                    Pool.TickInfo(liquidityGross, liquidityNet, feeGrowthOutside0X128, feeGrowthOutside1X128);
            }

            // deep copy only values that are used and change in fair delta calculation
            _lastCheckpoint.state.slot0 = Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(poolId)));
            (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1) = poolManager.getFeeGrowthGlobals(poolId);
            _lastCheckpoint.state.feeGrowthGlobal0X128 = feeGrowthGlobal0;
            _lastCheckpoint.state.feeGrowthGlobal1X128 = feeGrowthGlobal1;
            _lastCheckpoint.state.liquidity = poolManager.getLiquidity(poolId);
        }

        BalanceDelta _fairDelta = _fairDeltas[poolId];
        int128 feeAmount = 0;
        if (BalanceDelta.unwrap(_fairDelta) != 0) {
            if (delta.amount0() == _fairDelta.amount0() && delta.amount1() > _fairDelta.amount1()) {
                feeAmount = delta.amount1() - _fairDelta.amount1();
                poolManager.donate(key, 0, uint256(uint128(feeAmount)), "");
            }

            if (delta.amount1() == _fairDelta.amount1() && delta.amount0() > _fairDelta.amount0()) {
                feeAmount = delta.amount0() - _fairDelta.amount0();
                poolManager.donate(key, uint256(uint128(feeAmount)), 0, "");
            }

            _fairDeltas[poolId] = BalanceDelta.wrap(0);
        }

        return (this.afterSwap.selector, feeAmount);
    }

    /// @notice Set the permissions for the hook
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // -- calculate fair delta -- //
            afterSwap: true, // -- dynamics fees calculation -- //
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false, // -- extract fee from delta -- //
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
