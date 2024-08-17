// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {FeeTakingHook} from "v4-core/src/test/FeeTakingHook.sol";
import {srHook} from "src/srHook.sol";
import {DeltaReturningHook} from "v4-core/src/test/DeltaReturningHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

contract srHookTest is Test, Deployers {
    using SafeCast for *;

    srHook hook;
    PoolKey _key;
    PoolModifyLiquidityTest _modifyLiquidityRouter;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
        );
        deployCodeTo("srHook.sol:srHook", abi.encode(0, manager), hookAddr);
        hook = srHook(hookAddr);

        _key = PoolKey(currency0, currency1, 100, 2, IHooks(address(hook)));
        hook.initialize(_key, SQRT_PRICE_1_1, ZERO_BYTES);

        _modifyLiquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(hook)));

        ERC20(Currency.unwrap(currency0)).approve(address(_modifyLiquidityRouter), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(_modifyLiquidityRouter), type(uint256).max);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 100, SQRT_PRICE_1_1, ZERO_BYTES);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    /// @notice Unit test adding liquidity to hook.
    function test_modifyLiquidity() public {
        _modifyLiquidityRouter.modifyLiquidity(_key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    /// @notice Unit test for a single swap, not zero for one.
    function test_swap_single_notZeroForOne() public {
        // add liquidity to hook and poolmanager
        _modifyLiquidityRouter.modifyLiquidity(
            _key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
        initPool(currency0, currency1, IHooks(address(hook)), 100, SQRT_PRICE_1_1, ZERO_BYTES);

        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(amountToSwap),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        BalanceDelta hookDelta = swapRouter.swap(_key, params, testSettings, ZERO_BYTES);
        BalanceDelta nonHookdelta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        assertEq(hookDelta.amount0(), hookDelta.amount0(), "amount0");
        assertEq(nonHookdelta.amount1(), nonHookdelta.amount1(), "amount1");
    }

    /// @notice Unit test for a single swap, zero for one.
    function test_swap_single_zeroForOne() public {
        // add liquidity to hook and poolmanager
        _modifyLiquidityRouter.modifyLiquidity(
            _key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
        initPool(currency0, currency1, IHooks(address(hook)), 100, SQRT_PRICE_1_1, ZERO_BYTES);

        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountToSwap),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        BalanceDelta hookDelta = swapRouter.swap(_key, params, testSettings, ZERO_BYTES);
        BalanceDelta nonHookdelta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        assertEq(hookDelta.amount0(), hookDelta.amount0(), "amount0");
        assertEq(nonHookdelta.amount1(), nonHookdelta.amount1(), "amount1");
    }

    /// @notice Unit test for a failed sandwich attack using the hook.
    function test_swap_failedSandwich() public {
        // add liquidity to hook and poolmanager
        _modifyLiquidityRouter.modifyLiquidity(
            _key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
        initPool(currency0, currency1, IHooks(address(hook)), 100, SQRT_PRICE_1_1, ZERO_BYTES);

        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountToSwap),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        // buy currency0 for currency1, front run
        BalanceDelta delta = swapRouter.swap(_key, params, testSettings, ZERO_BYTES);

        // sandwiched buy currency0 for currency1
        swapRouter.swap(_key, params, testSettings, ZERO_BYTES);

        // sell currency1 for currency0, front run
        params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(delta.amount1()),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        BalanceDelta deltaEnd = swapRouter.swap(_key, params, testSettings, ZERO_BYTES);

        assertLe(deltaEnd.amount0(), -delta.amount0(), "front runner profit");

        vm.roll(block.number + 1);

        params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountToSwap),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        delta = swapRouter.swap(_key, params, testSettings, ZERO_BYTES);
        assertGe(deltaEnd.amount0(), 996911360539219, "state did not reset");
    }

    /// @notice Unit test for a successful sandwich attack without using the hook.
    function test_swap_successfulSandwich() public {
        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountToSwap),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        // buy currency0 for currency1, front run
        BalanceDelta delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // sandwiched buy currency0 for currency1
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // sell currency1 for currency0, front run
        params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(delta.amount1()),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        BalanceDelta deltaEnd = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        assertGe(deltaEnd.amount0(), -delta.amount0(), "front runner loss");

        params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountToSwap),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
    }
}
