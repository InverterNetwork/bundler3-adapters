# WCM Adapter MegaETH Live Validation Runbook

This runbook defines the live-network validation target for the WCM Bundler3
adapter on MegaETH. It is intended to be filled in during execution with tx
hashes, block numbers, balance snapshots, and Morpho position snapshots.

## Objective

Deploy the WCM adapter and prove, on the live MegaETH network, that it can be
used through Bundler3-style composition to:

- invoke `buy`
- open/increase a leveraged USDm/wiTRY Morpho position using `sell`
- fully close the borrower position using `buyMorphoDebt`

The final desired state is:

- borrower has zero debt on the target Morpho market
- borrower has zero collateral left supplied on the target Morpho market
- WCM adapter holds no USDm or wiTRY
- GeneralAdapter1 holds no USDm or wiTRY from the test flow
- WCM adapter has zero router allowance for USDm and wiTRY

## Network And Contracts

Chain:

```text
MegaETH chain id: 4326
RPC: https://rpc.inverter.network/main/evm/4326
```

Existing deployed contracts:

```text
Bundler3:        0xf53D4c8f0f83F697CD6bB303567400cCf411aA63
GeneralAdapter1: 0x74d3cbc721613C8461df92658d0a20dF275Ca31b
Morpho Blue:     0x18120312A7cf44DcfEc6dCe5632a431579ED9100
World Router:    0x94b6706fa26a4f3dcf501ff25e1e4628b75adc69
USDm:            0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7
wiTRY:           0x15B271D9012b5820FC42b1c495B4C1e206547De5
```

Target Morpho market:

```solidity
loanToken:       0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7 // USDm
collateralToken: 0x15B271D9012b5820FC42b1c495B4C1e206547De5 // wiTRY
oracle:          0xEebB019a6C66826f8BA8A583177E0dd5feEd0F22
irm:             0x56875764185548B0ca72A1877b3aE15E44e8A323
lltv:            770000000000000000
```

Market id:

```text
0xa8af4e59ea40a30b6867083a2527109285ee7ab6046b4b49888ade1476272767
```

## Actors

Primary signer and position owner:

```text
MEGAETH_TEST_BORROWER_ADDRESS
0x40E4471293383e6e38Cb5Ce1E2C2Cd996742Cc0B
```

Backstop / liquidity source:

```text
MEGAETH_TEST_LENDER_ADDRESS
0xa12dC13D9F3bE78E786E8cAd76F6289358448745
```

Secondary receiver / source if needed:

```text
LIQUIDATION_ADDRESS_4326
0xe6F2c3e1d0378F714272131a5e8250bDa1342987
```

Avoid depending on this account unless necessary because it currently has no
native ETH:

```text
EXECUTOR_ADDRESS_4326
0xa0e8b3794c85defda1f6567ed3999d00c9da08b0
```

## Current Live Snapshot

Captured on June 18, 2026.

| Label | ETH | Wallet USDm | Wallet wiTRY | Morpho USDm supply | Morpho USDm debt | Morpho wiTRY collateral |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `LIQUIDATION_ADDRESS_4326` | `0.000583358694989101` | `1.191180783793433048` | `0` | `0` | `0` | `0` |
| `EXECUTOR_ADDRESS_4326` | `0` | `0` | `4.135425687994771084` | `0` | `0` | `0` |
| `MEGAETH_TEST_LENDER_ADDRESS` | `0.000299622328893440` | `0` | `0` | `20.000018220019075792` | `0` | `0` |
| `MEGAETH_TEST_BORROWER_ADDRESS` | `0.000998513215810524` | `17.866807907270902531` | `527.546938828624657977` | `0` | `0.006606911083411371` | `172.914862401045783208` |

Refresh this table immediately before live execution and record the block number
in the proof ledger.

## Deployment

Deploy `WcmAdapter` with constructor arguments:

