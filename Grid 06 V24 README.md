# GRID 06 V24 — Controlled Basket Recovery

**Status:** experimental source; must compile and pass MT5 Strategy Tester before demo/live use.

## Design
- Uses the V02 primary-grid concept as the baseline.
- RSI defaults to 43/57 and reads the last closed candle (UseClosedCandleSignal=true).
- MA200 trend-side filter remains enabled.
- Primary grid defaults: 0.01 base lot, maximum 3 primary positions, 6,250-point first gap, 1.30 gap multiplier, primary volume capped at 0.03.
- Stage 1 recovery only; Stage 2 is intentionally disabled.
- Recovery volume is calculated with OrderCalcProfit against a projected basket target and is capped at 0.12 lots. If the projected $2 net basket target cannot be reached within the cap, the recovery trade is skipped.
- Recovery basket exits at the configured net basket target ($2). Otherwise the normal basket trailing begins at $5 and trails by $2.
- Risk controls: 10% equity drawdown from the running equity high-water mark, $35 basket loss cap, 35% projected margin-use cap, and 8-hour basket timeout.
- Position close/open requests check the trade-server retcode. Emergency close attempts are retried on later ticks if exposure remains.
- Requires a hedging account so primary and recovery positions remain individually identifiable.

## Default input preset
| Input | Default |
|---|---:|
| RSI lower / upper | 43 / 57 |
| MA / RSI periods | 200 / 14 |
| Initial lot | 0.01 |
| Max primary orders | 3 |
| First grid gap | 6250 points |
| Gap multiplier | 1.30 |
| Max primary lot | 0.03 |
| Recovery Stage 1 | Enabled |
| Recovery trigger | 6250 points adverse from latest primary entry |
| Recovery target move | $2.50 price movement |
| Recovery max lot | 0.12 |
| Recovery basket loss cap | $35 |
| Basket net target after R1 | $1 |
| Trailing start / distance | $5 / $2 |
| Equity DD limit | 10% from high-water equity |
| Projected margin usage cap | 35% |
| Max basket duration | 8 hours |

## Important limitations
- These values are starting test parameters, not proven optimal settings or a promise of recovery.
- Martingale/grid strategies cannot guarantee recovery if price trends against the basket. If the target requires a recovery lot above the cap, V24 skips the R1 order.
- The basket loss and equity limits are software triggers, not guaranteed fill prices. Gaps, slippage, spread, market closure, or rejected trade requests can cause a different realized loss.
- The current recovery calculation projects the existing basket and R1 at one target price using OrderCalcProfit; swap/commission can still change before actual closure.
- RecoveryTargetMoveUSD means a price move in the instrument quote (e.g. $1.50 in XAUUSD price), not $1.50 account profit.
- MaxBasketHours closes the basket at timeout by default; test this behavior carefully for your broker/session.
- MaxEquityDrawdownPct uses the EA's in-memory high-water equity. Restarting the EA/terminal resets this baseline in the current implementation; persistent high-water storage is not yet implemented.
- This file has not been compiled in MetaEditor in this workflow. Compile errors/warnings and Strategy Tester behavior must be checked before demo use.

## Test plan
1. Compile in MetaEditor; resolve all errors and warnings.
2. Test XAUUSDm M5 with real ticks and the same dates/deposit/spread assumptions as V02/V12.
3. Compare 41/61 baseline vs 43/57, keeping every other input identical.
4. Review net profit, profit factor, equity DD, largest loss, max margin use, recovery frequency, and basket holding duration.
5. Run out-of-sample dates and a demo forward test before any live deployment.
