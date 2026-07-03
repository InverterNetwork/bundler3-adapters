# WCM Bundler3 Adapter

Status: implementation spec.

This document describes the implemented Bundler3-native World Markets / WCM
adapter for the MegaETH `USDm <-> wiTRY` route. It is intended as reviewer and
operator context, not as discovery notes.

## Scope

The adapter is intentionally narrow:

- route: `USDm <-> wiTRY`
- chain: MegaETH, chain id `4326`
- venue: World Markets / WCM `SwapRouter`
- Morpho helper market: the USDm/wiTRY Morpho Blue market listed below
- public actions: `sell`, `buy`, and `buyMorphoDebt`

The adapter does not manage positions by itself. Morpho composition stays in
`GeneralAdapter1`; WCM-specific responsibilities stay in `WcmAdapter`.

## Files

- `src/adapters/WcmAdapter.sol`: adapter implementation.
- `src/interfaces/IWcmAdapter.sol`: adapter and WCM router interfaces.
- `test/WcmAdapterLocalTest.sol`: local mock-router tests.
- `test/fork/WcmAdapterForkTest.sol`: MegaETH fork tests against the deployed
  World router.
- `test/fork/WcmAdapterFlashLoanForkTest.sol`: MegaETH fork tests covering WCM
  calls inside Morpho flashloan callback/reenter flows.
- `test/fork/WcmSwapRouterProbeForkTest.sol`: direct router behavior probes.
- `script/WcmLiveValidation.s.sol`: live MegaETH validation scripts.
- `docs/wcm-live-validation-runbook.md`: live execution sequence and proof
  ledger.

## Adapter Model

`WcmAdapter` inherits `CoreAdapter`, so swap actions are only callable by
`Bundler3`.

The adapter follows the same Bundler3 conventions as the existing swap
adapters:

- input tokens are pre-sent to the adapter before the swap action
- every public action has an explicit `receiver`
- bought-token accounting uses balance deltas, not router return values
- router approvals are set for the call and cleared immediately afterwards
- no owner, governance, or custom rescue surface is introduced
- any balance cleanup uses existing `CoreAdapter` transfer helpers through
  Bundler3

## Constructor Configuration

Constructor arguments are immutable:

```solidity
constructor(
    address bundler3,
    address morpho,
    address router,
    uint256 chainId,
    bytes32 routerCodeHash,
    address usdm,
    address witry,
    address marketOracle,
    address marketIrm,
    uint256 marketLltv
)
```

MegaETH values used by the PR tests and live validation:

```text
chainId:             4326
Bundler3:            0xf53D4c8f0f83F697CD6bB303567400cCf411aA63
GeneralAdapter1:     0x74d3cbc721613C8461df92658d0a20dF275Ca31b
Morpho Blue:         0x18120312A7cf44DcfEc6dCe5632a431579ED9100
World SwapRouter:    0x94b6706FA26a4F3DCF501Ff25E1e4628B75AdC69
World router hash:   0x4fd3bfa5a8737b3e7411a83d8968153870956c17e0caac728dbfdc3399ba8a66
USDm:                0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7
wiTRY:               0x15B271D9012b5820FC42b1c495B4C1e206547De5
```

Reference Morpho market for `buyMorphoDebt`:

```solidity
MarketParams({
    loanToken:       0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7, // USDm
    collateralToken: 0x15B271D9012b5820FC42b1c495B4C1e206547De5, // wiTRY
    oracle:          0xEebB019a6C66826f8BA8A583177E0dd5feEd0F22,
    irm:             0x56875764185548B0ca72A1877b3aE15E44e8A323,
    lltv:            770000000000000000
});
```

Market id:

```text
0xa8af4e59ea40a30b6867083a2527109285ee7ab6046b4b49888ade1476272767
```

## Public Interface

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

### Refund Semantics

For generic `buy`, `receiver` is the beneficiary of the exact-output swap. The
adapter sends both the bought-token balance delta and the bounded unspent
source-token refund to `receiver`. Callers should only pass a third-party
receiver when that address is intended to receive both assets.

