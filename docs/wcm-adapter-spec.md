# WCM Bundler3 Adapter

Status: implementation spec.

This document describes the implemented Bundler3-native World Markets / WCM
adapter for the MegaETH `USDm <-> wiTRY` route. It is intended as reviewer and
operator context, not as discovery notes.

## Scope

The adapter is intentionally narrow:

- route: `USDm <-> wiTRY`
- chain: MegaETH, chain id `4326`
- venue: World Markets Exchange, price helper, and USDm/wiTRY spot order book
- Morpho helper market: the USDm/wiTRY Morpho Blue market listed below
- public actions: `sell`, `buy`, and `buyMorphoDebt`

The adapter does not manage positions by itself. Morpho composition stays in
`GeneralAdapter1`; WCM-specific responsibilities stay in `WcmAdapter`.

This is a deployment-breaking migration from the former SwapRouter adapter:
the three public action selectors are unchanged, but the constructor and public
immutables now identify the Exchange, PriceHelper, order book, and World
account. Existing router-based deployments and constructor tooling are not
compatible.

## Files

- `src/adapters/WcmAdapter.sol`: adapter implementation.
- `src/interfaces/IWcmAdapter.sol`: adapter and WCM Exchange interfaces.
- `test/WcmAdapterLocalTest.sol`: local mock-exchange tests.
- `test/fork/WcmAdapterForkTest.sol`: MegaETH fork tests against the deployed
  World Exchange.
- `test/fork/WcmAdapterFlashLoanForkTest.sol`: MegaETH fork tests covering WCM
  calls inside Morpho flashloan callback/reenter flows.
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
- bought-token accounting uses balance deltas, not Exchange return values
- Exchange approvals are set for the call and cleared immediately afterwards
- the adapter creates and owns its World account during construction
- swaps deposit to that account, place fill-all-or-revert spot orders, and
  withdraw only the balance deltas attributable to the swap
- no owner, governance, or custom rescue surface is introduced
- any balance cleanup uses existing `CoreAdapter` transfer helpers through
  Bundler3

Construction calls `World Exchange.createAccount()`, permanently binding the
new adapter address to its account id and the then-current USDm/wiTRY book. A
World dependency or book migration requires a new adapter deployment.

The deployed Exchange is an upgradeable proxy. Its proxy code hash is pinned,
and token ids, position decimals, book mapping, and account ownership are
revalidated on every swap, but an authorized World implementation upgrade can
still change behavior. The adapter therefore trusts World governance for
Exchange upgrades; PriceHelper and order-book runtime hashes remain pinned.

## Constructor Configuration

Constructor arguments are immutable:

```solidity
constructor(
    address bundler3,
    address morpho,
    address exchange,
    address priceHelper,
    uint256 chainId,
    bytes32 exchangeCodeHash,
    bytes32 priceHelperCodeHash,
    bytes32 orderBookCodeHash,
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
World Exchange:      0x5e3Ae52EbA0F9740364Bd5dd39738e1336086A8b
World PriceHelper:   0x9DA7FEF3A37536010cF7A0bbDcccE17DF69fE0a6
World spot book:     0x8214Ca3a606dF76660bC492A6B69CE2570ad82c0
Exchange hash:       0x7eff9da33cc2042d53428940c03a32662470f639863b356e5cd453b03bb0ce42
PriceHelper hash:    0xd074b9eedd1b030eba004e8ac12b1487a46f182e71906e243e59ba26490762c6
Spot-book hash:      0x7d32cc5d85dc003c87165c038c6f49f5ec13ec9bed2f774d00303bf579445b01
USDm:                0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7
wiTRY:               0x15B271D9012b5820FC42b1c495B4C1e206547De5
```

Reference Morpho market for `buyMorphoDebt`:

```solidity
MarketParams({
    loanToken:       0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7, // USDm
    collateralToken: 0x15B271D9012b5820FC42b1c495B4C1e206547De5, // wiTRY
    oracle:          0x5D15337913F6A2C29ecf37Af9E812d81dD77888d,
    irm:             0x56875764185548B0ca72A1877b3aE15E44e8A323,
    lltv:            770000000000000000
});
```

Market id:

```text
0xa9e57f86cc877f38f2daf080df6638f01afe017eaed59fa3b2f688f6e6d4bf19
```

