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
    }

    Checkpoint private _lastCheckpoint;

    constructor(uint256 controllerGasLimit, IPoolManager _poolManager) BaseV4Hook(controllerGasLimit, _poolManager) {}

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified == 0) {
            IPoolManager.SwapAmountCannotBeZero.selector.revertWith();
        }
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);
        pool.checkPoolInitialized();

        {
            uint32 blockNumber = uint32(block.number);
            if (_lastCheckpoint.blockNumber != blockNumber) {
                _lastCheckpoint = Checkpoint(blockNumber, pool.slot0);
            } else {
                // if checkpoint exists and it's not zeroForOne, make bid price constant
                if (!params.zeroForOne) {
                    pool.slot0 = _lastCheckpoint.slot0;
                }
            }
        }

        BalanceDelta swapDelta;

        {
            // execute swap, account protocol fees, and emit swap event
            // _swap is needed to avoid stack too deep error
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
        }

        _accountPoolBalanceDelta(key, swapDelta, msg.sender);

        // net tokens and, if zeroForOne, deincrease the amount of liquidity on the top of block (initial) tick
        BeforeSwapDelta hookDelta;
        if (params.zeroForOne) {
            poolManager.take(key.currency0, address(this), uint256(uint128(-swapDelta.amount0())));
            key.currency1.settle(poolManager, address(this), uint256(uint128(swapDelta.amount1())), false);

            this.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams(
                    _lastCheckpoint.slot0.tick() - 2, _lastCheckpoint.slot0.tick(), -swapDelta.amount0(), bytes32(0)
                ),
                ""
            );

            hookDelta = toBeforeSwapDelta(-swapDelta.amount0(), -swapDelta.amount1());
        } else {
            poolManager.take(key.currency1, address(this), uint256(uint128(-swapDelta.amount1())));
            key.currency0.settle(poolManager, address(this), uint256(uint128(swapDelta.amount0())), false);

            hookDelta = toBeforeSwapDelta(-swapDelta.amount1(), -swapDelta.amount0());
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
