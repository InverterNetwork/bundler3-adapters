# WCM Bundler3 Adapter Spec

Status: working draft

This document tracks the design for a Bundler3-native adapter that swaps through the
World Markets / WCM `SwapRouter`, with initial focus on MegaETH `USDm <-> wiTRY`
flows used to open, increase, delever, and close Morpho Blue positions.

The intent is to keep implementation decisions close to Morpho's existing
Bundler3 adapter model, especially `CoreAdapter`, `GeneralAdapter1`, and
`ParaswapAdapter`.

## Goals

- Add a Bundler3-native WCM swap adapter.
- Compose with `GeneralAdapter1` rather than embedding Morpho position logic.
- Support exact-input and exact-output swaps through World Markets.
- Include a `buyMorphoDebt` helper so close/delever bundles can buy the live
  current Morpho debt amount at execution time.
- Keep the adapter stateless and avoid persistent token balances.
- Enforce all swap bounds by balance delta, not by trusting router return values.

## Handoff Target

The intended implementation handoff is ready when the spec and task framing are
clear enough for an implementation agent to build the adapter and verify it with
a MegaETH fork test.

Minimum verification criterion:

- a MegaETH fork test invokes all three adapter functions successfully:
  - `sell`
  - `buy`
  - `buyMorphoDebt`
- a MegaETH fork test invokes all three adapter functions from inside a
  `GeneralAdapter1.morphoFlashLoan` callback/reenter flow
- each invocation goes through the deployed World `SwapRouter`
- each invocation enforces caller-supplied bounds by balance delta
- each invocation forwards bought tokens to the requested `receiver`
- `buyMorphoDebt` reads live Morpho debt during execution and buys at least the
  loan token amount needed for that debt
- flashloan repayment succeeds atomically, and `WcmAdapter` plus
  `GeneralAdapter1` finish with no USDm/wiTRY balances or World router approvals

## Handoff Resolution Checklist

These are the remaining items to resolve before handing implementation to an
agent with the fork-test verification target above.

1. Lock the v1 adapter scope.
   - Decision: hard-gate v1 to `USDm <-> wiTRY` on MegaETH.
   - V1 should not support arbitrary World-listed base-token pairs.

2. Lock constructor configuration.
   - Decision: use immutable `bundler3`, `morpho`, `router`, `chainId`,
     `routerCodeHash`, `usdm`, `witry`, `marketOracle`, `marketIrm`, and
     `marketLltv` values.
   - Use one adapter deployment per chain/router/reference Morpho market.

3. Lock exact interface names and parameters.
   - Decision: expose `sell`, `buy`, and `buyMorphoDebt` as defined below.
   - Revisit only if implementation discovers a WCM-specific blocker.

4. Lock deadline behavior.
   - Decision: caller provides an explicit deadline and the adapter requires
     `deadline >= block.timestamp`.
   - Rationale: aggregator-style adapters such as `ParaswapAdapter` do not need
     an adapter-level deadline because venue-specific deadline behavior is
     inside the opaque swap calldata. WCM uses structured router params, so the
     bundle builder should pass the router deadline explicitly.
   - There is no `deadline == 0` convenience mode in v1.

5. Lock dust/minimum-order behavior.
   - Decision: reject zero amounts and zero bounds only; do not read World
     minimum-order values in the hot path.
   - Rationale: WCM `exactInputSingle` / `exactOutputSingle` use raw ERC-20
     units. World position decimals matter for quote/native packed functions,
     which should live in the off-chain bundle builder, not the adapter.
   - The adapter does not enforce position-decimal minimums for raw router
     exact-in/exact-out amounts.
   - Fork note: the wiTRY/USDm order book returned `readMinOrderQuantity() =
     500000` at block `18981853`, which corresponds to `500 wiTRY` in this
     market. Small executable swaps below that threshold can revert with
     `QuantityTooLow()`.

6. Lock rescue behavior.
   - Decision: do not add owner/governance rescue in v1.
   - Rationale: Bundler3 adapters are not ownable. `CoreAdapter` already exposes
     `erc20Transfer` and `nativeTransfer` through Bundler3 for balance
     forwarding/skimming, and adapter balances are not meant to be protected or
     persistent.
   - No ownership should be introduced solely for rescue.

