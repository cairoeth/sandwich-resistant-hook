// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BaseV4Hook} from "base-v4-hook/BaseV4Hook.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";

/// @notice Sandwich resistant hook with v4-like liquidity and swap logic
/// @author cairoeth <https://github.com/cairoeth>
contract srHook is BaseV4Hook {
    using PoolIdLibrary for PoolKey;
    using Pool for *;
    using CurrencySettler for Currency;

    struct Checkpoint {
        uint32 blockNumber;
        Slot0 slot0;
        Pool.State state;
    }

    Checkpoint private _lastCheckpoint;

    /// @notice Sets the constant for protocol fees and base hook.
    /// @param controllerGasLimit The gas limit for the controller.
    /// @param _poolManager The pool manager contract.
    constructor(uint256 controllerGasLimit, IPoolManager _poolManager) BaseV4Hook(controllerGasLimit, _poolManager) {}

    /// @dev Execute swap with custom logic
    /// @param key The key for the pool
    /// @param params The parameters for the swap
    /// @return bytes4 The function selector for the hook
    /// @return BeforeSwapDelta The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    /// @return uint24 Optionally override the lp fee, only used if three conditions are met: 1. the Pool has a dynamic fee, 2. the value's 2nd highest bit is set (23rd bit, 0x400000), and 3. the value is less than or equal to the maximum fee (1 million)
    function _beforeSwap(address, PoolKey calldata key, Pool.SwapParams memory params)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        uint32 blockNumber = uint32(block.number);
        int24 tickBefore = 0;
        Pool.State storage pool = _getPool(id);

        bool newBlock = _lastCheckpoint.blockNumber != blockNumber;
        // update the top-of-block `slot0` if new block
        if (newBlock) {
            tickBefore = pool.slot0.tick();
            _lastCheckpoint.slot0 = pool.slot0;
        }

        BalanceDelta swapDelta;

        {
            Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
            // swap using base pool state only if first swap in new block, otherwise swap with both temporary and base pool states
            if (newBlock) {
                swapDelta = _swap(pool, id, params, inputCurrency, true);
            } else {
                Pool.State storage tempPool = _lastCheckpoint.state;
                // constant bid price
                if (!params.zeroForOne) {
                    tempPool.slot0 = _lastCheckpoint.slot0;
                }
                swapDelta = _swap(tempPool, id, params, inputCurrency, true);
                _swap(pool, id, params, inputCurrency, false);
            }
        }

        _accountPoolBalanceDelta(key, swapDelta, msg.sender);

        // net tokens from and to the pool, based on the swap delta from the base or temporary pool state
        if (params.zeroForOne) {
            poolManager.take(key.currency0, address(this), uint256(uint128(-swapDelta.amount0())));
            key.currency1.settle(poolManager, address(this), uint256(uint128(swapDelta.amount1())), false);
        } else {
            poolManager.take(key.currency1, address(this), uint256(uint128(-swapDelta.amount1())));
            key.currency0.settle(poolManager, address(this), uint256(uint128(swapDelta.amount0())), false);
        }

        // after the first swap in block, initialize the temporary pool state
        if (newBlock) {
            int24 tickAfter = pool.slot0.tick();
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

        return (
            this.beforeSwap.selector,
            params.zeroForOne
                ? toBeforeSwapDelta(-swapDelta.amount0(), -swapDelta.amount1())
                : toBeforeSwapDelta(-swapDelta.amount1(), -swapDelta.amount0()),
            0
        );
    }

    /// @notice Internal swap function to execute a swap, take fees on input token, and emit the swap event
    function _swap(
        Pool.State storage pool,
        PoolId id,
        Pool.SwapParams memory params,
        Currency inputCurrency,
        bool swapUsed
    ) internal returns (BalanceDelta) {
        // return delta;
        (BalanceDelta delta, uint256 feeForProtocol, uint24 swapFee, Pool.SwapState memory state) = pool.swap(params);

        // apply fee on the input currency only for applied swap
        if (swapUsed && feeForProtocol > 0) _updateProtocolFees(inputCurrency, feeForProtocol);

        // emit event only if the swap delta is used
        if (swapUsed) {
            emit IPoolManager.Swap(
                id,
                msg.sender,
                delta.amount0(),
                delta.amount1(),
                state.sqrtPriceX96,
                state.liquidity,
                state.tick,
                swapFee
            );
        }

        return delta;
    }
}
