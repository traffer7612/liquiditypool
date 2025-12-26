// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/test.sol";
import "../src/LiquidityPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Простой Mintable ERC20 для тестов
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LiquidityPoolTest is Test {
    LiquidityPool public pool;
    MockERC20 public token0;
    MockERC20 public token1;

    address public owner = address(0xA11CE);
    address public protocolFeeRecipient = address(0xBEEF);
    address public lp1 = address(0x1);
    address public lp2 = address(0x2);
    address public trader = address(0x3);

    uint256 public constant INITIAL_MINT = 1_000_000 ether;
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;
    uint256 public constant FEE_DENOMINATOR = 10_000;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");

        // Майнтим тестовые токены
        token0.mint(lp1, INITIAL_MINT);
        token1.mint(lp1, INITIAL_MINT);

        token0.mint(lp2, INITIAL_MINT);
        token1.mint(lp2, INITIAL_MINT);

        token0.mint(trader, INITIAL_MINT);
        token1.mint(trader, INITIAL_MINT);

        // Деплой пула: swapFee=0.30% (30 bps), protocolShare=50% (5000 bps)
        pool = new LiquidityPool(address(token0), address(token1), 30, 5000, protocolFeeRecipient, owner);

        // Аппрувы
        vm.startPrank(lp1);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(lp2);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(trader);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y / 2 + 1;
        z = y;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    }

    function _addInitialLiquidity(address provider, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 liquidity)
    {
        vm.startPrank(provider);
        (uint256 a0, uint256 a1, uint256 liq) =
            pool.addLiquidity(amount0, amount1, 0, 0, provider, block.timestamp + 1 days);
        vm.stopPrank();
        assertEq(a0, amount0, "amount0 used mismatch");
        assertEq(a1, amount1, "amount1 used mismatch");
        liquidity = liq;
    }

    /*//////////////////////////////////////////////////////////////
                            BASIC DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function testDeploymentState() public view {
        assertEq(address(pool.token0()), address(token0), "token0 mismatch");
        assertEq(address(pool.token1()), address(token1), "token1 mismatch");

        (uint112 r0, uint112 r1, uint32 ts) = pool.getReserves();
        assertEq(r0, 0, "reserve0 should be 0");
        assertEq(r1, 0, "reserve1 should be 0");
        assertEq(ts, 0, "timestamp should be 0");

        assertEq(pool.swapFeeBps(), 30);
        assertEq(pool.protocolFeeShareBps(), 5000);
        assertEq(pool.protocolFeeRecipient(), protocolFeeRecipient);
        assertEq(pool.owner(), owner);
    }

    /*//////////////////////////////////////////////////////////////
                          ADD LIQUIDITY TESTS
    //////////////////////////////////////////////////////////////*/

    function testAddLiquidityInitialMintsLPAndUpdatesReserves() public {
        uint256 amount0 = 10_000 ether;
        uint256 amount1 = 20_000 ether;

        uint256 expectedLiquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;

        uint256 liquidity = _addInitialLiquidity(lp1, amount0, amount1);

        // LP токены
        assertEq(liquidity, expectedLiquidity, "liquidity mismatch");
        assertEq(pool.totalSupply(), liquidity + MINIMUM_LIQUIDITY);
        assertEq(pool.balanceOf(lp1), liquidity);
        // MINIMUM_LIQUIDITY минтится на технический burn-адрес контракта
        assertEq(pool.balanceOf(pool.MINIMUM_LIQUIDITY_RECIPIENT()), MINIMUM_LIQUIDITY);

        // Резервы
        (uint112 r0, uint112 r1, uint32 ts) = pool.getReserves();
        assertEq(r0, amount0, "reserve0 mismatch");
        assertEq(r1, amount1, "reserve1 mismatch");
        assertGt(ts, 0, "timestamp not updated");
    }

    function testAddLiquiditySecondProviderGetsProportionalLP() public {
        uint256 amount0 = 10_000 ether;
        uint256 amount1 = 20_000 ether;
        uint256 liq1 = _addInitialLiquidity(lp1, amount0, amount1);

        // Второй LP добавляет ликвидность в той же пропорции
        uint256 amount0_2 = 5_000 ether;
        uint256 amount1_2 = 10_000 ether;

        vm.startPrank(lp2);
        (,, uint256 liq2) = pool.addLiquidity(amount0_2, amount1_2, 0, 0, lp2, block.timestamp + 1 days);
        vm.stopPrank();

        // Ожидаем: liq2 пропорционален totalSupply перед второй поставкой (liq1 + MINIMUM_LIQUIDITY)
        uint256 expectedLiq2 = ((liq1 + MINIMUM_LIQUIDITY) * amount0_2) / amount0;
        assertEq(liq2, expectedLiq2, "second LP liquidity mismatch");

        (uint112 r0, uint112 r1,) = pool.getReserves();
        assertEq(r0, amount0 + amount0_2, "reserve0 mismatch");
        assertEq(r1, amount1 + amount1_2, "reserve1 mismatch");
    }

    function testAddLiquidityRespectsDeadline() public {
        vm.warp(1000);
        uint256 deadline = 900; // уже в прошлом

        vm.startPrank(lp1);
        vm.expectRevert(LiquidityPool.DeadlineExpired.selector);
        pool.addLiquidity(1_000 ether, 1_000 ether, 0, 0, lp1, deadline);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         REMOVE LIQUIDITY TESTS
    //////////////////////////////////////////////////////////////*/

    function testRemoveLiquidityReturnsProportionalTokens() public {
        uint256 amount0 = 10_000 ether;
        uint256 amount1 = 10_000 ether;
        uint256 liq = _addInitialLiquidity(lp1, amount0, amount1);

        uint256 totalSupply = pool.totalSupply();

        vm.startPrank(lp1);
        uint256 lpBalanceBefore = pool.balanceOf(lp1);
        uint256 bal0Before = token0.balanceOf(lp1);
        uint256 bal1Before = token1.balanceOf(lp1);

        (uint256 amount0Out, uint256 amount1Out) = pool.removeLiquidity(liq / 2, 0, 0, lp1, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(amount0Out, (amount0 * (liq / 2)) / totalSupply, "amount0Out mismatch");
        assertEq(amount1Out, (amount1 * (liq / 2)) / totalSupply, "amount1Out mismatch");

        assertEq(pool.balanceOf(lp1), lpBalanceBefore - liq / 2);
        assertEq(token0.balanceOf(lp1), bal0Before + amount0Out);
        assertEq(token1.balanceOf(lp1), bal1Before + amount1Out);
    }

    /*//////////////////////////////////////////////////////////////
                               SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function testSwapExactInput_token0ToToken1_ChargesFeeAndRespectsMinOut() public {
        // Изначальная ликвидность
        uint256 reserve0 = 10_000 ether;
        uint256 reserve1 = 20_000 ether;
        _addInitialLiquidity(lp1, reserve0, reserve1);

        uint256 amountIn = 1_000 ether;
        uint256 swapFeeBps = pool.swapFeeBps(); // 30
        uint256 protocolShareBps = pool.protocolFeeShareBps(); // 5000

        vm.startPrank(trader);

        uint256 traderToken1Before = token1.balanceOf(trader);
        uint256 protocolToken0Before = token0.balanceOf(protocolFeeRecipient);

        // Считаем ожидаемый вывод по формуле контракта
        uint256 amountInWithFee = (amountIn * (FEE_DENOMINATOR - swapFeeBps)) / FEE_DENOMINATOR;
        uint256 expectedOut = (amountInWithFee * reserve1) / (reserve0 + amountInWithFee);

        // Требуем чуть меньше, чтобы не словить округление в меньшую сторону
        uint256 minAmountOut = (expectedOut * 99) / 100;

        uint256 amountOut =
            pool.swapExactInput(address(token0), amountIn, minAmountOut, trader, block.timestamp + 1 days);

        vm.stopPrank();

        assertEq(amountOut, expectedOut, "amountOut mismatch");
        assertEq(token1.balanceOf(trader), traderToken1Before + amountOut, "trader token1 balance mismatch");

        // Проверяем, что протокольная комиссия начислена
        uint256 totalFee = (amountIn * swapFeeBps) / FEE_DENOMINATOR;
        uint256 expectedProtocolFee = (totalFee * protocolShareBps) / FEE_DENOMINATOR;

        uint256 protocolToken0After = token0.balanceOf(protocolFeeRecipient);
        assertEq(protocolToken0After - protocolToken0Before, expectedProtocolFee, "protocol fee mismatch");

        // Инвариант k должен не уменьшиться
        (uint112 r0After, uint112 r1After,) = pool.getReserves();
        uint256 kBefore = uint256(reserve0) * uint256(reserve1);
        uint256 kAfter = uint256(r0After) * uint256(r1After);
        assertGe(kAfter, kBefore, "k decreased (should not)");
    }

    function testSwapExactInput_token1ToToken0_Works() public {
        uint256 reserve0 = 10_000 ether;
        uint256 reserve1 = 20_000 ether;
        _addInitialLiquidity(lp1, reserve0, reserve1);

        uint256 amountIn = 2_000 ether;

        vm.startPrank(trader);
        uint256 bal0Before = token0.balanceOf(trader);

        // просто проверяем, что swap проходит и отдает > 0
        uint256 amountOut = pool.swapExactInput(address(token1), amountIn, 0, trader, block.timestamp + 1 days);
        vm.stopPrank();

        assertGt(amountOut, 0, "amountOut must be > 0");
        assertEq(token0.balanceOf(trader), bal0Before + amountOut, "trader token0 balance mismatch");
    }

    function testSwapRevertsForInvalidToken() public {
        _addInitialLiquidity(lp1, 10_000 ether, 10_000 ether);

        address invalidToken = address(0xDEAD);

        vm.startPrank(trader);
        vm.expectRevert(LiquidityPool.InvalidToken.selector);
        pool.swapExactInput(invalidToken, 100 ether, 0, trader, block.timestamp + 1 days);
        vm.stopPrank();
    }

    function testSwapRespectsDeadline() public {
        _addInitialLiquidity(lp1, 10_000 ether, 10_000 ether);

        vm.warp(1_000);
        uint256 deadline = 900;

        vm.startPrank(trader);
        vm.expectRevert(LiquidityPool.DeadlineExpired.selector);
        pool.swapExactInput(address(token0), 100 ether, 0, trader, deadline);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             PAUSE / ADMIN
    //////////////////////////////////////////////////////////////*/

    function testPauseBlocksCoreFunctions() public {
        _addInitialLiquidity(lp1, 10_000 ether, 10_000 ether);

        // только владелец
        vm.prank(owner);
        pool.pause();

        // swap
        vm.startPrank(trader);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        pool.swapExactInput(address(token0), 100 ether, 0, trader, block.timestamp + 1 days);
        vm.stopPrank();

        // addLiquidity
        vm.startPrank(lp1);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        pool.addLiquidity(100 ether, 100 ether, 0, 0, lp1, block.timestamp + 1 days);
        vm.stopPrank();

        // removeLiquidity
        uint256 lpBalance = pool.balanceOf(lp1);
        vm.startPrank(lp1);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        pool.removeLiquidity(lpBalance / 2, 0, 0, lp1, block.timestamp + 1 days);
        vm.stopPrank();

        // unpause
        vm.prank(owner);
        pool.unpause();
    }

    function testSetFeesOnlyOwnerAndBounds() public {
        // успешное обновление
        vm.prank(owner);
        pool.setFees(50, 3000, address(0xCAFE));
        assertEq(pool.swapFeeBps(), 50);
        assertEq(pool.protocolFeeShareBps(), 3000);
        assertEq(pool.protocolFeeRecipient(), address(0xCAFE));

        // не владелец
        vm.prank(trader);
        vm.expectRevert(); // OwnableUnauthorizedAccount custom error
        pool.setFees(50, 3000, address(0xCAFE));

        // слишком большая комиссия
        vm.prank(owner);
        vm.expectRevert(LiquidityPool.FeeTooHigh.selector);
        pool.setFees(101, 3000, address(0xCAFE));

        // протокольная доля > 100%
        vm.prank(owner);
        vm.expectRevert(LiquidityPool.InvalidParameters.selector);
        pool.setFees(50, FEE_DENOMINATOR + 1, address(0xCAFE));

        // нулевой адрес получателя
        vm.prank(owner);
        vm.expectRevert(LiquidityPool.ZeroAddress.selector);
        pool.setFees(50, 3000, address(0));
    }

    function testSetTimestampProviderOnlyOwner() public {
        address newProvider = address(new DefaultBlockTimestampProvider());

        vm.prank(owner);
        pool.setTimestampProvider(newProvider);
        assertEq(address(pool.timestampProvider()), newProvider);

        vm.prank(trader);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        pool.setTimestampProvider(newProvider);
    }

    /*//////////////////////////////////////////////////////////////
                                 ORACLE
    //////////////////////////////////////////////////////////////*/

    function testPriceCumulativeUpdatesOnLiquidityChange() public {
        _addInitialLiquidity(lp1, 10_000 ether, 20_000 ether);

        (uint112 r0, uint112 r1, uint32 ts1) = pool.getReserves();
        assertGt(ts1, 0);

        uint256 p0Before = pool.price0CumulativeLast();
        uint256 p1Before = pool.price1CumulativeLast();

        // ждём немного и делаем swap, чтобы обновились кумулятивы
        vm.warp(block.timestamp + 100);
        vm.startPrank(trader);
        pool.swapExactInput(address(token0), 1_000 ether, 0, trader, block.timestamp + 1 days);
        vm.stopPrank();

        uint256 p0After = pool.price0CumulativeLast();
        uint256 p1After = pool.price1CumulativeLast();

        assertGt(p0After, p0Before, "price0CumulativeLast not increased");
        assertGt(p1After, p1Before, "price1CumulativeLast not increased");

        (uint112 r0After, uint112 r1After, uint32 ts2) = pool.getReserves();
        assertGt(ts2, ts1);
        assertTrue(r0After != r0 || r1After != r1, "reserves not changed");
    }

    function testConsultTWAPPureFunctions() public view {
        // price0: cumulative grows from 1000 to 2100 за 11 сек
        uint256 start = 1_000;
        uint256 end = 2_100;
        uint32 t0 = 10;
        uint32 t1 = 21;

        uint224 avg0 = pool.consultTWAP0(start, t0, end, t1);
        // (2100 - 1000)/11 = 100
        assertEq(avg0, 100);

        uint224 avg1 = pool.consultTWAP1(start, t0, end, t1);
        assertEq(avg1, 100);
    }
}