```text
bundler3 = 0xf53D4c8f0f83F697CD6bB303567400cCf411aA63
morpho   = 0x18120312A7cf44DcfEc6dCe5632a431579ED9100
router   = 0x94b6706fa26a4f3dcf501ff25e1e4628b75adc69
usdm     = 0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7
witry    = 0x15B271D9012b5820FC42b1c495B4C1e206547De5
```

After deployment, verify these immutables on-chain:

- `BUNDLER3`
- `MORPHO`
- `ROUTER`
- `USDM`
- `WITRY`

## Required Pre-Authorizations

The borrower must authorize the existing `GeneralAdapter1` in Morpho:

```text
Morpho.setAuthorization(GeneralAdapter1, true)
```

The borrower must also approve `GeneralAdapter1` for token pulls used by
`GeneralAdapter1.erc20TransferFrom`:

```text
USDm allowance borrower -> GeneralAdapter1
wiTRY allowance borrower -> GeneralAdapter1
```

Use exact allowances where practical. If a max allowance is used for execution
convenience, document it explicitly in the proof ledger.

No standing approval should remain from WCM adapter to World router after a swap.
This is a validation condition after each adapter call.

## Quote And Slippage Policy

Do not compute slippage on-chain. Quote World immediately before each swap and
set caller-supplied bounds from the quote:

- `buy`: `amountOut`, `maxAmountIn`
- `sell`: `amountIn`, `minAmountOut`
- `buyMorphoDebt`: live debt-derived `amountOut`, `maxAmountIn`

Recommended default live bounds:

- start with quote plus/minus `2-3%`
- widen only if the latest quote still supports the intended flow and the amount
  is within the available account balances
- keep deadlines short, around `now + 10 minutes`

The exact final amounts should be chosen from the live quote, not hardcoded from
the fork test.

## Live Execution Steps

### Step 0: Preflight Snapshot

Record:

- latest block number
- all actor ETH / USDm / wiTRY balances
- borrower Morpho position: supply shares, borrow shares, collateral, expected debt
- WCM adapter USDm / wiTRY balances
- WCM adapter router allowances for USDm and wiTRY
- GeneralAdapter1 USDm / wiTRY balances
- borrower allowances to GeneralAdapter1
- borrower Morpho authorization status for GeneralAdapter1

### Step 1: Deploy WCM Adapter

Deploy the adapter and verify constructor immutables.

Proof required:

- deployment tx hash
- deployed adapter address
- block number
- constructor arguments
- immutable readback

### Step 2: Prepare Authorizations

Submit any missing authorization or approval transactions:

- Morpho authorization for `GeneralAdapter1`
- USDm allowance to `GeneralAdapter1`, if needed
- wiTRY allowance to `GeneralAdapter1`, if needed

Proof required:

- tx hashes
- final allowance values
- final Morpho authorization value

### Step 3: Invoke `buy`

Purpose: prove exact-output WCM swap and receiver forwarding.

Recommended shape:

1. `GeneralAdapter1.erc20TransferFrom(USDm, WcmAdapter, maxAmountIn)`
2. `WcmAdapter.buy(USDm, wiTRY, amountOut, maxAmountIn, borrower, deadline)`
3. `WcmAdapter.erc20Transfer(USDm, borrower, type(uint256).max)`

Suggested starting size:

```text
amountOut: 1 wiTRY
```

Adjust from live World quote if needed.

Validation:

- borrower receives at least exact `amountOut` wiTRY
- any unused USDm is swept back to borrower
- WCM adapter USDm balance is zero
- WCM adapter wiTRY balance is zero
- WCM adapter router allowance for USDm is zero

### Step 4: Open / Increase Leverage Using `sell`

Purpose: prove an open leverage flow and exact-input WCM swap composition.

Recommended shape:

