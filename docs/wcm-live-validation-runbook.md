# WCM Adapter MegaETH Live Validation Runbook

This runbook documents how to reproduce the target-market live-network
validation flow for the WCM Bundler3 adapter on MegaETH. Its recorded proof
transactions are historical evidence from the superseded test-market
deployment only; they do not validate the current PR-head bytecode or target
market.

Use the fork tests in `docs/wcm-adapter-spec.md` before running any live
transaction. Live scripts move real funds.

## Network

```text
Chain: MegaETH
Chain id: 4326
RPC: https://rpc.inverter.network/main/evm/4326
```

Core contracts:

```text
Bundler3:        0xf53D4c8f0f83F697CD6bB303567400cCf411aA63
GeneralAdapter1: 0x74d3cbc721613C8461df92658d0a20dF275Ca31b
Morpho Blue:     0x18120312A7cf44DcfEc6dCe5632a431579ED9100
World Router:    0x94b6706FA26a4F3DCF501Ff25E1e4628B75AdC69
USDm:            0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7
wiTRY:           0x15B271D9012b5820FC42b1c495B4C1e206547De5
```

Target Morpho market:

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

## Actors Used By The Live Script

```text
Borrower:    0x40E4471293383e6e38Cb5Ce1E2C2Cd996742Cc0B
Lender:      0xa12dC13D9F3bE78E786E8cAd76F6289358448745
Liquidation: 0xe6F2c3e1d0378F714272131a5e8250bDa1342987
Executor:    0xA0e8B3794C85DEFdA1f6567Ed3999D00c9da08b0
```

The borrower is the signer and Morpho position owner for the scripted live
validation.

## Environment

Required for all live script commands:

```bash
export RPC_URL_4326=https://rpc.inverter.network/main/evm/4326
export MEGAETH_TEST_BORROWER_PRIVATE_KEY=<borrower private key>
```

Required after deployment:

```bash
export WCM_ADAPTER_ADDRESS=<deployed WcmAdapter>
```

Optional knobs:

```bash
export WCM_SLIPPAGE_BPS=300
export WCM_DEADLINE_TTL=120
export WCM_ALLOW_MAX_APPROVALS=0
export WCM_BUY_WITRY_OUT=600000000000000000000
export WCM_SELL_WITRY_IN=500000000000000000000
export WCM_OPEN_INITIAL_COLLATERAL=1000000000000000000000
export WCM_OPEN_BORROW_USDM=12000000000000000000
```

Safety limits enforced by `script/WcmLiveValidation.s.sol`:

- `block.chainid == 4326`
- World router runtime code hash matches the pinned hash
- live adapter runtime code hash matches `WCM_ADAPTER_CODE_HASH`
- live adapter immutables match the constants in the script
- `WCM_SLIPPAGE_BPS <= 500`
- `0 < WCM_DEADLINE_TTL <= 300`
- no WCM adapter router allowance remains after a swap

## Script Commands

Run from the repository root.

Preflight snapshot:

```bash
forge script script/WcmLiveValidation.s.sol:WcmPreflightLive \
  --rpc-url "$RPC_URL_4326"
```

Deploy:

```bash
forge script script/WcmLiveValidation.s.sol:WcmDeployLive \
  --rpc-url "$RPC_URL_4326" \
  --broadcast \
  -g 400
```

Set `WCM_ADAPTER_ADDRESS` to the deployed address printed by the deploy script.
The script also prints the adapter runtime code hash; update
`WCM_ADAPTER_CODE_HASH` in `script/WcmLiveValidation.s.sol` before moving funds
with a newly deployed adapter.

Prepare borrower authorizations and allowances:

```bash
forge script script/WcmLiveValidation.s.sol:WcmPrepareLive \
  --rpc-url "$RPC_URL_4326" \
  --broadcast \
  -g 400
```

Prove exact-output `buy`:

```bash
forge script script/WcmLiveValidation.s.sol:WcmBuyLive \
  --rpc-url "$RPC_URL_4326" \
  --broadcast \
  -g 400
```

Prove direct exact-input `sell`:

```bash
forge script script/WcmLiveValidation.s.sol:WcmSellLive \
  --rpc-url "$RPC_URL_4326" \
  --broadcast \
  -g 400
```

Open leverage via `sell(USDm, wiTRY, ...)`:

```bash
forge script script/WcmLiveValidation.s.sol:WcmOpenLive \
  --rpc-url "$RPC_URL_4326" \
  --broadcast \
  -g 400
```

