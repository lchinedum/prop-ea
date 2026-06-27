# XAUUSD Session EA

Dual-platform Expert Advisor for XAUUSD (Gold) based on Asian range sweep and NY displacement strategies.

## Platforms

| Platform | Path | Chart |
|----------|------|-------|
| **MT5** | `MT5/XAUUSD_Session_EA.mq5` | Attach to XAUUSD M5 |
| **cTrader** | `cTrader/XAUUSD_Session_EA.cs` | Attach to XAUUSD M5 |

## Installation

### MT5
1. Copy `XAUUSD_Session_EA.mq5` to `MQL5/Experts/`
2. Compile in MetaEditor (F7)
3. Attach to XAUUSD M5 chart
4. Enable AutoTrading

### cTrader
1. Open cTrader Automate
2. Add `XAUUSD_Session_EA.cs` to your algo project
3. Build and deploy
4. Attach to XAUUSD M5 chart
5. Start the cBot

## Logic Summary

- **Asia:** Range 19:00–23:00 → Sweep detection → Enter on close-back-inside → TP1=midline, TP2=opposite extreme
- **NY:** Sweep of Asia/London/PrevDay levels + strong displacement candle → 50% retrace entry → Fixed RR target
- **Max 2 trades/day** (1 Asia, 1 NY)
- **Position management:** Move SL to BE at midline (Asia), at 1R profit (NY)
- **Risk:** % of balance per trade, daily loss limit, drawdown limit

## Key Inputs

| Input | Default | Description |
|-------|---------|-------------|
| RiskPercent | 0.5 | Risk per trade |
| DailyLossLimitPercent | 3.0 | Disable new entries if breached |
| AsiaRangeStart/End | 19/23 | Asia range build window |
| AsiaTradeWindowEnd | 2 | Asia trade window end (next day) |
| NYStart | 7.5 (MT5) / 7:30 (cTrader) | NY session start |
| SweepBufferPips | 5 | SL buffer beyond sweep |

## Broker Time

Session times use **broker server time**. If your broker uses GMT+2, adjust `BrokerUTCoffset` (MT5) or session hours to match your timezone. Industry standard for gold Asian range is 00:00–06:00 UTC.

## Specs

- `EA-LOGIC-SPECIFICATION.md` — Full logic spec
- `ASIA-LOGIC-COMPARISON.md` — Asian logic vs industry best practices