7. Identify fork-test prerequisites.
   - Decision: use the fork configuration and market parameters in
     [Fork-Test Inputs](#fork-test-inputs).
   - Decision: create a fresh fork position for `buyMorphoDebt`; do not rely on
     the old live borrower because its remaining debt is dust-sized.

8. Verify World exact-output behavior.
   - Decision: `exactOutputSingle` works from a contract caller with
     `msg.value == 0` for both directions needed by the adapter when order size
     is above the World book minimum.
   - Probe result: buying `600 wiTRY` with USDm and buying `12 USDm` with wiTRY
     both passed on a MegaETH fork at block `18981853`.
   - Small exact-output probes below the book minimum reverted with
     `QuantityTooLow()`.

9. Verify World contract-caller eligibility.
   - Decision: a freshly deployed probe contract can call the router
     successfully in both directions on the reference fork, and output lands on
     the probe/router `msg.sender`.
   - There is no current evidence of contract registration, KYB, or allowlisting.
   - The final adapter fork test should still exercise the deployed adapter code
     path, but this is now an implementation verification item rather than a
     discovery blocker.

## Non-Goals

- Do not build a standalone position-management wrapper.
- Do not expose a direct public router wrapper as the long-term contract
  boundary.
- Do not implement on-chain quote or slippage policy in v1.
- Do not put World order-book discovery or liquidity sizing in the adapter hot path.
- Do not change Bundler3 or `GeneralAdapter1` unless adapter integration proves it
  is strictly necessary.

## Settled Decisions

### Boundary

The adapter should be Bundler3-native:

- inherit `CoreAdapter`
- gate callable actions with `onlyBundler3`
- expect tokens to have been sent to the adapter before each operation
- expose explicit `receiver` parameters
- forward bought tokens by balance delta
- leave no intended persistent balances
- avoid standing approvals by approving for the call and clearing afterwards
- compose with `GeneralAdapter1` in bundles

The direct World `SwapRouter` call is an implementation detail inside the adapter.

### Repository Setup

Development happens in this forked Bundler3-compatible repo:

- origin: `InverterNetwork/bundler3-adapters`
- upstream: `morpho-org/bundler3`

This avoids forcing Solidity `0.8.28` Bundler3 adapter work into the
`ITRY-contracts` Solidity `0.8.20` / LayerZero-oriented repo.

### Fund Routing

The adapter must not rely on World router `recipient`, because the current World
source says it is ignored.

The adapter should assume the router sends output to `msg.sender`. Since the
adapter is `msg.sender` to the router, the adapter measures the bought-token
balance delta and transfers the delta to `receiver`.

This mirrors the important part of `ParaswapAdapter.swap`.

### Slippage and Quotes

The adapter should not compute slippage policy on-chain in v1.

Execution accepts caller-supplied bounds:

- exact input: `amountIn` plus `minAmountOut`
- exact output: `amountOut` plus `maxAmountIn`

The off-chain bundle builder is responsible for quoting World, checking depth,
applying slippage policy, and choosing safe bounds. The adapter only enforces
those bounds with source and destination token balance deltas.

### Swap Directions

Levered position flows need both directions:

- opening or increasing leverage: `USDm -> wiTRY`
- closing or delevering: `wiTRY -> USDm`

Depth is needed in both directions on World. The adapter cannot solve thin CLOB
liquidity.

### buyMorphoDebt

The adapter should include a `buyMorphoDebt` equivalent to Paraswap's helper.

Purpose: buy the live current Morpho debt amount during execution, rather than
relying on an off-chain debt estimate that can drift because of interest accrual.
For the v1 USDm path, the swap target is rounded up to the next World USDm
position tick so execution buys at least the amount needed to cover debt.

Expected behavior:

- require `onBehalf == Bundler3.initiator()` so normal close flows cannot be
  tricked into buying and repaying another borrower's debt
- require `marketParams` to match the deployment-pinned USDm/wiTRY Morpho market
- read `MorphoBalancesLib.expectedBorrowAssets(MORPHO, marketParams, onBehalf)`
- revert if debt is zero
- exact-output swap into `marketParams.loanToken`
- for this v1 `USDm` loan-token path, round the target output amount up to the
  next USDm World position tick before swapping
- enforce `srcSpent <= maxAmountIn`
- forward bought loan token to `receiver`, usually `GeneralAdapter1`
- refund unspent source token to `onBehalf`, not to the operational repay
  receiver

The USDm tick is `0.0001 USDm`, or `1e14` raw units. Rounding up by at most one
tick avoids exact-output underbuy edges caused by World position precision. The
bundle should repay the live Morpho debt and then transfer or otherwise handle
any tiny surplus loan-token balance according to normal Bundler3 balance
plumbing.

## Proposed V1 Interface

Names are provisional.

```solidity
function sell(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    bool sellEntireBalance,
    address receiver,
    uint256 deadline
) external;

function buy(
    address tokenIn,
    address tokenOut,
    uint256 amountOut,
    uint256 maxAmountIn,
    address receiver,
    uint256 deadline
) external;

function buyMorphoDebt(
    address tokenIn,
    MarketParams calldata marketParams,
    uint256 maxAmountIn,
    address onBehalf,
    address receiver,
    uint256 deadline
) external;
```

Potential internal shape:

```solidity
function _swapExactIn(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address receiver,
    uint256 deadline
) internal returns (uint256 spent, uint256 received);

function _swapExactOut(
    address tokenIn,
    address tokenOut,
    uint256 amountOut,
    uint256 maxAmountIn,
    address receiver,
    address refundReceiver,
    uint256 deadline
) internal returns (uint256 spent, uint256 received);
```

## Execution Semantics

### Exact Input `sell`

1. Optionally replace `amountIn` with adapter `tokenIn` balance when
   `sellEntireBalance == true`.
2. Revert if `amountIn == 0`.
3. Revert if `minAmountOut == 0`.
4. Revert if `receiver == address(0)` or `receiver == address(this)`.
5. Record `tokenIn` and `tokenOut` balances.
6. Approve the World router for the swap.
7. Call `exactInputSingle` with:
   - `tokenIn`
   - `tokenOut`
   - `fee = 0`
   - `recipient = address(this)`
   - `deadline`
   - `amountIn`
   - `amountOutMinimum = minAmountOut`
   - `sqrtPriceLimitX96 = 0`
8. Clear router approval.
9. Compute source spent and destination received by balance delta.
10. Require `spent <= amountIn`.
11. Require `spent == amountIn`.
12. Require `received >= minAmountOut`.
13. Transfer `received` `tokenOut` to `receiver`.

### Exact Output `buy`

1. Revert if `amountOut == 0`.
2. Revert if `maxAmountIn == 0`.
3. Revert if `receiver == address(0)` or `receiver == address(this)`.
4. Record `tokenIn` and `tokenOut` balances.
5. Approve the World router for the swap.
6. Call `exactOutputSingle` with:
   - `tokenIn`
   - `tokenOut`
   - `fee = 0`
   - `recipient = address(this)`
   - `deadline`
   - `amountOut`
   - `amountInMaximum = maxAmountIn`
   - `sqrtPriceLimitX96 = 0`
7. Clear router approval.
8. Compute source spent and destination received by balance delta.
9. Require `spent <= maxAmountIn`.
10. Require `received >= amountOut`.
11. Transfer `received` `tokenOut` to `receiver`.
12. Refund up to the unspent `maxAmountIn - spent` source-token remainder to
    `receiver`.

`buyMorphoDebt` uses the same exact-output primitive, but passes `onBehalf` as
the source-token refund receiver. This prevents unused wiTRY from being stranded
on `GeneralAdapter1` when the bought USDm must be sent there for `morphoRepay`.

Note: if World exact-output returns exactly `amountOut` but the router transfers
slightly more because of rounding, the adapter should forward the actual balance
delta. The bundle builder should account for that possibility.

`buy` uses the caller-provided `amountOut` directly. The debt-rounding behavior
described above is specific to `buyMorphoDebt`.

## Known World / WCM Facts

MegaETH:

- chain id: `4326`
- World Exchange: `0x5e3Ae52EbA0F9740364Bd5dd39738e1336086A8b`
- World SwapRouter: `0x94b6706fa26a4f3dcf501ff25e1e4628b75adc69`
- World SwapRouter code hash, queried June 18, 2026:
  `0x4fd3bfa5a8737b3e7411a83d8968153870956c17e0caac728dbfdc3399ba8a66`
- Live validation must also pin the deployed `WcmAdapter` runtime code hash.
  `WcmDeployLive` prints this value after deployment; later live scripts compare
  candidate adapters against a compiled-in `WCM_ADAPTER_CODE_HASH` constant.
- wiTRY / USDm spot order book: `0x8214Ca3a606dF76660bC492A6B69CE2570ad82c0`
- USDm token: `0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7`
- wiTRY token: `0x15B271D9012b5820FC42b1c495B4C1e206547De5`
- USDm token id: `1`
- wiTRY token id: `9`
- USDm ERC-20 decimals: `18`
- wiTRY ERC-20 decimals: `18`
- USDm World position decimals: `4`
- wiTRY World position decimals: `3`

Router behavior from World source:

- `exactInputSingle` and `exactOutputSingle` use raw ERC-20 units.
- quote/native swap functions use uint64 World position units.
- `fee` is ignored.
- `recipient` is ignored by current implementation.
- `sqrtPriceLimitX96` is unsupported and must be zero.
- native ETH is not supported for `exactOutputSingle`; do not send ETH.
- one side must be the World base token, currently USDm for this route.

## Fork-Test Inputs

Use this fork configuration for the final handoff verification tests:

```bash
RPC_URL_4326=https://rpc.inverter.network/main/evm/4326
```

Recommended fork block:

```text
18981853
```

Flashloan callback/reenter proof block:

```text
19054909
```

Use `19054909` for flashloan composition tests because it is the live-validated
close block and supports the exact World sizes used by the proof. Keep
`18981853` as the baseline adapter/probe discovery block.

Prior successful liquidation fork block:

```text
18815971
```

Minimum useful fork block:

```text
18755218
```

`18755218` is the market creation block. Use `19054909` for flashloan
callback/reenter proof tests, `18981853` for baseline adapter/probe checks, or
`18815971` only when reproducing the older liquidation helper exactly.

### Deployed Contracts

- Morpho Blue: `0x18120312A7cf44DcfEc6dCe5632a431579ED9100`
- Bundler3: `0xf53D4c8f0f83F697CD6bB303567400cCf411aA63`
- GeneralAdapter1: `0x74d3cbc721613C8461df92658d0a20dF275Ca31b`
- World Router: `0x94b6706fa26a4f3dcf501ff25e1e4628b75adc69`
- World Exchange: `0x5e3Ae52EbA0F9740364Bd5dd39738e1336086A8b`

### Morpho Market

Market id:

```text
0xa8af4e59ea40a30b6867083a2527109285ee7ab6046b4b49888ade1476272767
```

Market params:

```solidity
MarketParams({
    loanToken: 0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7,
    collateralToken: 0x15B271D9012b5820FC42b1c495B4C1e206547De5,
    oracle: 0xEebB019a6C66826f8BA8A583177E0dd5feEd0F22,
    irm: 0x56875764185548B0ca72A1877b3aE15E44e8A323,
    lltv: 770000000000000000
});
```

### Fork Position Setup

Use a fresh fork-created position rather than an existing borrower.

Suggested setup:

- lender supplies `50-200 USDm`
- borrower supplies `1000 wiTRY`
- borrower borrows `12-15 USDm`

At the observed oracle price of approximately `0.02320804 USDm/wiTRY`,
`1000 wiTRY` supports about `17.87 USDm` max borrow at `77%` LLTV, so a
`12-15 USDm` borrow is expected to be safely collateralized while also making
`buyMorphoDebt` large enough to clear the World order-book minimum.

Use Foundry `deal` for funding in fork tests:

- `deal(USDM, lender, amount)`
- `deal(WITRY, borrower, amount)`

Avoid relying on World Exchange balances unless necessary. The exchange had
large balances at the reference block, but mutating those balances makes tests
more coupled to venue internals.

Existing borrower from a prior live liquidation:

```text
0x40E4471293383e6e38Cb5Ce1E2C2Cd996742Cc0B
```

Do not use this borrower for the main adapter fork test. Its remaining position
is dust-sized, around `172.914862401 wiTRY` collateral and `0.006606911 USDm`
debt, and full close/withdraw flows would require borrower authorization or
impersonation.

### Known Small Swap Sizes

At block `18981853`, read-only router quotes filled both directions.

Exact input:

- sell `0.1 wiTRY` -> about `0.0022 USDm`
- sell `1 wiTRY` -> about `0.0230 USDm`
- sell `0.1 USDm` -> about `4.305 wiTRY`
- sell `1 USDm` -> about `43.038 wiTRY`

Exact output examples:

- buy `1 wiTRY` with USDm: about `0.0232 USDm`
- buy `0.1 USDm` with wiTRY: about `4.32 wiTRY`
- buy `1 USDm` with wiTRY: about `43.211 wiTRY`

These small values are useful for quote sanity checks, but they are below the
executable book minimum observed at the reference block.

Executable fork probe sizes that passed at block `18981853`:

- exact input: sell `600 wiTRY` for at least `12 USDm`
- exact input: sell `12 USDm` for at least `500 wiTRY`
- exact output: buy `600 wiTRY` with at most `15 USDm`
- exact output: buy `12 USDm` with at most `600 wiTRY`

For fork tests, choose sizes around or above these values to avoid CLOB minimum
order and depth fragility. At the flashloan proof block `19054909`, `12 USDm`
exact-input and `600 wiTRY` exact-output are the live-proven sizes. Smaller
`6-10 USDm` exact-input open sizes can fail execution with World custom error
`0x7d92b186` even when read-only quotes look plausible.

### Prior Reference Code

Useful local references:

- `/Users/fabianscherer/repos/inverter/brix/liquidation-bot/itry-liquidation-bot/docs/fork-test-liquidation.md`
- `/Users/fabianscherer/repos/inverter/brix/liquidation-bot/itry-liquidation-bot/apps/client/src/smokeWorldSwapFork.ts`
- `/Users/fabianscherer/repos/inverter/brix/liquidation-bot/itry-liquidation-bot/apps/client/src/setupMorphoForkPosition.ts`
- `/Users/fabianscherer/repos/inverter/brix/liquidation-bot/itry-liquidation-bot/apps/client/src/liquidateMorphoForkPosition.ts`
- `/Users/fabianscherer/repos/inverter/brix/liquidation-bot/itry-liquidation-bot/apps/client/src/forceMorphoForkOraclePrice.ts`
- `/Users/fabianscherer/repos/inverter/brix/liquidation-bot/itry-liquidation-bot/apps/liquidity-venues/src/worldMarkets/index.ts`
- `/Users/fabianscherer/repos/inverter/brix/docs/discovery/world-markets-swaprouter-adapter.md`

## Remaining Open Questions

### World Router / Venue Behavior

- Confirm whether World intends to keep ignoring `recipient`.
- Confirm whether World recommends `exactInputSingle` / `exactOutputSingle` over
  native packed swap functions for contract integrations.

The adapter should not wait on those confirmations. The current implementation
assumption is to call `exactInputSingle` / `exactOutputSingle`, set
`recipient = address(this)`, and enforce all routing with adapter balance deltas.

## Settled Scope Details

### Pair Scope

Decision: hard-gate v1 to `USDm <-> wiTRY` on MegaETH.

### Router Address Configuration

Decision: constructor immutables, with one adapter deployment per chain / World
router / reference Morpho market.

The adapter pins both the expected chain id and the World router runtime code
hash at construction and checks both before every swap. This makes a wrong-chain
deployment or router-address/code mismatch fail before any approval is granted.

### Deadlines

Decision: caller must provide an explicit deadline, and the adapter requires
`deadline >= block.timestamp`. There is no `deadline == 0` convenience mode in
v1.

### Dust / Minimum Orders

Known precision:

- wiTRY position precision: `0.001 wiTRY`
- USDm position precision: `0.0001 USDm`
- observed order-book minimum at block `18981853`: `500000` position units,
  corresponding to `500 wiTRY`

Decision: do not enforce position-decimal minimums and do not read minimum order
quantity in the hot path for v1. Let the router enforce protocol minimums, and
make the off-chain builder pre-check quotes and depth.

### Rescue Function

Decision: do not include any custom rescue path beyond `CoreAdapter` in v1.

Reasoning:

- existing Bundler3 adapters are not ownable
- `CoreAdapter` already exposes `erc20Transfer` and `nativeTransfer` through
  Bundler3
- adapter balances are not intended to be protected or persistent
- accidentally sent tokens should be treated as unsafe to leave in the adapter,
  consistent with the existing Bundler3 security model

## Test Plan

### Unit / Local Tests

- constructor rejects zero addresses, zero chain id, and zero router code hash
- swap actions reject wrong chain id or router code hash before approval
- `sell` rejects zero input
- `sell` rejects zero min output
- `sell` supports `sellEntireBalance`
- `sell` approves router, clears approval, measures deltas, and forwards output
- `sell` reverts on underfill
- `sell` reverts if WCM spends less than the exact input amount
- `buy` rejects zero output
- `buy` rejects zero max input
- `buy` approves router, clears approval, measures deltas, and forwards output
- `buy` reverts when source spent exceeds max
- `buy` refunds unspent source-token remainder to `receiver`
- `buyMorphoDebt` refunds unspent source-token remainder to `onBehalf`
- `buyMorphoDebt` requires `onBehalf == Bundler3.initiator()`
- `buyMorphoDebt` rejects same-token but non-pinned Morpho market params
- `buyMorphoDebt` reverts on zero debt
- `buyMorphoDebt` rounds live USDm debt up to the next USDm World position tick
  and forwards loan token to receiver
- no intended leftover balances after bundle-level skim/transfer steps
- rescue function access control and token transfer behavior

### Bundler3 Composition Tests

- open leverage: borrow USDm, buy wiTRY, supply collateral
- increase leverage: borrow additional USDm, buy wiTRY, supply collateral
- delever: withdraw collateral, sell wiTRY for USDm, repay
- close: withdraw all collateral, buy exact current debt, repay
- full callback/reenter flow with `GeneralAdapter1`
- receiver forwarding between WCM adapter and `GeneralAdapter1`

### Fork / Live-Equivalent Tests

- MegaETH fork: adapter exact-input `wiTRY -> USDm`
- MegaETH fork: adapter exact-output `wiTRY -> USDm`
- MegaETH fork: adapter exact-input `USDm -> wiTRY`
- MegaETH fork: adapter exact-output `USDm -> wiTRY`
- MegaETH fork: `sell` succeeds through the deployed World router
- MegaETH fork: `buy` succeeds through the deployed World router
- MegaETH fork: `buyMorphoDebt` succeeds by reading live Morpho debt and buying
  at least the required loan token amount
- confirm no allowlist/registration issue for adapter caller
- confirm output lands on adapter and is forwarded by delta

### Flashloan Callback / Reenter Tests

- MegaETH fork at block `19054909`: `GeneralAdapter1.morphoFlashLoan(USDm, ...)`
  reenters Bundler3 and invokes `WcmAdapter.sell(USDm, wiTRY, ...)` for a
  flashloan-assisted open/increase flow.
- MegaETH fork at block `19054909`: `GeneralAdapter1.morphoFlashLoan(USDm, ...)`
  reenters Bundler3 and invokes `WcmAdapter.buy(USDm, wiTRY, ...)` as a focused
  exact-output callback smoke test.
- MegaETH fork at block `19054909`: `GeneralAdapter1.morphoFlashLoan(wiTRY, ...)`
  reenters Bundler3 and invokes `WcmAdapter.buyMorphoDebt(wiTRY, ...)`, repays
  the full borrower debt through `GeneralAdapter1`, withdraws all borrower
  collateral, and repays the wiTRY flashloan atomically.
- After each flashloan path, assert `WcmAdapter` and `GeneralAdapter1` hold zero
  USDm and wiTRY, and assert the WCM router allowances for both tokens are zero.
- For the wiTRY flashloan close, seed extra fork-only Morpho wiTRY collateral
  liquidity before the close so Morpho can satisfy the collateral withdrawal
  before the flashloan repayment is pulled.

### Exact-Output Verification Recipe

Answer the `exactOutputSingle` question with a minimal contract-caller fork test
before depending on the full adapter implementation.

Test shape:

1. Fork MegaETH at block `18981853`.
2. Deploy a small probe contract or the adapter itself.
3. Fund the probe with the input token using Foundry `deal`.
4. Have the probe call World `SwapRouter.exactOutputSingle` with:
   - `tokenIn`
   - `tokenOut`
   - `fee = 0`
   - `recipient = address(probe)`
   - `deadline >= block.timestamp`
   - `amountOut`
   - `amountInMaximum`
   - `sqrtPriceLimitX96 = 0`
   - `msg.value = 0`
5. Measure input and output balances on the probe before and after the router
   call.
6. Assert:
   - input spent is `<= amountInMaximum`
   - output received is `>= amountOut`
   - output balance lands on the probe/router `msg.sender`

Run this for both directions:

- buy `600 wiTRY` with USDm, with about `15 USDm` max input
- buy `12 USDm` with wiTRY, with about `600 wiTRY` max input

If either direction fails from a contract caller, the current `buy` /
`buyMorphoDebt` interface needs redesign before implementation continues.

Result on block `18981853`: both directions passed from a freshly deployed probe
contract at the sizes above. Smaller probes below the book minimum reverted with
`QuantityTooLow()`.

Keep `test/fork/WcmSwapRouterProbeForkTest.sol` as a reference probe for the
implementation agent. It is not a replacement for the final adapter fork test,
but it captures the venue assumptions that the adapter depends on.

## Implementation Handoff

Use this as the `/goal` handoff target:

```text
Implement a Bundler3-native WCM swap adapter in the bundler3-adapters repo,
modeled after ParaswapAdapter and scoped to MegaETH USDm <-> wiTRY.

Required public functions:
- sell(tokenIn, tokenOut, amountIn, minAmountOut, sellEntireBalance, receiver, deadline)
- buy(tokenIn, tokenOut, amountOut, maxAmountIn, receiver, deadline)
- buyMorphoDebt(tokenIn, marketParams, maxAmountIn, onBehalf, receiver, deadline)

Adapter requirements:
- inherit/use the existing Bundler3 adapter patterns, especially CoreAdapter
- only callable by Bundler3 for swap actions
- expect pre-sent balances
- use explicit receiver parameters
- call the deployed World SwapRouter
- pin the expected chain id and World SwapRouter runtime code hash
- set World router recipient to address(this)
- do not trust router return values for accounting
- enforce bounds by token balance deltas
- forward the actual bought-token delta to receiver
- avoid persistent balances and standing approvals
- clear router approvals after each swap
- do not add custom owner/governance rescue
- hard-gate v1 to USDm <-> wiTRY
- hard-gate buyMorphoDebt to the reference Morpho market params
- require buyMorphoDebt onBehalf to equal the Bundler3 initiator
- require sell to spend the exact input amount
- refund generic buy source-token remainder to receiver
- refund buyMorphoDebt source-token remainder to onBehalf

Verification target:
- run a MegaETH fork at block 18981853 using RPC_URL_4326
- create a fresh Morpho position on the reference USDm/wiTRY market
- use roughly 1000 wiTRY collateral and 12-15 USDm debt so buyMorphoDebt clears
  World minimum order size
- invoke sell successfully through the deployed World router
- invoke buy successfully through the deployed World router
- invoke buyMorphoDebt successfully by reading live Morpho debt at execution time
- verify all three functions forward bought tokens to receiver by balance delta
- verify output lands on the adapter/router msg.sender before forwarding
- verify underfill/max-spend failures revert
```

## Implementation Notes

- Model after `ParaswapAdapter`, but without opaque calldata offsets.
- Prefer structured router params because World exposes Uniswap V3-shaped
  `exactInputSingle` and `exactOutputSingle`.
- Do not trust router return values for accounting.
- Use `SafeERC20.forceApprove` for router approvals and clear after each swap.
- Keep Morpho operations in `GeneralAdapter1`.
- Keep swap adapter responsibilities narrow: swap, bound enforcement, forwarding.