1. `GeneralAdapter1.erc20TransferFrom(wiTRY, GeneralAdapter1, initialCollateral)`
2. `GeneralAdapter1.morphoSupplyCollateral(marketParams, initialCollateral, borrower, "")`
3. `GeneralAdapter1.morphoBorrow(marketParams, borrowAmount, 0, minSharePriceE27, WcmAdapter)`
4. `WcmAdapter.sell(USDm, wiTRY, borrowAmount, minAmountOut, false, GeneralAdapter1, deadline)`
5. `GeneralAdapter1.morphoSupplyCollateral(marketParams, type(uint256).max, borrower, "")`
6. sweep WCM adapter leftovers to borrower
7. sweep GeneralAdapter1 leftovers to borrower

Suggested starting size:

```text
initialCollateral: quote-driven, small enough to preserve borrower free wiTRY buffer
borrowAmount:      quote-driven, likely 1-5 USDm unless World depth requires more
```

Before broadcasting, confirm the borrower will still have enough free wallet
wiTRY after the initial collateral transfer to fund the later `buyMorphoDebt`
close with the chosen `maxAmountIn`.

Validation:

- borrower debt increases by the borrow amount
- borrower collateral increases by initial collateral plus bought wiTRY
- `sell` forwards bought wiTRY to `GeneralAdapter1`
- WCM adapter USDm balance is zero
- WCM adapter wiTRY balance is zero
- WCM adapter router allowance for USDm is zero

### Step 5: Fully Close Using `buyMorphoDebt`

Purpose: prove `buyMorphoDebt` reads live debt during execution and can fund a
full Morpho repay.

Preferred low-risk live shape:

1. `GeneralAdapter1.erc20TransferFrom(wiTRY, WcmAdapter, maxAmountIn)`
2. `WcmAdapter.buyMorphoDebt(wiTRY, marketParams, maxAmountIn, borrower, GeneralAdapter1, deadline)`
3. `GeneralAdapter1.morphoRepay(marketParams, 0, type(uint256).max, maxSharePriceE27, borrower, "")`
4. `WcmAdapter.erc20Transfer(wiTRY, borrower, type(uint256).max)`
5. `GeneralAdapter1.erc20Transfer(USDm, borrower, type(uint256).max)`
6. `GeneralAdapter1.morphoWithdrawCollateral(marketParams, type(uint256).max, borrower)`
7. sweep any remaining WCM adapter and GeneralAdapter1 balances

This close path intentionally uses the borrower's free wiTRY as the temporary
funding source. It avoids adding Morpho flashloan mechanics to the required live
validation while still proving the important adapter behavior:

- exact-output WCM execution
- live Morpho debt read
- rounded USDm debt purchase
- receiver forwarding into `GeneralAdapter1`
- full debt repay
- final collateral withdrawal

Validation:

- borrower expected debt is zero
- borrower borrow shares are zero
- borrower collateral is zero
- borrower receives remaining collateral back in wallet
- WCM adapter USDm balance is zero
- WCM adapter wiTRY balance is zero
- GeneralAdapter1 USDm balance is zero
- GeneralAdapter1 wiTRY balance is zero
- WCM adapter router allowance for wiTRY is zero

### Optional Step 6: Collateral-Funded Close Variant

If the required validation is expanded from "adapter proof" to "collateral-funded
full close proof", use a separate runbook step after fork-simulating it at the
latest block.

Candidate shape:

1. `GeneralAdapter1.morphoFlashLoan(wiTRY, currentCollateral, callbackData)`
2. inside callback, transfer flashloaned wiTRY to WCM adapter
3. `WcmAdapter.buyMorphoDebt(wiTRY, marketParams, maxAmountIn, borrower, GeneralAdapter1, deadline)`
4. sweep leftover wiTRY from WCM adapter to `GeneralAdapter1`
5. repay full borrower debt
6. withdraw all borrower collateral to `GeneralAdapter1`
7. let Morpho pull back the flashloaned wiTRY
8. after callback, sweep remaining wiTRY to borrower

This is not required for the first live validation because it adds flashloan
liquidity and callback ordering risk beyond the adapter's three-function surface.

## Proof Ledger

Fill this table during execution.