Close via `buyMorphoDebt(wiTRY, ...)`:

```bash
forge script script/WcmLiveValidation.s.sol:WcmCloseLive \
  --rpc-url "$RPC_URL_4326" \
  --broadcast \
  -g 400
```

Final invariant check:

```bash
forge script script/WcmLiveValidation.s.sol:WcmFinalCheckLive \
  --rpc-url "$RPC_URL_4326"
```

## Historical Proof Ledger (Superseded Market)

The June 19, 2026 proof below used the former test-market oracle
`0xEebB019a6C66826f8BA8A583177E0dd5feEd0F22` and market id
`0xa8af4e59ea40a30b6867083a2527109285ee7ab6046b4b49888ade1476272767`.
It is retained as historical execution evidence only. Its adapter address and
runtime code hash must not be used for the target market above.

Hardened adapter historically validated on June 19, 2026:

```text
Borrower:              0x40E4471293383e6e38Cb5Ce1E2C2Cd996742Cc0B
Lender:                0xa12dC13D9F3bE78E786E8cAd76F6289358448745
WCM adapter:           0x5752E97738Aa65A2a67e704475124453BEceC2Df
WCM adapter code hash: 0x420c6d7f76359c0c7d0bdfa8261abf00d2e986db45d76881b170d0a5a3e46c9c
World router:          0x94b6706FA26a4F3DCF501Ff25E1e4628B75AdC69
```

| Step | Tx hash | Block | Result |
| --- | --- | ---: | --- |
| Preflight snapshot | n/a | 19054152 | Borrower had no Morpho position; WCM adapter and GeneralAdapter1 were clean; borrower authorization and allowances were present. |
| Deploy hardened adapter | `0xa884967110e3deb9c7dc9ee6a69ad38c3077bc8d526c8d4c873c5735236aea1e` | 19053728 | Adapter deployed at `0x5752E97738Aa65A2a67e704475124453BEceC2Df`; immutables and runtime code hash verified. |
| Fund borrower for `buy` | `0x04fe6774c1f99f22d34d589fcd1c78d6375ab0b28dc4096906b7f1862a1b77f6` | 19054215 | Lender withdrew `12 USDm` to borrower for exact-output proof liquidity. |
| `buy` | `0x891949e64fb223fb62cea16635bf1bcf1fed708b0d9f69aeac5daa1a6949ff98` | 19054399 | Exact-output `600 wiTRY`; borrower wiTRY delta `600 wiTRY`; adapter clean. |
| Direct `sell` | `0x58889bdec621438cf5769b9c64dba28118b795d3999cb4e926dd2c41fdc1de11` | 19054630 | Exact-input `500 wiTRY`; borrower USDm delta `11.5711 USDm`; adapter clean. |
| Return setup liquidity | `0x831fc28c275316a4a3cbd217231f0b754859fb7e39c6d5b55d964dbbefa4153a` | 19054677 | Borrower returned `10 USDm` to lender. |
| Lender approval | `0x3a76c309107ad9a45d552caa9470b12bcf2ba7a7497705b4260c3efe50db7a90` | 19054693 | Lender approved Morpho for restored liquidity. |
| Restore Morpho liquidity | `0xf1a18f73b807d7dcc5d527c94915fe47b38f457a8f6512cc7d5bd2399b22d79b` | 19054707 | Lender supplied `10 USDm` to Morpho. |
| Open leverage via `sell` | `0xc9ff77d7c99e82de0faf6deabc672fe725ea39cabc0655ee4ba0fa3ad537d871` | 19054830 | Supplied `800 wiTRY`, borrowed `12 USDm`, sold USDm into wiTRY, resupplied; debt after open `12 USDm`. |
| Close via `buyMorphoDebt` | `0x1067fc36628c5f183e526804005c1c602ed7add93fb9f9bc78eafead73fff14f` | 19054909 | Bought rounded live debt `12.0001 USDm`, repaid all borrow shares, withdrew all collateral. |
| Final invariant check | n/a | 19054923 | Borrower debt and collateral were zero; WCM adapter and GeneralAdapter1 held zero USDm/wiTRY; WCM router allowances were zero. |

Final snapshot:

```text
Block: 19054923
Borrower wallet:
  ETH:   0.000556416679091707
  USDm:  3.555698222015651947
  wiTRY: 1396.008801229670441185
Borrower Morpho position:
  supplyShares: 0
  borrowShares: 0
  expectedDebt: 0
  collateral: 0
WCM adapter:
  USDm balance: 0
  wiTRY balance: 0
  USDm router allowance: 0
  wiTRY router allowance: 0
GeneralAdapter1:
  USDm balance: 0
  wiTRY balance: 0
```

