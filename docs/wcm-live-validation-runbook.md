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
chainId  = 4326
routerCodeHash = 0x4fd3bfa5a8737b3e7411a83d8968153870956c17e0caac728dbfdc3399ba8a66
usdm     = 0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7
witry    = 0x15B271D9012b5820FC42b1c495B4C1e206547De5
```

After deployment, verify these immutables on-chain:

- `WCM_ADAPTER_ADDRESS.codehash == WCM_ADAPTER_CODE_HASH`
- `BUNDLER3`
- `MORPHO`
- `ROUTER`
- `CHAIN_ID == 4326`
- `ROUTER_CODE_HASH == 0x4fd3bfa5a8737b3e7411a83d8968153870956c17e0caac728dbfdc3399ba8a66`
- `ROUTER.codehash == 0x4fd3bfa5a8737b3e7411a83d8968153870956c17e0caac728dbfdc3399ba8a66`
- `USDM`
- `WITRY`
- `MARKET_ORACLE`
- `MARKET_IRM`
- `MARKET_LLTV`

Before any transaction that transfers borrower funds to `WCM_ADAPTER_ADDRESS`,
the live script must verify:

- `block.chainid == 4326`
- World router bytecode hash matches the pinned hash above
- `WCM_ADAPTER_ADDRESS` has contract code
- `WCM_ADAPTER_ADDRESS.codehash` matches `WCM_ADAPTER_CODE_HASH`
- all adapter immutables match the constants above

`WcmDeployLive` prints the deployed adapter code hash. Record that value in the
proof ledger and pass it as `WCM_ADAPTER_CODE_HASH` for every later live script
run. Do not derive this hash from the candidate adapter address in the same
command that moves funds.

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

Use exact allowances by default. The live script only uses max allowances when
`WCM_ALLOW_MAX_APPROVALS=1` is explicitly set; if a max allowance is used for
execution convenience, document it explicitly in the proof ledger.

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
- keep deadlines short; the live script defaults to `now + 2 minutes` and rejects
  `WCM_DEADLINE_TTL` values above 5 minutes

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
3. `WcmAdapter.erc20Transfer(USDm, borrower, type(uint256).max)` as a final
   zero-balance cleanup assertion

Suggested starting size:

```text
amountOut: 600 wiTRY
```

Adjust from live World quote if needed.

Validation:

- borrower receives at least exact `amountOut` wiTRY
- any unused USDm is refunded or swept back to borrower
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

`buyMorphoDebt` requires `onBehalf == Bundler3.initiator()`, so this bundle must
be sent by the borrower or by the exact account that owns the Morpho debt. The
WCM adapter forwards bought USDm to `receiver` but refunds exact-output
source-token remainder to `onBehalf`, so the close bundle must still sweep
GeneralAdapter1 USDm surplus and any explicit adapter dust.

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

Live validation executed on June 18, 2026 with borrower signer
`0x40E4471293383e6e38Cb5Ce1E2C2Cd996742Cc0B`.

| Step | Tx hash | Block | Signer | Primary calls | Status | Notes |
| --- | --- | ---: | --- | --- | --- | --- |
| 0. Preflight snapshot | n/a | 18996760 | n/a | read-only | Complete | Adapter and GeneralAdapter1 clean; borrower authorization/allowances checked after prepare. |
| 1. Deploy adapter | `0xc559f8bbf820f9420d2f9f13acb3355a3dce4ae557daf4d21380be00cd5bcd11` | 18996576 | borrower | `new WcmAdapter(...)` | Complete | Adapter: `0xbde192287378Ef3d7f1658c48f48F9e4c4095125`; immutables verified. |
| 2a. Morpho authorization | `0x43013d8e0ef8066198aeed4ac0a967762585f3d7ba9c9833192937ddd115789b` | 18996733 | borrower | `setAuthorization(GeneralAdapter1, true)` | Complete | Final authorization: `true`. |
| 2b. USDm approval | `0xd944e269ffb00930f3bf47f6dd7ced45c0eb9a1c245df74fe6b0bdd9df74ff89` | 18996663 | borrower | `USDm.approve(GeneralAdapter1, type(uint256).max)` | Complete | Final allowance: max uint256. |
| 2c. wiTRY approval | `0x19d7bf064ad6dc38928bd2101ddaaa67b827e35e82de03e71c89f88de9f51b91` | 18996749 | borrower | `wiTRY.approve(GeneralAdapter1, type(uint256).max)` | Complete | Final allowance: max uint256. |
| 3. `buy` | `0x95bdbc906d8abfdd5b65e4249d5de7aed7267277a0bb3724969602f081f6d0d6` | 18997024 | borrower | `Bundler3.multicall` | Complete | Exact-output `600 wiTRY`; actual spend `13.9412 USDm`; USDm refund `0.4183`. |
| 4. Open leverage via `sell` | `0xc4207cd66a1e6fb889361bc15fa10057ad450a69505499536109dfa7115c5ac5` | 18997490 | borrower | `Bundler3.multicall` | Complete | Supplied `550 wiTRY`, borrowed `12 USDm`, sold into `516.456 wiTRY`, resupplied. |
| 5. Close via `buyMorphoDebt` | `0xe47cd922008bce658f5d334ef76a6f5822688348b0bfb366d1dd95f06ccf8dff` | 18997754 | borrower | `Bundler3.multicall` | Complete | Bought rounded debt, repaid all borrow shares, withdrew all collateral. |
| 6. Cleanup, if any | n/a | 18997778 | n/a | read-only final check | Complete | No cleanup tx required; final invariant script passed. |

Notes:

- Two forge deployment attempts failed from gas under-estimation before the
  successful `cast send --create` deployment with explicit gas. Failed txs:
  `0x72cfd8241b6b72204b7c2f513115babb1c96eb9dea4625b6f8f0f25383654489`
  and `0x045610dfead3af18ac65f74158054a9edd767503a7253bdb05680ce1bc76d307`.
- Small live World swaps failed during dry-run with custom error `0x7d92b186`.
  The successful live sizes were `600 wiTRY` exact-output for `buy` and
  `12 USDm` exact-input for the open `sell`.
- Open and close transactions were first simulated locally with `forge script`
  and then checked with `eth_call` using the exact Bundler3 calldata before
  broadcasting with `cast send`.

## Snapshot Ledger

### Before Execution

```text
Block: 18996760
WCM adapter: 0xbde192287378Ef3d7f1658c48f48F9e4c4095125

