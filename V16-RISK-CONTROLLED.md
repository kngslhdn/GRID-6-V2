# GRID 06 V16 — Risk Controlled

## Objective
V16 preserves the V15 primary grid/profit-direction engine while reducing recovery leverage and correcting equity drawdown protection.

## Changes from V15
- MaxEquityLossPercent: **25%** (was 80%).
- Equity DD is measured from the **peak equity high-water mark**, not only current balance.
- PointsForProfitGap: **1500** (was 1000) to reduce over-tight profit pyramiding.
- Recovery 1: multiplier **3.0**, max lot **0.18** (V15 could reach 0.60 lot).
- Recovery 2: multiplier **4.0**, max lot **0.30** (V15 could reach 1.80 lot).
- Trading session: **07:00–21:00**; 22:00 exposure removed from the default session.
- Recovery remains basket-aware and only activates when the basket is negative when `RecoveryOnlyWhenMinus=true`.
- Outside the configured trading session, all EA exposure is closed.

## V15 baseline
Tested on XAUUSDm M5, 2026.08.01–2026.08.18, initial deposit $2,500:
- Net Profit: +$566.25
- Profit Factor: 1.32
- Balance DD: 17.74%
- Equity DD: 39.48%
- Largest profit trade: +$578.16
- Largest loss trade: -$606.54

## V16 validation target
The first validation goal is **not** maximum profit. Target is to keep positive expectancy while reducing equity DD toward **<25%**, reducing dependence on oversized recovery trades, and improving Recovery Factor.

## Recommended test matrix
1. V16 default.
2. MaxEquityLossPercent 20 / 25 / 30.
3. Recovery1MaxLot 0.12 / 0.18 / 0.24.
4. Recovery2MaxLot 0.20 / 0.30 / 0.40.
5. PointsForProfitGap 1500 / 2000 / 2500.

Do not use V16 live before a fresh MT5 real-tick backtest and forward/demo validation.