## Target Deployment Provenance

Before a target-market deployment is accepted, record all of the following in
this runbook from one canonical `main` commit:

- repository commit and clean-tree status
- Solidity and Foundry versions plus every git submodule commit
- creation bytecode hash, constructor arguments and encoded constructor suffix
- deployed address, deployer, nonce, transaction hash, block and successful receipt
- runtime bytecode hash and size
- every immutable getter, including the target oracle, IRM and LLTV
- independently recomputed target market id and live Morpho `idToMarketParams` tuple
- World router runtime code hash
- fork-test and live-validation results
- final zero USDm/wiTRY balances and zero World-router allowances on both adapters

### Target-market deployment record — 2026-07-23

The target-market adapter was deployed from clean canonical `main` after
fetching both remotes:

```text
Repository:             InverterNetwork/bundler3-adapters
Canonical merge:        c7a41c93691e8646021c8de61aed038408799c6f
Reviewed merge parent:  e256afcd862c80e5a6bdb2c905b2c923df07841d
Upstream main ancestor: 9afc2f4ea32c9dbeba2205a485731b8a98f7ae4c
Tree status at signing: clean; HEAD == origin/main
Forge:                  1.7.1 (4072e48705af9d93e3c0f6e29e93b5e9a40caed8)
Solc:                   0.8.28+commit.7893614a
```

Submodule commits:

```text
lib/forge-std                                                     8f24d6b04c92975e0795b5868aa0d783251cdeaa
lib/morpho-blue                                                   8fd926254dd21bc6e5bf0ac401202a58f0ffa612
lib/morpho-blue/lib/forge-std                                     2f112697506eab12d433a65fdc31a639548fe365
lib/morpho-blue/lib/forge-std/lib/ds-test                         e282159d5170298eb2455a6c05280ab5a73a4ef0
lib/openzeppelin-contracts                                        49cd64565aafa5b8f6863bf60a30ef015861614c
lib/openzeppelin-contracts/lib/erc4626-tests                      8b1d7c2ac248c33c3506b1bff8321758943c5e11
lib/openzeppelin-contracts/lib/forge-std                          8f24d6b04c92975e0795b5868aa0d783251cdeaa
lib/openzeppelin-contracts/lib/halmos-cheatcodes                  c0d865508c0fee0a11b97732c5e90f9cad6b65a5
lib/permit2                                                       576f549a7351814f112edcc42f3f8472d1712673
lib/permit2/lib/forge-gas-snapshot                                3c5d52a26169876a144f7690d2f9ef0200eb0791
lib/permit2/lib/forge-gas-snapshot/lib/forge-std                  2c7cbfc6fbede6d7c9e6b17afe997e3fdfe22fef
lib/permit2/lib/forge-gas-snapshot/lib/forge-std/lib/ds-test      9310e879db8ba3ea6d5c6489a579118fd264a3f5
lib/permit2/lib/forge-std                                         66bf4e2c92cf507531599845e8d5a08cc2e3b5bb
lib/permit2/lib/forge-std/lib/ds-test                             e282159d5170298eb2455a6c05280ab5a73a4ef0
lib/permit2/lib/openzeppelin-contracts                            d3ff81b37f3c773b44dcaf5fda212c7176eef0e2
lib/permit2/lib/solmate                                           8d910d876f51c3b2585c9109409d601f600e68e1
lib/permit2/lib/solmate/lib/ds-test                               9310e879db8ba3ea6d5c6489a579118fd264a3f5
```

Reproduced deployment inputs:

```text
WcmAdapter artifact SHA-256:       9bbd00fc52451074f4d42c84dcf15f63ed2ec8c66d74ea5af986ee235378682b
Creation bytecode bytes/hash:      10,988 / 0x25e7f8d817a9c9852e6a9426ba01c952b233606ac4f23c3cb2b6c508a4f47238
Constructor suffix bytes/hash:     320 / 0xf08e43f49f5e446487ea674c5b35c0b04a914776028620f1b6cb85321c39b830
Full target initcode bytes/hash:    11,308 / 0xf6ebae3a357e6f386c31921a7250cf61c9bd00a54fc93754c7715beb33305328
Runtime template bytes/hash:       10,281 / 0x0fec972d519d2bdfa842a5338c318c396e84e4b250990d9affced3d4a8393a0e
Simulated/deployed runtime hash:    0x80b776eae2a28fb16aa05bce7a9d9492df6f9d9dd5493af75070bd22aba9c64c
```

