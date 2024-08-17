// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BaseV4Hook} from "base-v4-hook/BaseV4Hook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {console2 as console} from "forge-std/console2.sol";

/// @notice Sandwich resistant hook with v4-like liquidity and swap logic
/// @author cairoeth <https://github.com/cairoeth>
contract srHook is BaseV4Hook {
    using PoolIdLibrary for PoolKey;
    using Pool for *;
    using CustomRevert for bytes4;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    struct Checkpoint {
        uint32 blockNumber;
        Slot0 slot0;
        Pool.State state;
    }

    Checkpoint private _lastCheckpoint;

    constructor(uint256 controllerGasLimit, IPoolManager _poolManager) BaseV4Hook(controllerGasLimit, _poolManager) {}

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        uint32 blockNumber = uint32(block.number);
        int24 tickBefore = 0;
        Pool.State storage pool = _getPool(id);
        Pool.State storage tempPool = _lastCheckpoint.state;

        bool newBlock = _lastCheckpoint.blockNumber != blockNumber;
        if (newBlock) {
            tickBefore = pool.slot0.tick();
            _lastCheckpoint.slot0 = pool.slot0;
        } else {
            if (!params.zeroForOne) {
                tempPool.slot0 = _lastCheckpoint.slot0;
            }
        }

        BalanceDelta swapDelta;

        {
            // use base pool swap delta
            if (newBlock) {
                swapDelta = _swap(
                    pool,
                    id,
                    Pool.SwapParams({
                        tickSpacing: key.tickSpacing,
                        zeroForOne: params.zeroForOne,
                        amountSpecified: params.amountSpecified,
                        sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                        lpFeeOverride: 0
                    }),
                    params.zeroForOne ? key.currency0 : key.currency1 // input token
                );
            } else {
                swapDelta = _swap(
                    tempPool,
                    id,
                    Pool.SwapParams({
                        tickSpacing: key.tickSpacing,
                        zeroForOne: params.zeroForOne,
                        amountSpecified: params.amountSpecified,
                        sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                        lpFeeOverride: 0
                    }),
                    params.zeroForOne ? key.currency0 : key.currency1 // input token
                );
                _swap(
                    pool,
                    id,
                    Pool.SwapParams({
                        tickSpacing: key.tickSpacing,
                        zeroForOne: params.zeroForOne,
                        amountSpecified: params.amountSpecified,
                        sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                        lpFeeOverride: 0
                    }),
                    params.zeroForOne ? key.currency0 : key.currency1 // input token
                );
            }
        }

        _accountPoolBalanceDelta(key, swapDelta, msg.sender);

        // net tokens and, if zeroForOne, deincrease the amount of liquidity on the top of block (initial) tick
        BeforeSwapDelta hookDelta;
        if (params.zeroForOne) {
            poolManager.take(key.currency0, address(this), uint256(uint128(-swapDelta.amount0())));
            key.currency1.settle(poolManager, address(this), uint256(uint128(swapDelta.amount1())), false);

            hookDelta = toBeforeSwapDelta(-swapDelta.amount0(), -swapDelta.amount1());
        } else {
            poolManager.take(key.currency1, address(this), uint256(uint128(-swapDelta.amount1())));
            key.currency0.settle(poolManager, address(this), uint256(uint128(swapDelta.amount0())), false);

            hookDelta = toBeforeSwapDelta(-swapDelta.amount1(), -swapDelta.amount0());
        }

        // create temporary pool state for new block
        if (newBlock) {
            int24 tickAfter = pool.slot0.tick();
            console.log("tickBefore", tickBefore);
            console.log("tickAfter", tickAfter);
            _lastCheckpoint.blockNumber = blockNumber;
            // deep copy only values that are used and change in swap logic
            _lastCheckpoint.state.slot0 = pool.slot0;
            _lastCheckpoint.state.feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128;
            _lastCheckpoint.state.feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128;
            _lastCheckpoint.state.liquidity = pool.liquidity;
            // iterate over ticks
            for (int24 tick = tickBefore; tick < tickAfter; tick += key.tickSpacing) {
                _lastCheckpoint.state.ticks[tick] = pool.ticks[tick];
            }
        }

        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    /// @notice Internal swap function to execute a swap, take fees on input token, and emit the swap event
    function _swap(Pool.State storage pool, PoolId id, Pool.SwapParams memory params, Currency inputCurrency)
        internal
        returns (BalanceDelta)
    {
        // return delta;
        (BalanceDelta delta, uint256 feeForProtocol, uint24 swapFee, Pool.SwapState memory state) = pool.swap(params);

        // the fee is on the input currency
        if (feeForProtocol > 0) _updateProtocolFees(inputCurrency, feeForProtocol);

        // event is emitted before the afterSwap call to ensure events are always emitted in order
        emit IPoolManager.Swap(
            id, msg.sender, delta.amount0(), delta.amount1(), state.sqrtPriceX96, state.liquidity, state.tick, swapFee
        );

        return delta;
    }

    /// @notice Set the permissions for the hook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // -- liquidity must be deposited here directly -- //
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // -- custom curve handler -- //
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // -- enable custom curve by skipping poolmanager swap -- //
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
