# GRID 06 V21 — P2 QA / Stress Test Matrix

## Scope
P2 validates V21 under XAUUSD stress conditions after P1 logic fixes.

## Baseline
- Initial lot: 0.02
- Trading hours: OFF (24H)
- Profit direction: ON
- Profit gap: 1000 points
- Max primary orders: 3
- First loss gap: 6250 points
- Loss gap multiplier: 1.30
- Recovery: ON
- Recovery Stage 1: 2.0x, max 0.50 lot
- Recovery Stage 2: OFF
- Recovery hard cap: 2.0x
- Max total lots: 3.0
- Free margin floor: 70%
- Max spread: 500 points
- Daily target: $50
- Equity HWM DD stop: 20%
- News filter: USD high-impact, ±30 minutes

## Test Matrix

| ID | Test | Expected Result | Status |
|---|---|---|---|
| P2-01 | Normal trend | Profit-direction adds only after 1000 points | NOT RUN |
| P2-02 | Fast trend | MaxOrders=3 prevents unlimited primary expansion | NOT RUN |
| P2-03 | Sideways/chop | Loss-grid spacing widens; no rapid-fire entries | NOT RUN |
| P2-04 | Sharp reversal | Recovery only activates after max primary orders + loss + recovery gap | NOT RUN |
| P2-05 | Recovery stress | Recovery multiplier remains capped at 2x and max lot is respected | NOT RUN |
| P2-06 | Spread spike >500 points | New entry/grid/recovery blocked | NOT RUN |
| P2-07 | Free margin <70% | New exposure blocked | NOT RUN |
| P2-08 | Total exposure near 3 lots | Further entries blocked | NOT RUN |
| P2-09 | High-impact USD news | Entry/grid/recovery blocked during ±30m window | NOT RUN |
| P2-10 | News close window | Only if CloseBeforeNews=true, exposure is closed in configured window | NOT RUN |
| P2-11 | Daily target $50 | Basket closes and daily trading locks | NOT RUN |
| P2-12 | EA restart after daily target | Daily lock remains active for same WIB day | NOT RUN |
| P2-13 | EA restart after equity peak | HWM is restored and DD remains measured from persisted peak | NOT RUN |
| P2-14 | Equity DD >=20% | Basket closes and EA enters risk lock | NOT RUN |
| P2-15 | 24H session | No forced close from StartHour/EndHour while UseTradingHour=false | NOT RUN |
| P2-16 | Weekend/reconnect | EA must not create duplicate exposure after reconnect | NOT RUN |
| P2-17 | Rapid ticks | 30s entry cooldown prevents immediate repeated entries | NOT RUN |
| P2-18 | Symbol isolation | Only current symbol + MagicNumber are managed | NOT RUN |

## Required Metrics
Record:
- Net profit
- Max equity drawdown
- Max balance drawdown
- Profit factor
- Recovery frequency
- Maximum simultaneous lots
- Maximum simultaneous positions
- Daily-target hit count
- News-block count
- Risk-stop count
- Spread-block count
- Free-margin-block count

## Acceptance Gate
P2 is not considered PASS until the EA is compiled in MetaEditor and the Strategy Tester produces a report for the matrix above.

No profitability conclusion should be drawn from static source inspection alone.