Creation transaction and finality:

```text
Deployer:               0x40E4471293383e6e38Cb5Ce1E2C2Cd996742Cc0B
Deployer nonce:         54
Predicted/deployed:     0xDef91Fe75e81e6B8D363EEaeD13F9ABAE245Fb76
Transaction:            0x62e66eff28fcf106f656c162f89e496f5dfb1993fa8c79f63a9cb94edbbe751b
Block:                  21996422
Block hash:             0xa8d6aa442a0b0c2745b4f0e8378ae8ef9708ea669202ae1e13c275d9770a288a
Block timestamp:        1784793433
Receipt status:         success
Gas used (`gasUsed`):   106632685
Cumulative gas used:    106734277
Effective gas price:    1200000 wei
Execution fee:          127959222000000 wei
L1 fee:                 11083164395 wei
Total fee:              127970305164395 wei
Finalized checkpoint:   21996652
Deployer balance after: 5629332970944398 wei
```

Every immutable getter matched the target constants above: Bundler3, Morpho,
World router, chain id, router code hash, USDm, wiTRY, oracle, IRM and LLTV.
Recomputing the market id from those deployed values produced
`0xa9e57f86cc877f38f2daf080df6638f01afe017eaed59fa3b2f688f6e6d4bf19`.

Post-deployment read-only checks confirmed:

- `nativeTransfer`, `erc20Transfer`, `sell`, `buy` and `buyMorphoDebt` all
  reject a non-Bundler3 caller with `UnauthorizedSender()`;
- native, USDm and wiTRY balances are zero;
- USDm and wiTRY World-router allowances are zero;
- storage slots 0 through 3 are zero;
- the finalized runtime is 10,281 bytes and has hash
  `0x80b776eae2a28fb16aa05bce7a9d9492df6f9d9dd5493af75070bd22aba9c64c`.

The deployment-only step did not update application configuration or
AWS/DynamoDB, and did not run any live swap, leverage or close operation.

Do not reuse the historical adapter address or code hash. Update
`WCM_ADAPTER_CODE_HASH` only from the newly deployed target-market runtime
bytecode, then review that change before moving funds.

## Flashloan Fork Proof

Live validation intentionally did not use flashloans. The PR includes a fork
proof for the flashloan architecture in
`test/fork/WcmAdapterFlashLoanForkTest.sol`.

That test covers:

- `sell` inside `GeneralAdapter1.morphoFlashLoan(USDm, ...)` callback/reenter
- `buy` inside `GeneralAdapter1.morphoFlashLoan(USDm, ...)` callback/reenter
- `buyMorphoDebt` inside `GeneralAdapter1.morphoFlashLoan(wiTRY, ...)`
  callback/reenter
- full close with zero borrower debt and collateral
- zero WCM/GeneralAdapter1 USDm and wiTRY balances
- zero WCM router allowances

Run:

```bash
export RPC_URL_4326=https://rpc.inverter.network/main/evm/4326
forge test --match-path test/fork/WcmAdapterFlashLoanForkTest.sol -vvv
```

## Operational Notes

- Quote World immediately before every live swap and let the script derive
  bounds from that quote plus `WCM_SLIPPAGE_BPS`.
- Keep deadlines short; the script rejects `WCM_DEADLINE_TTL > 300`.
- Use live-proven sizes unless current quotes show better executable depth:
  `600 wiTRY` exact output, `500 wiTRY` exact input, and `12 USDm` exact input.
- Small World swaps can quote but fail execution with custom error
  `0x7d92b186`.
- Use `-g 400` for complex broadcasts. Default Foundry gas estimates were too
  tight for some successful simulations.

## Stop Conditions

Do not broadcast the next live transaction if any of these are true:

- chain id, router code hash, adapter code hash, or adapter immutable validation
  fails
- latest World quote is missing, stale, or worse than the chosen bound
- expected adapter balance after a step is non-zero and cannot be explained
- WCM adapter router allowance remains non-zero after a swap
- borrower Morpho position is not in the expected state after the previous step
- GeneralAdapter1 authorization or token allowance is missing
- a fork simulation of the exact calldata fails at the latest block

## Historical Context

The earlier June 18, 2026 live run used adapter
`0xbde192287378Ef3d7f1658c48f48F9e4c4095125`. It is retained only as
pre-hardening context and is not proof for the current adapter bytecode.