Borrower wallet:
  ETH:   0.000873339549447595
  USDm:  17.866807907270902531
  wiTRY: 527.546938828624657977

Borrower Morpho position:
  supplyShares: 0
  borrowShares: 6606904317320549110443
  expectedDebt: 0.006607010623615862
  collateral:   172.914862401045783208

WCM adapter:
  USDm balance:  0
  wiTRY balance: 0
  USDm router allowance:  0
  wiTRY router allowance: 0

GeneralAdapter1:
  USDm balance:  0
  wiTRY balance: 0

Borrower permissions:
  Morpho authorization for GeneralAdapter1: true
  USDm allowance to GeneralAdapter1: max uint256
  wiTRY allowance to GeneralAdapter1: max uint256
```

### After `buy`

```text
Block: 18997024
Tx: 0x95bdbc906d8abfdd5b65e4249d5de7aed7267277a0bb3724969602f081f6d0d6
amountOut: 600 wiTRY
maxAmountIn: 14.3595 USDm
Actual USDm spent: 13.9412 USDm
Actual borrower wiTRY delta: 600 wiTRY
Refunded USDm: 0.4183 USDm
WCM adapter USDm balance: 0
WCM adapter wiTRY balance: 0
WCM adapter USDm router allowance: 0

Post-buy read-only snapshot at block 18997238:
  Borrower ETH:   0.000872554148413023
  Borrower USDm:  3.925607907270902531
  Borrower wiTRY: 1127.546938828624657977
  Borrower expectedDebt: 0.006607011311761424
  Borrower collateral:   172.914862401045783208
  GeneralAdapter1 USDm balance:  0
  GeneralAdapter1 wiTRY balance: 0
```

### After Open Leverage

```text
Block: 18997490
Tx: 0xc4207cd66a1e6fb889361bc15fa10057ad450a69505499536109dfa7115c5ac5
initialCollateral: 550 wiTRY
borrowAmount: 12 USDm
minAmountOut: 500.962 wiTRY
Actual WCM sell output: 516.456 wiTRY
Actual supplied collateral delta: 1066.456 wiTRY
Debt after open: 12.006607223104269327 USDm
Collateral after open: 1239.370862401045783208 wiTRY
WCM adapter USDm balance: 0
WCM adapter wiTRY balance: 0
WCM adapter USDm router allowance: 0
GeneralAdapter1 USDm balance: 0
GeneralAdapter1 wiTRY balance: 0

Post-open read-only snapshot at block 18997517:
  Borrower ETH:   0.000871072406258566
  Borrower USDm:  3.925607907270902531
  Borrower wiTRY: 577.546938828624657977
  Borrower borrowShares: 12006411916879121024439170
  Borrower expectedDebt: 12.006607223104269327
  Borrower collateral:   1239.370862401045783208
```

### After Full Close

```text
Block: 18997754
Tx: 0xe47cd922008bce658f5d334ef76a6f5822688348b0bfb366d1dd95f06ccf8dff
Debt before close: 12.006607794733071637 USDm
Rounded debt bought: 12.0067 USDm
maxAmountIn: 534.389 wiTRY
Actual wiTRY spent: 518.824 wiTRY
Unused wiTRY returned from WCM adapter: 15.565 wiTRY
Actual Morpho repay: 12.006609078860010592 USDm
Surplus USDm swept to borrower: 0.000090921139989408
Collateral withdrawn to borrower: 1239.370862401045783208 wiTRY

Final check at block 18997778:
  Borrower ETH:   0.000869704874917527
  Borrower USDm:  3.925698828410891939
  Borrower wiTRY: 1298.093801229670441185
  Final borrowShares: 0
  Final expectedDebt: 0
  Final collateral: 0
  WCM adapter USDm balance: 0
  WCM adapter wiTRY balance: 0
  WCM adapter USDm router allowance: 0
  WCM adapter wiTRY router allowance: 0
  GeneralAdapter1 USDm balance: 0
  GeneralAdapter1 wiTRY balance: 0
```

## Stop Conditions

Do not broadcast the next live transaction if any of these are true:

- chain id or WCM adapter immutable validation fails
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