`buyMorphoDebt` intentionally separates the bought-token receiver from the
refund receiver. Bought USDm may be sent to `GeneralAdapter1` for a subsequent
`morphoRepay`, while any unspent wiTRY is refunded to `onBehalf`, which must be
the Bundler3 initiator.

### `sell`

Exact-input swap.

- If `sellEntireBalance` is true, `amountIn` is replaced with the adapter's full
  `tokenIn` balance.
- Rounds `amountIn` down to the input token's World position precision
  (`1e14` for USDm and `1e15` for wiTRY), and refunds the source-token dust
  remainder to the Bundler3 initiator when the rounded input is nonzero.
- Reverts if `amountIn` is below the input token's World position precision.
- Reverts on zero input, zero minimum output, unsupported pair, expired
  deadline, wrong chain id, wrong router code hash, or invalid receiver.
- Calls WCM `exactInputSingle` with `fee = 0`, `recipient = address(this)`, and
  `sqrtPriceLimitX96 = 0`.
- Requires the router to spend exactly the rounded input amount.
- Requires the bought-token balance delta to be at least `minAmountOut`.
- Transfers the bought-token delta to `receiver`.

### `buy`

Exact-output swap.

- Reverts on zero output, zero maximum input, unsupported pair, expired deadline,
  wrong chain id, wrong router code hash, or invalid receiver.
- Calls WCM `exactOutputSingle` with `fee = 0`, `recipient = address(this)`, and
  `sqrtPriceLimitX96 = 0`.
- Requires input spent to be at most `maxAmountIn`.
- Requires the bought-token balance delta to be at least `amountOut`.
- Transfers the bought-token delta to `receiver`.
- Refunds up to the unspent `maxAmountIn - spent` source-token amount to
  `receiver`.

### `buyMorphoDebt`

Exact-output helper for closing or delevering a Morpho position.

- Requires `onBehalf == Bundler3.initiator()`.
- Requires `marketParams` to match the deployment-pinned USDm/wiTRY market.
- Reads live debt with
  `MorphoBalancesLib.expectedBorrowAssets(MORPHO, marketParams, onBehalf)`.
- Reverts if debt is zero.
- Rounds the USDm output target up to the next World USDm position tick
  (`0.0001 USDm`, or `1e14` raw units).
- Buys that rounded loan-token amount through WCM exact-output.
- Sends bought USDm to `receiver`, usually `GeneralAdapter1` for a subsequent
  `morphoRepay`.
- Refunds unspent wiTRY to `onBehalf`, not to `receiver`.

## WCM Router Assumptions

The implementation is based on these verified WCM router behaviors:

- `exactInputSingle` and `exactOutputSingle` use raw ERC-20 units.
- One side of the pair must be the World base token, USDm for this route.
- `fee` is ignored.
- `recipient` is ignored by current router code, so the adapter measures output
  received by `address(this)` and forwards it by balance delta.
- `sqrtPriceLimitX96` must be zero.
- Native ETH is not used for WCM exact-output.

The adapter does not read World minimum order values on-chain. The off-chain
bundle builder should quote World immediately before execution and choose
caller-supplied bounds that account for book depth.

Known executable fork/live sizes:

- `12 USDm` exact input for `USDm -> wiTRY`
- `600 wiTRY` exact output for `USDm -> wiTRY`
- `500-600 wiTRY` exact input for `wiTRY -> USDm`
- `12 USDm` exact output for `wiTRY -> USDm`

Smaller swaps can quote successfully but still revert during execution with WCM
custom error `0x7d92b186`.

## Composition Patterns

### Open / Increase

The open leverage flow composes `GeneralAdapter1` and `WcmAdapter`:

1. supply seed wiTRY collateral through `GeneralAdapter1`
2. borrow USDm through `GeneralAdapter1`
3. send borrowed USDm to `WcmAdapter`
4. call `sell(USDm, wiTRY, ...)`
5. send bought wiTRY to `GeneralAdapter1`
6. supply bought wiTRY as collateral
7. sweep leftovers

### Close / Delever

The close flow uses `buyMorphoDebt`:

