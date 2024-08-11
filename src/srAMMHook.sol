// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {NoDelegateCall} from "v4-core/src/NoDelegateCall.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ProtocolFees} from "v4-core/src/ProtocolFees.sol";
import {ERC6909Claims} from "v4-core/src/ERC6909Claims.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Lock} from "v4-core/src/libraries/Lock.sol";
import {CurrencyDelta} from "v4-core/src/libraries/CurrencyDelta.sol";
import {NonZeroDeltaCount} from "v4-core/src/libraries/NonZeroDeltaCount.sol";
import {CurrencyReserves} from "v4-core/src/libraries/CurrencyReserves.sol";
import {Extsload} from "v4-core/src/Extsload.sol";
import {Exttload} from "v4-core/src/Exttload.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {BaseV4Hook} from "src/BaseV4Hook.sol";

contract srAMMHook is BaseV4Hook {
    using PoolIdLibrary for PoolKey;
    using Pool for *;
    using CustomRevert for bytes4;
    using CurrencySettler for Currency;

    constructor(uint256 controllerGasLimit, IPoolManager _poolManager) BaseV4Hook(controllerGasLimit, _poolManager) {}

    function _beforeSwap(
        address, /* sender **/
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata /* hookData **/
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (params.amountSpecified == 0) {
            IPoolManager.SwapAmountCannotBeZero.selector.revertWith();
        }
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);
        pool.checkPoolInitialized();

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

        {
            (Currency inputCurrency, Currency outputCurrency) =
                params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

            poolManager.take(
                inputCurrency,
                address(this),
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified)
            );
            outputCurrency.settle(poolManager, address(this), uint256(uint128(swapDelta.amount1())), false);
        }

        uint256 amountIn =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // return -amountSpecified as specified to no-op the concentrated liquidity swap
        BeforeSwapDelta hookDelta =
            toBeforeSwapDelta(int128(int256(amountIn)), int128(-int256(uint256(uint128(swapDelta.amount1())))));
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    /// @notice Internal swap function to execute a swap, take protocol fees on input token, and emit the swap event
    function _swap(Pool.State storage pool, PoolId id, Pool.SwapParams memory params, Currency inputCurrency)
        internal
        returns (BalanceDelta)
    {
        (BalanceDelta delta, uint256 feeForProtocol, uint24 swapFee, Pool.SwapState memory state) = pool.swap(params);

        // the fee is on the input currency
        if (feeForProtocol > 0) _updateProtocolFees(inputCurrency, feeForProtocol);

        // event is emitted before the afterSwap call to ensure events are always emitted in order
        emit IPoolManager.Swap(
            id, msg.sender, delta.amount0(), delta.amount1(), state.sqrtPriceX96, state.liquidity, state.tick, swapFee
        );

        return delta;
    }
}