| Step | Tx hash | Block | Signer | Primary calls | Status | Notes |
| --- | --- | ---: | --- | --- | --- | --- |
| 0. Preflight snapshot | n/a | TBD | n/a | read-only | Pending | Record latest block and balances below. |
| 1. Deploy adapter | TBD | TBD | TBD | `new WcmAdapter(...)` | Pending | Adapter address: TBD |
| 2a. Morpho authorization | TBD | TBD | borrower | `setAuthorization` | Pending | Skip if already authorized. |
| 2b. USDm approval | TBD | TBD | borrower | `USDm.approve` | Pending | Skip if sufficient. |
| 2c. wiTRY approval | TBD | TBD | borrower | `wiTRY.approve` | Pending | Skip if sufficient. |
| 3. `buy` | TBD | TBD | borrower | `Bundler3.multicall` | Pending | Exact-output USDm -> wiTRY. |
| 4. Open leverage via `sell` | TBD | TBD | borrower | `Bundler3.multicall` | Pending | Borrow USDm, sell to wiTRY, resupply. |
| 5. Close via `buyMorphoDebt` | TBD | TBD | borrower | `Bundler3.multicall` | Pending | Buy debt, repay, withdraw all collateral. |
| 6. Cleanup, if any | TBD | TBD | TBD | sweeps / approvals | Pending | Only if needed. |

## Snapshot Ledger

### Before Execution

```text
Block: TBD
WCM adapter: TBD

Borrower wallet:
  ETH:   TBD
  USDm:  TBD
  wiTRY: TBD

Borrower Morpho position:
  supplyShares: TBD
  borrowShares: TBD
  expectedDebt: TBD
  collateral:   TBD

WCM adapter:
  USDm balance:  TBD
  wiTRY balance: TBD
  USDm router allowance:  TBD
  wiTRY router allowance: TBD

GeneralAdapter1:
  USDm balance:  TBD
  wiTRY balance: TBD
```

### After `buy`

```text
Block: TBD
Tx: TBD
Quoted amountOut: TBD
maxAmountIn: TBD
Actual borrower wiTRY delta: TBD
Refunded USDm: TBD
WCM adapter USDm balance: TBD
WCM adapter wiTRY balance: TBD
WCM adapter USDm router allowance: TBD
```

### After Open Leverage

```text
Block: TBD
Tx: TBD
initialCollateral: TBD
borrowAmount: TBD
minAmountOut: TBD
Actual supplied collateral delta: TBD
Actual debt delta: TBD
WCM adapter USDm balance: TBD
WCM adapter wiTRY balance: TBD
WCM adapter USDm router allowance: TBD
```

### After Full Close

```text
Block: TBD
Tx: TBD
Debt before close: TBD
Rounded debt bought: TBD
maxAmountIn: TBD
Actual wiTRY spent: TBD
Final borrowShares: TBD
Final expectedDebt: TBD
Final collateral: TBD
WCM adapter USDm balance: TBD
WCM adapter wiTRY balance: TBD
GeneralAdapter1 USDm balance: TBD
GeneralAdapter1 wiTRY balance: TBD
WCM adapter wiTRY router allowance: TBD
```

## Stop Conditions

Do not broadcast the next live transaction if any of these are true:

- latest World quote is missing, stale, or worse than the chosen bound
- expected adapter balance after a step is non-zero and cannot be explained
- WCM adapter router allowance remains non-zero after a swap
- borrower Morpho position is not in the expected state after the previous step
- GeneralAdapter1 authorization or token allowance is missing
- a fork simulation of the exact calldata fails at the latest block

## Final Acceptance Criteria

The live validation is complete only when the proof ledger contains tx hashes for:

- adapter deployment
- any required approvals or Morpho authorization
- successful `buy`
- successful open leverage flow using `sell`
- successful full close flow using `buyMorphoDebt`

And the final snapshot proves:

- borrower debt is zero
- borrower collateral is zero
- WCM adapter has no USDm or wiTRY
- GeneralAdapter1 has no USDm or wiTRY from the flow
- WCM adapter has no standing World router approvals