1. send wiTRY to `WcmAdapter`
2. call `buyMorphoDebt(wiTRY, marketParams, ..., borrower, GeneralAdapter1, ...)`
3. repay all borrower debt through `GeneralAdapter1`
4. withdraw collateral through `GeneralAdapter1`
5. sweep leftovers

### Flashloan Callback / Reenter

The adapter does not initiate flashloans. Flashloan composition is:

```text
Bundler3.multicall
  -> GeneralAdapter1.morphoFlashLoan(...)
  -> Morpho.flashLoan(...)
  -> GeneralAdapter1.onMorphoFlashLoan(...)
  -> Bundler3.reenter(callbackBundle)
  -> WcmAdapter action(s)
```

`test/fork/WcmAdapterFlashLoanForkTest.sol` proves all three public WCM
functions in this callback/reenter context.

## Reproducible Validation

Run commands from the repository root.

Install dependencies:

```bash
git submodule update --init --recursive
```

### Required Env Vars

Fork tests:

```bash
export RPC_URL_4326=https://rpc.inverter.network/main/evm/4326
```

CI-style non-WCM fork tests:

```bash
export ALCHEMY_KEY=<alchemy key>
```

Live scripts, only for real MegaETH execution:

```bash
export RPC_URL_4326=https://rpc.inverter.network/main/evm/4326
export MEGAETH_TEST_BORROWER_PRIVATE_KEY=<borrower private key>
export WCM_ADAPTER_ADDRESS=<deployed adapter>
```

Optional live-script env vars:

```bash
export WCM_SLIPPAGE_BPS=300
export WCM_DEADLINE_TTL=120
export WCM_ALLOW_MAX_APPROVALS=0
export WCM_BUY_WITRY_OUT=600000000000000000000
export WCM_SELL_WITRY_IN=500000000000000000000
export WCM_OPEN_INITIAL_COLLATERAL=1000000000000000000000
export WCM_OPEN_BORROW_USDM=12000000000000000000
```

### Local Checks

```bash
forge fmt --check
forge lint
forge build --sizes --skip Import
forge build script/WcmLiveValidation.s.sol
forge test --match-path test/WcmAdapterLocalTest.sol
```

The GitHub formatting workflow mutates Solidity files to strip transient
keywords before `forge fmt --check`. Use plain `forge fmt --check` locally.

### MegaETH Fork Checks

```bash
RPC_URL_4326=$RPC_URL_4326 forge test --match-path test/fork/WcmAdapterForkTest.sol -vvv
RPC_URL_4326=$RPC_URL_4326 forge test --match-path test/fork/WcmAdapterFlashLoanForkTest.sol -vvv
RPC_URL_4326=$RPC_URL_4326 forge test --match-path test/fork/WcmSwapRouterProbeForkTest.sol -vvv
```

Combined WCM-focused run:

```bash
RPC_URL_4326=$RPC_URL_4326 forge test --match-contract 'Wcm.*Test' -vvv
```

Fork blocks are pinned in the tests:

- `WcmAdapterForkTest`: block `18_981_853`
- `WcmSwapRouterProbeForkTest`: block `18_981_853`
- `WcmAdapterFlashLoanForkTest`: block `19_054_909`

### CI-Style Full Checks

These mirror the upstream workflows and require `ALCHEMY_KEY`:

```bash
forge test --chain 1
forge test --chain 8453
```

The GitHub formatting workflow also runs a Certora config JSON check. It is not
WCM-specific and does not require WCM env vars.

## Live Validation

The current hardened live proof is documented in
`docs/wcm-live-validation-runbook.md`.

Current live adapter:

```text
WCM adapter:           0x5752E97738Aa65A2a67e704475124453BEceC2Df
WCM adapter code hash: 0x420c6d7f76359c0c7d0bdfa8261abf00d2e986db45d76881b170d0a5a3e46c9c
```

The live run proved:

- `buy`: exact-output `USDm -> wiTRY`
- `sell`: exact-input `wiTRY -> USDm`
- open leverage via `sell(USDm, wiTRY, ...)`
- full close via `buyMorphoDebt(wiTRY, ...)`
- final zero debt and zero collateral
- zero WCM/GeneralAdapter1 USDm and wiTRY balances
- zero WCM router allowances
