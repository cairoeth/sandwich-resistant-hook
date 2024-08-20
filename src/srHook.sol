// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BaseV4Hook} from "base-v4-hook/BaseV4Hook.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Slot0, Slot0Library} from "v4-core/src/types/Slot0.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {console2 as console} from "forge-std/console2.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";

/// @notice Sandwich resistant hook with v4-like liquidity and swap logic
/// @author cairoeth <https://github.com/cairoeth>
contract srHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using Pool for *;
    using SafeCast for *;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using Slot0Library for Slot0;
    using ProtocolFeeLibrary for *;
    using LPFeeLibrary for uint24;

    struct Checkpoint {
        uint32 blockNumber;
        Slot0 slot0;
    }

    Checkpoint private _lastCheckpoint;
    BalanceDelta private _fairDelta;

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
        uint32 blockNumber = uint32(block.number);
        uint24 fee = 0;

        bool newBlock = _lastCheckpoint.blockNumber != blockNumber;
        // update the top-of-block `slot0` if new block
        if (newBlock) {
            _lastCheckpoint.blockNumber = blockNumber;
            _lastCheckpoint.slot0 = Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(key.toId())));
        } else {
            // constant bid price
            if (!params.zeroForOne) {
                // calculate fair delta
                (_fairDelta,,,) = getFairDelta(
                    key,
                    Pool.SwapParams({
                        tickSpacing: key.tickSpacing,
                        zeroForOne: params.zeroForOne,
                        amountSpecified: params.amountSpecified,
                        sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                        lpFeeOverride: 0
                    })
                );
            }
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    /// @notice The hook called after a swap
    /// @param key The key for the pool
    /// @param params The parameters for the swap
    /// @param delta The amount owed to the caller (positive) or owed to the pool (negative)
    /// @return bytes4 The function selector for the hook
    /// @return int128 The hook's delta in unspecified currency. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        int128 feeAmount = 0;
        if (BalanceDelta.unwrap(_fairDelta) != int256(0) && delta.amount0() > _fairDelta.amount0()) {
            console.log(delta.amount0());
            console.log(delta.amount1());
            console.log(_fairDelta.amount0());
            console.log(_fairDelta.amount1());

            feeAmount = delta.amount0() - _fairDelta.amount0();
            poolManager.take(key.currency0, address(this), uint128(feeAmount));

            _fairDelta = BalanceDelta.wrap(int256(0));
        }

        // TODO: donate feeAmount to LPs

        return (this.afterSwap.selector, feeAmount);
    }

    function getFairDelta(PoolKey calldata key, Pool.SwapParams memory params)
        internal
        returns (BalanceDelta result, uint256 feeForProtocol, uint24 swapFee, Pool.SwapState memory state)
    {
        Slot0 slot0Start = _lastCheckpoint.slot0;
        bool zeroForOne = params.zeroForOne;

        uint128 liquidityStart = poolManager.getLiquidity(key.toId());
        uint256 protocolFee =
            zeroForOne ? slot0Start.protocolFee().getZeroForOneFee() : slot0Start.protocolFee().getOneForZeroFee();

        state.amountSpecifiedRemaining = params.amountSpecified;
        state.amountCalculated = 0;
        state.sqrtPriceX96 = slot0Start.sqrtPriceX96();
        state.tick = slot0Start.tick();
        (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1) = poolManager.getFeeGrowthGlobals(key.toId());
        state.feeGrowthGlobalX128 = zeroForOne ? feeGrowthGlobal0 : feeGrowthGlobal1;
        state.liquidity = liquidityStart;

        // if the beforeSwap hook returned a valid fee override, use that as the LP fee, otherwise load from storage
        {
            uint24 lpFee = params.lpFeeOverride.isOverride()
                ? params.lpFeeOverride.removeOverrideFlagAndValidate()
                : slot0Start.lpFee();

            swapFee = protocolFee == 0 ? lpFee : uint16(protocolFee).calculateSwapFee(lpFee);
        }

        bool exactInput = params.amountSpecified < 0;
        if (params.amountSpecified == 0) return (BalanceDeltaLibrary.ZERO_DELTA, 0, swapFee, state);

        Pool.StepComputations memory step;

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (!(state.amountSpecifiedRemaining == 0 || state.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                nextInitializedTickWithinOneWord(key.toId(), state.tick, params.tickSpacing, zeroForOne);

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext <= TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            if (step.tickNext >= TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
                state.liquidity,
                state.amountSpecifiedRemaining,
                swapFee
            );

            if (!exactInput) {
                unchecked {
                    state.amountSpecifiedRemaining -= step.amountOut.toInt256();
                }
                state.amountCalculated -= (step.amountIn + step.feeAmount).toInt256();
            } else {
                // safe because we test that amountSpecified > amountIn + feeAmount in SwapMath
                unchecked {
                    state.amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                }
                state.amountCalculated += step.amountOut.toInt256();
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            if (protocolFee > 0) {
                unchecked {
                    // step.amountIn does not include the swap fee, as it's already been taken from it,
                    // so add it back to get the total amountIn and use that to calculate the amount of fees owed to the protocol
                    // this line cannot overflow due to limits on the size of protocolFee and params.amountSpecified
                    uint256 delta = (step.amountIn + step.feeAmount) * protocolFee / ProtocolFeeLibrary.PIPS_DENOMINATOR;
                    // subtract it from the total fee and add it to the protocol fee
                    step.feeAmount -= delta;
                    feeForProtocol += delta;
                }
            }

            // update global fee tracker
            if (state.liquidity > 0) {
                unchecked {
                    state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);
                }
            }

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                // if (step.initialized) {
                //     // todo check below
                //     (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = zeroForOne
                //         ? (state.feeGrowthGlobalX128, feeGrowthGlobal1)
                //         : (feeGrowthGlobal0, state.feeGrowthGlobalX128);
                //     int128 liquidityNet =
                //         Pool.crossTick(self, step.tickNext, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
                //     // if we're moving leftward, we interpret liquidityNet as the opposite sign
                //     // safe because liquidityNet cannot be type(int128).min
                //     unchecked {
                //         if (zeroForOne) liquidityNet = -liquidityNet;
                //     }

                //     state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                // }

                // Equivalent to `state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;`
                unchecked {
                    // cannot cast a bool to an int24 in Solidity
                    int24 _zeroForOne;
                    assembly ("memory-safe") {
                        _zeroForOne := and(zeroForOne, 0xff)
                    }
                    state.tick = step.tickNext - _zeroForOne;
                }
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);
            }
        }

        unchecked {
            if (zeroForOne != exactInput) {
                result = toBalanceDelta(
                    state.amountCalculated.toInt128(),
                    (params.amountSpecified - state.amountSpecifiedRemaining).toInt128()
                );
            } else {
                result = toBalanceDelta(
                    (params.amountSpecified - state.amountSpecifiedRemaining).toInt128(),
                    state.amountCalculated.toInt128()
                );
            }
        }
    }

    /// @notice Returns the next initialized tick contained in the same word (or adjacent word) as the tick that is either
    /// to the left (less than or equal to) or right (greater than) of the given tick
    /// @param tick The starting tick
    /// @param tickSpacing The spacing between usable ticks
    /// @param lte Whether to search for the next initialized tick to the left (less than or equal to the starting tick)
    /// @return next The next initialized or uninitialized tick up to 256 ticks away from the current tick
    /// @return initialized Whether the next tick is initialized, as the function only searches within up to 256 ticks
    function nextInitializedTickWithinOneWord(PoolId poolId, int24 tick, int24 tickSpacing, bool lte)
        internal
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, tickSpacing);

            if (lte) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                // all the 1s at or to the right of the current bitPos
                uint256 mask = (1 << (uint256(bitPos) + 1)) - 1;
                uint256 masked = poolManager.getTickBitmap(poolId, wordPos) & mask;

                // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
                initialized = masked != 0;
                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                // start from the word of the next tick, since the current tick state doesn't matter
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);
                // all the 1s at or to the left of the bitPos
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = poolManager.getTickBitmap(poolId, wordPos) & mask;

                // if there are no initialized ticks to the left of the current tick, return leftmost in the word
                initialized = masked != 0;
                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
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
