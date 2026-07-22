// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "../../lib/forge-std/src/Test.sol";

interface IWorldSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

contract WcmSwapRouterProbe {
    using SafeERC20 for IERC20;

    IWorldSwapRouter internal immutable router;

    constructor(address _router) {
        router = IWorldSwapRouter(_router);
    }

    function exactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        returns (uint256 spent, uint256 received, uint256 returnedAmountOut)
    {
        uint256 tokenInBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(address(router), amountIn);

        returnedAmountOut = router.exactInputSingle(
            IWorldSwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: 0,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );

        IERC20(tokenIn).forceApprove(address(router), 0);

        spent = tokenInBefore - IERC20(tokenIn).balanceOf(address(this));
        received = IERC20(tokenOut).balanceOf(address(this)) - tokenOutBefore;
    }

    function exactOutput(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxAmountIn, uint256 deadline)
        external
        returns (uint256 spent, uint256 received, uint256 returnedAmountIn)
    {
        uint256 tokenInBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(address(router), maxAmountIn);

        returnedAmountIn = router.exactOutputSingle(
            IWorldSwapRouter.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: 0,
                recipient: address(this),
                deadline: deadline,
                amountOut: amountOut,
                amountInMaximum: maxAmountIn,
                sqrtPriceLimitX96: 0
            })
        );

        IERC20(tokenIn).forceApprove(address(router), 0);

        spent = tokenInBefore - IERC20(tokenIn).balanceOf(address(this));
        received = IERC20(tokenOut).balanceOf(address(this)) - tokenOutBefore;
    }
}

contract WcmSwapRouterProbeForkTest is Test {
    uint256 internal constant MEGAETH_CHAIN_ID = 4326;
    address internal constant WORLD_SWAP_ROUTER = 0x94b6706FA26a4F3DCF501Ff25E1e4628B75AdC69;
    address internal constant USDM = 0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7;
    address internal constant WITRY = 0x15B271D9012b5820FC42b1c495B4C1e206547De5;
    uint256 internal constant FORK_BLOCK = 21_959_976;

    WcmSwapRouterProbe internal probe;

    function setUp() public {
        string memory rpcUrl = vm.envString("RPC_URL_4326");
        assertEq(vm.parseUint(vm.toString(vm.rpc(rpcUrl, "eth_chainId", "[]"))), MEGAETH_CHAIN_ID, "rpc chain id");
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        vm.chainId(MEGAETH_CHAIN_ID);
        probe = new WcmSwapRouterProbe(WORLD_SWAP_ROUTER);
    }

    function testExactInputSellWitryForUsdmFromContract() public {
        uint256 amountIn = 600e18;
        uint256 minAmountOut = 12e18;

        deal(WITRY, address(probe), amountIn);

        (uint256 spent, uint256 received, uint256 returnedAmountOut) =
            probe.exactInput(WITRY, USDM, amountIn, minAmountOut, block.timestamp + 1 hours);

        assertEq(spent, amountIn, "spent unexpected wiTRY amount");
        assertGe(received, minAmountOut, "received too little USDm");
        assertEq(returnedAmountOut, received, "router return amount mismatch");
        assertEq(IERC20(USDM).balanceOf(address(probe)), received, "USDm did not land on probe");
    }

    function testExactInputSellUsdmForWitryFromContract() public {
        uint256 amountIn = 12e18;
        uint256 minAmountOut = 500e18;

        deal(USDM, address(probe), amountIn);

        (uint256 spent, uint256 received, uint256 returnedAmountOut) =
            probe.exactInput(USDM, WITRY, amountIn, minAmountOut, block.timestamp + 1 hours);

        assertEq(spent, amountIn, "spent unexpected USDm amount");
        assertGe(received, minAmountOut, "received too little wiTRY");
        assertEq(returnedAmountOut, received, "router return amount mismatch");
        assertEq(IERC20(WITRY).balanceOf(address(probe)), received, "wiTRY did not land on probe");
    }

    function testExactOutputBuyWitryWithUsdmFromContract() public {
        uint256 amountOut = 600e18;
        uint256 maxAmountIn = 15e18;

        deal(USDM, address(probe), maxAmountIn);

        (uint256 spent, uint256 received, uint256 returnedAmountIn) =
            probe.exactOutput(USDM, WITRY, amountOut, maxAmountIn, block.timestamp + 1 hours);

        assertLe(spent, maxAmountIn, "spent too much USDm");
        assertGe(received, amountOut, "received too little wiTRY");
        assertEq(returnedAmountIn, spent, "router return amount mismatch");
        assertEq(IERC20(WITRY).balanceOf(address(probe)), received, "wiTRY did not land on probe");
    }

    function testExactOutputBuyUsdmWithWitryFromContract() public {
        uint256 amountOut = 12e18;
        uint256 maxAmountIn = 600e18;

        deal(WITRY, address(probe), maxAmountIn);

        (uint256 spent, uint256 received, uint256 returnedAmountIn) =
            probe.exactOutput(WITRY, USDM, amountOut, maxAmountIn, block.timestamp + 1 hours);

        assertLe(spent, maxAmountIn, "spent too much wiTRY");
        assertGe(received, amountOut, "received too little USDm");
        assertEq(returnedAmountIn, spent, "router return amount mismatch");
        assertEq(IERC20(USDM).balanceOf(address(probe)), received, "USDm did not land on probe");
    }
}