The previous test-market tuple used oracle
`0xEebB019a6C66826f8BA8A583177E0dd5feEd0F22` and market id
`0xa8af4e59ea40a30b6867083a2527109285ee7ab6046b4b49888ade1476272767`.
`buyMorphoDebt` must reject that tuple on a target-market deployment.

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
  deadline, wrong chain id, wrong Exchange code hashes, or invalid receiver.
- Requires the adapter's `tokenIn` balance to be at least `amountIn` before
  refunding dust and calling the Exchange.
- Quotes the fill directly through World `PriceHelper`, deposits the quoted
  input, and submits a fill-all-or-revert spot order from the adapter's account.
- Requires the Exchange to spend exactly the rounded input amount.
- Inputs that World cannot represent as a fully consumed fill-all-or-revert
  order revert instead of changing exact-input semantics to a partial spend.
- Requires the bought-token balance delta to be at least `minAmountOut`.
- Transfers the bought-token delta to `receiver`.

### `buy`

Exact-output swap.

- Reverts on zero output, zero maximum input, unsupported pair, expired deadline,
  wrong chain id, wrong Exchange code hashes, or invalid receiver.
- Requires the adapter's `tokenIn` balance to be at least `maxAmountIn` before
  calling the Exchange.
- Quotes the fill directly through World `PriceHelper`; if World lot rounding
  returns one or more position ticks below the target, the quote request is
  increased until it covers the requested output.
- Deposits only the quoted input and submits a fill-all-or-revert spot order
  from the adapter's account.
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

## WCM Exchange Assumptions

The implementation is based on these verified WCM Exchange behaviors:

- `createAccount` binds a World account id to the adapter contract; this is the
  account World can whitelist for zero maker/taker fees.
- `depositErc20` and `withdrawErc20` use raw ERC-20 units.
- `getBalance` also returns raw ERC-20 units, while price-helper and order
  fields use token position precision (`1e14` USDm, `1e15` wiTRY).
- The price helper traverses the live book and returns order quantity, input,
  output, and limit price. It is called transactionally and cleared after every
  estimate, matching World's integration contract.
- The helper is also cleared before the first estimate to avoid inheriting any
  scratch state established earlier in the same transaction.
- Orders encode fill-all-or-revert type, the adapter's account id, quantity,
  and limit price, then call `newSpotBuyOrder` or `newSpotSellOrder` directly.
- The adapter measures World internal balances before and after execution,
  withdraws attributable output and unspent input, and validates external
  ERC-20 deltas before forwarding or refunding funds.
- Available and sequestered balances must return to their pre-order state; a
  resting or partially sequestered order makes the whole swap revert.

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
export WCM_ADAPTER_CODE_HASH=<deployed adapter runtime code hash>
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
```

Combined WCM-focused run:

```bash
RPC_URL_4326=$RPC_URL_4326 forge test --match-contract 'Wcm.*Test' -vvv
```

Fork blocks are pinned in the tests:

- `WcmAdapterForkTest`: block `21_959_976`
- `WcmAdapterFlashLoanForkTest`: block `21_959_976`

### CI-Style Full Checks

These mirror the upstream workflows and require `ALCHEMY_KEY`:

```bash
forge test --chain 1
forge test --chain 8453
```

The GitHub formatting workflow also runs a Certora config JSON check. It is not
WCM-specific and does not require WCM env vars.

## Historical Live Validation

The June 19, 2026 live proof documented in
`docs/wcm-live-validation-runbook.md` used the former test-market oracle
`0xEebB019a6C66826f8BA8A583177E0dd5feEd0F22` and market id
`0xa8af4e59ea40a30b6867083a2527109285ee7ab6046b4b49888ade1476272767`.
It did not validate the target-market tuple specified above.

Historical test-market adapter:

```text
WCM adapter:           0x5752E97738Aa65A2a67e704475124453BEceC2Df
WCM adapter code hash: 0x420c6d7f76359c0c7d0bdfa8261abf00d2e986db45d76881b170d0a5a3e46c9c
```

For that former test market only, the live run proved:

- `buy`: exact-output `USDm -> wiTRY`
- `sell`: exact-input `wiTRY -> USDm`
- open leverage via `sell(USDm, wiTRY, ...)`
- full close via `buyMorphoDebt(wiTRY, ...)`
- final zero debt and zero collateral
- zero WCM/GeneralAdapter1 USDm and wiTRY balances
- zero WCM Exchange allowances

The historical adapter address and runtime code hash must not be reused for the
target market. A newly deployed target-market adapter must complete the
target-specific preflight, fork, deployment-provenance, and live validation
gates in `docs/wcm-live-validation-runbook.md`.
